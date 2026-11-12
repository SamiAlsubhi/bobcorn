'use strict';
// A streaming torrent session. It only ever holds a sliding window of the
// streamed file: 5 minutes behind the playhead to 15 minutes ahead, plus the
// first and last 2 MiB (container headers and indexes). Everything outside is
// neither requested nor kept.

const EventEmitter = require('events').EventEmitter;
const Peer = require('./peer');
const WebSeed = require('./webseed');
const Storage = require('./storage');
const trackers = require('./trackers');
const dht = require('./dht');
const metainfo = require('./metainfo');
const fetch = require('./fetch');
const util = require('./util');

const BLOCK = 16384;
const BEHIND_SECONDS = 300;
const AHEAD_SECONDS = 900;
const PIN_BYTES = 2 * 1024 * 1024;
const DEFAULT_BPS = 600000;
const MAX_PEERS = 50;
const MAX_CONNECTING = 15;
const REQUEST_TIMEOUT = 20000;       // a block not delivered in this long is asked of someone else
const URGENT_TIMEOUT = 6000;         // ...or this long, right at the playhead
const CHOKED_GIVE_UP = 45000;        // a peer that won't send for this long makes room for another
const DUPLICATE_AFTER = 2500;
const UPLOAD_SLOTS = 6;             // peers we upload to at once, as the Mac engine does
const UPLOAD_RATE = 1024 * 1024;     // bytes per second at most, to spare the home connection        // an idle fast peer may re-ask a block another peer has had this long
const SEEK_STREAM_BYTES = 4 * 1024 * 1024; // a read outside the window this long is playback, not a probe

function cacheCap() {
    const env = parseInt(process.env.BOBCORN_CACHE_MAX || '', 10);
    return env > 0 ? env : 3 * 1024 * 1024 * 1024;
}

class Torrent extends EventEmitter {
    // opts: { infoHash, name, announce, urlList, exactSource, info, cacheDir, runtimeMinutes }
    constructor(opts) {
        super();
        this.infoHash = opts.infoHash;
        this.infoHashBuf = util.from(opts.infoHash, 'hex');
        this.displayName = opts.name || null;
        this.announce = (opts.announce || []).slice();
        this.urlList = (opts.urlList || []).slice();
        this.exactSource = opts.exactSource || [];
        this.cacheDir = opts.cacheDir;
        this.runtimeMinutes = opts.runtimeMinutes > 0 ? opts.runtimeMinutes : 0;
        this.peerId = util.peerId();
        this.info = null;
        this.storage = null;
        this.closed = false;

        this.peers = new Map(); // key -> Peer
        this.closeReasons = {};
        this.candidates = []; // [{host, port}]
        this.known = new Set(); // every address ever offered
        this.connecting = 0;
        this.webSeeds = [];
        this.webRuns = [];

        this.active = new Map(); // piece -> download state
        this.waiters = new Map(); // piece -> [fn]
        this.readers = new Set();
        this.metadataPieces = [];

        // Streaming state.
        this.file = null;
        this.durationSeconds = 0;
        this.positionSeconds = 0;
        this.positionAt = 0;
        this.seekOffset = -1;
        this.seekAt = 0;
        this.lastReadOffset = 0;
        this.win = null;

        this.downloaded = 0;
        this.uploaded = 0;
        this.uploadBudget = UPLOAD_RATE;
        this.speedSamples = [];
        this.speedBucket = 0;
        this.timers = [];
        this.scheduled = false;
        this.dhtLookup = null;
        this.lastDHT = 0;

        if (opts.info) this.setInfo(opts.info);
    }

    get name() { return this.info ? this.info.name : (this.displayName || this.infoHash); }

    start() {
        this.timers.push(setInterval(() => this.tick(), 1000));
        this.timers.push(setInterval(() => this.announceAll(), 60000));
        this.announceAll('started');
        this.lookupDHT();
        if (!this.info) this.fetchExactSource();
        this.schedule();
    }

    // cb(err) once the metadata is known, or after timeoutMs.
    whenReady(timeoutMs, cb) {
        if (this.info) return cb(null);
        let done = false;
        const timer = setTimeout(() => {
            if (done) return;
            done = true;
            this.removeListener('ready', onReady);
            cb(new Error('Timed out waiting for the torrent metadata (no peers answered)'));
        }, timeoutMs);
        const onReady = () => {
            if (done) return;
            done = true;
            clearTimeout(timer);
            cb(null);
        };
        this.once('ready', onReady);
    }

