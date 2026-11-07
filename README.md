# Movie Crawler

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Android](https://img.shields.io/badge/Android-7%2B-green.svg)](MovieCrawler.apk)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Android-blue.svg)](#run)
[![Deps](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#run)

Type a movie name → pick a source → see every available quality with its real
file size → resolve a **direct, ad-free download link**. Two catalogs are
supported:

- **moviezda** — `moviezda.me`, Tamil movies & web series (4,092 titles)
- **isaiDub** — `isaidub.green`, Tamil-dubbed Hollywood movies & web series
  (4,382 titles)

Real posters are pulled from Wikipedia / TVmaze and shown uncropped in the
detail view. Everything runs locally — no accounts, no tracking, no ads.

---

## Download

### Android app

**[`MovieCrawler.apk`](MovieCrawler.apk)** — signed release, ~189 KB.

1. Download the APK on your phone (tap the link above → *Download raw file*,
   or `adb install -r MovieCrawler.apk` from a computer).
2. Allow "install from this source" when Android asks.
3. Open **Movie Crawler** — the whole UI and scraper are bundled inside; no
   server or PC needed.

Package `me.moviezda.crawler` · minSdk 24 (Android 7) · targetSdk 34 ·
debug-signed, so rebuilds install as updates over the same signature.

### Browser / desktop

The entire UI is one self-contained file — no build step, no CDN, no fonts:

```powershell
git clone https://github.com/aswindatha/fuzzy-waddle.git
cd fuzzy-waddle
pwsh -File .\start-crawler.ps1
```

Open <http://127.0.0.1:8787/> and search. The page also works opened directly
as `file://moviezda-crawler.html` — catalog search is fully offline; only
live link resolution needs the helper.

---

## Features

- **Two sources, one UI** — site switcher in the chrome; catalogs, variants,
  and download chains are all site-aware
- **Instant catalog search** — ~8,400 titles embedded in the HTML; works with
  the helper offline
- **Real file sizes** — `1.09 GB`, `1280x536`, `01:54:10` read from the
  source site's own metadata pages
- **Multi-download** — Select mode on results (>4 hits) queues the best
  quality per title / per episode through the real resolver
- **Real posters** — Wikipedia (Wikidata P18 → sized thumbnail, film/TV
  category-validated, typo-corrected) with TVmaze fallback for series;
  cached in `cache/posters.json`, gradient fallback when nothing matches
- **Ad-free direct links** — full redirect chain traced hop-by-hop with
  status codes; every hop outside the allow-list is refused *before* the
  request is made
- **Link health check** — final CDN URL probed with `Range: bytes=0-1`
  (1 MB cap) so dead links are caught without downloading the movie
- **Android app** — WebView bridge (`window.Android.download/copy/openSite`),
  DownloadManager integration, SQLite cache with stale-fallback

## Files

| file | what it is |
|---|---|
| `moviezda-crawler.html` | the whole UI, single self-contained file; embeds both catalogs |
| `start-crawler.ps1` | local resolver + static server, 0 dependencies (PowerShell 7) |
| `build-apk.ps1` | builds the Android APK with SDK tools only (no Gradle) |
| `MovieCrawler.apk` | signed Android app — see [Download](#download) |
| `android/` | APK source: manifest, Java scraper/activity/db, bundled HTML asset |
| `cache/index.json` | crawled moviezda A–Z catalog (committed so it runs out of the box) |
| `cache/isai-index.json` | crawled isaiDub A–Z catalog |

## Run

```powershell
pwsh -File .\start-crawler.ps1
```

Rebuild the catalogs (a–z index, ~26 letters × N pages each):

```powershell
pwsh -File .\start-crawler.ps1 -RebuildIndex                      # moviezda
pwsh -File .\start-crawler.ps1 -RebuildIndex -Site isaidub        # isaiDub
```

Inspect one movie from the terminal:

```powershell
pwsh -File .\start-crawler.ps1 -Movie /kumbaari-2024-tamil-movie/
pwsh -File .\start-crawler.ps1 -Movie /movie/red-eye-2005-tamil-dubbed-movie/ -Site isaidub
```

## Why a helper is needed

`moviezda.me` / `isaidub.green` send no `Access-Control-Allow-Origin` header.
A page opened as `file://` (or any other origin) cannot `fetch()` them — the
browser refuses. `start-crawler.ps1` does the HTTP work on loopback and serves
the same HTML file from `http://127.0.0.1:8787/`, so the page is same-origin
with its API. In the APK, `MainActivity` intercepts `https://app.local/` and
answers the same API natively — no server needed at all.

## How the sites are walked

moviezda.me:

```
/tamil-movies/<letter>/?page=N        17–21 pages per letter, 20 titles each
  └─ /<movie>-<year>-tamil-movie/     movie folder
       └─ /<movie>-original-movie/    collection (Original / Dubbed / …)
            └─ /<movie>-720p-hd-movie/   quality folder
                 └─ /download/<slug>/    metadata + server link
                      └─ download.moviespage.xyz/download/file/<id>
                           └─ movies.downloadpage.xyz/download/page/<id>
                                └─ download.fastbytes.xyz/download.php?dl=<base64>
                                     └─ 302 → cdn7.<id>.r2.cloudflarestorage.com/…
```

isaidub.green:

```
/tamil-atoz-dubbed-movies/<letter>/<page>   catalog crawl (div.f / div.folder wrappers)
  └─ /movie/<slug>-tamil-dubbed-movie/      movie page (season pages for web series)
       └─ /movie/<id>/                      collection  e.g. "Red Eye (Original)"
            └─ /movie/<id>/                 quality      e.g. "Red Eye (720p HD)"
                 └─ /download/page/<id>/    one per file/episode, .details + size/format
                      └─ dubpage.xyz/download/view/<id>
                           └─ dubmv.xyz/download/file/<id>
                                ├─ dub.uptodub.ch/download.php?dl=<base64>
                                │    └─ 302 → dub<N>-<M>.uptodub.ch/files/…mp4?h=…&e=…
                                └─ download.isaidub.dad/download.php?url=<url>
                                     └─ 302 → s<N>.<hash>.r2.cloudflarestorage.com/…
```

Sizes (`1.09 GB`, `1280x536`, `01:54:10`) come from the `/download/…` metadata
page on the source site itself, so the ad-laden third-party hosts are only
touched once, at click time, and only to read one `href`. On isaiDub the
per-file `File Size:` / `Download Format:` `<li>` values are also read on the
quality page itself, which is what lets each episode/mirror row show its own
size before the detail fetch.

## Poster lookup

Artwork never comes from the source sites (their pages carry no usable posters).
`Get-PosterImage` / `Scraper.posterImage` resolve it in this order:

1. **Wikipedia** — `generator=search` on the cleaned title (+ year), validated
   as a film/TV article by category (rejects mythology/disambiguation hits),
   then the article's **Wikidata P18** image preferred, with filename-scored
   fallback; Wikipedia's own spell-check suggestion retries once for typos
   (e.g. `Chpater` → `Chapter`). Served as an `iiurlwidth=480` thumbnail.
2. **TVmaze** — series first, movies as fallback; `static.tvmaze.com` poster.

Metadata hosts (`en.wikipedia.org`, `upload.wikimedia.org`, `api.tvmaze.com`,
`static.tvmaze.com`) are allow-listed separately from download hosts and are
never part of the redirect chain. Results cache to `cache/posters.json`;
failures cache as `null` so they don't retry every open.

## Redirect / ad handling

Every request goes through a host allow-list:

```
moviezda.me  www.moviezda.me
isaidub.green  www.isaidub.green
metadata: en.wikipedia.org  upload.wikimedia.org  commons.wikimedia.org
           api.tvmaze.com  static.tvmaze.com
download.moviespage.xyz  movies.downloadpage.xyz  download.fastbytes.xyz
play.onestream.today
dubpage.xyz  www.dubpage.xyz  dubmv.xyz  www.dubmv.xyz
uptodub.ch  dub.uptodub.ch  *.uptodub.ch
isaidub.dad  *.isaidub.dad  dubshare.one  *.dubshare.one
*.r2.cloudflarestorage.com
```

Anything else — `<sub>.glaucusworries.com`, `d3h4vtr7axmx3p.cloudfront.net`,
`red-suspect.com`, whatever a popunder tries next — is **refused before the
request is made** and recorded in the chain log as `BLOCKED`. The crawler never
executes the site's JavaScript, never opens a popup, and never follows an
unexpected `Location:` header.

The final CDN URL is signed and is fetched with `Range: bytes=0-1` (capped at
1 MB even if a server ignores Range) to prove it is alive, so nothing large is
downloaded just to check a link. Any allowed URL whose path ends in a video
extension (`.mp4`, `.mkv`, …) is treated as a file and probed the same way.

## Notes

- Server binds `127.0.0.1` only.
- `?u=` parameters are restricted to paths or allow-listed hosts; `?site=` is
  `moviezda` (default) or `isaidub` and selects the parser + catalog;
  `?t=` carries the display title for poster lookup.
- The catalogs are snapshots; press `-RebuildIndex` (or the rebuild endpoint
  `/api/rebuild?site=…`) to refresh.
- Rate limits: Wikipedia/TVmaze lookups retry 429/5xx with backoff; a failed
  lookup just falls back to the gradient tile.

## Android APK

`MovieCrawler.apk` is a small signed Android app, package
`me.moviezda.crawler`, minSdk 24 (Android 7), targetSdk 34. No Gradle, no
AndroidX, no Kotlin.

```powershell
pwsh -File .\build-apk.ps1
adb install -r .\MovieCrawler.apk
```

Build pipeline: `aapt2 compile` → `aapt2 link` → `javac` → `d8` →
`zipalign` → `apksigner`. Requires Android SDK build-tools + platform
android-34 on `PATH` (or `ANDROID_HOME`); `android/debug.keystore` is
auto-generated on first build if missing.

Inside the APK the WebView loads `https://app.local/` — a host that exists only
in the app. `shouldInterceptRequest()` serves the bundled HTML and answers
`/api/health`, `/api/movie` and `/api/link` natively from the Java scraper, so
the page is same-origin: no CORS workaround, no local server, no extra
permission. `Scraper.java` implements both sites' trees, both download chains,
and the same poster lookup (Wikipedia → TVmaze, cached in `posters.json`
inside the app). Any navigation or request outside `app.local` is refused.

After resolving a variant the page calls `window.Android.download(url, name)`;
`DownloadManager` writes the film to `Downloads/`, showing progress in the
notification shade. Each row also has:

- **copy** - resolves the chain, then puts the direct CDN URL on the clipboard
  (no browser navigation, no ad page)
- **open site** - opens that variant's page on the source site (`moviezda.me`
  or `isaidub.green`) in the real browser; only those hosts are accepted

Header actions **copy page url** and **open on site** work the same way for the
movie page.

### SQLite cache

`android/java/me/moviezda/crawler/Db.java` keeps `cache.db` privately in the
app's data directory. Cache keys are prefixed with the site (`moviezda|…`,
`isaidub|…`) so the two catalogs never collide:

| table | key | TTL | contents |
|---|---|---|---|
| `movie` | movie path | 6 h | full `/api/movie` JSON (variants, sizes, pages, server links, `img`) |
| `link` | server URL | 12 h | resolved signed CDN URL, byte count, MIME type, chain |

- A cache hit is instant and is labelled `cached` in the movie header; cached
  responses missing `img` get a poster backfill lookup.
- If the network is down and the row has expired, the old movie JSON is still
  returned and labelled `stale cache`, so sizes remain readable offline.
- Writes are capped at 200 movies and 500 links; the oldest rows are pruned.
- The header shows live counts, e.g. `cache 1 movies · 3 links`.
- Reinstalling with `adb install -r` keeps app data, so the cache survives
  upgrades.

The APK was tested on an Android 16 x86_64 emulator:

- catalog search and the four Kumbaari variants with sizes/resolutions
- full chain `200 → 200 → 302 → 206 CDN`
- **copy** on a cold link: `link stored` + `clipboard set 675 chars`
- **copy** on a cached link: `link hit` + `clipboard set 678 chars`
  (Android showed the clipboard preview)
- **open site**: Chrome received
  `ACTION_VIEW https://moviezda.me/download/kumbaari-2024-original-1080p-hd/`
- **download** with a cached link: `link hit` + `download queued`, then
  `530,118,383` bytes downloaded; ffprobe reported H.264 640x360 + AAC,
  01:54:10, MP4
- **offline**: airplane mode on, `ping moviezda.me` failed, app relaunch still
  returned `movie hit (6987s old)` from SQLite and rendered all four variants
- the same app signature after rebuild (`SHA-256 35d91d45…`)

## Disclaimer

Personal tool for personal use. The catalogs are snapshots of publicly
listed pages; respect the source sites' terms and your local laws. This
project is not affiliated with moviezda, isaiDub, or any linked host.
