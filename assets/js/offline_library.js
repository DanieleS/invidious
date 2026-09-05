'use strict';

/*
 * offline_library.js — la pagina /offline.
 *
 * Legge l'elenco da IndexedDB e lo disegna. Il server non sa niente di
 * quello che c'è qui dentro: la pagina che arriva dalla rete è un guscio
 * vuoto, e proprio per questo il service worker può servirla anche quando
 * la rete non c'è. È l'unica pagina del sito che funziona davvero offline,
 * ed è dove il service worker manda chi prova a navigare senza connessione.
 */

(function () {
    var labels = JSON.parse(document.getElementById('offline_page_data').textContent);

    var list = document.getElementById('offline_list');
    var empty = document.getElementById('offline_empty');
    var usage = document.getElementById('offline_usage');
    var clearButton = document.getElementById('offline_clear');

    var stage = document.getElementById('offline_stage');
    var media = document.getElementById('offline_media');
    var stageTitle = document.getElementById('offline_stage_title');
    var stageClose = document.getElementById('offline_stage_close');

    if (!window.indexedDB || !window.offlineDB) {
        empty.hidden = false;
        empty.textContent = labels.unsupported;
        return;
    }

    // Gli URL degli oggetti tengono in vita il Blob finché non li revochi.
    // Uno per l'elemento in riproduzione, uno per ogni anteprima disegnata.
    var playing = null;
    var poster = null;
    var thumbnails = [];

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

    function formatDuration(seconds) {
        if (!seconds) return '';

        var parts = [Math.floor(seconds / 60) % 60, Math.floor(seconds % 60)];
        if (seconds >= 3600) parts.unshift(Math.floor(seconds / 3600));

        return parts.map(function (value, index) {
            return index === 0 ? String(value) : ('0' + value).slice(-2);
        }).join(':');
    }

    function element(tag, className, text) {
        var node = document.createElement(tag);
        if (className) node.className = className;
        if (text != null) node.textContent = text;
        return node;
    }

    // Le icone dell'app sono <use> dentro uno sprite già in pagina, e vanno
    // create nel namespace SVG: createElement le farebbe nascere HTML e non
    // disegnerebbero niente.
    function icon(href) {
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        var use = document.createElementNS('http://www.w3.org/2000/svg', 'use');

        svg.setAttribute('class', 'icon icon--sm');
        use.setAttribute('href', href);
        svg.appendChild(use);

        return svg;
    }

    function iconButton(href, title, onClick) {
        var button = element('button');
        button.type = 'button';
        button.title = title;
        button.appendChild(icon(href));
        button.addEventListener('click', onClick);
        return button;
    }

    // ---------------------------------------------------------------------
    // Riproduzione
    // ---------------------------------------------------------------------

    function stopPlaying() {
        media.pause();
        media.removeAttribute('src');
        media.removeAttribute('poster');
        media.load();

        if (playing) URL.revokeObjectURL(playing);
        if (poster) URL.revokeObjectURL(poster);
        playing = null;
        poster = null;
        delete media.dataset.id;

        stage.hidden = true;
    }

    function play(meta) {
        window.offlineDB.media(meta.id).then(function (blob) {
            if (!blob) return;

            media.dataset.id = meta.id;

            if (playing) URL.revokeObjectURL(playing);
            if (poster) URL.revokeObjectURL(poster);
            playing = URL.createObjectURL(blob);
            poster = null;

            // Un file di solo audio in un <video> è un rettangolo nero:
            // mettiamoci l'anteprima, così somiglia a un lettore musicale.
            if (meta.kind === 'audio' && meta.thumb) {
                poster = URL.createObjectURL(meta.thumb);
                media.poster = poster;
            } else {
                media.removeAttribute('poster');
            }

            media.src = playing;
            stageTitle.textContent = meta.title;
            stage.hidden = false;
            stage.scrollIntoView({block: 'start', behavior: 'smooth'});
            media.play().catch(function () {});
        });
    }

    stageClose.addEventListener('click', stopPlaying);

    // ---------------------------------------------------------------------
    // Elenco
    // ---------------------------------------------------------------------

    /*
     * Una scheda uguale alle altre del sito (components/item.ecr): anteprima,
     * comandi sopra l'anteprima, testo sotto. Cambia una cosa sola, ed è il
     * senso della pagina: l'anteprima non porta da nessuna parte, fa partire
     * il video da qui.
     */
    function card(meta) {
        var node = element('div', 'card offline-card');

        // Il riferimento posizionato che vuole `.thumb-actions`. Anche le
        // schede del sito lo dichiarano così, inline.
        var frame = element('div');
        frame.style.position = 'relative';

        var thumb = element('button', 'thumb offline-card__play');
        thumb.type = 'button';
        thumb.title = labels.play;

        if (meta.thumb) {
            var url = URL.createObjectURL(meta.thumb);
            thumbnails.push(url);

            var image = element('img');
            image.src = url;
            image.alt = '';
            thumb.appendChild(image);
        }

        // Senza anteprima resta la cornice vuota di `.thumb`, che è quello
        // che il sito mostra in modalità leggera.

        if (meta.kind === 'audio')
            thumb.appendChild(element('span', 'stamp', labels.audio_only));
        else if (meta.lengthSeconds)
            thumb.appendChild(element('span', 'stamp length', formatDuration(meta.lengthSeconds)));

        thumb.addEventListener('click', function () { play(meta); });
        frame.appendChild(thumb);

        // Esporta ed elimina, sopra l'anteprima: gli stessi comandi che hanno
        // le schede della cronologia e delle playlist.
        var actions = element('div', 'thumb-actions');

        actions.appendChild(iconButton('#i-save', labels.export, function () {
            exportFile(meta);
        }));

        actions.appendChild(iconButton('#i-trash', labels.remove, function () {
            if (!confirm(labels.confirm_remove)) return;
            if (media.dataset.id === meta.id) stopPlaying();
            window.offlineDB.remove(meta.id).then(render);
        }));

        frame.appendChild(actions);

        // Dall'altro lato dell'anteprima le azioni di contesto, come nelle
        // altre schede: qui ce n'è una sola, la pagina del video.
        var tools = element('div', 'card__tools');
        var page = element('a');
        page.href = '/watch?v=' + meta.id;
        page.title = labels.open_page;
        page.appendChild(icon('#i-video'));
        tools.appendChild(page);
        frame.appendChild(tools);

        node.appendChild(frame);

        var body = element('div', 'card__body');
        var text = element('div', 'card__text');

        var title = element('h3', 'card__title', meta.title);
        title.dir = 'auto';
        text.appendChild(title);

        if (meta.author) {
            var by = element('p', 'card__by');
            if (meta.ucid) {
                var link = element('a', null, meta.author);
                link.href = '/channel/' + meta.ucid;
                by.appendChild(link);
            } else {
                by.appendChild(element('span', null, meta.author));
            }
            text.appendChild(by);
        }

        text.appendChild(element('p', 'card__meta',
            [meta.quality, formatBytes(meta.size), new Date(meta.savedAt).toLocaleDateString()]
                .filter(Boolean).join(' · ')));

        body.appendChild(text);
        node.appendChild(body);

        return node;
    }

    // Tira fuori il file dal browser e lo consegna al sistema, così si può
    // spostare, mandare a qualcuno, o guardare con un altro lettore.
    function exportFile(meta) {
        window.offlineDB.media(meta.id).then(function (blob) {
            if (!blob) return;

            var url = URL.createObjectURL(blob);
            var link = document.createElement('a');

            // Nel nome ci va anche l'id: due video possono chiamarsi uguale,
            // e a quel punto non si capisce più quale è quale.
            link.href = url;
            link.download = meta.title.replace(/[\\/:*?"<>|]/g, '_') + '-' + meta.id + '.' + meta.ext;
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);

            setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
        });
    }

    function renderUsage(rows) {
        var saved = rows.reduce(function (total, meta) { return total + (meta.size || 0); }, 0);

        window.offlineDB.estimate().then(function (estimate) {
            var text = labels.used.replace('`x`', formatBytes(saved));

            if (estimate && estimate.quota)
                text += ' · ' + labels.available.replace('`x`',
                    formatBytes(Math.max(0, estimate.quota - (estimate.usage || 0))));

            usage.textContent = text;
        });
    }

    function render() {
        thumbnails.forEach(URL.revokeObjectURL);
        thumbnails = [];

        return window.offlineDB.list().then(function (rows) {
            list.textContent = '';

            rows.forEach(function (meta) { list.appendChild(card(meta)); });

            empty.hidden = rows.length !== 0;
            clearButton.hidden = rows.length === 0;
            renderUsage(rows);
        }).catch(function () {
            empty.hidden = false;
            empty.textContent = labels.unsupported;
        });
    }

    clearButton.addEventListener('click', function () {
        if (!confirm(labels.confirm_clear)) return;
        stopPlaying();
        window.offlineDB.clear().then(render);
    });

    render();
})();