    setInfo(info) {
        if (this.info) return;
        this.info = info;
        info.announce.forEach(a => { if (this.announce.indexOf(a) === -1) this.announce.push(a); });
        info.urlList.forEach(u => { if (this.urlList.indexOf(u) === -1) this.urlList.push(u); });
        this.info.announce = this.announce;
        this.info.urlList = this.urlList;
        this.webSeeds = this.urlList.map(u => new WebSeed(u, info));
        this.storage = new Storage(this.cacheDir, this.infoHash, info.pieceLength);
        const vi = metainfo.videoIndex(info);
        this.selectFile(vi >= 0 ? vi : 0);
        util.log('ready:', info.name, info.files.length, 'files,', info.pieces.length, 'pieces of', info.pieceLength,
            'bytes,', this.webSeeds.length, 'web seeds');
        this.emit('ready');
        this.schedule();
    }

    // ---- Peer discovery ----

    addPeers(list) {
        list.forEach(p => {
            const k = p.host + ':' + p.port;
            if (this.known.has(k)) return;
            this.known.add(k);
            this.candidates.push(p);
        });
        this.connectMore();
    }

    announceAll(event) {
        if (this.closed) return;
        if (!event && this.peers.size >= 25) return;
        const left = this.info ? this.info.length : 1;
        this.announce.forEach(a => {
            trackers.announce(a, { infoHash: this.infoHashBuf, peerId: this.peerId, left: left, event: event }, (err, res) => {
                if (this.closed) return;
                if (err) return util.log('tracker', a, 'failed:', err.message);
                util.log('tracker', a, 'gave', res.peers.length, 'peers');
                this.addPeers(res.peers);
            });
        });
    }

    lookupDHT() {
        if (this.closed || this.dhtLookup) return;
        this.lastDHT = Date.now();
        let found = 0;
        this.dhtLookup = dht.lookup(this.infoHashBuf, peers => {
            found += peers.length;
            this.addPeers(peers);
        }, () => {
            this.dhtLookup = null;
            util.log('DHT lookup found', found, 'peers');
        }, 30000);
    }

    fetchExactSource() {
        this.exactSource.forEach(src => {
            fetch.getBuffer(src, { timeout: 30000 }, (err, body) => {
                if (err || this.info || this.closed) return;
                try {
                    const info = metainfo.parseTorrent(body);
                    if (info.infoHash === this.infoHash) this.setInfo(info);
                } catch (e) { /* not a usable .torrent */ }
            });
        });
    }

    connectMore() {
        while (!this.closed && this.candidates.length && this.peers.size < MAX_PEERS && this.connecting < MAX_CONNECTING) {
            const c = this.candidates.shift();
            const peer = new Peer(c.host, c.port, this.infoHashBuf, this.peerId);
            this.connecting++;
            let counted = true;
            const uncount = () => { if (counted) { counted = false; this.connecting--; } };
            this.peers.set(peer.key, peer);
            peer.on('handshake', () => {
                uncount();
                peer.chokedSince = Date.now();
                this.sendBitfield(peer);
                this.schedule();
            });
            // Uploading, as the Mac engine does: peers that get pieces from us send more back.
            peer.on('interested', () => {
                let open = 0;
                this.peers.forEach(p => { if (!p.amChoking) open++; });
                if (this.info && open < UPLOAD_SLOTS) peer.unchoke();
            });
            peer.on('not-interested', () => peer.choke());
            peer.on('request', (index, begin, length) => this.serve(peer, index, begin, length));
            peer.on('unchoke', () => { peer.chokedSince = 0; this.schedule(); });
            peer.on('have', () => this.schedule());
            peer.on('bitfield', () => this.schedule());
            peer.on('choke', () => { peer.chokedSince = Date.now(); this.releasePeer(peer); });
            peer.on('block', (index, begin, data) => this.onBlock(peer, index, begin, data));
            peer.on('extended', () => this.requestMetadata(peer));
            peer.on('metadata', (piece, data, total) => this.onMetadata(peer, piece, data, total));
            peer.on('close', (reason) => {
                // Why connections end, by reason (in /status): tells unreachable peers from refusals.
                const why = (peer.handshaken ? 'after handshake: ' : 'before handshake: ') + reason;
                this.closeReasons[why] = (this.closeReasons[why] || 0) + 1;
                uncount();
                this.peers.delete(peer.key);
                this.releasePeer(peer);
                this.connectMore();
            });
            peer.connect(10000);
        }
    }

