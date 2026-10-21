'use strict';
// The HTTP API the TV app and its player use (contract in the TV app docs);
// every response carries CORS headers.

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const url = require('url');
const Torrent = require('./torrent');
const metainfo = require('./metainfo');
const fetch = require('./fetch');
const util = require('./util');
const unzip = require('./unzip');

const VERSION = '1.1.0';
const PORT = 8615;

function pickCacheDir() {
    const options = [process.env.BOBCORN_CACHE, '/home/owner/share/bobcorn-cache', path.join(os.tmpdir(), 'bobcorn-cache')];
    for (let k = 0; k < options.length; k++) {
        const dir = options[k];
        if (!dir) continue;
        try {
            mkdirp(dir);
            const probe = path.join(dir, '.probe');
            fs.writeFileSync(probe, 'ok');
            fs.unlinkSync(probe);
            return dir;
        } catch (e) { /* try the next */ }
    }
    throw new Error('No writable cache directory');
}

function mkdirp(dir) {
    if (fs.existsSync(dir)) return;
    mkdirp(path.dirname(dir));
    fs.mkdirSync(dir);
}

function wipe(dir) {
    fs.readdirSync(dir).forEach(name => {
        if (/\.cache$/.test(name)) {
            try { fs.unlinkSync(path.join(dir, name)); } catch (e) { /* in use or gone */ }
        }
    });
}

function cors(res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Range');
    res.setHeader('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges, X-File-Name');
}

function json(res, code, body) {
    const data = util.from(JSON.stringify(body));
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length });
    res.end(data);
}

