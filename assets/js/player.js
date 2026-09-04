'use strict';
var player_data = JSON.parse(document.getElementById('player_data').textContent);
var video_data = JSON.parse(document.getElementById('video_data').textContent);
const CONFIG = JSON.parse(document.getElementById('config').textContent);

var options = {
    liveui: true,
    playbackRates: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0],
    fontPercent: [0.5, 0.75, 1.25, 1.5, 1.75, 2, 3, 4],
    windowOpacity: ['0', '0.5', '1'],
    textOpacity: ['0.5', '1'],
    persistTextTrackSettings: true,
    controlBar: {
        // La barra di scorrimento apre l'elenco perché nel nuovo disegno è una
        // riga a sé, sopra i pulsanti. I quattro menù (sottotitoli, traccia
        // audio, qualità, velocità) restano qui dentro ma il CSS li nasconde:
        // servono solo come motore del pannello unico, che è `ivPills` +
        // `IvPanel`.
        children: [
            'progressControl',
            'playToggle',
            'ivSeekBack',
            'ivSeekForward',
            'volumePanel',
            'currentTimeDisplay',
            'timeDivider',
            'durationDisplay',
            'Spacer',
            'captionsButton',
            'audioTrackButton',
            'playbackRateMenuButton',
            'ivPills',
            'fullscreenToggle'
        ]
    },
    html5: {
        preloadTextTracks: false,
        vhs: {
            overrideNative: true
        }
    }
};

if (player_data.aspect_ratio) {
    options.aspectRatio = player_data.aspect_ratio;
}

var embed_url = new URL(location);
embed_url.searchParams.delete('v');
var short_url = location.origin + '/' + video_data.id + embed_url.search;
embed_url = location.origin + '/embed/' + video_data.id + embed_url.search;

var save_player_pos_key = 'save_player_pos';

videojs.Vhs.xhr.beforeRequest = function(options) {
    // set local if requested not videoplayback
    if (!options.uri.includes('videoplayback')) {
        if (!options.uri.includes('local=true'))
            options.uri += '?local=true';
    }
    return options;
};

// Buffer limits
if (CONFIG.videojs.goal_buffer_length) {
    videojs.Vhs.GOAL_BUFFER_LENGTH = CONFIG.videojs.goal_buffer_length;
}
if (CONFIG.videojs.max_goal_buffer_length) {
    videojs.Vhs.MAX_GOAL_BUFFER_LENGTH = CONFIG.videojs.max_goal_buffer_length;
}

/* ==========================================================================
 * L'interfaccia del lettore
 *
 * Tre pezzi, tutti registrati prima che il lettore nasca perché la barra dei
 * comandi li cerca per nome:
 *
 *   - i pulsanti di salto (10 secondi avanti e indietro);
 *   - le pillole, cioè i comandi scritti a parole (velocità, qualità,
 *     sottotitoli) invece che quattro icone da indovinare;
 *   - il pannello, uno solo, che sostituisce le quattro tendine separate.
 *
 * Il pannello non riscrive la logica di nessuno: i menù originali di video.js
 * e dei plugin restano nella barra, nascosti dal CSS, e il pannello li legge e
 * ci clicca dentro. Così cambiare qualità continua a passare per il codice che
 * lo sa fare (silvermine o http-source-selector, a seconda del flusso), e noi
 * ci mettiamo solo la faccia.
 * ========================================================================== */

var IV_ICONS = {
    // Il triangolo e' centrato nel viewBox (5.5..18.5, centro 12) come lo e'
    // pause (7..17). Prima era 7..20, cioe' spostato di 1,5 unita' a destra:
    // uno scostamento ottico "alla Material", che pero' qui si sommava a un
    // margin-left nel CSS e a un sollevamento del segnaposto, per un totale di
    // 3,4 px a destra e 2 px in alto su un cerchio da 76. Se un giorno si
    // vuole uno scostamento ottico, va messo qui e in un posto solo: cosi'
    // vale per il pulsante grande e per quello della barra insieme, e play e
    // pause continuano a scambiarsi nello stesso punto.
    play: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-fill" d="M5.5 4.5v15l13-7.5z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-fill" d="M7 4.5h3.6v15H7zM13.4 4.5H17v15h-3.6z"/></svg>',
    replay: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M20.4 12a8.4 8.4 0 1 1-2.6-6.1M20.6 3.4v4.2h-4.2"/></svg>',
    back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M12 4.6V1.4L7.6 5.4 12 9.4V6.2a5.6 5.6 0 1 1-5.6 5.6"/></svg>',
    forward: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M12 4.6V1.4l4.4 4-4.4 4V6.2a5.6 5.6 0 1 0 5.6 5.6"/></svg>',
    volume: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M4 9.5h3.4L12 5.5v13L7.4 14.5H4zM15.8 9.4a4 4 0 0 1 0 5.2M18.4 7a7.4 7.4 0 0 1 0 10"/></svg>',
    volumeLow: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M4 9.5h3.4L12 5.5v13L7.4 14.5H4zM15.8 9.4a4 4 0 0 1 0 5.2"/></svg>',
    mute: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M4 9.5h3.4L12 5.5v13L7.4 14.5H4zM16 9.8l5 4.4M21 9.8l-5 4.4"/></svg>',
    captions: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect class="iv-icon-stroke" x="2.5" y="5" width="19" height="14" rx="3.5"/><path class="iv-icon-stroke" d="M10.2 10.6a2.6 2.6 0 1 0 0 2.9M17.6 10.6a2.6 2.6 0 1 0 0 2.9"/></svg>',
    settings: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M3 7.5h9.5M17.5 7.5H21M3 16.5h3.5M11.5 16.5H21"/><circle class="iv-icon-stroke" cx="15" cy="7.5" r="2.6"/><circle class="iv-icon-stroke" cx="9" cy="16.5" r="2.6"/></svg>',
    share: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M8.6 13.4l6.8 3.6M15.4 7l-6.8 3.6"/><circle class="iv-icon-stroke" cx="17.8" cy="5.6" r="2.8"/><circle class="iv-icon-stroke" cx="6.2" cy="12" r="2.8"/><circle class="iv-icon-stroke" cx="17.8" cy="18.4" r="2.8"/></svg>',
    enterFullscreen: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M4 9V4.5h5M15 4.5h5V9M20 15v4.5h-5M9 19.5H4v-4.5"/></svg>',
    exitFullscreen: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M9 4.5V9H4.5M19.5 9H15V4.5M15 19.5V15h4.5M4.5 15H9v4.5"/></svg>',
    check: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M4.5 12.5l5 5 10-11"/></svg>',
    chevron: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M9.5 5l7 7-7 7"/></svg>',
    chevronBack: '<svg viewBox="0 0 24 24" aria-hidden="true"><path class="iv-icon-stroke" d="M14.5 5l-7 7 7 7"/></svg>'
};

/**
 * Mette un'icona SVG dentro il segnaposto che video.js riserva al suo
 * carattere di icone (che il CSS spegne).
 *
 * @param {Element} root Elemento radice in cui cercare
 * @param {String} selector Selettore del comando
 * @param {String} icon Nome dell'icona in IV_ICONS
 */
function iv_set_icon(root, selector, icon) {
    if (!root) return;
    var host = root.querySelector(selector);
    if (!host) return;
    var slot = host.querySelector('.vjs-icon-placeholder');
    if (!slot) {
        slot = document.createElement('span');
        slot.className = 'vjs-icon-placeholder';
        host.insertBefore(slot, host.firstChild);
    }
    if (slot.getAttribute('data-iv-icon') === icon) return;
    slot.setAttribute('data-iv-icon', icon);
    slot.innerHTML = IV_ICONS[icon] || '';
}