    // ---- Magnet metadata (BEP 9) ----

    requestMetadata(peer) {
        if (this.info || !peer.utMetadata || !peer.metadataSize || peer.metadataSize > 16 * 1024 * 1024) return;
        const count = Math.ceil(peer.metadataSize / BLOCK);
        if (this.metadataPieces.length !== count) this.metadataPieces = new Array(count);
        for (let i = 0; i < count; i++) {
            if (!this.metadataPieces[i]) peer.requestMetadata(i);
        }
    }

    onMetadata(peer, piece, data, total) {
        if (this.info || typeof piece !== 'number') return;
        const count = Math.ceil((total || peer.metadataSize) / BLOCK);
        if (this.metadataPieces.length !== count) this.metadataPieces = new Array(count);
        if (piece >= count) return;
        this.metadataPieces[piece] = data;
        for (let i = 0; i < count; i++) if (!this.metadataPieces[i]) return;
        const buf = Buffer.concat(this.metadataPieces);
        if (util.sha1(buf).toString('hex') !== this.infoHash) {
            util.log('metadata hash mismatch from', peer.key);
            this.metadataPieces = [];
            peer.destroy('bad metadata');
            return;
        }
        try {
            this.setInfo(metainfo.parseInfo(buf, { announce: [], urlList: [] }));
        } catch (e) {
            util.log('bad metadata:', e.message);
            this.metadataPieces = [];
        }
    }

    // ---- Streaming window ----

    selectFile(index) {
        if (!this.info) return;
        const f = this.info.files[index];
        if (!f || f === this.file) return;
        this.file = f;
        this.durationSeconds = 0;
        this.positionSeconds = 0;
        this.positionAt = 0;
        this.seekOffset = -1;
        this.seekAt = 0;
        this.lastReadOffset = 0;
        this.updateWindow();
    }

    setPosition(fileIndex, seconds, duration) {
        if (!this.info) return;
        if (typeof fileIndex === 'number' && fileIndex >= 0) this.selectFile(fileIndex);
        if (duration > 0) this.durationSeconds = duration;
        if (seconds >= 0) {
            this.positionSeconds = seconds;
            this.positionAt = Date.now();
        }
        this.updateWindow();
    }

    bytesPerSecond() {
        const f = this.file;
        if (!f) return DEFAULT_BPS;
        if (this.durationSeconds > 0) return Math.max(1, f.size / this.durationSeconds);
        if (this.runtimeMinutes > 0) return Math.max(1, f.size / (this.runtimeMinutes * 60));
        return DEFAULT_BPS;
    }

    // The playhead as a byte offset in the file.
    playhead() {
        const f = this.file;
        const bps = this.bytesPerSecond();
        if (this.positionAt && this.positionAt >= this.seekAt) return Math.min(f.size, Math.floor(this.positionSeconds * bps));
        if (this.seekAt) return this.seekOffset;
        return this.lastReadOffset;
    }

    pieceAt(absoluteOffset) {
        return Math.floor(absoluteOffset / this.info.pieceLength);
    }

    updateWindow() {
        const f = this.file;
        if (!f) return;
        const bps = this.bytesPerSecond();
        const head = this.playhead();
        let behind = BEHIND_SECONDS * bps;
        let ahead = AHEAD_SECONDS * bps;
        const room = cacheCap() - 2 * PIN_BYTES;
        if (behind + ahead > room) {
            ahead = Math.max(32 * 1024 * 1024, room - behind);
            if (behind + ahead > room) behind = Math.max(0, room - ahead);
        }
        const start = Math.max(0, Math.floor(head - behind));
        const end = Math.min(f.size, Math.ceil(head + ahead));
        const old = this.win;
        this.win = {
            start: start,
            end: Math.max(end, Math.min(f.size, start + 1)),
            head: head,
            bps: bps,
            pStart: this.pieceAt(f.offset + start),
            pEnd: this.pieceAt(f.offset + Math.max(start, Math.min(f.size, end) - 1)),
            pHead: this.pieceAt(f.offset + Math.min(head, Math.max(0, f.size - 1))),
            headPins: [this.pieceAt(f.offset), this.pieceAt(f.offset + Math.min(PIN_BYTES, f.size) - 1)],
            tailPins: [this.pieceAt(f.offset + Math.max(0, f.size - PIN_BYTES)), this.pieceAt(f.offset + f.size - 1)]
        };
        if (!old || old.pStart !== this.win.pStart || old.pEnd !== this.win.pEnd) {
            this.dropUnwanted();
            this.evict();
        }
        this.schedule();
    }

