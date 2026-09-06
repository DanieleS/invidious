'use strict';

/*
 * offline_db.js — il magazzino dei video salvati sul dispositivo.
 *
 * Tutto quello che scarichi finisce in IndexedDB, dentro il browser, e non
 * esce mai di lì: nessuna chiamata al server per sapere cosa hai salvato,
 * nessun elenco tenuto dall'istanza. Se cancelli i dati del sito, i video
 * spariscono con loro.
 *
 * Due archivi separati e non uno solo con dentro tutto:
 *
 *   videos — i metadati (titolo, autore, durata, anteprima). Piccoli, letti
 *            in blocco ogni volta che si apre /offline.
 *   media  — il file vero e proprio, una riga per video.
 *
 * Tenerli divisi vuol dire che disegnare l'elenco non tocca nemmeno i
 * gigabyte che stanno nell'altro archivio.
 */

window.offlineDB = (function () {
    var DB_NAME = 'invidious-offline';
    var DB_VERSION = 1;
    var STORE_META = 'videos';
    var STORE_MEDIA = 'media';

    var connection = null;

    function open() {
        if (connection) return connection;

        connection = new Promise(function (resolve, reject) {
            var request = indexedDB.open(DB_NAME, DB_VERSION);

            request.onupgradeneeded = function () {
                var db = request.result;
                if (!db.objectStoreNames.contains(STORE_META))
                    db.createObjectStore(STORE_META, {keyPath: 'id'});
                if (!db.objectStoreNames.contains(STORE_MEDIA))
                    db.createObjectStore(STORE_MEDIA, {keyPath: 'id'});
            };

            request.onsuccess = function () { resolve(request.result); };
            request.onerror = function () { reject(request.error); };
            request.onblocked = function () { reject(new Error('IndexedDB bloccato')); };
        });

        // Una connessione fallita non deve restare appesa per sempre: al
        // tentativo successivo si riparte da zero.
        connection.catch(function () { connection = null; });

        return connection;
    }

    /* Avvolge una transazione in una promessa che si risolve al commit. */
    function transact(stores, mode, body) {
        return open().then(function (db) {
            return new Promise(function (resolve, reject) {
                var tx = db.transaction(stores, mode);
                var result;

                tx.oncomplete = function () { resolve(result); };
                tx.onerror = function () { reject(tx.error); };
                tx.onabort = function () { reject(tx.error || new Error('transazione annullata')); };

                try {
                    result = body(tx);
                } catch (e) {
                    tx.abort();
                    reject(e);
                }
            });
        });
    }

    /*
     * Una singola lettura. Le transazioni di sola lettura si chiudono da
     * sole quando non hanno più richieste in volo, quindi qui basta
     * aspettare la richiesta invece del commit.
     */
    function read(store, body) {
        return open().then(function (db) {
            var req = body(db.transaction([store], 'readonly').objectStore(store));
            return new Promise(function (resolve, reject) {
                req.onsuccess = function () { resolve(req.result); };
                req.onerror = function () { reject(req.error); };
            });
        });
    }

    return {
        /* Elenco dei metadati, dal più recente al più vecchio. */
        list: function () {
            return read(STORE_META, function (store) {
                return store.getAll();
            }).then(function (rows) {
                return (rows || []).sort(function (a, b) {
                    return (b.savedAt || 0) - (a.savedAt || 0);
                });
            });
        },

        get: function (id) {
            return read(STORE_META, function (store) {
                return store.get(id);
            }).then(function (row) { return row || null; });
        },

        /* Il file vero. Restituisce un Blob, che il browser tiene su disco. */
        media: function (id) {
            return read(STORE_MEDIA, function (store) {
                return store.get(id);
            }).then(function (row) { return row ? row.blob : null; });
        },

        /*
         * Metadati e file insieme, nella stessa transazione: o entrano
         * entrambi o non entra niente. Un video senza file nell'elenco
         * sarebbe peggio di un video che non c'è.
         */
        put: function (meta, blob) {
            return transact([STORE_META, STORE_MEDIA], 'readwrite', function (tx) {
                tx.objectStore(STORE_MEDIA).put({id: meta.id, blob: blob});
                tx.objectStore(STORE_META).put(meta);
            });
        },

        remove: function (id) {
            return transact([STORE_META, STORE_MEDIA], 'readwrite', function (tx) {
                tx.objectStore(STORE_MEDIA).delete(id);
                tx.objectStore(STORE_META).delete(id);
            });
        },

        clear: function () {
            return transact([STORE_META, STORE_MEDIA], 'readwrite', function (tx) {
                tx.objectStore(STORE_MEDIA).clear();
                tx.objectStore(STORE_META).clear();
            });
        },

        /*
         * Spazio occupato e disponibile. Il browser risponde per l'intera
         * origine, quindi il numero comprende anche cache e cookie: va bene
         * lo stesso, quello che interessa è quanto margine resta.
         */
        estimate: function () {
            if (!navigator.storage || !navigator.storage.estimate)
                return Promise.resolve(null);
            return navigator.storage.estimate().catch(function () { return null; });
        },

        /*
         * Chiede al browser di non buttare via i dati quando lo spazio
         * scarseggia. Senza questo, un download da mezzo giga può sparire
         * da solo. Il browser può dire di no, e allora pazienza.
         */
        persist: function () {
            if (!navigator.storage || !navigator.storage.persist)
                return Promise.resolve(false);
            return navigator.storage.persisted().then(function (already) {
                return already || navigator.storage.persist();
            }).catch(function () { return false; });
        },

        /*
         * Scarica un URL in un Blob riferendo l'avanzamento.
         *
         * Il corpo viene letto a pezzi e ripiegato in un Blob ogni tot MB
         * invece di essere tenuto tutto in memoria: un video da 500 MB non
         * deve costare 500 MB di RAM su un telefono. I Blob, a differenza
         * degli array, il browser li appoggia su disco.
         */
        fetchToBlob: function (url, options) {
            options = options || {};

            var FLUSH_AT = 8 * 1024 * 1024;
            var onProgress = options.onProgress || function () {};
            var expected = options.expectedSize || 0;

            return fetch(url, {signal: options.signal, credentials: 'same-origin'}).then(function (response) {
                if (!response.ok)
                    throw new Error('HTTP ' + response.status);

                var type = options.type || response.headers.get('Content-Type') || 'application/octet-stream';
                var declared = parseInt(response.headers.get('Content-Length'), 10);
                var total = expected || (isNaN(declared) ? 0 : declared);

                // Senza ReadableStream niente barra di avanzamento, ma il
                // download funziona comunque.
                if (!response.body || !response.body.getReader) {
                    return response.blob().then(function (blob) {
                        onProgress(blob.size, blob.size);
                        return blob;
                    });
                }

                var reader = response.body.getReader();
                var pending = [];
                var pendingBytes = 0;
                var blob = new Blob([], {type: type});
                var received = 0;

                function fold() {
                    if (!pendingBytes) return;
                    blob = new Blob([blob].concat(pending), {type: type});
                    pending = [];
                    pendingBytes = 0;
                }

                function pump() {
                    return reader.read().then(function (step) {
                        if (step.done) {
                            fold();
                            onProgress(received, received);
                            return blob;
                        }

                        pending.push(step.value);
                        pendingBytes += step.value.byteLength;
                        received += step.value.byteLength;

                        if (pendingBytes >= FLUSH_AT) fold();
                        onProgress(received, total);

                        return pump();
                    });
                }

                return pump().catch(function (error) {
                    reader.cancel().catch(function () {});
                    throw error;
                });
            });
        }
    };
})();