/**
 * Legge le voci di un menù di video.js (o di un plugin) direttamente dal DOM.
 *
 * Passare per il DOM invece che per i componenti ci rende indifferenti a come
 * ciascun plugin ha impacchettato il suo menù: a noi serve solo un elenco di
 * voci con un'etichetta, uno stato e un posto dove cliccare.
 *
 * @param {Element} root Elemento del lettore
 * @param {Array<String>} selectors Selettori possibili, in ordine di preferenza
 * @returns {Array<{el: Element, label: String, selected: Boolean}>}
 */
function iv_read_menu(root, selectors) {
    for (var i = 0; i < selectors.length; i++) {
        var host = root.querySelector(selectors[i]);
        if (!host) continue;

        var nodes = host.querySelectorAll('.vjs-menu-item');
        if (!nodes.length) continue;

        var items = [];
        for (var j = 0; j < nodes.length; j++) {
            var node = nodes[j];
            var text = node.querySelector('.vjs-menu-item-text');
            items.push({
                el: node,
                label: (text ? text.textContent : node.textContent).trim(),
                selected: node.classList.contains('vjs-selected')
            });
        }
        return items;
    }
    return [];
}

/** Le sezioni del pannello, ognuna appoggiata al menù originale che la sa fare. */
var IV_SECTIONS = [
    { id: 'quality', title: 'Quality', selectors: ['.vjs-quality-selector', '.vjs-http-source-selector'] },
    { id: 'speed', title: 'Playback Rate', selectors: ['.vjs-playback-rate'] },
    { id: 'captions', title: 'Subtitles', selectors: ['.vjs-captions-button', '.vjs-subs-caps-button'] },
    { id: 'audio', title: 'Audio Track', selectors: ['.vjs-audio-button'] }
];

/**
 * Dice se una voce di menù è una scelta (una qualità, una lingua) oppure una
 * voce di servizio, come «impostazioni sottotitoli», che apre un'altra cosa.
 *
 * @param {Object} item Voce restituita da iv_read_menu
 * @returns {Boolean}
 */
function iv_is_choice(item) {
    return !item.el.classList.contains('vjs-texttrack-settings');
}

/**
 * Restituisce la traccia di sottotitoli accesa, se c'è.
 *
 * @param {Object} p Lettore
 * @returns {TextTrack|null}
 */
function iv_showing_caption(p) {
    var tracks = p.textTracks();
    for (var i = 0; i < tracks.length; i++) {
        var track = tracks[i];
        var is_caption = track.kind === 'captions' || track.kind === 'subtitles';
        if (is_caption && track.mode === 'showing') return track;
    }
    return null;
}

var Component = videojs.getComponent('Component');
var Button = videojs.getComponent('Button');

/* --- Salta indietro / avanti ------------------------------------------- */

/**
 * @param {String} name Nome con cui registrare il componente
 * @param {String} css Classe che distingue avanti da indietro
 * @param {Number} delta Secondi di salto (negativo per indietro)
 * @param {String} icon Nome dell'icona
 */
function iv_register_seek(name, css, delta, icon) {
    var Seek = videojs.extend(Button, {
        constructor: function (p, opts) {
            Button.call(this, p, opts);
            this.controlText((delta > 0 ? 'Forward ' : 'Back ') + Math.abs(delta) + ' seconds');

            var slot = this.el().querySelector('.vjs-icon-placeholder');
            slot.innerHTML = IV_ICONS[icon] +
                '<span class="iv-seek-num">' + Math.abs(delta) + '</span>';
        },

        buildCSSClass: function () {
            return 'vjs-control vjs-button iv-seek ' + css;
        },

        handleClick: function () {
            var p = this.player();
            var step = delta * p.playbackRate();
            var duration = p.duration() || 0;
            var target = p.currentTime() + step;

            p.currentTime(duration ? helpers.clamp(target, 0, duration) : Math.max(0, target));
            iv_toast((delta > 0 ? '+' : '−') + Math.abs(delta) + ' s');
        }
    });

    videojs.registerComponent(name, Seek);
}

iv_register_seek('ivSeekBack', 'iv-seek-back', -10, 'back');
iv_register_seek('ivSeekForward', 'iv-seek-fwd', 10, 'forward');

/* --- Le pillole -------------------------------------------------------- */

var IvPill = videojs.extend(Button, {
    constructor: function (p, opts) {
        Button.call(this, p, opts);
        this.section_ = opts.section;

        this.label_ = document.createElement('span');
        this.label_.className = 'iv-pill-label';
        this.el().appendChild(this.label_);

        if (opts.icon) {
            this.el().querySelector('.vjs-icon-placeholder').innerHTML = IV_ICONS[opts.icon];
        }
        this.controlText(opts.text || '');
    },

    buildCSSClass: function () {
        return 'vjs-control vjs-button iv-pill iv-pill-' + (this.options_.section || 'more');
    },

    /**
     * @param {String} text Etichetta visibile
     * @param {Boolean} on Se il comando è attivo
     */
    setLabel: function (text, on) {
        if (this.label_.textContent !== text) this.label_.textContent = text;
        this.toggleClass('iv-pill-on', !!on);
    },

    handleClick: function () {
        var panel = this.player().getChild('IvPanel');
        if (this.options_.onClick) return this.options_.onClick.call(this);
        if (panel) panel.toggle(this.section_);
    }
});

videojs.registerComponent('IvPill', IvPill);

var IvPills = videojs.extend(Component, {
    constructor: function (p, opts) {
        Component.call(this, p, opts);

        this.rate_ = this.addChild('IvPill', { section: 'speed', text: 'Playback Rate' });
        this.quality_ = this.addChild('IvPill', { section: 'quality', text: 'Quality' });
        this.captions_ = this.addChild('IvPill', {
            section: 'captions',
            icon: 'captions',
            text: 'Subtitles',
            onClick: function () { toggle_captions(); }
        });
        this.more_ = this.addChild('IvPill', { section: null, icon: 'settings', text: 'Settings' });

        this.refresh();

        var self = this;
        var refresh = function () { self.refresh(); };

        // Il selettore di qualità nasce dopo di noi (lo aggiunge la pagina o il
        // plugin): alla prima passata la pillola non trova ancora niente da
        // dire, quindi si riallinea appena il lettore è pronto.
        p.ready(refresh);
        this.on(p, ['ratechange', 'texttrackchange', 'loadedmetadata', 'playing'], refresh);
        p.textTracks().addEventListener('addtrack', refresh);
        p.textTracks().addEventListener('change', refresh);
    },

    createEl: function () {
        return videojs.dom.createEl('div', { className: 'iv-pills' });
    },

    /** Riallinea le etichette allo stato vero del lettore. */
    refresh: function () {
        var p = this.player();

        var rate = p.playbackRate();
        this.rate_.setLabel((Math.round(rate * 100) / 100) + '×', rate !== 1);

        var quality = iv_read_menu(p.el(), IV_SECTIONS[0].selectors);
        var chosen = null;
        for (var i = 0; i < quality.length; i++) {
            if (quality[i].selected) chosen = quality[i];
        }

        if (quality.length) {
            this.quality_.show();
            this.quality_.setLabel(chosen ? chosen.label : '—', false);
        } else {
            this.quality_.hide();
        }

        // Invidious non mette il codice lingua sulle tracce, solo il nome:
        // «Italiano» diventa «ITA», che in una pillola ci sta.
        var track = iv_showing_caption(p);
        var code = '';
        if (track) {
            code = track.language
                ? track.language.slice(0, 2).toUpperCase()
                : (track.label || '').slice(0, 3).toUpperCase();
        }
        this.captions_.setLabel(code, !!track);
    }
});

