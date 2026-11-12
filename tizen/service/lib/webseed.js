'use strict';
// HTTP web seeds (BEP 19): a run of pieces fetched with Range requests from a
// plain web server, split across files for multi-file torrents.

const url = require('url');
const fetch = require('./fetch');
const util = require('./util');

class WebSeed {
    constructor(base, info) {
        // archive.org lists http:// seeds; every archive.org host serves https.
        const u = url.parse(base);
        if (u.protocol === 'http:' && u.hostname && (u.hostname === 'archive.org' || /\.archive\.org$/.test(u.hostname))) {
            base = 'https:' + base.slice(5);
        }
        this.base = base;
        this.info = info;
        this.active = 0;
        this.successes = 0;
        this.failures = 0;
        this.resolved = new Map(); // file position -> final URL after redirects
        this.disabledUntil = 0;
    }

    get maxConcurrent() { return this.successes > 0 ? 3 : 1; }

    get proven() { return this.successes > 0; }

    // `urgent` (a reader is waiting) gets one extra slot on a seed that works.
    available(urgent) {
        if (Date.now() < this.disabledUntil) return false;
        return this.active < this.maxConcurrent + (urgent && this.proven ? 1 : 0);
    }

    // Takes the seed out of rotation for a while.
    penalize(ms) {
        this.disabledUntil = Math.max(this.disabledUntil, Date.now() + ms);
    }

    fileURL(file, position) {
        if (this.resolved.has(position)) return this.resolved.get(position);
        const enc = s => encodeURIComponent(s);
        let s = this.base;
        if (this.info.multiFile) {
            if (s[s.length - 1] !== '/') s += '/';
            s += [this.info.name].concat(file.path).map(enc).join('/');
        } else if (s[s.length - 1] === '/') {
            s += enc(this.info.name);
        }
        return s;
    }

    // Fetches pieces [first, first+count). onPiece(index, buffer) for each whole
    // piece in order; onDone(err) at the end. Returns { abort() }.
    fetchRun(first, count, onPiece, onDone) {
        const info = this.info;
        const pl = info.pieceLength;
        const start = first * pl;
        const end = Math.min(info.length, (first + count) * pl); // exclusive
        this.active++;

        // The file segments covering [start, end).
        const segments = [];
        info.allFiles.forEach((f, position) => {
            const a = Math.max(start, f.offset);
            const b = Math.min(end, f.offset + f.size);
            if (b > a) segments.push({ file: f, position: position, from: a - f.offset, to: b - f.offset });
        });

        let piece = first;
        let pieceBuf = util.allocUnsafe(Math.min(pl, info.length - piece * pl));
        let fill = 0;
        let aborted = false;
        let finished = false;
        let currentRes = null;
        let currentReq = null;

        const finish = (err) => {
            if (finished) return;
            finished = true;
            this.active--;
            if (err && !aborted) {
                this.failures++;
                // A host that doesn't exist or refuses is out for 10 minutes;
                // other failures back off 5 s, 10 s, 20 s... up to 5 minutes.
                const dead = /ENOTFOUND|EAI_AGAIN|ECONNREFUSED|HTTP 40[34]/.test(err.code || err.message || '');
                this.penalize(dead ? 600000 : Math.min(300000, 5000 * Math.pow(2, this.failures - 1)));
            } else if (!err) {
                this.failures = 0;
                this.successes++;
            }
            onDone(aborted ? new Error('aborted') : err);
        };

        const push = (chunk) => {
            let off = 0;
            while (off < chunk.length && !aborted) {
                const n = Math.min(chunk.length - off, pieceBuf.length - fill);
                chunk.copy(pieceBuf, fill, off, off + n);
                fill += n;
                off += n;
                if (fill === pieceBuf.length) {
                    onPiece(piece, pieceBuf);
                    piece++;
                    fill = 0;
                    if (piece * pl < end) pieceBuf = util.allocUnsafe(Math.min(pl, info.length - piece * pl));
                }
            }
        };

        const nextSegment = (i) => {
            if (aborted) return finish(new Error('aborted'));
            if (i >= segments.length) return finish(null);
            const seg = segments[i];
            if (seg.file.pad) { // padding files are zeros and live on no server
                push(util.alloc(seg.to - seg.from));
                return nextSegment(i + 1);
            }
            const target = this.fileURL(seg.file, seg.position);
            fetch.request(target, {
                headers: { Range: 'bytes=' + seg.from + '-' + (seg.to - 1) },
                timeout: 20000,
                onRequest: r => { currentReq = r; }
            }, (err, res, finalUrl) => {
                if (err) return finish(err);
                if (aborted) { res.destroy(); return finish(new Error('aborted')); }
                currentRes = res;
                const ok = res.statusCode === 206 || (res.statusCode === 200 && seg.from === 0);
                if (!ok) {
                    res.resume();
                    return finish(new Error('web seed answered HTTP ' + res.statusCode));
                }
                if (finalUrl && finalUrl !== target) this.resolved.set(seg.position, finalUrl);
                let got = 0;
                const want = seg.to - seg.from;
                res.on('data', chunk => {
                    if (aborted) return;
                    if (got + chunk.length > want) chunk = chunk.slice(0, want - got);
                    got += chunk.length;
                    push(chunk);
                    if (got >= want) { res.destroy(); }
                });
                const segDone = () => {
                    if (got >= want) nextSegment(i + 1);
                    else finish(new Error('web seed ended early'));
                };
                let ended = false;
                res.on('end', () => { if (!ended) { ended = true; segDone(); } });
                res.on('close', () => { if (!ended) { ended = true; segDone(); } });
                res.on('error', e => { if (!ended) { ended = true; finish(e); } });
            });
        };
        nextSegment(0);

        return {
            first: first,
            count: count,
            seed: this,
            startedAt: Date.now(),
            abort: () => {
                if (aborted || finished) return;
                aborted = true;
                if (currentRes) currentRes.destroy();
                if (currentReq) currentReq.abort();
                finish(new Error('aborted'));
            }
        };
    }
}

module.exports = WebSeed;