function readBody(req, cb) {
    const chunks = [];
    let size = 0;
    req.on('data', c => {
        size += c.length;
        if (size < 1024 * 1024) chunks.push(c);
    });
    req.on('end', () => {
        if (!chunks.length) return cb(null, {});
        try { cb(null, JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (e) { cb(new Error('Body is not JSON')); }
    });
    req.on('error', cb);
}

function createServer() {
    const cacheDir = pickCacheDir();
    wipe(cacheDir);
    const torrents = new Map(); // id -> Torrent
    util.log('cache in', cacheDir, '| node', process.version, '| TLS checks', fetch.VERIFY_TLS ? 'on' : 'off');

    const closeOthers = (keepId) => {
        torrents.forEach((t, id) => {
            if (id === keepId) return;
            t.close();
            torrents.delete(id);
        });
    };

    const describe = (t) => ({
        id: t.infoHash,
        name: t.name,
        files: t.info.files.map(f => ({ index: f.index, path: f.path.join('/'), size: f.size })),
        videoIndex: metainfo.videoIndex(t.info)
    });

    // Resolves a link to { infoHash, name, announce, urlList, exactSource, info }.
    const resolveLink = (link, cb) => {
        if (/^magnet:/i.test(link)) {
            let m;
            try { m = metainfo.parseMagnet(link); } catch (e) { return cb(e); }
            return cb(null, { infoHash: m.infoHash, name: m.name, announce: m.announce, urlList: m.urlList, exactSource: m.exactSource });
        }
        if (/^https?:\/\//i.test(link)) {
            return fetch.getBuffer(link, { timeout: 30000, maxBytes: 16 * 1024 * 1024 }, (err, body, res) => {
                if (err) return cb(new Error('Could not download the .torrent: ' + err.message));
                if (res.statusCode !== 200) return cb(new Error('The .torrent link answered HTTP ' + res.statusCode));
                let info;
                try { info = metainfo.parseTorrent(body); } catch (e) { return cb(e); }
                cb(null, { infoHash: info.infoHash, name: info.name, announce: info.announce, urlList: info.urlList, info: info });
            });
        }
        cb(new Error('Give a magnet link or an http(s) .torrent URL'));
    };

    const openTorrent = (body, res) => {
        const link = typeof body.link === 'string' ? body.link.trim() : '';
        if (!link) return json(res, 400, { error: 'Missing "link"' });
        resolveLink(link, (err, r) => {
            if (err) return json(res, 400, { error: err.message });
            let t = torrents.get(r.infoHash);
            closeOthers(r.infoHash);
            if (!t) {
                t = new Torrent({
                    infoHash: r.infoHash, name: r.name, announce: r.announce, urlList: r.urlList,
                    exactSource: r.exactSource, info: r.info, cacheDir: cacheDir, runtimeMinutes: Number(body.runtimeMinutes) || 0
                });
                torrents.set(r.infoHash, t);
                t.start();
            } else if (Number(body.runtimeMinutes) > 0) {
                t.runtimeMinutes = Number(body.runtimeMinutes);
            }
            t.whenReady(90000, e => {
                if (t.closed) return json(res, 410, { error: 'The torrent was closed' });
                if (e) {
                    t.close();
                    torrents.delete(r.infoHash);
                    return json(res, 504, { error: e.message });
                }
                json(res, 200, describe(t));
            });
        });
    };

    const streamFile = (t, index, req, res) => {
        const f = t.info.files[index];
        if (!f) return json(res, 404, { error: 'No such file' });
        let start = 0;
        let end = f.size - 1;
        let partial = false;
        const range = req.headers.range;
        if (range) {
            const m = /bytes=(\d*)-(\d*)/.exec(range);
            if (m) {
                partial = true;
                if (m[1] === '' && m[2] !== '') { // suffix range: last N bytes
                    start = Math.max(0, f.size - parseInt(m[2], 10));
                } else {
                    start = parseInt(m[1] || '0', 10);
                    if (m[2] !== '') end = Math.min(end, parseInt(m[2], 10));
                }
            }
        }
        if (start >= f.size || start > end) {
            res.writeHead(416, { 'Content-Range': 'bytes */' + f.size });
            return res.end();
        }
        const headers = {
            'Content-Type': metainfo.contentType(f.path.join('/')),
            'Content-Length': end - start + 1,
            'Accept-Ranges': 'bytes'
        };
        if (partial) headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + f.size;
        res.writeHead(partial ? 206 : 200, headers);
        if (req.method === 'HEAD') return res.end();

        const reader = t.openReader(index, start);
        let remaining = end - start + 1;
        let done = false;
        const opened = Date.now();
        util.log('read', index, 'bytes', start + '-' + end);
        const stop = () => {
            if (done) return;
            done = true;
            util.log('read', index, 'from', start, 'ended after', (end - start + 1 - remaining), 'bytes in', (Date.now() - opened) + ' ms');
            t.closeReader(reader);
        };
        req.on('close', stop);
        res.on('close', stop);
        res.on('finish', stop);
        const pump = () => {
            if (done) return;
            if (remaining <= 0) { stop(); return res.end(); }
            t.read(reader, Math.min(remaining, 256 * 1024), (err, buf) => {
                if (done) return;
                if (err || !buf.length) { stop(); return res.end(); }
                remaining -= buf.length;
                if (res.write(buf)) pump();
                else res.once('drain', pump);
            });
        };
        pump();
    };

    // OpenSubtitles' hash of a file: its size plus the sum of its first and last
    // 64 KiB as little-endian 64-bit words, kept to 64 bits (two 32-bit halves,
    // since Node 4 has no BigInt).
    const HASH_CHUNK = 65536;
    const fileHash = (t, index, res) => {
        const f = t.info.files[index];
        if (!f) return json(res, 404, { error: 'No such file' });
        if (f.size <= 2 * HASH_CHUNK) return json(res, 422, { error: 'The file is too small to hash' });
        const readChunk = (start, cb) => {
            const r = t.openReader(index, start);
            const parts = [];
            let got = 0;
            const next = () => t.read(r, HASH_CHUNK - got, (err, buf) => {
                if (err || !buf.length) { t.closeReader(r); return cb(err || new Error('The file ended early')); }
                parts.push(buf);
                got += buf.length;
                if (got < HASH_CHUNK) return next();
                t.closeReader(r);
                cb(null, Buffer.concat(parts));
            });
            next();
        };
        let lo = f.size % 0x100000000;
        let hi = Math.floor(f.size / 0x100000000);
        const add = (buf) => {
            for (let i = 0; i < buf.length; i += 8) {
                lo += buf.readUInt32LE(i);
                hi += buf.readUInt32LE(i + 4) + Math.floor(lo / 0x100000000);
                lo %= 0x100000000;
                hi %= 0x100000000;
            }
        };
        const hex = (n) => ('00000000' + n.toString(16)).slice(-8);
        readChunk(0, (err, head) => {
            if (err) return json(res, 500, { error: err.message });
            readChunk(f.size - HASH_CHUNK, (err2, tail) => {
                if (err2) return json(res, 500, { error: err2.message });
                add(head);
                add(tail);
                json(res, 200, { hash: hex(hi) + hex(lo), size: f.size });
            });
        });
    };

    const proxy = (target, res, opts) => {
        if (!target || !/^https?:\/\//i.test(target)) return json(res, 400, { error: 'Give ?url=http(s)://...' });
        opts = opts || {};
        fetch.request(target, { timeout: 20000, method: opts.method, headers: opts.headers, body: opts.body }, (err, up) => {
            if (err) return json(res, 502, { error: err.message });
            const headers = {};
            if (up.headers['content-type']) headers['Content-Type'] = up.headers['content-type'];
            if (up.headers['content-length']) headers['Content-Length'] = up.headers['content-length'];
            res.writeHead(up.statusCode, headers);
            up.pipe(res);
            up.on('error', () => res.end());
            res.on('close', () => up.destroy());
        });
    };

    const server = http.createServer((req, res) => {
        cors(res);
        if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
        const u = url.parse(req.url, true);
        const parts = u.pathname.split('/').filter(Boolean);
        try {
            if (u.pathname === '/ping') {
                return json(res, 200, { ok: true, version: VERSION, node: process.version, cache: cacheDir });
            }
            if (u.pathname === '/fetch' && req.method === 'GET') return proxy(u.query.url, res);
            // A zipped subtitle (as YIFY Subtitles serves them): the file inside, as bytes, for the app to decode.
            if (u.pathname === '/unzip' && req.method === 'GET') {
                const target = u.query.url;
                if (!target || !/^https?:\/\//i.test(target)) return json(res, 400, { error: 'Give ?url=http(s)://...' });
                return fetch.getBuffer(target, { timeout: 30000, maxBytes: 8 * 1024 * 1024 }, (err, body, up) => {
                    if (err) return json(res, 502, { error: err.message });
                    if (up.statusCode !== 200) return json(res, 502, { error: 'The archive answered HTTP ' + up.statusCode });
                    let file;
                    try { file = unzip.subtitle(body); } catch (e) { return json(res, 422, { error: e.message }); }
                    if (!file) return json(res, 422, { error: 'The archive is empty' });
                    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': file.data.length, 'X-File-Name': encodeURIComponent(file.name) });
                    res.end(file.data);
                });
            }
            // Any request with its own method, headers and body (OpenSubtitles needs an Api-Key header and POST).
            if (u.pathname === '/request' && req.method === 'POST') {
                return readBody(req, (err, b) => {
                    if (err) return json(res, 400, { error: err.message });
                    const body = b.body === undefined ? undefined : (typeof b.body === 'string' ? b.body : JSON.stringify(b.body));
                    proxy(b.url, res, { method: b.method, headers: b.headers, body: body });
                });
            }
            if (parts[0] === 'torrents' && parts.length === 1 && req.method === 'POST') {
                return readBody(req, (err, body) => err ? json(res, 400, { error: err.message }) : openTorrent(body, res));
            }
            if (parts[0] === 'torrents' && parts.length >= 2) {
                const t = torrents.get(parts[1].toLowerCase());
                if (!t) return json(res, 404, { error: 'That torrent is not open' });
                if (parts.length === 2 && req.method === 'DELETE') {
                    t.close();
                    torrents.delete(t.infoHash);
                    res.writeHead(204);
                    return res.end();
                }
                if (!t.info) return json(res, 409, { error: 'The torrent metadata is not here yet' });
                if (parts[2] === 'files' && parts.length === 4 && (req.method === 'GET' || req.method === 'HEAD')) {
                    return streamFile(t, parseInt(parts[3], 10), req, res);
                }
                if (parts[2] === 'files' && parts[4] === 'hash' && req.method === 'GET') {
                    return fileHash(t, parseInt(parts[3], 10), res);
                }
                if (parts[2] === 'position' && req.method === 'POST') {
                    return readBody(req, (err, body) => {
                        if (err) return json(res, 400, { error: err.message });
                        t.setPosition(Number(body.file), Number(body.seconds), Number(body.duration));
                        res.writeHead(204);
                        res.end();
                    });
                }
                if (parts[2] === 'status' && req.method === 'GET') return json(res, 200, t.status());
            }
            json(res, 404, { error: 'Not found' });
        } catch (e) {
            util.log('request failed:', e.stack || e.message);
            if (!res.headersSent) json(res, 500, { error: e.message });
            else res.end();
        }
    });

    return {
        server: server,
        cacheDir: cacheDir,
        torrents: torrents,
        listen: (cb) => {
            const host = process.env.BOBCORN_HOST || '127.0.0.1';
            const port = parseInt(process.env.BOBCORN_PORT || '', 10) || PORT;
            server.listen(port, host, () => {
                util.log('listening on', host + ':' + port);
                if (cb) cb();
            });
        },
        close: () => {
            torrents.forEach(t => t.close());
            torrents.clear();
            try { server.close(); } catch (e) { /* closed */ }
        }
    };
}

module.exports = { createServer: createServer, VERSION: VERSION, PORT: PORT };