videojs.registerComponent('IvPills', IvPills);

/* --- Il pannello ------------------------------------------------------- */

var IvPanel = videojs.extend(Component, {
    constructor: function (p, opts) {
        Component.call(this, p, opts);

        var self = this;

        this.outside_ = function (event) {
            if (!self.hasClass('iv-panel-open')) return;
            if (self.el().contains(event.target)) return;
            if (event.target.closest && event.target.closest('.iv-pill')) return;
            self.close();
        };

        this.escape_ = function (event) {
            if (event.key === 'Escape' && self.hasClass('iv-panel-open')) self.close();
        };

        this.on(p, ['fullscreenchange', 'ended'], function () { self.close(); });
    },

    createEl: function () {
        return videojs.dom.createEl('div', { className: 'iv-panel' }, {
            role: 'menu',
            tabindex: '-1'
        });
    },

    /**
     * Ricostruisce il contenuto leggendo i menù originali.
     *
     * Il pannello ha due livelli, come il pannello di un telefono: l'indice
     * dice cosa è impostato adesso (qualità, velocità, sottotitoli, traccia),
     * e si scende dentro una voce sola per cambiarla. Rovesciare in faccia
     * tutte le venti opzioni insieme era esattamente il difetto delle quattro
     * tendine di prima.
     *
     * @param {String|null} section Sezione da aprire; null per l'indice
     */
    render: function (section) {
        this.section_ = section || null;
        this.el().innerHTML = '';

        if (this.section_) this.renderSection_(this.section_);
        else this.renderIndex_();
    },

    /** Disegna l'indice: una riga per impostazione, col valore attuale. */
    renderIndex_: function () {
        var self = this;
        var p = this.player();
        var shown = 0;

        IV_SECTIONS.forEach(function (spec) {
            var items = iv_read_menu(p.el(), spec.selectors);
            var choosable = items.filter(iv_is_choice);
            if (!choosable.length) return;

            var chosen = null;
            choosable.forEach(function (item) { if (item.selected) chosen = item; });

            // I sottotitoli spenti si chiamano «captions off» nel menù di
            // video.js: come valore di una riga che dice già «Sottotitoli»,
            // basta «Off».
            var value = chosen ? chosen.label : '—';
            if (spec.id === 'captions') {
                var track = iv_showing_caption(p);
                value = track ? (track.label || track.language || p.localize('On')) : p.localize('Off');
            }

            var row = self.row_(p.localize(spec.title), value, 'chevron');
            row.addEventListener('click', function () { self.render(spec.id); });
            self.el().appendChild(row);
            shown++;
        });

        if (!shown) {
            self.el().appendChild(videojs.dom.createEl('div', {
                className: 'iv-panel-title',
                textContent: p.localize('No content')
            }));
        }
    },

    /**
     * Disegna una sezione sola: intestazione con il ritorno, poi le voci.
     *
     * @param {String} section
     */
    renderSection_: function (section) {
        var self = this;
        var p = this.player();

        var spec = null;
        IV_SECTIONS.forEach(function (candidate) { if (candidate.id === section) spec = candidate; });
        if (!spec) return this.render(null);

        var items = iv_read_menu(p.el(), spec.selectors);
        if (!items.length) return this.render(null);

        var head = videojs.dom.createEl('button', { className: 'iv-panel-item iv-panel-head' }, { type: 'button' });
        head.insertAdjacentHTML('beforeend', IV_ICONS.chevronBack);
        var title = document.createElement('span');
        title.textContent = p.localize(spec.title);
        head.appendChild(title);
        head.addEventListener('click', function () { self.render(null); });
        this.el().appendChild(head);
        this.el().appendChild(videojs.dom.createEl('div', { className: 'iv-panel-sep' }));

        // Le impostazioni dei sottotitoli (corpo, sfondo) sono un'altra cosa
        // rispetto alla scelta della lingua: vanno in fondo, dopo una riga.
        var choices = items.filter(iv_is_choice);
        var extras = items.filter(function (item) { return !iv_is_choice(item); });

        choices.forEach(function (item) {
            var row = self.row_(item.label, '', 'check');
            row.setAttribute('role', 'menuitemradio');
            row.setAttribute('aria-checked', item.selected ? 'true' : 'false');
            row.addEventListener('click', function () { self.choose_(item); });
            self.el().appendChild(row);
        });

        extras.forEach(function (item) {
            self.el().appendChild(videojs.dom.createEl('div', { className: 'iv-panel-sep' }));
            var row = self.row_(item.label, '', null);
            row.addEventListener('click', function () { self.choose_(item); });
            self.el().appendChild(row);
        });
    },

    /**
     * Una riga del pannello.
     *
     * @param {String} label Testo a sinistra
     * @param {String} value Valore a destra
     * @param {String|null} icon Icona di coda
     * @returns {Element}
     */
    row_: function (label, value, icon) {
        var row = videojs.dom.createEl('button', { className: 'iv-panel-item' }, {
            type: 'button',
            role: 'menuitem'
        });

        var text = document.createElement('span');
        text.textContent = label;
        row.appendChild(text);

        if (value) {
            var val = document.createElement('span');
            val.className = 'iv-panel-value';
            val.textContent = value;
            row.appendChild(val);
        }

        if (icon) row.insertAdjacentHTML('beforeend', IV_ICONS[icon]);
        return row;
    },

    /**
     * Sceglie una voce cliccando dentro il menù originale, che sa cosa fare.
     *
     * @param {Object} item Voce restituita da iv_read_menu
     */
    choose_: function (item) {
        var p = this.player();

        item.el.click();

        // Il cambio di qualità o di traccia non è istantaneo: si rilegge lo
        // stato dopo, non subito.
        p.setTimeout(function () {
            var pills = p.getChild('controlBar').getChild('IvPills');
            if (pills) pills.refresh();
        }, 120);

        this.close();
    },

    /** @param {String|null} section */
    open: function (section) {
        this.render(section || null);
        this.addClass('iv-panel-open');
        document.addEventListener('click', this.outside_, true);
        document.addEventListener('keydown', this.escape_);
    },

    close: function () {
        this.removeClass('iv-panel-open');
        document.removeEventListener('click', this.outside_, true);
        document.removeEventListener('keydown', this.escape_);
    },

    /** @param {String|null} section */
    toggle: function (section) {
        var open = this.hasClass('iv-panel-open');
        var same = this.section_ === section;
        this.section_ = section;

        if (open && same) return this.close();
        if (open) return this.render(section || null);
        this.open(section);
    }
});

videojs.registerComponent('IvPanel', IvPanel);

/* --- Riscontro a schermo ----------------------------------------------- */

var iv_toast_timer = null;

/**
 * Mostra per un attimo cosa è appena cambiato (volume, salto, velocità).
 * Senza questo, sul telefono un doppio tocco non dà nessun segno di essere
 * stato capito.
 *
 * @param {String} text
 */
