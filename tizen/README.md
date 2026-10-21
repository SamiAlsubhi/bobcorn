# Bobcorn for Samsung TVs

Bobcorn as a Samsung TV app (Tizen 3 and newer: 2017 and later TVs), run with the remote. The same catalog API
sources as the Mac app, the same poster grid, details, seasons and episodes, My List and Continue Watching, and
playback over BitTorrent while it downloads.

It runs entirely on the TV; the Mac doesn't need to be on.

## Streams, never keeps films

The TV keeps only a window of the film around what you're watching: **5 minutes behind the playhead and 15 minutes
ahead**. Pieces outside it are deleted as the film plays, and a seek moves the window. A two-hour film never takes
more than about 20 minutes' worth of space (capped at 3 GB), so it fits in the TV's own storage.

## How it's made

| Part | What it is |
| --- | --- |
| [`app/`](app) | The web app the TV shows: plain HTML, CSS and JavaScript for the TV's Chromium, no build step. `js/catalog.js` reads catalog APIs as `Sources/Bobcorn/CatalogAPI.swift` does, `js/player.js` plays with Samsung's AVPlay (MKV, MP4, AVI, TS play natively, so nothing is remuxed), `js/nav.js` moves focus with the remote, `js/services.js` has OMDb ratings and OpenSubtitles (ports of `Ratings.swift` and `OpenSubtitles.swift`). |
| [`service/`](service) | The torrent engine, a Node.js service the TV runs in the background, a JavaScript port of `Sources/TorrentKit` with no dependencies, written for the Node 4 some TVs ship. It serves `127.0.0.1:8615`: the app opens torrents and reads their files there, and AVPlay streams from it. |
| [`config.xml`](config.xml) | The Tizen package: app `BobcornApp.Bobcorn`, service `BobcornApp.Engine`. |
| [`build.py`](build.py) | Packs `build/Bobcorn.wgt` and signs it. |
| [`tools/sdb.py`](tools/sdb.py) | Installs and runs it on the TV over Developer Mode, without Tizen Studio. |

## On the remote

While playing, any key shows the controls. On the seek bar, ◀ ▶ seek 10 seconds and OK pauses; ▼ moves to the
buttons, **Play/Pause**, **Subtitles**, **Audio** and **Next episode**, and OK opens them. Back stops (your place is
kept). ⏪ ⏩ seek a minute. Remotes with colour keys also have shortcuts: Green subtitles, Yellow audio, Blue next
episode.

**Subtitles** lists the tracks inside the video, `.srt`/`.vtt` files in the torrent, subtitles you've downloaded for
this film, and **Search subtitles**, in the language set in Settings → Playback (Arabic unless you pick another) or
any other. The search asks [YIFY Subtitles](https://yts-subs.com) for films, which needs no key, and OpenSubtitles
when it has a key (by IMDb ID or file name and by the file's hash, so subtitles timed to that very release come
first; episodes need it). Downloads are kept on the TV, so picking one again costs nothing, each film remembers the
subtitle it showed, and old files in Windows code pages (common for Arabic) are decoded. Embedded subtitles in your
language turn on by themselves.

**Rotten Tomatoes scores** show on posters and title pages with an OMDb key.

## API keys

Settings → Ratings and subtitles takes an [OMDb](https://www.omdbapi.com/apikey.aspx) key and an
[OpenSubtitles](https://www.opensubtitles.com/consumers) key (optional: films find subtitles without one). Typing them with the remote is slow, so the build can
carry them: put them in `tizen/keys.json` (git-ignored), `{"omdb": "…", "opensubtitles": "…"}`, and build. Keys typed
on the TV take precedence. OMDb's example address from its welcome email works as well as the bare key.

## Install it on your TV

1. **On the TV:** open **Apps**, type `1 2 3 4 5` on the remote, turn **Developer mode** on, set **Host PC IP** to
   this computer's IP address, and restart the TV.
2. **A certificate, once.** 2017–2022 TVs take a Tizen author certificate. With
   [tizen.js](https://github.com/reisxd/tizen.js) (`npm i -g github:reisxd/tizen.js`):
   `tizenjs create-tizen-cert --name "Your name" --password <password> --output author.p12`. Keep `author.p12`:
   updates must be signed with the same one, or the TV refuses them. (tizen.js 1.0.1 stores the wrong private key
   in the certificate it makes, and the TV then refuses the package with "Invalid signature". Until that's fixed,
   pass the generated key, `key.privateKey`, to `toPkcs12Asn1` in its `src/tizenCertificateCreator.js`.)
3. **Build, sign and install:**

   ```bash
   python3 tizen/build.py --sign author.p12 --password-file password.txt --install 192.168.1.50
   ```

   It ends with `install completed`, and Bobcorn opens on the TV.
4. **Afterwards**, you can set Host PC IP back to what it was (TizenBrew wants `127.0.0.1`).

2023 and newer TVs (Tizen 7+) need a Samsung certificate instead: run `python3 tizen/build.py` and install
`build/Bobcorn.wgt` with [TizenBrew Installer](https://github.com/reisxd/TizenBrewInstaller), which re-signs it
with your Samsung account.

## Working on it

- **The app in a browser:** run the engine on the Mac, `BOBCORN_HOST=127.0.0.1 node tizen/service/dev.js`, serve
  `tizen/` (`python3 -m http.server -d tizen 8000`), and open
  `http://localhost:8000/app/index.html?engine=http%3A%2F%2F127.0.0.1%3A8615` at 1920×1080. Arrows, Enter and Esc
  stand in for the remote; the player falls back to `<video>`, which plays MP4 but not MKV.
- **The engine's tests:** `node tizen/service/test/unit.js` (offline) and `node tizen/service/test/e2e.js` (streams a public-domain film from archive.org; add `magnet` to also fetch metadata from peers).
- **On the TV:** `python3 tizen/tools/sdb.py shell <IP> "0 vd_applist"` lists the apps;
  `python3 tizen/tools/sdb.py uninstall <IP>` removes Bobcorn.
