# World Brief

Fifteen minutes a day instead of browsing news sites.

World Brief scrapes the RSS feeds of ~500 labelled news outlets plus a Google News edition for every one of 197 nations, groups the articles into events, geolocates and classifies them with small models it trains itself, ranks them, and shows two interfaces:

* **Brief** — ranked events with time, place, relevance, reading time, a neutral extractive summary with its sources, extracts for context, the sides of the story, and every article tagged with its outlet's editorial position and ownership. A 15-minute timer tracks the daily budget and the brief is sized to fit it.
* **World map** — events as markers (colour = macro-topic, size = relevance, ring = in today's brief), country hotspots, and dashed lines between countries that the same stories link.
* **Languages** — the interface in sixteen languages, and offline machine translation of the foreign-language news into whichever one you read.

No external AI service is used, and no API key is needed. Everything runs locally, translation included.

## Install

World Brief is a native application. One click on the icon starts everything: the server, the
refresh scheduler and the window are a single process, and closing the window leaves the news
being collected in the background.

| | Package | Notes |
|---|---|---|
| macOS 11+ | `World Brief-<v>.dmg` | Drag it into Applications. Closing the window hides the app; the Dock icon brings it back, ⌘Q quits it. |
| Windows 10+ | `WorldBrief-<v>-setup.exe`, or a portable `.zip` | Installs for one user, no administrator needed. Lives in the notification area while it refreshes. |
| Linux | `.deb`, `.AppImage`, or a `.tar.gz` with a `--user` installer | Install WebKitGTK for the native window; without it the app opens in your browser instead. |
| Android 8+ | `WorldBrief-<v>.apk` | A reader for the copy on your own computer — see below. |

Building the packages yourself is [`packaging/README.md`](packaging/README.md); the short version
is `packaging/build.sh`.

The first launch spends a few minutes fetching ~700 feeds before the first brief appears, then
refreshes every 30 minutes for as long as the app is running. The database, the briefs, the models
and any language packages live outside the app, in the place each system keeps user data —
`~/Library/Application Support/WorldBrief`, `%LOCALAPPDATA%\WorldBrief`, or
`~/.local/share/worldbrief` — so upgrading or removing the app never touches them.

### The Android app

The phone does not gather the news: clustering 23,000 articles and running translation models is
work for a laptop, not a handset. The app points at the desktop copy on your own network — it can
find it for you — and shows that interface in full. In the background it keeps a copy of the
current brief, so the app opens instantly, reads offline, and can tell you when a new brief is
ready. Nothing goes through a server of ours, because there isn't one.

### From a checkout

```bash
./run.sh                 # http://localhost:8011
```

Everything then stays in `data/`, exactly as before. `python -m backend.pipeline` runs one refresh
from the shell; `--no-fetch` rebuilds from stored articles. Only one refresh runs at a time, even
across processes. `python -m desktop.main` opens the native window against the checkout, and
`--no-window` runs the server and scheduler with no GUI at all.

## How it works

| Stage | Module | Method |
|---|---|---|
| Sources | `outlets.py`, `countries.py` | ~500 direct feeds labelled with leaning, ownership and tier; one Google News edition per nation in its own language; an English "about this country" feed as a fallback for any nation still uncovered after a fetch. |
| Fetch | `fetcher.py` | Async HTTP (httpx + feedparser), 24 concurrent, per-feed health recorded. Boilerplate, tracking URLs and navigation blocks are stripped. |
| Store | `store.py` | SQLite (`data/news.db`); articles kept 14 days; derived features cached per article and invalidated by a version stamp when the rules or gazetteer change. |
| Places | `geo.py` | Gazetteer of 197 countries with demonyms and exonyms in ten languages, ~270 cities and hotspots with multilingual aliases, regions and blocs. Token n-gram dictionary lookup, one pass per article, with substring matching for Chinese, Japanese and Korean. Guards for person names ("Milan Pradhan") and overshadowed countries (Niger vs Nigeria). |
| Topics | `classify.py`, `ml.py` | 23 focus areas. Keyword rules (weak supervision) plus 220 seed headlines train 22 one-vs-rest logistic-regression classifiers (SGD) over hashed word and character n-grams, retrained on the live corpus at every refresh. |
| Events | `cluster.py` | TF-IDF cosine agglomeration inside each language, strongest pairs first, with a centroid check that stops chaining. Clusters in different languages merge when they share a specific place (Greenland / Groenlandia / Grönland) and at least two names, with a size cap. |
| Newsworthiness | `ml.py` `SalienceModel` | SGD regression predicting coverage breadth from text alone, trained on the app's own clustering and on your "Important / Not important" feedback. |
| Summary | `ml.py` `Summarizer` | Unsupervised extractive: sentence centroid relevance with MMR diversity, each sentence attributed to its outlet, in the language of the headline. Full text of the lead article is fetched for the top 20 events. |
| Sides | `ml.py` `perspectives` | Articles grouped by the outlets' country (for multi-country stories) or by editorial polarity (left / right / centre / state-government / independent-opposition). The most central headline per side is shown with a framing-divergence score. |
| Ranking | `pipeline.py` | Log-scaled article, outlet, country and polarity counts; category weight and gravity; tier-1 bonus; recency decay; predicted salience; contestedness; your feedback. The brief is a greedy diverse selection under the reading budget (230 wpm) requiring at least two independent outlets per event. |
| Translation | `translate.py` | Open-source Argos/OpenNMT models run by CTranslate2 + SentencePiece, entirely offline. Packages are downloaded once on request; a pair with no direct model pivots through English. Sentence-level splitting, batched decoding, and a SQLite translation memory so a headline is translated once and then remembered. |
| Interface languages | `i18n.py`, `frontend/i18n/*.json` | Sixteen locales, right-to-left included. Plural forms follow CLDR through `Intl.PluralRules` (Russian needs four, Arabic six); country, language, date and number formatting come from the browser's own CLDR data. |
| API / UI | `app.py`, `frontend/` | FastAPI JSON API; vanilla JS and Leaflet — both vendored, so the map needs no CDN — light and dark, with country outlines served locally from Natural Earth (no tile server or key). |
| Desktop shell | `desktop/` | One process: uvicorn on a loopback port, the refresh scheduler, and a native window (WKWebView, WebView2 or WebKitGTK) over it. A second launch raises the first window instead of starting a second server; launch-at-login, the tray menu and the new-brief notification are the platform's own. |
| Packaging | `packaging/`, `android/` | PyInstaller for the three desktop systems, each with its native installer; a Kotlin client for Android. Every icon and both installers' artwork are drawn by `packaging/make_icons.py`. |

Typical full refresh on an Apple-silicon Mac: about 100 seconds for 700 feeds and 23,000 articles, of which clustering is 3 seconds and training plus classification about 5.

## API

`GET /api/events` with `brief=1`, `category=`, `country=`, `region=`, `hours=`, `q=`, `min_articles=`, `sort=relevance|discussed|newest|divergence` ·
`GET /api/events/{id}` with optional `lang=` (returns the event translated, with every original kept alongside) ·
`GET /api/map` · `GET /api/sources` · `GET /api/categories` · `GET /api/countries` · `GET /api/status` · `POST /api/refresh` · `POST /api/feedback {event_id,label}`.

Translation: `GET /api/i18n/locales` · `GET /api/translate/status` (optionally `?lang=` to see which packages today's news would need) ·
`POST /api/translate {texts,to,langs?}` · `POST /api/translate/packages {from_code,to_code}` · `DELETE /api/translate/packages/{from}/{to}` ·
`POST /api/translate/index/refresh` · `DELETE /api/translate/cache`.

## Languages

Open the **Languages** tab (or the globe in the header).

* **Interface language** — sixteen are shipped: English, Spanish, French, German, Italian, Portuguese, Dutch, Polish, Russian, Ukrainian, Turkish, Arabic, Hindi, Chinese, Japanese and Korean. The browser's own preference is used on first visit. Arabic renders right-to-left. Country and language names, dates, numbers and plural forms come from the browser's CLDR data, so they are correct without this project translating them.
* **Translating the news** — pick the language you want articles in. Headlines, summaries, perspectives, extracts and article titles are translated as you read them; the badge on each card names the original language and one click in the detail panel swaps the whole panel back to the original. Roughly half the corpus is not in English, so this is the difference between a readable brief and a wall of foreign headlines.

Translation runs on this machine. The first time you choose a language, the tab lists the languages today's events are actually written in and offers the packages that cover them, biggest share first. A package is an `.argosmodel` (open-source Argos/OpenNMT weights, 70–280 MB) downloaded once from the Argos package index and then used offline forever; they live in `data/translate/`. A pair with no direct model, say Greek to Spanish, pivots through English. Translations are remembered in SQLite, so a headline costs about 20 ms once and nothing thereafter.

About 49 languages have models. Serbian, Croatian, Bosnian, Icelandic and Armenian do not yet; those articles stay in the original and the interface says so rather than pretending.

If `ctranslate2` and `sentencepiece` cannot be installed on your platform, everything else still works and the tab tells you the command to run. Alternatively point `NEWS_TRANSLATE_ENDPOINT` at a [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate) server you run yourself.

Adding an interface language: copy `frontend/i18n/en.json`, translate the values (a counted phrase is an object of CLDR plural forms), and check it with

```bash
.venv/bin/python tools/check_i18n.py    # missing keys, broken {placeholders}, missing plural forms
```

## Configuration (environment variables)

`NEWS_REFRESH_MINUTES` (30), `NEWS_WINDOW_HOURS` (48), `NEWS_BRIEF_MINUTES` (15), `NEWS_READING_WPM` (230), `NEWS_FEED_CONCURRENCY` (24), `NEWS_GNEWS_SEARCH_ALL` (false: add an English search feed for every country, not just uncovered ones), `NEWS_FULLTEXT_TOP_N` (20), `NEWS_CLUSTER_SIM` (0.42), `NEWS_TOPIC_THRESHOLD` (0.65), `NEWS_RETRAIN` (true), `NEWS_DATA_DIR` (overrides the per-user data location), `NEWS_LOG_DIR`.

Translation: `NEWS_TRANSLATE` (true), `NEWS_UI_LANG` (en: the interface language when the browser asks for nothing this build has), `NEWS_TRANSLATE_MODELS_IN_MEMORY` (4), `NEWS_TRANSLATE_BEAM` (2), `NEWS_TRANSLATE_THREADS` (4), `NEWS_TRANSLATE_MAX_CHARS` (4000), `NEWS_TRANSLATE_INDEX_URL`, `NEWS_TRANSLATE_ENDPOINT`, `NEWS_TRANSLATE_ENDPOINT_KEY`.

## Maintenance

Feed URLs rot. The Sources tab shows which feeds are failing and why.

```bash
.venv/bin/python tools/discover_feeds.py            # probe failing feeds, try autodiscovery and common paths
.venv/bin/python tools/discover_feeds.py --apply    # write the repaired URLs into backend/outlets.py
```

## Notes and limits

* Leaning labels are approximate. They are a reading aid drawn from widely cited assessments and each outlet's own stated line, not a verdict; edit `backend/outlets.py` to change them. State and party media are included deliberately and marked as such, because what a government wants said is itself information.
* Roughly 140 of the 700 feeds fail at any time (403 blocks, dead paths, malformed XML). Coverage of all 197 nations is maintained regardless, because the Google News national editions and the search fallback cover the gaps.
* The keyword rules are English-first. Non-English articles are still clustered, placed and ranked; they are classified mainly through the learned character n-gram model and through the places they mention.
* Summaries are extractive, never generated, so a sentence in the brief is always a sentence somebody published. Each one names its outlet.
* Translation is machine translation, and the models are small enough to run on a laptop. It is reliable for the gist of a headline and unreliable for the exact wording of a quotation, which is why the original is always one click away and every translated panel says so.
* The distributed packages are unsigned unless you build them with your own certificate, so the first launch asks for confirmation: on macOS, right-click the app and choose Open; on Windows, "More info" then "Run anyway". Set the signing variables in `packaging/README.md` to remove that step.
* The Android app is a reader, not a second copy of the pipeline. If the computer running World Brief is asleep or on another network, the phone shows the last brief it saved rather than a live one, and says so.
* The desktop app keeps a `settings.json` next to its data — window size, whether to start at login, how often to refresh. Deleting it restores the defaults.
* The editorial-position labels are hand-written English phrases. The common ones are translated in the locale files, including compound forms like "liberal/independent"; anything unusual is passed through the translation engine when you have it switched on, and otherwise left in English.

## How this was built

World Brief is architected and directed by **Pengyue Wang**, with **Claude** used as an
implementation assistant.

Claude generated boilerplate, scaffolded unit tests, and accelerated the front-end work. The
engineering judgement is mine:

- **Architecture.** I designed the pipeline stages above — what a source, an event, a side and
  a brief each are — along with the local-first constraint that runs every model and every
  translation on the user's own machine, and the decision that no external AI service or API
  key would ever be involved. The rule that summaries stay extractive and attributed, rather
  than generated, is part of that design and not a limitation of it.
- **Review.** I peer-reviewed the code that came back, and rejected or reworked what did not
  fit the design.
- **Debugging.** I found and fixed the inconsistencies and functional flaws — clustering that
  chained across unrelated stories, gazetteer false positives on person names and overshadowed
  countries, translation pivots, plural forms in right-to-left locales, and packaging failures
  on three desktop systems.
- **Direction.** I decided what to build next, how each piece should behave, and when it was done.

Note that the assistance is in the writing of this application, not in its running: World Brief
itself calls no language model at all, at any point, by design.

## License

Copyright © 2026 Pengyue Wang.

World Brief is licensed under the **Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)**
license — see [`LICENSE`](LICENSE). You may share and adapt the work for
**non-commercial** purposes, with attribution, and any derivatives must be
shared under the same license.