function iv_toast(text, sticky) {
    if (typeof player === 'undefined' || !player.el()) return;

    var el = player.el().querySelector('.iv-toast');
    if (!el) {
        el = videojs.dom.createEl('div', { className: 'iv-toast' }, { 'aria-live': 'polite' });
        player.el().appendChild(el);
    }

    el.textContent = text;
    el.classList.add('iv-toast-on');

    if (iv_toast_timer) clearTimeout(iv_toast_timer);
    if (!sticky) iv_toast_timer = setTimeout(function () { el.classList.remove('iv-toast-on'); }, 900);
}

/** Chiude il riscontro rimasto aperto per la durata di un gesto. */
function iv_toast_release() {
    if (typeof player === 'undefined' || !player.el()) return;

    var el = player.el().querySelector('.iv-toast');
    if (!el) return;

    if (iv_toast_timer) clearTimeout(iv_toast_timer);
    iv_toast_timer = setTimeout(function () { el.classList.remove('iv-toast-on'); }, 600);
}

// Il selettore di qualità dei flussi progressivi esiste solo quando la pagina
// ha caricato il suo script (cioè quando non siamo in DASH): chiederlo alla
// cieca farebbe fallire la costruzione della barra.
if (videojs.getComponent('QualitySelector')) {
    options.controlBar.children.push('qualitySelector');
}

// I comandi della diretta si aggiungono solo a una diretta: video.js li
// nasconderebbe da solo, ma tenerli fuori quando non servono è più onesto che
// affidarsi a una classe che qualcuno potrebbe sovrascrivere.
if (video_data.live_now) {
    var iv_spacer_at = options.controlBar.children.indexOf('Spacer');
    options.controlBar.children.splice(iv_spacer_at, 0, 'liveDisplay', 'seekToLive');
}

var player = videojs('player', options);

/* --- Montaggio dell'interfaccia ---------------------------------------- */

// Il pannello è figlio del lettore, non della barra: deve galleggiare sopra
// l'immagine sia quando la barra sta sotto (plancia) sia quando ci sta sopra
// (schermo intero, incorporamento).
player.addChild('IvPanel');

/** Ridisegna le icone dei comandi in base allo stato del lettore. */
function iv_paint_icons() {
    var root = player.el();
    if (!root) return;

    var volume_icon = 'volume';
    if (player.muted() || player.volume() === 0) volume_icon = 'mute';
    else if (player.volume() < 0.5) volume_icon = 'volumeLow';

    iv_set_icon(root, '.vjs-big-play-button', 'play');
    iv_set_icon(root, '.vjs-play-control', player.ended() ? 'replay' : (player.paused() ? 'play' : 'pause'));
    iv_set_icon(root, '.vjs-mute-control', volume_icon);
    iv_set_icon(root, '.vjs-fullscreen-control', player.isFullscreen() ? 'exitFullscreen' : 'enterFullscreen');
    iv_set_icon(root, '.vjs-share-control', 'share');
}

player.ready(iv_paint_icons);
player.on(['play', 'pause', 'ended', 'playing', 'loadstart', 'volumechange', 'fullscreenchange'], iv_paint_icons);

// I plugin appendono i loro pulsanti quando sono pronti loro, non quando lo
// siamo noi: si ridipinge anche dopo il primo fotogramma.
player.one('playing', function () { player.setTimeout(iv_paint_icons, 0); });

// Lo spazio sotto il riquadro dev'essere alto quanto la plancia: se la barra
// va a capo su uno schermo stretto, il titolo si sposta invece di finirci
// sotto. Quando la barra torna sopra l'immagine (schermo intero, telefono in
// orizzontale) non si riserva niente.
(function () {
    var shell = document.getElementById('player-container');
    var bar = player.getChild('controlBar');
    if (!shell || !bar) return;

    function sync_dock_height() {
        if (player.isFullscreen()) {
            shell.style.setProperty('--dock-h', '0px');
            return;
        }

        var bar_box = bar.el().getBoundingClientRect();
        var shell_box = shell.getBoundingClientRect();
        var docked = bar_box.height > 0 && bar_box.top >= shell_box.bottom - 4;

        shell.style.setProperty('--dock-h', docked ? Math.round(bar_box.height) + 'px' : '0px');
    }

    player.ready(sync_dock_height);
    player.on(['fullscreenchange', 'playerresize', 'loadedmetadata'], sync_dock_height);
    addEventListener('resize', sync_dock_height);
    addEventListener('orientationchange', sync_dock_height);

    if (window.ResizeObserver) new ResizeObserver(sync_dock_height).observe(bar.el());
})();

// Il riscontro a schermo parte solo dopo il primo avvio: il volume e la
// velocità vengono impostati dalle preferenze appena il lettore nasce, e non
// c'è niente da annunciare per una cosa che l'utente non ha fatto.
var iv_feedback_ready = false;
player.one('play', function () { iv_feedback_ready = true; });

player.on('volumechange', function () {
    if (!iv_feedback_ready) return;

    if (player.muted() || player.volume() === 0) iv_toast(player.localize('Mute'));
    else iv_toast(player.localize('Volume') + ' ' + Math.round(player.volume() * 100) + '%');
});

player.on('error', function () {
    if (video_data.params.quality === 'dash') return;

    var localNotDisabled = (
        !player.currentSrc().includes('local=true') && !video_data.local_disabled
    );
    var reloadMakesSense = (
        player.error().code === MediaError.MEDIA_ERR_NETWORK ||
        player.error().code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED
    );

    if (localNotDisabled) {
        // add local=true to all current sources
        player.src(player.currentSources().map(function (source) {
            source.src += '&local=true';
            return source;
        }));
    } else if (reloadMakesSense) {
        setTimeout(function () {
            console.warn('An error occurred in the player, reloading...');

            // After load() all parameters are reset. Save them
            var currentTime = player.currentTime();
            var playbackRate = player.playbackRate();
            var paused = player.paused();

            player.load();

            if (currentTime > 0.5) currentTime -= 0.5;

            player.currentTime(currentTime);
            player.playbackRate(playbackRate);
            if (!paused) player.play();
        }, 5000);
    }
});

if (video_data.params.quality === 'dash') {
    player.reloadSourceOnError({
        errorInterval: 10
    });
}

/**
 * Function for add time argument to url
 *
 * @param {String} url
 * @param {String} [base]
 * @param {'t' | 'start'} param
 * @returns {URL} urlWithTimeArg
 */
function addCurrentTimeToURL(url, base, param = 't') {
    var urlUsed = new URL(url, base);
    urlUsed.searchParams.delete('start');
    var currentTime = Math.ceil(player.currentTime());
    if (currentTime > 0)
        urlUsed.searchParams.set(param, currentTime);
    else if (urlUsed.searchParams.has('t'))
        urlUsed.searchParams.delete('t');
    return urlUsed;
}

/**
 * Global variable to save the last timestamp (in full seconds) at which the external
 * links were updated by the 'timeupdate' callback below.
 *
 * It is initialized to 5s so that the video will always restart from the beginning
 * if the user hasn't really started watching before switching to the other website.
 */
var timeupdate_last_ts = 5;

/**
 * Callback that updates the timestamp on all external links
 */
