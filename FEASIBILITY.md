# Analisi di fattibilità — OIDC, ammodernamento UI, modalità Kids

Analisi sul codebase alla revisione `b3a3f3a`. Nessuna implementazione: solo
fattibilità, punti di innesto, costi e rischi.

## 0. Baseline architetturale

| Aspetto | Stato |
|---|---|
| Stack | Crystal + Kemal, 127 file `.cr`, 42 template ECR server-side |
| Persistenza | PostgreSQL, migrazioni versionate additive (`0001`…`0010`) |
| Sessioni | tabella `session_ids` (SID random 32B) + cookie `SID`, bcrypt su `users.password` |
| API auth | schema separato: token HMAC firmati (`v1:` prefix), `AuthHandler` su `/api/v1/auth/*` |
| Frontend | zero framework JS, zero build step CSS, Pure.css + Ionicons |
| Dipendenze | 6 shard in totale, scelta deliberatamente minimale |
| Test | 15 file spec, nessun test di route/integrazione, nessun visual regression |

Due punti chiave che condizionano tutto il resto:

1. **Il livello sessione è già disaccoppiato dalle credenziali.** Il login fa
   tre cose (`src/invidious/routes/login.cr:57-65`): genera un SID random, lo
   inserisce con `SessionIDs.insert(sid, email)`, imposta il cookie. Nient'altro
   nel codebase sa *come* ti sei autenticato.
2. **Le rotte media non hanno contesto utente, per design.**
   `BeforeAll.handle` (`src/invidious/routes/before_all.cr:70-81`) fa `return`
   prima della lookup di sessione per i prefissi `/videoplayback`,
   `/latest_version`, `/api/manifest/`, `/companion/`, `/vi/`, `/sb/`. Questo
   è il vincolo centrale della modalità Kids.

---

## 1. OIDC auth

**Verdetto: fattibile, effort medio. Il rischio è nelle dipendenze, non nell'architettura.**

### Perché è architetturalmente facile

Un callback OIDC deve fare esattamente le stesse tre righe del login locale.
Non serve toccare né il modello utente né il resto delle rotte.

Inoltre il punto di innesto **esiste già**: `login.cr:21,41-44` legge
`env.params.query["type"]` in una variabile `account_type` con dispatch
`case`, e `views/user/login.ecr:9` ha un `<% case account_type when %>` con il
ramo vuoto — residui del Google login rimosso. Sono i ganci per un secondo
provider, già in posizione.

Sul lato schema: `users.password` è `String?` **nullable**
(`migrations/0004_create_users_table.cr`), quindi un utente OIDC-only senza
password entra nello schema attuale **senza migrazione**. `users.email` ha già
l'unique index e mappa naturalmente sulla claim `email` (o `sub`).

### Cosa va costruito

1. `OIDCConfig` in `config.cr` (issuer, client_id/secret, scope, redirect_uri,
   mapping claim→email, auto-provisioning, eventuale mapping gruppo→admin).
2. Discovery `/.well-known/openid-configuration`, con cache. Banale con
   `make_client` (`yt_backend/connection_pool.cr:122`).
3. Due rotte: `GET /oidc/login` (authz URL + PKCE + state + nonce) e
   `GET /oidc/callback` (verifica state, code exchange, risoluzione utente,
   `SessionIDs.insert`, cookie).
4. Storage di state/nonce: **riusare la tabella `nonces`**, che esiste già con
   scadenza (`database/nonces.cr`).
5. Provisioning utente: riusare `create_user` senza password **e non
   dimenticare la materialized view** `subscriptions_<sha256(email)>` che
   `login.cr:127` crea a mano — senza quella il feed abbonamenti si rompe.
6. Gestione `alternative_domains` per il cookie: `login.cr` la ripete due
   volte, va replicata anche nel callback.
7. Flag di config: modalità "solo OIDC" che nasconde il form password, e
   interazione con `login_enabled` / `registration_enabled` / `captcha_enabled`.

### Il rischio vero: validazione della firma dell'ID token