    inWindow(i) {
        const w = this.win;
        return !!w && i >= w.pStart && i <= w.pEnd;
    }

    pinned(i) {
        const w = this.win;
        return !!w && ((i >= w.headPins[0] && i <= w.headPins[1]) || (i >= w.tailPins[0] && i <= w.tailPins[1]));
    }

    // Pieces a reader is on or about to need, even outside the window.
    readerNeeds(i) {
        let need = false;
        this.readers.forEach(r => {
            if (r.closed) return;
            const p = this.pieceAt(r.file.offset + r.pos);
            if (i >= p && i <= p + 2) need = true;
        });
        return need;
    }

    keep(i) {
        return this.inWindow(i) || this.pinned(i) || this.readerNeeds(i);
    }

    // Pieces to fetch, most urgent first: what readers wait for, the pinned
    // head and tail, then the playhead forward to the window's end.
    wantedList() {
        const list = [];
        const seen = new Set();
        const add = (i) => {
            if (i < 0 || i >= this.info.pieces.length || seen.has(i)) return;
            seen.add(i);
            if (!this.storage.has(i)) list.push(i);
        };
        const readers = [];
        this.readers.forEach(r => { if (!r.closed) readers.push(r); });
        readers.sort((a, b) => b.touched - a.touched);
        readers.forEach(r => {
            const p = this.pieceAt(r.file.offset + r.pos);
            add(p); add(p + 1); add(p + 2);
        });
        const w = this.win;
        if (!w) return list;
        for (let i = w.headPins[0]; i <= w.headPins[1]; i++) add(i);
        for (let i = w.tailPins[0]; i <= w.tailPins[1]; i++) add(i);
        for (let i = Math.max(w.pStart, w.pHead); i <= w.pEnd; i++) add(i);
        return list;
    }

    // Cancels requests and web runs for pieces nothing wants any more.
    dropUnwanted() {
        if (!this.info) return;
        this.active.forEach((a, i) => {
            if (this.keep(i)) return;
            if (a.owner === 'peers') {
                a.requestedBy.forEach((set, b) => {
                    set.forEach(key => {
                        const peer = this.peers.get(key);
                        if (peer) peer.cancel(i, b * BLOCK, this.blockLength(i, b));
                    });
                });
                this.active.delete(i);
            }
        });
        this.webRuns.slice().forEach(run => {
            let anyWanted = false;
            for (let i = run.first; i < run.first + run.count; i++) if (this.keep(i) && !this.storage.has(i)) anyWanted = true;
            if (!anyWanted) run.abort();
        });
    }

    evict() {
        if (!this.storage) return;
        const drop = [];
        this.storage.forEach(i => { if (!this.keep(i)) drop.push(i); });
        drop.forEach(i => this.storage.evict(i));
        if (drop.length) util.log('evicted', drop.length, 'pieces; cache holds', this.storage.count);
    }

    // ---- Downloading ----

    pieceLength(i) {
        const pl = this.info.pieceLength;
        return Math.min(pl, this.info.length - i * pl);
    }

    blockLength(i, b) {
        return Math.min(BLOCK, this.pieceLength(i) - b * BLOCK);
    }

    newActive(i, owner) {
        const length = this.pieceLength(i);
        const blocks = Math.ceil(length / BLOCK);
        const a = {
            index: i,
            owner: owner,
            length: length,
            blocks: blocks,
            data: owner === 'peers' ? util.allocUnsafe(length) : null,
            received: new Array(blocks),
            receivedCount: 0,
            requestedBy: new Map(), // block -> Set(peer keys)
            contributors: new Set()
        };
        this.active.set(i, a);
        return a;
    }

    maxActive() {
        const budget = 96 * 1024 * 1024;
        return Math.max(4, Math.min(64, Math.floor(budget / this.info.pieceLength)));
    }

    schedule() {
        if (this.scheduled || this.closed) return;
        this.scheduled = true;
        setImmediate(() => {
            this.scheduled = false;
            if (!this.closed && this.info && this.storage) this.pick();
        });
    }