player.on('timeupdate', function () {
    // Only update once every second
    let current_ts = Math.floor(player.currentTime());
    if (current_ts != timeupdate_last_ts) timeupdate_last_ts = current_ts;
    else return;

    // YouTube links

    if (!video_data.live_now) {
        let elem_yt_watch = document.getElementById('link-yt-watch');
        if (elem_yt_watch) {
            let base_url_yt_watch = elem_yt_watch.getAttribute('data-base-url');
            elem_yt_watch.href = addCurrentTimeToURL(base_url_yt_watch);
        }

        let elem_yt_embed = document.getElementById('link-yt-embed');
        if (elem_yt_embed) {
            let base_url_yt_embed = elem_yt_embed.getAttribute('data-base-url');
            elem_yt_embed.href = addCurrentTimeToURL(base_url_yt_embed, undefined, 'start');
        }
    }

    // Invidious links

    let domain = window.location.origin;

    let elem_iv_embed = document.getElementById('link-iv-embed');
    if (elem_iv_embed) {
        let base_url_iv_embed = elem_iv_embed.getAttribute('data-base-url');
        elem_iv_embed.href = addCurrentTimeToURL(base_url_iv_embed, domain);
    }

    let elem_iv_other = document.getElementById('link-iv-other');
    if (elem_iv_other) {
        let base_url_iv_other = elem_iv_other.getAttribute('data-base-url');
        elem_iv_other.href = addCurrentTimeToURL(base_url_iv_other, domain);
    }

    let elem_iv_listen = document.getElementById('link-iv-listen');
    if (elem_iv_listen) {
        let base_url_iv_listen = elem_iv_listen.getAttribute('data-base-url');
        elem_iv_listen.href = addCurrentTimeToURL(base_url_iv_listen, domain);
    }
});


var shareOptions = {
    socials: ['fbFeed', 'tw', 'reddit', 'email'],

    get url() {
        return addCurrentTimeToURL(short_url);
    },
    title: player_data.title,
    description: player_data.description,
    image: player_data.thumbnail,
    get embedCode() {
        // Single quotes inside here required. HTML inserted as is into value attribute of input
        return "<iframe id='ivplayer' width='640' height='360' src='" +
            addCurrentTimeToURL(embed_url) + "' style='border:none;'></iframe>";
    }
};

if (location.pathname.startsWith('/embed/')) {
    var overlay_content = '<h1><a rel="noopener noreferrer" target="_blank" href="' + location.origin + '/watch?v=' + video_data.id + '">' + player_data.title + '</a></h1>';
    player.overlay({
        overlays: [
            { start: 'loadstart', content: overlay_content, end: 'playing', align: 'top'},
            { start: 'pause',     content: overlay_content, end: 'playing', align: 'top'}
        ]
    });
}

// Detect mobile users and initialize mobileUi for better UX
// Detection code taken from https://stackoverflow.com/a/20293441

function isMobile() {
  try{ document.createEvent('TouchEvent'); return true; }
  catch(e){ return false; }
}

/**
 * Opzioni dello strato di gesti su tocco.
 *
 * Prima, su telefono, qualità e sottotitoli venivano staccati dalla barra e
 * appiccicati in un angolo sopra l'immagine, con i menù che si aprivano fuori
 * schermo. Adesso non serve più: la barra sta sotto il video e ci sta tutta,
 * quindi al plugin resta solo il suo mestiere, cioè i gesti e la rotazione.
 *
 * @returns {Object} opzioni per videojs-mobile-ui
 */
function iv_mobile_ui_options() {
    return {
        fullscreen: { enterOnRotate: true, exitOnRotate: true, lockOnRotate: true },
        touchControls: { seekSeconds: 5 * player.playbackRate() }
    };
}

if (isMobile()) {
    player.mobileUi(iv_mobile_ui_options());
}

/* ==========================================================================
 * I gesti sul video
 *
 * `videojs-mobile-ui` porta già il doppio tocco per saltare e la rotazione che
 * manda a schermo intero, ma solo su Android e iOS veri e senza modo di
 * spegnerne una parte. Qui si aggiunge quello che non fa, con lo stesso
 * riscontro a schermo del resto del lettore:
 *
 *   - tocco lungo   → doppia velocità finché tieni premuto
 *   - trascinamento orizzontale → cerca, con l'orario di arrivo in vista
 *   - trascinamento verticale   → volume a destra, luminosità a sinistra
 *
 * Il verticale vale solo quando attorno al video non c'è pagina da scorrere,
 * cioè a schermo intero o col telefono in orizzontale. In verticale, sulla
 * pagina di visione, scorrere col dito sul video deve continuare a scorrere la
 * pagina: rubare quel gesto per il volume è il modo più veloce per far
 * arrabbiare qualcuno. Chi decide non è questo file ma il CSS, con
 * `touch-action`: `pan-y` lascia il verticale al browser, `none` lo prende.
 *
 * In modalità VR il trascinamento serve a girare la testa, quindi lì i gesti
 * non si installano affatto.
 * ========================================================================== */

if (isMobile() && !(video_data.vr && video_data.params.vr_mode)) {
    (function () {
        var root = player.el();

        var LONG_PRESS_MS = 450;   // oltre questo, tenere premuto è un comando
        var THRESHOLD = 14;        // px di movimento prima di decidere il verso
        var SWIPE_RANGE = 1.4;     // quanta altezza serve per l'intera scala

        var gesture = null;
        var brightness = 1;

        /**
         * @param {EventTarget} target
         * @returns {Boolean} vero se il tocco è su un comando, non sul video
         */
        function on_controls(target) {
            if (!target || !target.closest) return false;
            return !!target.closest('.vjs-control-bar, .iv-panel, .vjs-menu, .vjs-modal-dialog');
        }

        /**
         * Il verticale è nostro solo dove non c'è pagina da scorrere.
         *
         * @returns {Boolean}
         */
        function owns_vertical() {
            return player.isFullscreen() ||
                window.matchMedia('(orientation: landscape) and (max-height: 480px)').matches;
        }

        /**
         * Quanto video copre un trascinamento da un bordo all'altro: due minuti,
         * o l'intero video se dura meno. Su un video di tre ore un rapporto
         * fisso renderebbe impossibile spostarsi di dieci secondi.
         *
         * @returns {Number} secondi
         */
        function seek_span() {
            var duration = player.duration();
            if (!duration || !isFinite(duration)) return 120;
            return Math.min(duration, 120);
        }

        /** @param {Number} value Luminosità, 1 = quella vera */
        function set_brightness(value) {
            brightness = value;
            root.style.setProperty('--iv-brightness', value.toFixed(2));
            root.classList.toggle('iv-dimmed', Math.abs(value - 1) > 0.01);
        }

        function start_long_press() {
            if (!gesture || gesture.mode) return;

            gesture.mode = 'rate';
            player.playbackRate(2);
            iv_toast('2×', true);
        }

        root.addEventListener('pointerdown', function (e) {
            if (e.pointerType !== 'touch' || !e.isPrimary) return;
            if (on_controls(e.target)) return;

            gesture = {
                x: e.clientX,
                y: e.clientY,
                mode: null,
                time: player.currentTime(),
                volume: player.volume(),
                brightness: brightness,
                rate: player.playbackRate(),
                timer: setTimeout(start_long_press, LONG_PRESS_MS)
            };
        });

        root.addEventListener('pointermove', function (e) {
            if (!gesture || e.pointerType !== 'touch') return;

            var dx = e.clientX - gesture.x;
            var dy = e.clientY - gesture.y;

            // Finché non si è deciso cosa sia, un movimento qualsiasi basta a
            // escludere il tocco lungo: tenere premuto vuol dire stare fermi.
            if (Math.abs(dx) > 4 || Math.abs(dy) > 4) clearTimeout(gesture.timer);

            if (gesture.mode === 'rate') return;

            var box = root.getBoundingClientRect();

            if (!gesture.mode) {
                if (Math.abs(dx) < THRESHOLD && Math.abs(dy) < THRESHOLD) return;

                if (Math.abs(dx) > Math.abs(dy)) {
                    gesture.mode = 'seek';
                } else if (owns_vertical()) {
                    gesture.mode = (gesture.x - box.left) > box.width / 2 ? 'volume' : 'brightness';
                } else {
                    // Il verticale è della pagina: ci togliamo di mezzo.
                    gesture.mode = 'scroll';
                }
            }

            if (gesture.mode === 'scroll') return;

            if (gesture.mode === 'seek') {
                var duration = player.duration() || 0;
                var delta = (dx / box.width) * seek_span();
                var target = helpers.clamp(gesture.time + delta, 0, duration || Infinity);

                gesture.target = target;

                var sign = delta >= 0 ? '+' : '−';
                iv_toast(videojs.formatTime(target, duration) +
                    '  ' + sign + Math.abs(Math.round(delta)) + ' s', true);
                return;
            }

            var shift = -(dy / box.height) * SWIPE_RANGE;

            if (gesture.mode === 'volume') {
                var volume = helpers.clamp(gesture.volume + shift, 0, 1);
                player.muted(false);
                player.volume(volume);
                iv_toast(player.localize('Volume') + ' ' + Math.round(volume * 100) + '%', true);
            } else {
                var value = helpers.clamp(gesture.brightness + shift, 0.25, 1.5);
                set_brightness(value);
                iv_toast(player.localize('Brightness') + ' ' + Math.round(value * 100) + '%', true);
            }
        });

        function finish() {
            if (!gesture) return;

            clearTimeout(gesture.timer);

            if (gesture.mode === 'rate') {
                player.playbackRate(gesture.rate);
                iv_toast_release();
            } else if (gesture.mode === 'seek' && gesture.target !== undefined) {
                player.currentTime(gesture.target);
                iv_toast_release();
            } else if (gesture.mode === 'volume' || gesture.mode === 'brightness') {
                iv_toast_release();
            }

            gesture = null;
        }

        root.addEventListener('pointerup', finish);
        root.addEventListener('pointercancel', finish);

        // La luminosità è una correzione per il buio, non una preferenza: se
        // cambia video torna com'era.
        player.on('loadstart', function () { set_brightness(1); });

        // E torna com'era anche quando si esce da dove il gesto esiste: un
        // video rimasto scuro dentro la pagina, senza nessun comando visibile
        // per rischiararlo, è una trappola.
        function restore_brightness() {
            if (!owns_vertical()) set_brightness(1);
        }

        player.on('fullscreenchange', restore_brightness);
        addEventListener('orientationchange', function () {
            setTimeout(restore_brightness, 120);
        });

        root.classList.add('iv-gestures');
    })();
}

