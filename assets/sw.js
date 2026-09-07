'use strict';

/*
 * sw.js — il service worker che rende Invidious installabile e utilizzabile
 * senza rete.
 *
 * Fa tre cose, e nessun'altra:
 *
 *   1. tiene in cache il guscio dell'app (CSS, JS, font) così l'avvio da
 *      icona è immediato anche con la rete lenta;
 *   2. quando una navigazione fallisce perché sei offline, invece della
 *      pagina di errore del browser mostra /offline, cioè l'elenco dei video
 *      che hai già scaricato: è esattamente quello che serve in quel momento;
 *   3. sta alla larga da tutto il resto.
 *
 * Il punto 3 è il più importante. Il proxy video, le API, i form e le pagine
 * che dipendono dalla sessione non passano da qui: intercettarli vorrebbe
 * dire servire byte vecchi al posto di byte giusti, e su un sito dove ogni
 * URL firmata scade dopo poche ore è un danno, non un'ottimizzazione.
 *
 * La versione arriva dalla query string con cui la pagina registra il worker
 * (/sw.js?v=<commit degli asset>): cambia a ogni deploy che tocca assets/,
 * quindi i nomi delle cache cambiano con lei e le vecchie vengono buttate.
 */

var VERSION = new URL(self.location.href).searchParams.get('v') || 'dev';
var SHELL_CACHE = 'invidious-shell-' + VERSION;

/* La pagina che si vede quando la rete non c'è. */
var OFFLINE_PAGE = '/offline';

/*
 * Il guscio minimo. Sono tutti file versionati dall'URL (?v=...), quindi
 * possono stare in cache a lungo senza rischio di diventare bugiardi.
 * Li salviamo senza query: al momento di rileggerli usiamo ignoreSearch.
 */
var SHELL = [
    OFFLINE_PAGE,
    '/css/tokens.css',
    '/css/base.css',
    '/css/layout.css',
    '/css/components.css',
    '/js/_helpers.js',
    '/js/handlers.js',
    '/js/theme_boot.js',
    '/js/themes.js',
    '/js/pwa.js',
    '/js/offline_db.js',
    '/js/offline_library.js',
    '/fonts/figtree-latin.woff2',
    '/fonts/archivo-latin.woff2',
    '/android-chrome-192x192.png',
    '/android-chrome-512x512.png',
    '/site.webmanifest'
];

/* Prefissi che il worker non deve toccare nemmeno per sbaglio. */
var BYPASS = [
    '/videoplayback',
    '/latest_version',
    '/api/',
    '/companion/',
    '/download',
    '/vi/',
    '/sb/',
    '/ggpht/',
    '/s_p/',
    '/yts/',
    '/feed/webhook'
];

/* Cartelle di soli asset statici, tutti versionati dall'URL. */
var STATIC_DIRS = ['/css/', '/js/', '/fonts/', '/videojs/'];

function isStatic(url) {
    if (SHELL.indexOf(url.pathname) !== -1) return true;
    return STATIC_DIRS.some(function (dir) { return url.pathname.startsWith(dir); });
}

function isBypassed(url) {
    return BYPASS.some(function (prefix) { return url.pathname.startsWith(prefix); });
}

self.addEventListener('install', function (event) {
    event.waitUntil(
        caches.open(SHELL_CACHE)
            // Uno per uno e senza propagare l'errore: se un singolo file non
            // c'è (una build senza videojs, un asset rinominato) l'install non
            // deve fallire in blocco, altrimenti il worker non si attiva mai.
            .then(function (cache) {
                return Promise.all(SHELL.map(function (path) {
                    return cache.add(new Request(path, {cache: 'reload'})).catch(function () {});
                }));
            })
            .then(function () { return self.skipWaiting(); })
    );
});

self.addEventListener('activate', function (event) {
    event.waitUntil(
        caches.keys()
            .then(function (names) {
                return Promise.all(names.map(function (name) {
                    if (name.startsWith('invidious-') && name !== SHELL_CACHE)
                        return caches.delete(name);
                }));
            })
            .then(function () {
                // Navigation preload: mentre il worker si sveglia il browser
                // ha già la richiesta di rete in volo, così la prima
                // navigazione non paga l'avvio del worker.
                if (self.registration.navigationPreload)
                    return self.registration.navigationPreload.enable();
            })
            .then(function () { return self.clients.claim(); })
    );
});

/*
 * Asset statico: rispondi dalla cache e intanto rinfresca. L'URL porta già
 * la versione, quindi la copia in cache non può essere sbagliata; il refresh
 * serve solo a riempire la cache la prima volta.
 */
function staleWhileRevalidate(request) {
    return caches.open(SHELL_CACHE).then(function (cache) {
        return cache.match(request, {ignoreSearch: true}).then(function (cached) {
            var network = fetch(request).then(function (response) {
                if (response && response.ok && response.type === 'basic')
                    cache.put(request, response.clone());
                return response;
            }).catch(function () { return cached; });

            return cached || network;
        });
    });
}

/*
 * Navigazione: prima la rete, sempre. Una pagina di Invidious dipende dalla
 * sessione e dai dati freschi di YouTube, servirla dalla cache sarebbe
 * sbagliato. Se la rete non risponde ripieghiamo su /offline, che è l'unica
 * pagina che funziona davvero senza connessione.
 */
function networkFirstNavigation(event) {
    var request = event.request;
    var isOfflinePage = new URL(request.url).pathname === OFFLINE_PAGE;

    return Promise.resolve(event.preloadResponse)
        .then(function (preloaded) { return preloaded || fetch(request); })
        .then(function (response) {
            // Una risposta che arriva da un redirect (istanza privata che
            // rimanda a /login) non si può nemmeno mettere in cache, e
            // soprattutto non è la pagina che vogliamo.
            if (isOfflinePage && response && response.ok && !response.redirected) {
                var copy = response.clone();
                caches.open(SHELL_CACHE).then(function (cache) {
                    cache.put(OFFLINE_PAGE, copy);
                });
            }
            return response;
        })
        .catch(function () {
            return caches.open(SHELL_CACHE).then(function (cache) {
                return cache.match(request, {ignoreSearch: true}).then(function (cached) {
                    return cached || cache.match(OFFLINE_PAGE);
                });
            });
        });
}

self.addEventListener('fetch', function (event) {
    var request = event.request;

    if (request.method !== 'GET') return;

    var url;
    try {
        url = new URL(request.url);
    } catch (e) {
        return;
    }

    if (url.origin !== self.location.origin) return;
    if (isBypassed(url)) return;

    if (request.mode === 'navigate') {
        event.respondWith(networkFirstNavigation(event));
        return;
    }

    if (isStatic(url)) {
        event.respondWith(staleWhileRevalidate(request));
    }
});
