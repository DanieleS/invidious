'use strict';

/*
 * offline_save.js — le voci «salva per l'offline» nel menu della pagina video.
 *
 * Scarica il flusso scelto passando dal proxy dell'istanza (/latest_version,
 * che rimanda a /videoplayback) e lo mette in IndexedDB. Sono solo formati
 * che si reggono da soli — video con l'audio dentro, oppure la sola traccia
 * audio — quindi quello che finisce in memoria si riproduce così com'è,
 * senza rimettere insieme niente.
 *
 * Le altre voci del menu, quelle che scaricano il file, non passano di qui:
 * sono pulsanti d'invio di un modulo e non hanno bisogno di JavaScript.
 *
 * Il salvataggio vive finché vive la pagina: se la chiudi, si interrompe. È
 * il limite di farlo senza Background Fetch, ed è scritto nel menu mentre va.
 */

(function () {
    var group = document.getElementById('offline_group');
    if (!group) return;

    var data = JSON.parse(document.getElementById('offline_data').textContent);

    var label = document.getElementById('download_label');
    var progress = document.getElementById('offline_progress');
    var bar = progress.querySelector('.offline-bar');
    var status = document.getElementById('offline_status');
    var cancelButton = document.getElementById('offline_cancel');
    var done = document.getElementById('offline_done');
    var doneText = document.getElementById('offline_done_text');
    var deleteButton = document.getElementById('offline_delete');
    var error = document.getElementById('offline_error');
    var errorText = document.getElementById('offline_error_text');

    // Il gruppo nasce nascosto. Se il browser non sa tenersi i video resta
    // nascosto: una voce di menu che non fa niente è peggio di una che non c'è.
    if (!window.indexedDB || !window.offlineDB) return;
    group.hidden = false;

    var idle = label.textContent;
    var running = null; // AbortController del salvataggio in corso

    function formatBytes(bytes) {
        if (!bytes) return '0 B';
        if (bytes < 1024) return bytes + ' B';

        var units = ['KB', 'MB', 'GB', 'TB'];
        var value = bytes;
        var unit = units[0];

        for (var i = 0; i < units.length; i++) {
            unit = units[i];
            value /= 1024;
            if (value < 1024) break;
        }

        return (value < 10 ? value.toFixed(1).replace(/\.0$/, '') : Math.round(value)) + ' ' + unit;
    }

    // ---------------------------------------------------------------------
    // Stati del menu
    // ---------------------------------------------------------------------

    function showIdle() {
        group.hidden = false;
        progress.hidden = true;
        done.hidden = true;
        error.hidden = true;
        label.textContent = idle;
    }

    // Un video alla volta: finché è in memoria le voci spariscono, e per
    // cambiare qualità si toglie e si rifà. Tenerne due copie non servirebbe
    // a niente se non a occupare il doppio.
    function showSaved(meta) {
        group.hidden = true;
        progress.hidden = true;
        error.hidden = true;
        done.hidden = false;
        doneText.textContent = data.saved + ' · ' + meta.quality + ' · ' + formatBytes(meta.size);
        label.textContent = idle;
    }

    function showProgress(received, total) {
        group.hidden = true;
        progress.hidden = false;
        done.hidden = true;
        error.hidden = true;

        var percent = total ? Math.min(100, Math.round(received / total * 100)) : null;

        bar.style.setProperty('--offline-progress', percent === null ? '100%' : percent + '%');
        bar.classList.toggle('offline-bar--unknown', percent === null);

        if (percent === null) {
            bar.removeAttribute('aria-valuenow');
        } else {
            bar.setAttribute('aria-valuenow', percent);
            // Anche a tendina chiusa si deve vedere che sta lavorando.
            label.textContent = idle + ' · ' + percent + '%';
        }

        status.textContent = data.saving + ' ' + formatBytes(received) +
            (total ? ' / ' + formatBytes(total) : '');
    }

    function showError(message) {
        group.hidden = false;
        progress.hidden = true;
        done.hidden = true;
        error.hidden = false;
        label.textContent = idle;
        bar.style.setProperty('--offline-progress', '0%');
        errorText.textContent = data.failed + (message ? ' (' + message + ')' : '');
    }

    // ---------------------------------------------------------------------
    // Salvataggio
    // ---------------------------------------------------------------------

    // L'anteprima serve all'elenco offline: senza rete non la potremmo più
    // chiedere. Se non arriva pazienza, il video resta salvato lo stesso.
    function fetchThumbnail() {
        return fetch('/vi/' + data.id + '/mqdefault.jpg', {credentials: 'same-origin'})
            .then(function (response) { return response.ok ? response.blob() : null; })
            .catch(function () { return null; });
    }

    function save(format) {
        running = new AbortController();
        showProgress(0, format.size);

        // Il proxy dell'istanza: la stessa origine della pagina, quindi
        // niente CORS, e l'URL firmata di YouTube non esce dal server.
        var url = '/latest_version?id=' + encodeURIComponent(data.id) +
            '&itag=' + encodeURIComponent(format.itag) + '&local=true';

        // Lo spazio va chiesto prima di riempirlo: senza, il browser può
        // buttare via il salvataggio quando la memoria stringe.
        window.offlineDB.persist()
            .then(function () {
                return Promise.all([
                    window.offlineDB.fetchToBlob(url, {
                        signal: running.signal,
                        expectedSize: format.size,
                        type: format.mime,
                        onProgress: showProgress
                    }),
                    fetchThumbnail()
                ]);
            })
            .then(function (results) {
                var blob = results[0];

                var meta = {
                    id: data.id,
                    title: data.title,
                    author: data.author,
                    ucid: data.ucid,
                    lengthSeconds: data.lengthSeconds,
                    itag: format.itag,
                    quality: format.label,
                    kind: format.kind,
                    ext: format.ext,
                    mime: format.mime,
                    size: blob.size,
                    savedAt: Date.now(),
                    thumb: results[1]
                };

                return window.offlineDB.put(meta, blob).then(function () { return meta; });
            })
            .then(function (meta) {
                running = null;
                showSaved(meta);
            })
            .catch(function (err) {
                running = null;
                if (err && err.name === 'AbortError') {
                    showIdle();
                    return;
                }
                showError(err && err.message);
            });
    }

    group.querySelectorAll('[data-offline-itag]').forEach(function (item) {
        item.addEventListener('click', function () {
            var itag = item.getAttribute('data-offline-itag');
            var format = data.formats.find(function (fmt) {
                return String(fmt.itag) === itag;
            });
            if (format) save(format);
        });
    });

    cancelButton.addEventListener('click', function () {
        if (running) running.abort();
    });

    deleteButton.addEventListener('click', function () {
        if (!confirm(data.confirm_delete)) return;
        window.offlineDB.remove(data.id).then(showIdle);
    });

    // Il menu deve dire la verità appena si apre la pagina: se il video è già
    // in memoria, si offre di toglierlo, non di riscaricarlo.
    window.offlineDB.get(data.id).then(function (meta) {
        if (meta) showSaved(meta);
    }).catch(function () {});
})();