// Enable VR video support
if (!video_data.params.listen && video_data.vr && video_data.params.vr_mode) {
    player.crossOrigin('anonymous');
    switch (video_data.projection_type) {
        case 'EQUIRECTANGULAR':
            player.vr({projection: 'equirectangular'});
        default: // Should only be 'MESH' but we'll use this as a fallback.
            player.vr({projection: 'EAC'});
    }
}

// Add markers
if (video_data.params.video_start > 0 || video_data.params.video_end > 0) {
    var markers = [{ time: video_data.params.video_start, text: 'Start' }];

    if (video_data.params.video_end < 0) {
        markers.push({ time: video_data.length_seconds - 0.5, text: 'End' });
    } else {
        markers.push({ time: video_data.params.video_end, text: 'End' });
    }

    player.markers({
        onMarkerReached: function (marker) {
            if (marker.text === 'End')
                player.loop() ? player.markers.prev('Start') : player.pause();
        },
        markers: markers
    });

    player.currentTime(video_data.params.video_start);
}

player.volume(video_data.params.volume / 100);
player.playbackRate(video_data.params.speed);

/**
 * Method for getting the contents of a cookie
 *
 * @param {String} name Name of cookie
 * @returns {String|null} cookieValue
 */
function getCookieValue(name) {
    var cookiePrefix = name + '=';
    var matchedCookie = document.cookie.split(';').find(function (item) {return item.includes(cookiePrefix);});
    if (matchedCookie)
        return matchedCookie.replace(cookiePrefix, '');
    return null;
}

/**
 * Method for updating the 'PREFS' cookie (or creating it if missing)
 *
 * @param {number} newVolume New volume defined (null if unchanged)
 * @param {number} newSpeed New speed defined (null if unchanged)
 */
function updateCookie(newVolume, newSpeed) {
    var volumeValue = newVolume !== null ? newVolume : video_data.params.volume;
    var speedValue = newSpeed !== null ? newSpeed : video_data.params.speed;

    var cookieValue = getCookieValue('PREFS');
    var cookieData;

    if (cookieValue !== null) {
        var cookieJson = JSON.parse(decodeURIComponent(cookieValue));
        cookieJson.volume = volumeValue;
        cookieJson.speed = speedValue;
        cookieData = encodeURIComponent(JSON.stringify(cookieJson));
    } else {
        cookieData = encodeURIComponent(JSON.stringify({ 'volume': volumeValue, 'speed': speedValue }));
    }

    // Set expiration in 2 year
    var date = new Date();
    date.setFullYear(date.getFullYear() + 2);

    var ipRegex = /^((\d+\.){3}\d+|[\dA-Fa-f]*:[\d:A-Fa-f]*:[\d:A-Fa-f]+)$/;
    var domainUsed = location.hostname;

    // Fix for a bug in FF where the leading dot in the FQDN is not ignored
    if (domainUsed.charAt(0) !== '.' && !ipRegex.test(domainUsed) && domainUsed !== 'localhost')
        domainUsed = '.' + location.hostname;

    var secure = location.protocol.startsWith("https") ? " Secure;" : "";

    document.cookie = 'PREFS=' + cookieData + '; SameSite=Lax; path=/; domain=' +
        domainUsed + '; expires=' + date.toGMTString() + ';' + secure;

    video_data.params.volume = volumeValue;
    video_data.params.speed = speedValue;
}

player.on('ratechange', function () {
    updateCookie(null, player.playbackRate());
    if (isMobile()) {
        player.mobileUi(iv_mobile_ui_options());
    }
    if (iv_feedback_ready) iv_toast((Math.round(player.playbackRate() * 100) / 100) + '\u00d7');
});

player.on('volumechange', function () {
    updateCookie(Math.ceil(player.volume() * 100), null);
});

player.on('waiting', function () {
    if (player.playbackRate() > 1 && player.liveTracker.isLive() && player.liveTracker.atLiveEdge()) {
        console.info('Player has caught up to source, resetting playbackRate');
        player.playbackRate(1);
    }
});

if (video_data.premiere_timestamp && Math.round(new Date() / 1000) < video_data.premiere_timestamp) {
    player.getChild('bigPlayButton').hide();
}

if (video_data.params.save_player_pos) {
    const url = new URL(location);
    const hasTimeParam = url.searchParams.has('t');
    const rememberedTime = get_video_time();
    let lastUpdated = 0;

    if(!hasTimeParam) {
      if (rememberedTime >= video_data.length_seconds - 20)
        set_seconds_after_start(0);
      else
        set_seconds_after_start(rememberedTime);
    }

    player.on('timeupdate', function () {
        const raw = player.currentTime();
        const time = Math.floor(raw);

        if(lastUpdated !== time && raw <= video_data.length_seconds - 15) {
            save_video_time(time);
            lastUpdated = time;
        }
    });
}
else remove_all_video_times();

