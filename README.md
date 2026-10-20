# Bobcorn

A Popcorn Time–style movie player for macOS, written in Swift. Browse a
poster grid, open a title, press play: the film streams over BitTorrent while
it downloads.

The catalog is the Internet Archive's public-domain and openly licensed film,
TV and animation collections (`feature_films`, `classic_tv`,
`animationandcartoons`). Every archive.org title has a real `.torrent` with
the Archive's servers as web seeds, so titles stream from the swarm and the
Archive at once. You can also open any magnet link or `.torrent` you have the
right to download.

## Build and run

Requires macOS 14 or later and Xcode 15 or later (Swift 5.10+).

```bash
scripts/build-app.sh
```

```bash
open build/Bobcorn.app
```

`scripts/build-app.sh install` also copies it to `/Applications`, which
registers it for `magnet:` links and `.torrent` files.

To install it on another Mac, make the installer:

```bash
scripts/make-installer.sh
```

`build/Bobcorn.dmg` opens to Bobcorn beside a link to Applications; drag one
onto the other. The app is signed only ad hoc, not notarized, so the first time
it opens on another Mac, macOS blocks it: Control-click it and choose Open, or
allow it in System Settings → Privacy & Security.

## Features

- **Browse** Movies, TV Shows, Animation, and My List. Filter by genre, sort by
  popularity, trending, rating, year, date added or title, and search. The grid
  scrolls without end.
- **Details**: synopsis, rating, director, a quality picker, an episode list
  for series, and watched/favorite marks.
- **Seed counts**: while a detail page is open, Bobcorn joins the title's
  swarm without downloading and counts the peers holding each file. Quality
  options show their seeds and are sorted by them. Pressing play reuses that
  already-connected swarm.
- **Player**: AVKit with picture-in-picture and full screen. It resumes where
  you stopped, auto-plays the next episode, and shows `.srt`/`.vtt` subtitles
  from the title, the torrent or a local file.
- **Sources**: Settings → Sources adds your own RSS or Atom torrent feeds, or
  a catalog API, a JSON service with `/movies/<page>`, `/shows/<page>`,
  `/movie/<imdb_id>` and `/show/<imdb_id>` endpoints. An API source gets its
  own endless poster grid of movies and shows, with genre, sort and search
  passed to the API, and detail pages listing each torrent's quality, size and
  seeds. Shows have season and episode lists; episodes play as one playlist,
  and an episode inside a season pack plays its own file. Only add sources
  you have the right to download from.
- **Any torrent** (⇧⌘O, ⌘O, drag and drop): shows each video's seeds and
  peers, best-seeded first.
- **MKV** plays in Bobcorn's own player. It's repackaged on the fly, while it
  downloads, as HLS that AVPlayer streams and seeks in: H.264, HEVC or AV1
  (on Macs that decode it) with AAC, AC-3, E-AC-3, MP3 or Opus. Nothing is
  re-encoded. AVI, and MKVs with DTS or TrueHD audio or VP9 video, open in
  IINA or VLC through the same local stream, and Bobcorn says why.
- **Resilient**: if a torrent stalls or an archive.org data node is down,
  playback falls back to direct HTTPS from a node that works.

## How it works

`Sources/TorrentKit` is a BitTorrent client written from scratch, with no
dependencies:

| File | What it does |
| --- | --- |
| `Bencode.swift`, `Metainfo.swift` | bencode, `.torrent` files, magnet links (hex and base32), BEP 47 padding files |
| `Trackers.swift` | HTTP and UDP (BEP 15) trackers |
| `DHT.swift` | mainline DHT `get_peers` lookups (BEP 5) for tracker-less magnets |
| `PeerConnection.swift` | the peer wire protocol over `Network.framework` |
| `TorrentSession.swift` | metadata exchange (BEP 9/10), streaming piece picker, endgame re-requests near the play position, hash checks, resume state |
| `WebSeed.swift` | HTTP web seeds (BEP 19) |
| `StreamServer.swift` | a loopback HTTP server with Range support that AVPlayer reads from; a read of missing bytes waits for them and moves the download window there |

`Sources/Remux` turns Matroska into HLS without re-encoding, also with no
dependencies: `Matroska.swift` reads the tracks, the keyframe index and the
blocks (with lacing and header stripping), `Codecs.swift` describes each codec
the way MP4 does, `MP4.swift` writes fragmented MP4, and `HLSRemuxer.swift`
cuts segments at keyframes about six seconds apart, making each when the
player asks for it. A file without an index is cut at byte offsets instead.

Downloads go to one sparse file per torrent in `~/Library/Caches/Bobcorn`, so
watching one film out of a 40 GB torrent uses about that film's size on disk.
Settings → Cache shows its size and clears it.

`swift run bobcorn-torrent <magnet|.torrent URL|path> [MB]` streams the first
megabytes of a torrent's largest video through the engine headlessly, which is
handy for testing. `swift test` runs the unit tests.

Debug builds (`scripts/build-app.sh debug`) can drive the UI from a script
and save screenshots; see `Sources/Bobcorn/DebugScript.swift`.

## Limits

- Bobcorn leeches with minimal upload: it serves pieces to the peers it
  connects to but does not accept incoming connections.
- The DHT client only looks up peers; it does not join the DHT as a node.
- BitTorrent v2-only torrents are not supported.
