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

### Opzione zero: delegare a un reverse proxy

Prima di scrivere codice va messa sul tavolo l'alternativa a costo quasi nullo:
mettere `oauth2-proxy` o Authelia davanti a Invidious e lasciare che sia il
proxy a fare OIDC. Upstream questa strada è stata **provata e rifiutata**
(PR #4402, auth via header con Authelia), ma il rifiuto era per non avere due
meccanismi di auth nel progetto, non perché non funzioni. Su un deploy proprio
è la soluzione più economica in assoluto, al prezzo di non avere account
Invidious distinti per utente senza lavoro extra sul mapping header → utente.

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
caso**, ed è l'unico tier che ha già un avallo upstream esplicito (vedi §4).

Unico caveat noto, sollevato nella issue #5056: le custom properties
**rompono l'estensione Dark Reader**. Va verificato prima di impegnarsi, non
dopo.

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

### Un complemento a basso costo, da verificare

Due issue upstream ancora **aperte** (#2536, #2487) chiedono di esporre la
*restricted mode* di YouTube come toggle per istanza o per utente. Entrambe
sono etichettate `research-needed`: **nessuno ha ancora verificato se sia
raggiungibile via InnerTube**. Se lo fosse sarebbe una baseline di sicurezza
del contenuto quasi gratuita, complementare all'allowlist — non sostitutiva,
perché filtra per categoria e non per lista. Vale una spike di mezza giornata
prima di dimensionare la feature.

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

## 4. Prior art upstream

Ricerca su issue e PR di `iv-org/invidious`. Cambia le conclusioni su due
feature su tre, quindi va letta prima di pianificare.

> Nota di metodo: alcuni thread di commenti non si sono caricati (nuova vista
> issue di GitHub). Per #2979, #3334 e #1950 ho letto solo il corpo della
> issue, non le motivazioni di chiusura.

### OIDC — c'è un rifiuto esplicito, e c'è codice da cui partire

| # | Cosa | Stato |
|---|---|---|
| #705 | auth against LDAP/OAuth/OpenID | chiusa *not planned*, ago 2019 |
| #3159 | OAuth/OpenID accounts | chiusa, giu 2022 |
| PR #4402 | auth via header del reverse proxy (Authelia) | chiusa, feb 2024 |
| PR #3164 | Implemented OAuth Authentication | **chiusa, apr 2026** |
| #5539 | Support Single Sign On | chiusa come duplicato di #705, nov 2025 |

La richiesta ha **sette anni** e quattro thread distinti. Il PR #4402 era stato
chiuso *in favore* di OAuth — unixfox: *"Closing as I would prefer to not have
many ways to implement external authentication"*; syeopite: *"Invidious is
already starved enough for maintenance as-is."*

Poi il PR #3164 ha effettivamente implementato OAuth2 (non OIDC): config con
endpoint e client id/secret, un `src/invidious/helpers/oauth.cr`, modifiche a
`login.cr`, opzione di backend forzato, testato con GitHub e Authentik. È stato
chiuso il 1 aprile 2026 da unixfox:

> "We are not going to implement oauth in Invidious. We lack of real free time
> in the team to maintain the source code and manage the community."

**Tre conseguenze concrete:**

1. **La feature non andrà mai upstream.** Non è un "non ancora": è una
   decisione motivata dalla capacità di manutenzione del team. Va messo a
   budget il mantenimento a fork perpetuo.
2. **Esiste un diff da cui partire.** Il PR #3164 non è OIDC e ha quattro anni,
   ma la forma della config e il punto di innesto in `login.cr` sono già
   scritti e già passati da una review.
3. **Tre difetti già trovati da quella review, da non ripetere:** il PR **non
   usava il parametro `state`**, quindi era vulnerabile a CSRF (segnalato da
   ColonelThirtyTwo, mag 2024); mancava il link di login nella UI, si doveva
   editare l'URL a mano; il `referer` si perdeva durante il flusso. Tutti e tre
   sono già nella lista di cose da costruire più sopra — ora con la conferma
   che sono esattamente i punti in cui si sbaglia.

### UI — è la feature con più vento a favore, non con meno

Qui la ricerca ribalta la valutazione iniziale.

| # | Cosa | Stato |
|---|---|---|
| #5056 | CSS: Overhaul the way theming is done | **aperta**, nov 2024 |
| #5130 | Improve styling and semantics for development and accessibility | **aperta**, dic 2024 |
| PR #5323 | Add workaround to avoid duplicating theme css | chiusa, ago 2025 |
| PR #5259 | Refactor/redesign Invidious frontend | **aperta (draft)**, mag 2025 |

**Il Tier 1 ha già l'avallo di un code owner.** Nel PR #5323 qualcuno aveva
provato a evitare la duplicazione dei temi generando il CSS a runtime;
SamantazFox ha risposto dimostrando le custom properties, dicendo che
*"it simplifies the CSS file, and makes everything easier to manage"*, e
chiudendo la questione del supporto browser: *"IE11 is the only browser setting
us back on that feature, it's probably time to leave it behind."* Il PR è stato
chiuso a favore di quell'approccio. Il Tier 1 quindi non è solo a basso
rischio: è la direzione che upstream ha già scelto, ed è plausibilmente
**upstreamabile**.

**La issue #5130 è, punto per punto, il piano Tier 1 + Tier 3** scritto da un
contributor a dicembre 2024: rimuovere Pure.css in modo incrementale, passare a
grid/flex, aggiungere variabili CSS, ripulire la semantica HTML, sistemare i
selettori JS e l'accessibilità (`<a href="javascript:null;">` → `<button>`). È
aperta e non assegnata.

**Il Tier 3 ha già un'implementazione parziale in corso.** Il PR #5259 è un
draft aperto con 13 commit, ultima attività settembre 2025: esce da Pure.css,
introduce variabili CSS, rifà la semantica. L'autore scrive *"I'm currently
using this every day and it feels stable enough to use as a personal version of
Invidious."* Va letto prima di riscrivere qualsiasi template — o ci si
costruisce sopra. Il feedback di review è già lì e vale anche per noi:
contrasto insufficiente su alcuni testi (verificare WCAG), e **non mescolare la
reindentazione dei file JS con le modifiche funzionali**, perché rende il diff
illeggibile.

Da tenere presente: #5056 avverte che le custom properties **rompono Dark
Reader**.

### Kids mode — richiesta da anni, mai tentata

| # | Cosa | Stato |
|---|---|---|
| #2979 | usare Invidious come filtro whitelist parentale | chiusa, mar 2022 |
| #2908 | filtrare le parti losche di YouTube Kids | chiusa, feb 2022 |
| #3334 | whitelist/blacklist di canali e video | chiusa, set 2022 |
| #1103 | rendere Invidious usabile nell'insegnamento | chiusa, lug 2022 |
| #2536 | restricted mode di YouTube, togglabile | **aperta**, ott 2021 |
| #2487 | safe mode per istanza o per utente | **aperta**, ott 2021 |
| #2528 | nascondere un canale | **aperta**, ott 2021 |
| #2150 | liste di canali | **aperta**, giu 2021 |
| #2079 | filter API | **aperta**, mag 2021 |

**Nessuna PR.** In cinque anni, zero tentativi di implementazione a fronte di
almeno nove issue distinte. Le motivazioni ricorrenti sono sempre le stesse
due: controllo parentale e uso scolastico. Il richiedente di #3334 la mette
così: *"It would be great to only allow certain channels for a distraction-free
experience and also could be useful for schools that want to block YouTube, but
would still like some videos/channels available."*

L'assenza totale di PR è coerente con la stima data sopra: il problema non è
difficile, è **largo**, e la larghezza è esattamente ciò che scoraggia un
contributor volontario. Non c'è quindi nessun design da copiare, ma nemmeno un
segnale di rifiuto dai maintainer.

---

## 5. Considerazioni trasversali

**Ordine consigliato:** UI Tier 1 → OIDC → Kids v1 → UI Tier 2/3.
Il refactor a token CSS va per primo perché sia OIDC sia Kids aggiungono UI, e
non conviene scrivere markup nuovo contro la duplicazione di tema attuale.

**Manutenzione del fork.** Tutte e tre divergono da upstream, con conflittualità
crescente: OIDC tocca pochi file (bassa), Kids tocca molti route handler
(media), UI Tier 3+ tocca ogni template (alta). Se si vuole continuare a fare
rebase su upstream, quell'ordine è anche l'ordine di rischio.

Il prior art (§4) aggiunge però una seconda dimensione, ortogonale: la
probabilità che il codice possa un giorno tornare upstream e smettere così di
essere debito di fork. Lì l'ordine si **inverte**. UI Tier 1 ha l'avallo di un
code owner e una issue aperta che la chiede; Kids mode non ha né precedenti né
rifiuti; OIDC ha un rifiuto esplicito e definitivo. La feature con il conflitto
tecnico più alto è quindi anche l'unica con una via d'uscita dal fork, e quella
con il conflitto più basso è quella che resterà divergente per sempre.

**Testing.** 15 spec, nessun test di route o integrazione, nessun visual
regression. Tutte e tre le feature sono esattamente il tipo di lavoro che ne
avrebbe bisogno. Va messo a budget un minimo di harness per test di route,
oppure si accetta la verifica manuale.

**`AI_POLICY.md`.** Se qualcosa di questo dovesse mai andare upstream su
iv-org, la policy impone di dichiarare modello e tooling esatti e di dimostrare
verifica umana; le PR "AI slop" vengono chiuse a vista. Su un fork privato non
si applica, ma è bene saperlo.

## 6. Riepilogo

| Feature | Fattibilità | Effort | Rischio principale |
|---|---|---|---|
| OIDC (senza crypto JWT) | Alta | 2-4 gg | — |
| OIDC (JWKS/RS256 completo) | Alta | +2-3 gg | shard nuovi vs build OpenSSL statica |
| UI Tier 1 (design token) | Alta | 1-2 gg | nessuno rilevante |
| UI Tier 2 (icone/font) | Alta | 1 gg | nessuno rilevante |
| UI Tier 3 (layout) | Media | 1-2 sett. | regressioni, niente visual test, conflitti upstream |
| Kids mode (soft) | Alta | 1-1,5 sett. | ampiezza delle superfici da filtrare |
| Kids mode (hard) | Medio-bassa | +1 sett. | rotte media senza contesto sessione by design |

Il prior art non cambia nessuna di queste stime tecniche, ma cambia due
raccomandazioni: l'UI Tier 1 sale di priorità (è avallata upstream, esiste una
issue aperta che la chiede e c'è un draft su cui costruire per il Tier 3), e
l'OIDC va pianificato sapendo che resterà per sempre nel fork — con l'opzione
zero, il reverse proxy, da valutare seriamente prima di scrivere codice.