if (video_data.params.autoplay) {
    var bpb = player.getChild('bigPlayButton');
    bpb.hide();

    player.ready(function () {
        new Promise(function (resolve, reject) {
            setTimeout(function () {resolve(1);}, 1);
        }).then(function (result) {
            var promise = player.play();

            if (promise !== undefined) {
                promise.then(function () {
                }).catch(function (error) {
                    bpb.show();
                });
            }
        });
    });
}

if (!video_data.params.listen && video_data.params.quality === 'dash') {
    player.httpSourceSelector();

    if (video_data.params.quality_dash !== 'auto') {
        player.ready(function () {
            player.on('loadedmetadata', function () {
                const qualityLevels = Array.from(player.qualityLevels()).sort(function (a, b) {return a.height - b.height;});
                let targetQualityLevel;
                switch (video_data.params.quality_dash) {
                    case 'best':
                        targetQualityLevel = qualityLevels.length - 1;
                        break;
                    case 'worst':
                        targetQualityLevel = 0;
                        break;
                    default:
                        const targetHeight = parseInt(video_data.params.quality_dash);
                        for (let i = 0; i < qualityLevels.length; i++) {
                            if (qualityLevels[i].height <= targetHeight)
                                targetQualityLevel = i;
                            else
                                break;
                        }
                }
                qualityLevels.forEach(function (level, index) {
                    level.enabled = (index === targetQualityLevel);
                });
            });
        });
    }
}

player.vttThumbnails({
    src: '/api/v1/storyboards/' + video_data.id + '?height=90',
    showTimestamp: true
});

// Enable annotations
if (!video_data.params.listen && video_data.params.annotations) {
    addEventListener('load', function (e) {
        addEventListener('__ar_annotation_click', function (e) {
            const url = e.detail.url,
                  target = e.detail.target,
                  seconds = e.detail.seconds;
            var path = new URL(url);

            if (path.href.startsWith('https://www.youtube.com/watch?') && seconds) {
                path.search += '&t=' + seconds;
            }

            path = path.pathname + path.search;

            if (target === 'current') {
                location.href = path;
            } else if (target === 'new') {
                open(path, '_blank', 'noopener,noreferrer');
            }
        });

        helpers.xhr('GET', '/api/v1/annotations/' + video_data.id, {
            responseType: 'text',
            timeout: 60000
        }, {
            on200: function (response) {
                var video_container = document.getElementById('player');
                videojs.registerPlugin('youtubeAnnotationsPlugin', youtubeAnnotationsPlugin);
                if (player.paused()) {
                    player.one('play', function (event) {
                        player.youtubeAnnotationsPlugin({ annotationXml: response, videoContainer: video_container });
                    });
                } else {
                    player.youtubeAnnotationsPlugin({ annotationXml: response, videoContainer: video_container });
                }
            }
        });

    });
}

function change_volume(delta) {
    const curVolume = player.volume();
    let newVolume = curVolume + delta;
    newVolume = helpers.clamp(newVolume, 0, 1);
    player.volume(newVolume);
}

function toggle_muted() {
    player.muted(!player.muted());
}

function skip_seconds(delta) {
    const duration = player.duration();
    const curTime = player.currentTime();
    let newTime = curTime + delta;
    newTime = helpers.clamp(newTime, 0, duration);
    player.currentTime(newTime);
}

function set_seconds_after_start(delta) {
    const start = video_data.params.video_start;
    player.currentTime(start + delta);
}

function save_video_time(seconds) {
    const all_video_times = get_all_video_times();
    all_video_times[video_data.id] = seconds;
    helpers.storage.set(save_player_pos_key, all_video_times);
}

function get_video_time() {
    return get_all_video_times()[video_data.id] || 0;
}

function get_all_video_times() {
    return helpers.storage.get(save_player_pos_key) || {};
}

function remove_all_video_times() {
    helpers.storage.remove(save_player_pos_key);
}

function set_time_percent(percent) {
    const duration = player.duration();
    const newTime = duration * (percent / 100);
    player.currentTime(newTime);
}

function play()  { player.play(); }
function pause() { player.pause(); }
function stop()  { player.pause(); player.currentTime(0); }
function toggle_play() { player.paused() ? play() : pause(); }

const toggle_captions = (function () {
    let toggledTrack = null;

    function bindChange(onOrOff) {
        player.textTracks()[onOrOff]('change', function (e) {
            toggledTrack = null;
        });
    }

    // Wrapper function to ignore our own emitted events and only listen
    // to events emitted by Video.js on click on the captions menu items.
    function setMode(track, mode) {
        bindChange('off');
        track.mode = mode;
        setTimeout(function () {
            bindChange('on');
        }, 0);
    }

    bindChange('on');
    return function () {
        if (toggledTrack !== null) {
            if (toggledTrack.mode !== 'showing') {
                setMode(toggledTrack, 'showing');
            } else {
                setMode(toggledTrack, 'disabled');
            }
            toggledTrack = null;
            return;
        }

        // Used as a fallback if no captions are currently active.
        // TODO: Make this more intelligent by e.g. relying on browser language.
        let fallbackCaptionsTrack = null;

        const tracks = player.textTracks();
        for (let i = 0; i < tracks.length; i++) {
            const track = tracks[i];
            if (track.kind !== 'captions') continue;

            if (fallbackCaptionsTrack === null) {
                fallbackCaptionsTrack = track;
            }
            if (track.mode === 'showing') {
                setMode(track, 'disabled');
                toggledTrack = track;
                return;
            }
        }

        // Fallback if no captions are currently active.
        if (fallbackCaptionsTrack !== null) {
            setMode(fallbackCaptionsTrack, 'showing');
            toggledTrack = fallbackCaptionsTrack;
        }
    };
})();

// For real-time updates to captions (if currently showing)
function update_captions() {
    if (document.body.querySelector('.vjs-text-track-cue')) {
        toggle_captions(); toggle_captions();
    }
}

function toggle_fullscreen() {
    player.isFullscreen() ? player.exitFullscreen() : player.requestFullscreen();
}

function increase_playback_rate(steps) {
    const maxIndex = options.playbackRates.length - 1;
    const curIndex = options.playbackRates.indexOf(player.playbackRate());
    let newIndex = curIndex + steps;
    newIndex = helpers.clamp(newIndex, 0, maxIndex);
    player.playbackRate(options.playbackRates[newIndex]);
}

function increase_caption_size(steps) {
    const maxIndex = options.fontPercent.length - 1;
    const fontPercent = player.textTrackSettings.getValues().fontPercent || 1.25;
    const curIndex = options.fontPercent.indexOf(fontPercent);
    let newIndex = curIndex + steps;
    newIndex = helpers.clamp(newIndex, 0, maxIndex);
    player.textTrackSettings.setValues({ fontPercent: options.fontPercent[newIndex] });
    update_captions();
}

function toggle_caption_window() {
    const numOptions = options.windowOpacity.length;
    const windowOpacity = player.textTrackSettings.getValues().windowOpacity || '0';
    const curIndex = options.windowOpacity.indexOf(windowOpacity);
    const newIndex = (curIndex + 1) % numOptions;
    player.textTrackSettings.setValues({ windowOpacity: options.windowOpacity[newIndex] });
    update_captions();
}

function toggle_caption_opacity() {
    const numOptions = options.textOpacity.length;
    const textOpacity = player.textTrackSettings.getValues().textOpacity || '1';
    const curIndex = options.textOpacity.indexOf(textOpacity);
    const newIndex = (curIndex + 1) % numOptions;
    player.textTrackSettings.setValues({ textOpacity: options.textOpacity[newIndex] });
    update_captions();
}

