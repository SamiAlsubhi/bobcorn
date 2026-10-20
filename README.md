# Bobcorn

A Popcorn Time–style movie player for macOS, written in Swift. Add a source,
browse its poster grid, open a title, press play: the film streams over
BitTorrent while it downloads.

Bobcorn ships with no catalog of its own. Its Movies and TV Shows tabs show
the sources you add: a catalog API or an RSS or Atom torrent feed. You can
also open any magnet link or `.torrent`. Only add sources and open torrents you
have the right to download.

Website: https://samialsubhi.github.io/bobcorn. To try Bobcorn, add the
example source there: a catalog API of public-domain films and TV from the
Internet Archive, `https://samialsubhi.github.io/bobcorn/api`, built by
`scripts/make-example-source.py` into `docs/api`.

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
onto the other. Releases are signed with a Developer ID and notarized, so they
open anywhere. An installer built here without those credentials is signed
only ad hoc: on another Mac, macOS stops it the first time ("Apple could not
verify…"); click Done, then Open Anyway in System Settings → Privacy &
Security.

## Releases and updates

Pushing a version tag publishes a release:

```bash
git tag v1.2.0
```

```bash
git push origin v1.2.0
```

The [release workflow](.github/workflows/release.yml) runs the tests, builds
the installer for Apple silicon and Intel, signs it with the repository's
`UPDATE_SIGNING_KEY` secret and attaches `Bobcorn.dmg` and its signature to a
GitHub release.

Once the repository has a Developer ID Application certificate and an App
Store Connect API key as secrets (`scripts/set-release-secrets.sh` stores
them), releases are also signed with the hardened runtime, notarized, and
have the ticket stapled, so they open on any Mac without a warning. Without
them, releases are signed ad hoc.

Bobcorn checks for a newer release at launch and every hour, and
Bobcorn → Check for Updates… checks now. When there is one, an Update button
appears in the top bar: it downloads the installer, refuses it unless the
signature matches the public key in `Updater.swift`, swaps the app in place
and relaunches. To change keys, run
`swift scripts/sign-update.swift --new-key <file>`, put the file's contents
in the secret and the printed public key in `Updater.swift`, and release that
build signed with the old key first.

## Features

- **Sources**: on first launch Bobcorn asks for one; more go in Settings →
  Sources, and the one picked in the top bar fills the tabs. A catalog API is
  a JSON service with `/movies/<page>`, `/shows/<page>`, `/movie/<imdb_id>` and
  `/show/<imdb_id>` endpoints; genre, sort and search are passed to it, and the
  grid scrolls without end. A feed lists torrents as magnet links or
  `.torrent` files: its films go under Movies and its episodes under TV Shows.
- **Posters** show their rating as a star and a score out of five, their
  Rotten Tomatoes Tomatometer (a tomato when fresh, a splat when rotten),
  their qualities and their best seed count. Tomatometer scores come from
  OMDb, with a free key set in Settings → Sources, and are kept on disk.
- **Details**: synopsis, rating, runtime, genres, and every torrent with its
  quality, size and seeds, most seeds first. Shows have season and episode
  lists, and episodes play as one playlist; an episode inside a season pack
  plays its own file.
- **My List**: titles you heart, and Continue Watching for what you left
  part-way.
- **Chromecast**: the player's TV menu lists the Chromecasts and Google TVs
  on the network. Casting hands the device a stream from this Mac, remuxed MKV
  included, and the subtitle picked in the player, which shows on the TV; the
  seek bar shows what's downloaded, as it does here. The next episode follows,
  resume positions are kept, and stopping carries on here where the TV left
  off. Other devices only reach the streams
  Bobcorn hands out: each address carries a random secret.
- **Player**: AVKit with picture-in-picture and full screen. It resumes where
  you stopped, auto-plays the next episode, and shows `.srt`/`.vtt` subtitles
  from the torrent, a local file or OpenSubtitles.
- **OpenSubtitles**: with an API key set in Settings → Sources, the player's
  subtitles menu searches OpenSubtitles in the language set in Settings →
  Playback (Arabic unless you pick another), by the title's IMDb ID (or the
  file's name) and by the file's hash, so subtitles timed to that very release
  come first. Picking one downloads it into the cache folder, so picking it
  again doesn't count against the key's daily quota (5 on a free key), and
  the film or episode keeps it: it's in the menu, and on, when it plays again.
- **Any torrent** (⇧⌘O, ⌘O, drag and drop): shows each video's seeds and
  peers, best-seeded first.
- **MKV** plays in Bobcorn's own player. It's repackaged on the fly, while it
  downloads, as HLS that AVPlayer streams and seeks in: H.264, HEVC or AV1
  (on Macs that decode it) with AAC, AC-3, E-AC-3, MP3 or Opus. Nothing is
  re-encoded. AVI, and MKVs with DTS or TrueHD audio or VP9 video, open in
  IINA or VLC through the same local stream, and Bobcorn says why.

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

`Sources/CastKit` speaks the Cast protocol from scratch: Bonjour discovery,
the protocol-buffer framing over TLS, and Google's Default Media Receiver.

`Sources/Remux` turns Matroska into HLS without re-encoding, also with no
dependencies: `Matroska.swift` reads the tracks, the keyframe index and the
blocks (with lacing and header stripping), `Codecs.swift` describes each codec
the way MP4 does, `MP4.swift` writes fragmented MP4, and `HLSRemuxer.swift`
cuts segments at keyframes about six seconds apart, making each when the
player asks for it. A file without an index is cut at byte offsets instead.

Downloads go to one sparse file per torrent in `~/Library/Caches/Bobcorn`, so
watching one film out of a 40 GB torrent uses about that film's size on disk.
Subtitles downloaded from OpenSubtitles go in a `Subtitles` folder there.
Settings → Cache shows its size, clears it, and moves it to another folder or
drive, taking what's downloaded along.

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