    pick() {
        const list = this.wantedList();
        if (!list.length) return;
        const wanted = new Set(list);

        const urgent = list.slice(0, 3);
        const anyProven = this.webSeeds.some(s => s.proven && Date.now() >= s.disabledUntil);

        // An urgent piece stuck on an untested seed for 4 s goes back to the pool
        // (and that seed sits out 30 s) so a seed that works can take it.
        if (anyProven) {
            this.webRuns.slice().forEach(run => {
                if (run.seed.proven || Date.now() - run.startedAt < 4000) return;
                for (let i = run.first; i < run.first + run.count; i++) {
                    if (urgent.indexOf(i) !== -1) {
                        run.seed.penalize(30000);
                        run.abort();
                        return;
                    }
                }
            });
        }

        // Web seeds take runs of consecutive pieces no one is fetching yet,
        // healthiest seeds first; untested seeds don't get urgent pieces
        // while a working one is around.
        const seeds = this.webSeeds.slice().sort((a, b) => (b.successes - a.successes) || (a.failures - b.failures));
        seeds.forEach(seed => {
            for (let guard = 0; guard < 8; guard++) {
                let first = -1;
                for (let k = 0; k < list.length; k++) {
                    const i = list[k];
                    if (this.active.has(i)) continue;
                    if (!seed.proven && anyProven && urgent.indexOf(i) !== -1) continue;
                    first = i;
                    break;
                }
                if (first < 0 || !seed.available(urgent.indexOf(first) !== -1)) return;
                let count = 1;
                const maxCount = Math.max(1, Math.floor(4 * 1024 * 1024 / this.info.pieceLength));
                // Urgent pieces go alone so they arrive as fast as possible.
                if (urgent.indexOf(first) === -1) {
                    while (count < maxCount && wanted.has(first + count) && !this.active.has(first + count)) count++;
                }
                this.startWebRun(seed, first, count);
            }
        });

        // Peers fill their request pipelines: each as deep as its speed warrants (about 3 s of data), so a
        // slow peer can't sit on the blocks that fast ones would deliver at once.
        const fastest = [];
        this.peers.forEach(peer => { if (peer.handshaken && !peer.choked && !peer.closed) fastest.push(peer); });
        fastest.sort((x, y) => (y.rate || 0) - (x.rate || 0));
        const now = Date.now();
        // Once comfortably ahead (2 min), download no faster than 4x the video's rate (at least 3 MB/s):
        // plenty to stay ahead, and gentler on the home network. Pieces at the playhead are never held back.
        const calm = this.secondsAhead() > 120 && this.downSpeed() > Math.max(3 * 1024 * 1024, 4 * (this.win ? this.win.bps : 0));
        fastest.forEach(peer => {
            const limit = calm ? Math.min(this.pipeline(peer), 8) : this.pipeline(peer);
            if (peer.requests.size >= limit) return;
            // First pass: blocks nobody has asked for. Second pass, for a peer still with room: blocks a
            // slower peer has had for a while (endgame-style), so the playhead never waits on the slowest.
            for (let pass = 0; pass < 2 && peer.requests.size < limit; pass++) {
                for (let k = 0; k < list.length && peer.requests.size < limit; k++) {
                    const i = list[k];
                    if (!peer.has(i)) continue;
                    let a = this.active.get(i);
                    if (a && a.owner !== 'peers') continue;
                    const urgentPiece = urgent.indexOf(i) !== -1;
                    if (!a) {
                        // The pieces at the playhead always start; others wait for room under the cap, or
                        // pieces further ahead stuck on slow peers would keep the player waiting (a deadlock
                        // seen on a TV: the player stalled for minutes on one piece that never began).
                        if (pass === 1 || (!urgentPiece && this.activePeerPieces() >= this.maxActive())) continue;
                        a = this.newActive(i, 'peers');
                    }
                    for (let b = 0; b < a.blocks && peer.requests.size < limit; b++) {
                        if (a.received[b]) continue;
                        let set = a.requestedBy.get(b);
                        if (!set) { set = new Set(); a.requestedBy.set(b, set); }
                        if (set.has(peer.key)) continue;
                        if (set.size > 0) {
                            if (pass === 0 || set.size >= (urgentPiece ? 3 : 2)) continue;
                            if (!this.stuckOnSlower(set, i, b, peer, now)) continue;
                        }
                        set.add(peer.key);
                        peer.request(i, b * BLOCK, this.blockLength(i, b));
                    }
                }
            }
        });
    }

