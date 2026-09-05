'use strict';

/*
 * offline_save.js — il pannello «salva sul dispositivo» nella pagina video.
 *
 * Scarica il flusso scelto passando dal proxy dell'istanza (/latest_version,
 * che rimanda a /videoplayback) e lo mette in IndexedDB. Sono solo formati
 * che si reggono da soli — video con l'audio dentro, oppure la sola traccia
 * audio — quindi quello che finisce in memoria si riproduce così com'è,
 * senza rimettere insieme niente.
 *
 * Il download vive finché vive la pagina: se la chiudi, si interrompe. È il
 * limite di farlo senza Background Fetch, ed è scritto nel pannello.
 */

(function () {
    var container = document.getElementById('offline_widget');
    if (!container) return;

    var data = JSON.parse(document.getElementById('offline_data').textContent);

    var select = document.getElementById('offline_format');
    var saveButton = document.getElementById('offline_save');
    var progress = document.getElementById('offline_progress');
    var bar = progress.querySelector('.offline-bar');
    var status = document.getElementById('offline_status');
    var cancelButton = document.getElementById('offline_cancel');
    var done = document.getElementById('offline_done');
    var doneText = document.getElementById('offline_done_text');
    var deleteButton = document.getElementById('offline_delete');

    // Il pannello nasce nascosto: se siamo qui il JavaScript c'è.
    container.hidden = false;

    if (!window.indexedDB || !window.offlineDB) {
        saveButton.disabled = true;
        status.textContent = data.unsupported;
        progress.hidden = false;
        cancelButton.hidden = true;
        return;
    }

    var running = null; // AbortController del download in corso

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

    function formatFor(itag) {
        return data.formats.find(function (fmt) { return String(fmt.itag) === String(itag); });
    }

    // ---------------------------------------------------------------------
    // Stati del pannello
    // ---------------------------------------------------------------------

    function showIdle() {
        progress.hidden = true;
        done.hidden = true;
        saveButton.hidden = false;
        saveButton.disabled = false;
        select.disabled = false;
        select.parentNode.hidden = false;
    }

    function showSaved(meta) {
        progress.hidden = true;
        saveButton.hidden = true;
        select.parentNode.hidden = true;
        done.hidden = false;
        doneText.textContent = data.saved + ' · ' + meta.quality + ' · ' + formatBytes(meta.size);
    }

    function showProgress(received, total) {
        progress.hidden = false;
        done.hidden = true;
        saveButton.disabled = true;
        select.disabled = true;
        cancelButton.hidden = false;

        var percent = total ? Math.min(100, Math.round(received / total * 100)) : null;

        bar.style.setProperty('--offline-progress', percent === null ? '100%' : percent + '%');
        bar.classList.toggle('offline-bar--unknown', percent === null);
        if (percent === null)
            bar.removeAttribute('aria-valuenow');
        else
            bar.setAttribute('aria-valuenow', percent);

        status.textContent = data.saving + ' ' + formatBytes(received) +
            (total ? ' / ' + formatBytes(total) : '');
    }

    function showError(message) {
        progress.hidden = false;
        done.hidden = true;
        cancelButton.hidden = true;
        saveButton.hidden = false;
        saveButton.disabled = false;
        select.disabled = false;
        bar.style.setProperty('--offline-progress', '0%');
        status.textContent = data.failed + (message ? ' (' + message + ')' : '');
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

    function save() {
        var format = formatFor(select.value);
        if (!format) return;

        running = new AbortController();
        showProgress(0, format.size);

        // Il proxy dell'istanza: la stessa origine della pagina, quindi
        // niente CORS, e l'URL firmata di YouTube non esce dal server.
        var url = '/latest_version?id=' + encodeURIComponent(data.id) +
            '&itag=' + encodeURIComponent(format.itag) + '&local=true';

        // Lo spazio va chiesto prima di riempirlo: senza, il browser può
        // buttare via il download quando la memoria stringe.
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
                var thumb = results[1];

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
                    thumb: thumb
                };

                return window.offlineDB.put(meta, blob).then(function () { return meta; });
            })
            .then(function (meta) {
                running = null;
                showSaved(meta);
            })
            .catch(function (error) {
                running = null;
                if (error && error.name === 'AbortError') {
                    showIdle();
                    return;
                }
                showError(error && error.message);
            });
    }

    saveButton.addEventListener('click', save);

    cancelButton.addEventListener('click', function () {
        if (running) running.abort();
    });

    deleteButton.addEventListener('click', function () {
        if (!confirm(data.confirm_delete)) return;
        window.offlineDB.remove(data.id).then(showIdle);
    });

    // Il pannello deve dire la verità appena si apre la pagina: se il video
    // è già in memoria, si offre di toglierlo, non di riscaricarlo.
    window.offlineDB.get(data.id).then(function (meta) {
        if (meta) showSaved(meta);
    }).catch(function () {});
})();