Nel repo non c'è **nulla** di JWT/OAuth/OIDC (zero occorrenze). E la stdlib
Crystal non espone `OpenSSL::PKey::RSA` — è una lacuna nota delle binding
([crystal-lang/crystal#3941](https://github.com/crystal-lang/crystal/issues/3941)).
Quindi RS256 richiede
[`crystal-community/jwt`](https://github.com/crystal-community/jwt) v1.7.2,
che a sua volta tira dentro `openssl_ext`, `bindata` ed `ed25519`: **4 shard
transitivi** su un progetto che ne ha 6 in tutto e una cultura esplicita di
"ci facciamo tutto in casa" (vedi `AI_POLICY.md`).

In più il `docker/Dockerfile` compila OpenSSL 3.6.3 da sorgente e linka
staticamente (per un memory leak noto): le binding LibCrypto di `openssl_ext`
andrebbero validate contro quella build. È l'incognita più grossa della feature.

**Mitigazione che elimina del tutto il problema:** usare authorization code +
PKCE con client confidenziale e leggere le claim dall'ID token ottenuto
*direttamente* dal token endpoint su TLS. OIDC Core §3.1.3.7 consente
esplicitamente di saltare la validazione della firma in questo caso. In
alternativa, ignorare l'ID token e chiamare `userinfo` con l'access token.
Così servono solo parsing JSON e `Base64.decode`: **zero shard nuovi**, ~300
righe di Crystal. È la strada consigliata per la v1.
Vincolo: vale **solo** per il code flow, mai per implicit/hybrid; se in futuro
serve un flusso front-channel, allora la validazione JWKS diventa obbligatoria.

### Altri punti da decidere

- **Account linking**: stessa email registrata prima localmente e poi via OIDC.
- **API token**: `/api/v1/auth/*` usa il suo schema HMAC. Gli access token OIDC
  **non** funzioneranno lì a meno di lavoro aggiuntivo. Consiglio: lasciarli
  invariati in v1.
- **Config da env**: la macro in `Config.load` genera override `INVIDIOUS_*`
  solo per le property top-level (c'è già un TODO nel codice per i nested tipo
  `DBConfig`). Un blocco `oidc:` annidato sarebbe quindi configurabile solo da
  file — rilevante per deploy containerizzati.

**Stima:** 2-4 giorni per la variante senza crypto JWT (config, rotte, UI,
docs). +2-3 giorni per validazione JWKS/RS256 completa con key rotation.

---

## 2. Ammodernamento UI

**Verdetto: fattibile, ma è la voce con effort e rischio più alti, e il costo
scala interamente con quanto lontano si vuole andare. Va scomposta in tier.**

### Baseline misurata

- 42 template ECR; **23** usano la griglia Pure.css (`pure-u-*`).
- `assets/css/default.css`: 929 righe, **zero custom properties, zero `var()`**.
  Il theming è fatto duplicando interi blocchi di regole sotto
  `.dark-theme` / `.light-theme` / `.no-theme` più `@media (prefers-color-scheme)`:
  **47 selettori a tema**, e le righe 575-929 (~38% del file) sono praticamente
  solo quella duplicazione.
- Icone: Ionicons costa **45KB di CSS + 656KB di webfont** per una trentina di
  icone effettivamente usate.
- **Nessun build step.** Il cache-busting è `ASSET_COMMIT` (`src/invidious.cr:81`),
  il rev git della cartella `assets/` iniettato a compile time. Aggiungere
  PostCSS/Node significa cambiare build e immagine Docker.
- CSP stretta: `script-src 'self'`, nessuna CDN esterna,
  `style-src 'unsafe-inline'` con un TODO per rimuoverlo. Attributi `style=`
  inline in ~15 template (9 solo in `watch.ecr`).
- i18n: 63 locale, 511 chiavi in `en-US`. Ogni stringa nuova va tradotta; ogni
  markup che perde una stringa rompe le traduzioni esistenti.

### Tier proposti

**Tier 1 — design token (alto valore, rischio nullo, ~1-2 gg).**
Introdurre custom properties su `:root`, definire le palette una volta per
tema, sostituire le ~330 righe di regole duplicate con override di variabili.
Riduce `default.css` in modo netto, rende economico tutto ciò che viene dopo,
non tocca nessun template, non aggiunge dipendenze. **Da fare per primo in ogni
caso.**

**Tier 2 — dieta icone/font (~1 gg).**
Sostituire Ionicons con sprite SVG inline: CSP-safe, niente font loading,
niente FOIT. Si eliminano `ionicons.min.css` e l'intera `assets/fonts/` (~700KB).

**Tier 3 — layout (~1-2 settimane).**
Sostituire la griglia Pure.css con CSS Grid/Flexbox. Tocca 23 template ed è
dove vivono le regressioni: `components/item.ecr` (217 righe, renderizzato da
**12 view** diverse via `items_paginated.ecr`), `watch.ecr` (21KB, la pagina
più complessa), le interazioni con `player.css`. Fattibile, ma richiede
verifica visiva disciplinata su ogni pagina × 3 temi × mobile/desktop, e nel
repo **non esiste visual regression testing**.

**Tier 4 — redesign dei componenti.** Non limitato superiormente. Ha senso solo
dopo 1-3 e con un riferimento di design.

### Vincoli da rispettare

- Restare CSS-only senza build step, o si cambia il Docker build e la storia
  di disponibilità del sorgente (AGPL).
- Il funzionamento **senza JS** deve restare: c'è un percorso `nojs=1` in
  `watch.cr` e oggi il sito funziona interamente senza JS.
- `embed.ecr` / `embed.css` sono una superficie separata usata da siti terzi.

**Rischio principale:** è il tipo di lavoro facile da iniziare e difficile da
chiudere, ed è quello che confligge di più con i rebase upstream — ogni
modifica upstream ai template tocca i file riscritti.

---

## 3. Modalità Kids

**Verdetto: fattibile per un modello di minaccia "famiglia/fiducia". NON è un
confine di sicurezza reale senza lavoro aggiuntivo significativo — e questa
distinzione è la decisione più importante da prendere subito.**

### Modello dati — la parte facile

Migrazione `0011`: `kids_profiles` (id, owner_email, nome, pin_hash, modalità)
e `kids_allowed_items` (profile_id, kind ∈ {video, channel, playlist}, value).
L'infrastruttura di migrazione è pulita e additiva, aggiungere una versione è
banale.

Alternativa più economica: una allowlist è di fatto una playlist, e le
playlist hanno già CRUD, limite a 500 elementi e UI. Consiglio per la v1:
*una o più playlist allowlist + allowlist di UCID canali*, in una tabella nuova
piccola, senza inventare semantiche nuove sulle playlist.

**Parent gate:** PIN con bcrypt (stesso meccanismo delle password), modalità
attivata **per sessione** (flag sulla riga di sessione, o cookie firmato con
`HMAC_KEY`) e non per utente — così il genitore può passare il dispositivo
senza fare logout.

### Enforcement — qui sta il lavoro vero

**Livello A — scoperta/navigazione (tutto da filtrare):**
`/` home, `/feed/popular`, `/feed/trending`, `/feed/subscriptions`,
`/feed/history`, `/feed/playlists`; `/search`, `/results`, `/api/v1/search`,
suggerimenti di ricerca, `/hashtag/:hashtag`; `/channel/:ucid/*` (12 tab),
`/playlist`, `/mix`, `/watch_videos`; video correlati e **commenti** su
`/watch` (i commenti YouTube sono testo user-generated: una Kids mode che li
mostra è un buco — `preferences.comments` si può forzare a off); e i feed RSS
(`/feed/channel/:ucid`, `/feeds/videos.xml`), facilissimi da dimenticare.

La buona notizia: quasi tutto passa da `components/item.ecr` tramite
`items_paginated.ecr` (12 view) su struct `SearchVideo`/`SearchPlaylist`/`SearchChannel`.
Un singolo filtro sugli array di item copre gran parte del livello A. Ma va
applicato nel **data/route layer, non nel template**, altrimenti le rotte
`/api/v1/*` continuano a restituire JSON non filtrato.

**Livello B — playback diretto (la parte difficile):**

- `/watch?v=ID`, `/embed/:id`, `/api/v1/videos/:id` → facili da gattare, è lì
  che si controlla l'allowlist.
- `/latest_version`, `/videoplayback`, `/api/manifest/dash/id/*`, `/companion/*`
  → **non gattabili così come sono.** `BeforeAll.handle` fa `return` su
  esattamente quei prefissi prima di qualsiasi lookup di sessione, quindi
  quegli handler non hanno alcun contesto utente. `/companion/*` in particolare
  è un proxy cieco che inoltra path, query e header verbatim
  (`routes/companion.cr`).
- Renderli kids-aware significa o (a) fare la lookup di sessione sulle rotte
  media — che sono le più trafficate del sito, quindi è una decisione di
  performance: un round-trip DB in più per segmento —, o (b) firmare le URL di
  playback per sessione.

**Conseguenza da mettere per iscritto:** un bambino che conosce o indovina un
video ID può comunque riprodurlo via URL di playback diretta, e le thumbnail
(`/vi/:id/*`) non sono protette. Per un bambino di 6 anni è irrilevante; per
uno di 13 è aggirabile in un minuto.

**Consiglio:** implementare Livello A + `/watch` + `/embed` +
`/api/v1/videos/:id`, documentare esplicitamente che gli endpoint di playback
grezzi non sono protetti, e trattare l'enforcement "hard" come decisione
separata e successiva (lookup di sessione sulle rotte media con cache è la
strada realistica).

### Altre decisioni

- Cosa vede il bambino al posto del contenuto bloccato: 404, pagina amichevole,
  o filtro silenzioso? Il filtro silenzioso è UX migliore e fa trapelare meno.
- Preferenze da forzare in Kids mode: commenti off, `related_videos` off,
  autoplay, `default_home`, `feed_menu`, ricerca on/off (disabilitare la
  ricerca è più semplice e più sicuro che filtrarla).
- La Kids mode deve valere anche sulla superficie API, altrimenti
  `/api/v1/auth/*` (che ha il suo `AuthHandler` separato) diventa un bypass.
- Incrocio con OIDC: se OIDC fa provisioning automatico, decidere se un utente
  provisionato via OIDC può essere genitore di un profilo kid.

**Stima:** v1 (modello dati + UI genitore + PIN gate + filtro livello A + gate
su watch/embed/api videos) ≈ 1-1,5 settimane. Enforcement hard sulle rotte
media: +diversi giorni e una discussione sulle performance.

---

## 4. Considerazioni trasversali

**Ordine consigliato:** UI Tier 1 → OIDC → Kids v1 → UI Tier 2/3.
Il refactor a token CSS va per primo perché sia OIDC sia Kids aggiungono UI, e
non conviene scrivere markup nuovo contro la duplicazione di tema attuale.

**Manutenzione del fork.** Tutte e tre divergono da upstream, con conflittualità
crescente: OIDC tocca pochi file (bassa), Kids tocca molti route handler
(media), UI Tier 3+ tocca ogni template (alta). Se si vuole continuare a fare
rebase su upstream, quell'ordine è anche l'ordine di rischio.

**Testing.** 15 spec, nessun test di route o integrazione, nessun visual
regression. Tutte e tre le feature sono esattamente il tipo di lavoro che ne
avrebbe bisogno. Va messo a budget un minimo di harness per test di route,
oppure si accetta la verifica manuale.

**`AI_POLICY.md`.** Se qualcosa di questo dovesse mai andare upstream su
iv-org, la policy impone di dichiarare modello e tooling esatti e di dimostrare
verifica umana; le PR "AI slop" vengono chiuse a vista. Su un fork privato non
si applica, ma è bene saperlo.

## 5. Riepilogo

| Feature | Fattibilità | Effort | Rischio principale |
|---|---|---|---|
| OIDC (senza crypto JWT) | Alta | 2-4 gg | — |
| OIDC (JWKS/RS256 completo) | Alta | +2-3 gg | shard nuovi vs build OpenSSL statica |
| UI Tier 1 (design token) | Alta | 1-2 gg | nessuno rilevante |
| UI Tier 2 (icone/font) | Alta | 1 gg | nessuno rilevante |
| UI Tier 3 (layout) | Media | 1-2 sett. | regressioni, niente visual test, conflitti upstream |
| Kids mode (soft) | Alta | 1-1,5 sett. | ampiezza delle superfici da filtrare |
| Kids mode (hard) | Medio-bassa | +1 sett. | rotte media senza contesto sessione by design |