    // Contiguous seconds of video held from the playhead.
    secondsAhead() {
        const w = this.win, f = this.file;
        if (!w || !f || !this.storage) return 0;
        const last = this.pieceAt(f.offset + f.size - 1);
        let i = w.pHead;
        while (i <= last && this.storage.has(i)) i++;
        const reach = Math.min(f.offset + f.size, i * this.info.pieceLength);
        return Math.max(0, reach - (f.offset + w.head)) / w.bps;
    }

    // Requests a peer may have in flight: about 3 s of its measured speed, 8 for a new one, at most 250.
    pipeline(peer) {
        const byRate = Math.ceil((peer.rate || 0) * 3 / BLOCK);
        return Math.max(8, Math.min(peer.maxRequests, 250, byRate + 4));
    }

    // Whether block b of piece i, asked of the peers in `set`, waits on someone slower than `peer` who has
    // had it longer than DUPLICATE_AFTER.
    stuckOnSlower(set, i, b, peer, now) {
        let stuck = true;
        set.forEach(key => {
            const other = this.peers.get(key);
            const r = other && other.requests.get(i + ':' + (b * BLOCK));
            if (!other || !r) return;
            if ((other.rate || 0) >= (peer.rate || 0) || now - r.at < DUPLICATE_AFTER) stuck = false;
        });
        return stuck;
    }

    activePeerPieces() {
        let n = 0;
        this.active.forEach(a => { if (a.owner === 'peers') n++; });
        return n;
    }

    startWebRun(seed, first, count) {
        for (let i = first; i < first + count; i++) this.newActive(i, 'webseed');
        const run = seed.fetchRun(first, count, (index, buf) => {
            this.countBytes(buf.length);
            this.active.delete(index);
            this.finishPiece(index, buf, null);
        }, (err) => {
            const at = this.webRuns.indexOf(run);
            if (at !== -1) this.webRuns.splice(at, 1);
            for (let i = first; i < first + count; i++) {
                const a = this.active.get(i);
                if (a && a.owner === 'webseed') this.active.delete(i);
            }
            if (err && err.message !== 'aborted') util.log('web seed', seed.base, 'failed:', err.message);
            this.schedule();
        });
        this.webRuns.push(run);
    }

    onBlock(peer, index, begin, data) {
        this.countBytes(data.length);
        const a = this.active.get(index);
        if (!a || a.owner !== 'peers') return;
        const b = begin / BLOCK;
        if (b !== Math.floor(b) || b >= a.blocks || data.length !== this.blockLength(index, b)) return;
        if (a.received[b]) return;
        data.copy(a.data, begin);
        a.received[b] = true;
        a.receivedCount++;
        a.contributors.add(peer.key);
        const set = a.requestedBy.get(b);
        if (set) {
            set.forEach(key => {
                if (key === peer.key) return;
                const other = this.peers.get(key);
                if (other) other.cancel(index, begin, data.length);
            });
            a.requestedBy.delete(b);
        }
        if (a.receivedCount === a.blocks) {
            this.active.delete(index);
            this.finishPiece(index, a.data, a.contributors);
        } else {
            this.schedule();
        }
    }

    // The pieces we hold, for a newly connected peer.
    sendBitfield(peer) {
        if (!this.info || !this.storage || !this.storage.count) return;
        const bits = util.alloc(Math.ceil(this.info.pieces.length / 8));
        this.storage.forEach(i => { bits[i >> 3] |= 0x80 >> (i & 7); });
        peer.sendBitfield(bits);
    }

    // A block a peer asked for, from the cache: only to peers we've unchoked, only what we still hold,
    // within UPLOAD_RATE. Anything else is left unanswered and the peer asks someone else.
    serve(peer, index, begin, length) {
        if (peer.amChoking || !this.info || !this.storage || !this.storage.has(index)) return;
        if (length > 128 * 1024 || begin + length > this.pieceLength(index) || peer.serving >= 16) return;
        if (this.uploadBudget < length) return;
        this.uploadBudget -= length;
        peer.serving++;
        this.storage.read(index, begin, length, (err, block) => {
            peer.serving--;
            if (err || peer.closed || peer.amChoking) return;
            peer.sendPiece(index, begin, block);
            this.uploaded += block.length;
        });
    }

    // A peer went away or choked us: its requests are void.
    releasePeer(peer) {
        peer.requests.forEach(r => {
            const a = this.active.get(r.index);
            if (!a || a.owner !== 'peers') return;
            const set = a.requestedBy.get(r.begin / BLOCK);
            if (set) set.delete(peer.key);
        });
        peer.requests.clear();
        this.schedule();
    }

