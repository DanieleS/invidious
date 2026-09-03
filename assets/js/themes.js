'use strict';

/*
 * Il tema vive in un attributo `data-theme` sull'<html>, non in una classe sul
 * <body>: lo script bloccante in <head> lo ha già scritto prima che venisse
 * disegnato il primo pixel, quindi qui non c'è nessun lampo da rimediare e
 * questo file si occupa solo di cosa succede *dopo* — il pulsante, le altre
 * schede aperte, e il sistema operativo che cambia idea.
 *
 * Senza JavaScript il link punta comunque a /toggle_theme e il server rimanda
 * indietro la pagina con l'attributo giusto: il pulsante funziona lo stesso.
 */

var STORAGE_KEY_THEME = 'dark_mode';
var THEME_DARK = 'dark';
var THEME_LIGHT = 'light';

var root = document.documentElement;
var toggle = document.getElementById('toggle_theme');

function current_theme() {
    return root.getAttribute('data-theme') === THEME_LIGHT ? THEME_LIGHT : THEME_DARK;
}

/** @param {THEME_DARK|THEME_LIGHT} theme */
function set_theme(theme) {
    root.setAttribute('data-theme', theme);
    paint_toggle(theme);
}

/* L'icona mostra dove si va, non dove si è: di notte offre il sole. */
function paint_toggle(theme) {
    if (!toggle) return;
    var use = toggle.querySelector('use');
    if (use) use.setAttribute('href', theme === THEME_DARK ? '#i-sun' : '#i-moon');
}

if (toggle) {
    paint_toggle(current_theme());

    toggle.addEventListener('click', function (e) {
        e.preventDefault();

        var next = current_theme() === THEME_DARK ? THEME_LIGHT : THEME_DARK;
        set_theme(next);

        // Da qui in poi la scelta è esplicita: smetti di seguire il sistema.
        root.removeAttribute('data-theme-auto');
        helpers.storage.set(STORAGE_KEY_THEME, next);

        // Il server tiene la stessa preferenza nel cookie PREFS, così la
        // prossima pagina arriva già con l'attributo giusto e non serve
        // aspettare questo script.
        helpers.xhr('GET', '/toggle_theme?redirect=false', {}, {});
    });
}

/* Un'altra scheda ha cambiato tema: seguila. */
addEventListener('storage', function (e) {
    if (e.key !== STORAGE_KEY_THEME) return;
    var stored = helpers.storage.get(STORAGE_KEY_THEME);
    if (stored === THEME_DARK || stored === THEME_LIGHT) {
        root.removeAttribute('data-theme-auto');
        set_theme(stored);
    }
});

/*
 * Nessuna scelta esplicita: il tema segue il sistema operativo, anche quando
 * cambia mentre la pagina è aperta (il passaggio automatico al tramonto).
 */
if (root.hasAttribute('data-theme-auto') && window.matchMedia) {
    var mql = window.matchMedia('(prefers-color-scheme: light)');
    var follow_os = function (e) {
        if (!root.hasAttribute('data-theme-auto')) return;
        set_theme(e.matches ? THEME_LIGHT : THEME_DARK);
    };

    if (mql.addEventListener) {
        mql.addEventListener('change', follow_os);
    } else if (mql.addListener) {
        // Safari sotto la 14
        mql.addListener(follow_os);
    }
}
