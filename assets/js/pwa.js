'use strict';

/*
 * pwa.js — registra il service worker e gestisce il pulsante «Installa».
 *
 * Lo script sta in fondo alla pagina e non blocca niente: se il browser non
 * sa cosa sia un service worker, o se il sito gira in HTTP su un dominio non
 * locale (dove i service worker sono vietati), qui non succede semplicemente
 * nulla e il sito resta quello di prima.
 */

(function () {
    var data = document.getElementById('pwa_data');
    var config = data ? JSON.parse(data.textContent) : {};

    // ---------------------------------------------------------------------
    // Registrazione
    // ---------------------------------------------------------------------

    if ('serviceWorker' in navigator) {
        // La versione nella query fa sì che ogni deploy che tocca assets/
        // produca uno script diverso: il browser lo rileva, lo installa e
        // butta le cache vecchie.
        var url = '/sw.js';
        if (config.version) url += '?v=' + encodeURIComponent(config.version);

        addEventListener('load', function () {
            navigator.serviceWorker.register(url, {scope: '/'}).catch(function () {
                // Niente da fare e niente da dire: il sito funziona lo stesso.
            });
        });
    }

    // ---------------------------------------------------------------------
    // Pulsante «Installa»
    // ---------------------------------------------------------------------

    var button = document.getElementById('install_app');
    if (!button) return;

    var deferred = null;

    // Chrome sospende il prompt e ce lo passa qui: lo teniamo da parte e
    // mostriamo il pulsante, perché il prompt si può aprire solo in risposta
    // a un gesto dell'utente.
    addEventListener('beforeinstallprompt', function (event) {
        event.preventDefault();
        deferred = event;
        button.hidden = false;
    });

    button.addEventListener('click', function () {
        if (!deferred) return;
        button.hidden = true;
        deferred.prompt();
        deferred.userChoice.finally(function () { deferred = null; });
    });

    // A installazione avvenuta il pulsante non ha più senso.
    addEventListener('appinstalled', function () {
        deferred = null;
        button.hidden = true;
    });

    // Aperta dall'icona: già installata, stesso discorso.
    if (matchMedia('(display-mode: standalone)').matches) button.hidden = true;
})();