    finishPiece(index, data, contributors) {
        if (util.sha1(data).equals(this.info.pieces[index]) === false) {
            util.log('piece', index, 'failed its hash check');
            if (contributors) contributors.forEach(key => { const p = this.peers.get(key); if (p) p.destroy('bad data'); });
            this.schedule();
            return;
        }
        if (!this.keep(index) || this.storage.has(index)) {
            this.schedule();
            return;
        }
        this.storage.write(index, data, err => {
            if (err) {
                util.log('cache write failed:', err.message);
                return;
            }
            const waiting = this.waiters.get(index);
            if (waiting) {
                this.waiters.delete(index);
                waiting.forEach(fn => fn());
            }
            this.emit('piece', index);
            // Tell connected peers we have it now (those that lack it may ask us for it).
            this.peers.forEach(p => { if (p.handshaken && !p.closed && !p.has(index)) p.sendHave(index); });
            this.schedule();
        });
    }

    countBytes(n) {
        this.downloaded += n;
        this.speedBucket += n;
    }

    // Once a second: speed, request timeouts, peer upkeep.
    tick() {
        if (this.closed) return;
        this.uploadBudget = UPLOAD_RATE;
        this.speedSamples.push(this.speedBucket);
        this.speedBucket = 0;
        if (this.speedSamples.length > 5) this.speedSamples.shift();
        const now = Date.now();
        const urgent = this.info && this.storage ? this.wantedList().slice(0, 3) : [];
        let chokedLongest = null;
        this.peers.forEach(peer => {
            // Speed over the last few seconds (smoothed), for sizing its pipeline.
            const got = peer.downloaded - (peer.lastCount || 0);
            peer.lastCount = peer.downloaded;
            peer.rate = Math.round((peer.rate || 0) * 0.6 + got * 0.4);
            peer.requests.forEach(r => {
                const limit = urgent.indexOf(r.index) !== -1 ? URGENT_TIMEOUT : REQUEST_TIMEOUT;
                if (now - r.at > limit) {
                    peer.cancel(r.index, r.begin, r.length);
                    const a = this.active.get(r.index);
                    const set = a && a.requestedBy.get(r.begin / BLOCK);
                    if (set) set.delete(peer.key);
                }
            });
            if (peer.handshaken && !peer.choked && peer.requests.size && now - peer.lastData > 60000) peer.destroy('snubbed');
            if (peer.handshaken && peer.choked && peer.chokedSince && now - peer.chokedSince > CHOKED_GIVE_UP &&
                (!chokedLongest || peer.chokedSince < chokedLongest.chokedSince)) chokedLongest = peer;
        });
        // Swap out the peer that has refused to send the longest, while there are others to try.
        if (chokedLongest && this.candidates.length && this.peers.size >= MAX_PEERS - 5) chokedLongest.destroy('kept us choked');
        if (this.peers.size < 10 && now - this.lastDHT > 300000) this.lookupDHT();
        this.connectMore();
        this.schedule();
    }

    downSpeed() {
        if (!this.speedSamples.length) return 0;
        let sum = 0;
        this.speedSamples.forEach(s => { sum += s; });
        return Math.round(sum / this.speedSamples.length);
    }

    // ---- Reading ----

    // A sequential reader over one file, starting at `start` (file offset).
    openReader(fileIndex, start) {
        const f = this.info.files[fileIndex];
        // Reading a subtitle or other small file doesn't change which video streams.
        if (f !== this.file && (!this.file || metainfo.isVideo(f.path.join('/')))) this.selectFile(fileIndex);
        const r = { file: f, pos: start, start: start, closed: false, touched: Date.now(), playback: false };
        this.readers.add(r);
        const w = this.win;
        const inside = w && start >= w.start && start < w.end;
        const inPins = start < PIN_BYTES || start >= f.size - PIN_BYTES;
        if (inside || (!this.positionAt && !this.seekAt && !inPins)) {
            r.playback = true;
            if (!this.positionAt) this.lastReadOffset = start;
        }
        this.updateWindow();
        return r;
    }

    closeReader(r) {
        r.closed = true;
        this.readers.delete(r);
    }

