'use strict';
// Mainline DHT get_peers lookups (BEP 5), client side only: we ask, never store.

const dgram = require('dgram');
const crypto = require('crypto');
const bencode = require('./bencode');
const util = require('./util');

const BOOTSTRAP = [
    { host: 'router.bittorrent.com', port: 6881 },
    { host: 'dht.transmissionbt.com', port: 6881 },
    { host: 'router.utorrent.com', port: 6881 },
    { host: 'dht.libtorrent.org', port: 25401 }
];

function distance(a, b) {
    const d = util.alloc(20);
    for (let i = 0; i < 20; i++) d[i] = a[i] ^ b[i];
    return d;
}

function compareDistance(a, b) {
    for (let i = 0; i < 20; i++) {
        if (a[i] !== b[i]) return a[i] - b[i];
    }
    return 0;
}

// Looks up peers for infoHash (Buffer). onPeers(list) may be called many times;
// onDone() once, after `timeout` ms or when the lookup runs dry.
function lookup(infoHash, onPeers, onDone, timeout) {
    const sock = dgram.createSocket('udp4');
    const myId = crypto.randomBytes(20);
    const pending = new Map(); // transaction id -> timer
    const queried = new Set();
    let candidates = []; // { id, host, port, dist }
    let queries = 0;
    let finished = false;
    let txCounter = 0;
    const seenPeers = new Set();

    const finish = () => {
        if (finished) return;
        finished = true;
        pending.forEach(t => clearTimeout(t));
        pending.clear();
        clearTimeout(overall);
        try { sock.close(); } catch (e) { /* closed */ }
        if (onDone) onDone();
    };
    const overall = setTimeout(finish, timeout || 30000);

    const query = (host, port) => {
        const key = host + ':' + port;
        if (queried.has(key) || finished || queries > 400) return;
        queried.add(key);
        queries++;
        const t = util.alloc(2);
        t.writeUInt16BE(txCounter++ & 0xffff, 0);
        const msg = bencode.encode({ t: t, y: 'q', q: 'get_peers', a: { id: myId, info_hash: infoHash } });
        const tk = t.toString('hex');
        pending.set(tk, setTimeout(() => { pending.delete(tk); step(); }, 3000));
        sock.send(msg, 0, msg.length, port, host, () => { /* errors just time out */ });
    };

    // Ask the closest not-yet-asked nodes, up to 8 in flight.
    const step = () => {
        if (finished) return;
        candidates.sort((a, b) => compareDistance(a.dist, b.dist));
        candidates = candidates.slice(0, 200);
        for (let i = 0; i < candidates.length && pending.size < 8; i++) {
            const c = candidates[i];
            if (!queried.has(c.host + ':' + c.port)) query(c.host, c.port);
        }
        if (pending.size === 0) finish();
    };

    sock.on('error', () => finish());
    sock.on('message', (msg) => {
        let d;
        try { d = bencode.decode(msg).value; } catch (e) { return; }
        if (!d || !Buffer.isBuffer(d.t)) return;
        const tk = d.t.toString('hex');
        if (!pending.has(tk)) return;
        clearTimeout(pending.get(tk));
        pending.delete(tk);
        const r = d.r;
        if (r) {
            if (Array.isArray(r.values)) {
                const fresh = [];
                r.values.forEach(v => {
                    util.compactPeers(v, false).forEach(p => {
                        const k = p.host + ':' + p.port;
                        if (!seenPeers.has(k)) { seenPeers.add(k); fresh.push(p); }
                    });
                });
                if (fresh.length) onPeers(fresh);
            }
            if (Buffer.isBuffer(r.nodes)) {
                for (let i = 0; i + 26 <= r.nodes.length; i += 26) {
                    const id = r.nodes.slice(i, i + 20);
                    const peer = util.compactPeers(r.nodes.slice(i + 20, i + 26), false)[0];
                    if (peer) candidates.push({ id: id, host: peer.host, port: peer.port, dist: distance(id, infoHash) });
                }
            }
        }
        step();
    });

    BOOTSTRAP.forEach(b => query(b.host, b.port));
    return { stop: finish };
}

module.exports = { lookup: lookup };