addEventListener('keydown', function (e) {
    if (e.target.tagName.toLowerCase() === 'input') {
        // Ignore input when focus is on certain elements, e.g. form fields.
        return;
    }
    // See https://github.com/ctd1500/videojs-hotkeys/blob/bb4a158b2e214ccab87c2e7b95f42bc45c6bfd87/videojs.hotkeys.js#L310-L313
    const isPlayerFocused = false
        || e.target === document.querySelector('.video-js')
        || e.target === document.querySelector('.vjs-tech')
        || e.target === document.querySelector('.iframeblocker')
        || e.target === document.querySelector('.vjs-control-bar')
        ;
    let action = null;

    const code = e.keyCode;
    const decoratedKey =
        e.key
        + (e.altKey ? '+alt' : '')
        + (e.ctrlKey ? '+ctrl' : '')
        + (e.metaKey ? '+meta' : '')
        ;
    switch (decoratedKey) {
        case ' ':
        case 'k':
        case 'MediaPlayPause':
            action = toggle_play;
            break;

        case 'MediaPlay':  action = play; break;
        case 'MediaPause': action = pause; break;
        case 'MediaStop':  action = stop; break;

        case 'ArrowUp':
            if (isPlayerFocused) action = change_volume.bind(this, 0.1);
            break;
        case 'ArrowDown':
            if (isPlayerFocused) action = change_volume.bind(this, -0.1);
            break;

        case 'm':
            action = toggle_muted;
            break;

        case 'ArrowRight':
        case 'MediaFastForward':
            action = skip_seconds.bind(this, 5 * player.playbackRate());
            break;
        case 'ArrowLeft':
        case 'MediaTrackPrevious':
            action = skip_seconds.bind(this, -5 * player.playbackRate());
            break;
        case 'l':
            action = skip_seconds.bind(this, 10 * player.playbackRate());
            break;
        case 'j':
            action = skip_seconds.bind(this, -10 * player.playbackRate());
            break;

        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
            // Ignore numpad numbers
            if (code > 57) break;

            const percent = (code - 48) * 10;
            action = set_time_percent.bind(this, percent);
            break;

        case 'c': action = toggle_captions; break;
        case 'f': action = toggle_fullscreen; break;

        case 'N':
        case 'MediaTrackNext':
            action = next_video;
            break;
        case 'P':
        case 'MediaTrackPrevious':
            // TODO: Add support to play back previous video.
            break;

        // TODO: More precise step. Now FPS is taken equal to 29.97
        // Common FPS: https://forum.videohelp.com/threads/81868#post323588
        // Possible solution is new HTMLVideoElement.requestVideoFrameCallback() https://wicg.github.io/video-rvfc/
        case ',': action = function () { pause(); skip_seconds(-1/29.97); }; break;
        case '.': action = function () { pause(); skip_seconds( 1/29.97); }; break;

        case '>': action = increase_playback_rate.bind(this, 1); break;
        case '<': action = increase_playback_rate.bind(this, -1); break;

        case '=': action = increase_caption_size.bind(this, 1); break;
        case '-': action = increase_caption_size.bind(this, -1); break;

        case 'w': action = toggle_caption_window; break;
        case 'o': action = toggle_caption_opacity; break;

        default:
            console.info('Unhandled key down event: %s:', decoratedKey, e);
            break;
    }

    if (action) {
        e.preventDefault();
        action();
    }
}, false);

// Add support for controlling the player volume by scrolling over it. Adapted from
// https://github.com/ctd1500/videojs-hotkeys/blob/bb4a158b2e214ccab87c2e7b95f42bc45c6bfd87/videojs.hotkeys.js#L292-L328
(function () {
    const pEl = document.getElementById('player');

    var volumeHover = false;
    var volumeSelector = pEl.querySelector('.vjs-volume-menu-button') || pEl.querySelector('.vjs-volume-panel');
    if (volumeSelector !== null) {
        volumeSelector.onmouseover = function () { volumeHover = true; };
        volumeSelector.onmouseout = function () { volumeHover = false; };
    }

    function mouseScroll(event) {
        // When controls are disabled, hotkeys will be disabled as well
        if (!player.controls() || !volumeHover) return;

        event.preventDefault();
        var wheelMove = event.wheelDelta || -event.detail;
        var volumeSign = Math.sign(wheelMove);

        change_volume(volumeSign * 0.05); // decrease/increase by 5%
    }

    player.on('mousewheel', mouseScroll);
    player.on('DOMMouseScroll', mouseScroll);
}());

// Since videojs-share can sometimes be blocked, we defer it until last
if (player.share) player.share(shareOptions);

// show the preferred caption by default
if (player_data.preferred_caption_found) {
    player.ready(function () {
        if (!video_data.params.listen && video_data.params.quality === 'dash') {
            // play.textTracks()[0] on DASH mode is showing some debug messages
            player.textTracks()[1].mode = 'showing';
        } else {
            player.textTracks()[0].mode = 'showing';
        }
    });
}

// Safari audio double duration fix
if (navigator.vendor === 'Apple Computer, Inc.' && video_data.params.listen) {
    player.on('loadedmetadata', function () {
        player.on('timeupdate', function () {
            if (player.remainingTime() < player.duration() / 2 && player.remainingTime() >= 2) {
                player.currentTime(player.duration() - 1);
            }
        });
    });
}

// Safari screen timeout on looped video playback fix
if (navigator.vendor === 'Apple Computer, Inc.' && !video_data.params.listen && video_data.params.video_loop) {
    player.loop(false);
    player.ready(function () {
        player.on('ended', function () {
            player.currentTime(0);
            player.play();
        });
    });
}

// Watch on Invidious link
if (location.pathname.startsWith('/embed/')) {
    let watch_on_invidious_button = new Button(player);

    // Create hyperlink for current instance
    var redirect_element = document.createElement('a');
    redirect_element.setAttribute('href', location.pathname.replace('/embed/', '/watch?v='));
    redirect_element.appendChild(document.createTextNode('Invidious'));

    watch_on_invidious_button.el().appendChild(redirect_element);
    watch_on_invidious_button.addClass('watch-on-invidious');

    var cb = player.getChild('ControlBar');
    cb.addChild(watch_on_invidious_button);
}

// Adatta il riquadro al rapporto reale del video.
//
// Il CSS parte da 16:9 perché la pagina va disegnata prima di sapere che video
// è, ma un verticale o un 4:3 in una cornice 16:9 resta incorniciato di nero.
// Appena i metadati arrivano sappiamo le dimensioni vere e le passiamo al CSS
// come rapporto; da lì la cornice e il limite di larghezza si ricalcolano.
(function () {
    var shell = document.getElementById('player-container');
    if (!shell) return;

    function sync_aspect_ratio() {
        var width = player.videoWidth();
        var height = player.videoHeight();

        // In modalità solo audio non c'è nessun fotogramma da misurare:
        // meglio tenere il 16:9 di partenza che una cornice di altezza zero.
        if (!width || !height) return;

        shell.style.setProperty('--ar', (width / height).toFixed(4));
    }

    player.ready(sync_aspect_ratio);
    player.on('loadedmetadata', sync_aspect_ratio);
})();

addEventListener('DOMContentLoaded', function () {
    // Save time during redirection on another instance
    const changeInstanceLink = document.querySelector('#watch-on-another-invidious-instance > a');
    if (changeInstanceLink) changeInstanceLink.addEventListener('click', function () {
        changeInstanceLink.href = addCurrentTimeToURL(changeInstanceLink.href);
    });
});