    // Reads up to maxLen bytes at the reader's position; waits for data.
    // cb(err, buffer) with a non-empty buffer, or an empty one at the end of the file.
    read(r, maxLen, cb) {
        if (this.closed) return cb(new Error('closed'));
        const f = r.file;
        if (r.pos >= f.size) return cb(null, util.alloc(0));
        const abs = f.offset + r.pos;
        const i = this.pieceAt(abs);
        const inPiece = abs - i * this.info.pieceLength;
        const len = Math.min(maxLen, this.pieceLength(i) - inPiece, f.size - r.pos);
        r.touched = Date.now();
        if (this.storage.has(i)) {
            this.storage.read(i, inPiece, len, (err, buf) => {
                if (err && /not cached/.test(err.message)) return this.read(r, maxLen, cb); // evicted meanwhile
                if (err) return cb(err);
                this.advance(r, buf.length);
                cb(null, buf);
            });
            return;
        }
        let list = this.waiters.get(i);
        if (!list) { list = []; this.waiters.set(i, list); }
        list.push(() => { if (!r.closed) this.read(r, maxLen, cb); });
        this.schedule();
    }

    advance(r, n) {
        const before = this.pieceAt(r.file.offset + r.pos);
        r.pos += n;
        // A read that keeps streaming outside the window is playback after a
        // seek: move the window there.
        if (!r.playback && r.pos - r.start >= SEEK_STREAM_BYTES) {
            r.playback = true;
            this.seekOffset = r.pos;
            this.seekAt = Date.now();
            util.log('seek to byte', r.pos);
        }
        if (r.playback && !this.positionAt && !this.seekAt) this.lastReadOffset = r.pos;
        if (this.pieceAt(r.file.offset + r.pos) !== before) this.updateWindow();
    }

    // ---- Status and teardown ----

    status() {
        const s = {
            id: this.infoHash,
            name: this.name,
            file: this.file ? this.file.index : -1,
            peers: 0,
            webSeeds: 0,
            downSpeed: this.downSpeed(),
            downloaded: this.downloaded,
            windowStart: 0,
            windowEnd: 0,
            playhead: 0,
            aheadBytes: 0,
            aheadSeconds: 0,
            cacheBytes: this.storage ? this.storage.bytes : 0,
            pieces: { have: 0, want: 0 }
        };
        s.unchoked = 0;
        s.requests = 0;
        this.peers.forEach(p => {
            if (!p.handshaken) return;
            s.peers++;
            if (!p.choked) s.unchoked++;
            s.requests += p.requests.size;
        });
        s.candidates = this.candidates ? this.candidates.length : 0;
        s.closes = this.closeReasons;
        s.uploaded = this.uploaded;
        s.uploading = 0;
        this.peers.forEach(p => { if (!p.amChoking) s.uploading++; });
        this.webSeeds.forEach(w => { if (w.active > 0) s.webSeeds++; });
        const w = this.win;
        if (!w || !this.file) return s;
        const f = this.file;
        s.windowStart = w.start;
        s.windowEnd = w.end;
        s.playhead = w.head;
        let have = 0;
        for (let i = w.pStart; i <= w.pEnd; i++) if (this.storage.has(i)) have++;
        s.pieces = { have: have, want: w.pEnd - w.pStart + 1 };
        // Contiguous verified bytes from the playhead.
        let i = w.pHead;
        while (i <= this.pieceAt(f.offset + f.size - 1) && this.storage.has(i)) i++;
        const reach = Math.min(f.offset + f.size, i * this.info.pieceLength);
        s.aheadBytes = Math.max(0, reach - (f.offset + w.head));
        s.aheadSeconds = Math.round(s.aheadBytes / w.bps);
        // The container's start and index (MP4 moov, MKV cues): a player reads these first.
        const all = (a, b) => { for (let j = a; j <= b; j++) if (!this.storage.has(j)) return false; return true; };
        s.headReady = all(w.headPins[0], w.headPins[1]);
        s.tailReady = all(w.tailPins[0], w.tailPins[1]);
        return s;
    }

    close() {
        if (this.closed) return;
        this.closed = true;
        this.timers.forEach(t => clearInterval(t));
        if (this.dhtLookup) this.dhtLookup.stop();
        this.peers.forEach(p => p.destroy('torrent closed'));
        this.peers.clear();
        this.webRuns.slice().forEach(r => r.abort());
        this.readers.forEach(r => { r.closed = true; });
        this.readers.clear();
        this.waiters.clear();
        if (this.storage) this.storage.close();
        this.emit('closed');
    }
}

module.exports = Torrent;
