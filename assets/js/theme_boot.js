'use strict';

// Questo script è deliberatamente bloccante e deliberatamente caricato in
// <head>: niente viene disegnato finché non è stato valutato, quindi
// l'attributo data-theme è già al suo posto al primo fotogramma e non si vede
// il lampo di tema sbagliato.
//
// Sta in un file invece che dentro la pagina perché la CSP dice
// `script-src 'self'`: inline veniva bloccato, e restava il default del CSS
// per chiunque non avesse la preferenza salvata sul server.
//
// Ordine di precedenza:
// 1. la preferenza salvata sul server (cookie PREFS o account) — già stampata
//    sull'<html> dal template, quindi non tocca nemmeno il DOM;
// 2. la scelta fatta in questa sessione, in localStorage;
// 3. l'impostazione del sistema operativo.
// Senza JavaScript non serve nulla di tutto questo: il caso 1 è già nell'HTML
// e il caso 3 è coperto dalla media query in tokens.css.

(function () {
    var root = document.documentElement;
    var served = root.getAttribute('data-theme');
    if (served === 'dark' || served === 'light') {
        try { localStorage.setItem('dark_mode', served); } catch (e) {}
        return;
    }
    var stored = null;
    try { stored = localStorage.getItem('dark_mode'); } catch (e) {}
    if (stored === 'dark' || stored === 'light') {
        root.setAttribute('data-theme', stored);
        return;
    }
    root.setAttribute('data-theme',
        window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
    root.setAttribute('data-theme-auto', '');
})();
