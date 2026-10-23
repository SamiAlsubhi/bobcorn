'use strict';
// Tracker announces: HTTP(S) and UDP (BEP 15). Each calls back with peers.

const dgram = require('dgram');
const crypto = require('crypto');
const url = require('url');
const bencode = require('./bencode');
const fetch = require('./fetch');
const util = require('./util');

// opts: { infoHash (Buffer), peerId (Buffer), left, event }
// cb(err, { peers: [{host, port}], interval })
function announce(announceUrl, opts, cb) {
    if (/^https?:\/\//i.test(announceUrl)) return announceHTTP(announceUrl, opts, cb);
    if (/^udp:\/\//i.test(announceUrl)) return announceUDP(announceUrl, opts, cb);
    cb(new Error('Unsupported tracker ' + announceUrl));
}

function announceHTTP(announceUrl, opts, cb) {
    const q = [
        'info_hash=' + util.escapeBytes(opts.infoHash),
        'peer_id=' + util.escapeBytes(opts.peerId),
        'port=6881', 'uploaded=0', 'downloaded=0',
        'left=' + Math.max(0, opts.left || 0),
        'compact=1', 'numwant=80'
    ];
    if (opts.event) q.push('event=' + opts.event);
    const full = announceUrl + (announceUrl.indexOf('?') === -1 ? '?' : '&') + q.join('&');
    fetch.getBuffer(full, { timeout: 15000, maxBytes: 2 * 1024 * 1024 }, (err, body) => {
        if (err) return cb(err);
        let d;
        try { d = bencode.decode(body).value; } catch (e) { return cb(new Error('Bad tracker response')); }
        if (d['failure reason']) return cb(new Error(bencode.str(d['failure reason'])));
        let peers = [];
        if (Buffer.isBuffer(d.peers)) peers = util.compactPeers(d.peers, false);
        else if (Array.isArray(d.peers)) {
            d.peers.forEach(p => {
                const ip = bencode.str(p.ip);
                if (ip && p.port) peers.push({ host: ip, port: p.port });
            });
        }
        if (Buffer.isBuffer(d.peers6)) peers = peers.concat(util.compactPeers(d.peers6, true));
        cb(null, { peers: peers, interval: d.interval || 300 });
    });
}

const CONNECT_MAGIC_HI = 0x417;
const CONNECT_MAGIC_LO = 0x27101980;

function announceUDP(announceUrl, opts, cb) {
    const u = url.parse(announceUrl);
    const port = parseInt(u.port, 10);
    if (!u.hostname || !port) return cb(new Error('Bad UDP tracker'));
    const sock = dgram.createSocket('udp4');
    let done = false;
    let tries = 0;
    let connId = null;
    let timer = null;
    const tx = crypto.randomBytes(4).readUInt32BE(0);
    const finish = (err, res) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { sock.close(); } catch (e) { /* closed */ }
        cb(err, res);
    };
    const send = () => {
        if (tries++ >= 3) return finish(new Error('UDP tracker timed out'));
        let msg;
        if (!connId) {
            msg = util.alloc(16);
            msg.writeUInt32BE(CONNECT_MAGIC_HI, 0);
            msg.writeUInt32BE(CONNECT_MAGIC_LO, 4);
            msg.writeUInt32BE(0, 8); // action: connect
            msg.writeUInt32BE(tx, 12);
        } else {
            msg = util.alloc(98);
            connId.copy(msg, 0);
            msg.writeUInt32BE(1, 8); // action: announce
            msg.writeUInt32BE(tx, 12);
            opts.infoHash.copy(msg, 16);
            opts.peerId.copy(msg, 36);
            // downloaded (8) = 0, left (8), uploaded (8) = 0
            const left = Math.max(0, opts.left || 0);
            msg.writeUInt32BE(Math.floor(left / 4294967296), 64);
            msg.writeUInt32BE(left % 4294967296, 68);
            const events = { completed: 1, started: 2, stopped: 3 };
            msg.writeUInt32BE(events[opts.event] || 0, 80);
            msg.writeUInt32BE(0, 84); // IP
            msg.writeUInt32BE(crypto.randomBytes(4).readUInt32BE(0), 88); // key
            msg.writeInt32BE(80, 92); // num_want
            msg.writeUInt16BE(6881, 96);
        }
        sock.send(msg, 0, msg.length, port, u.hostname, err => { if (err) finish(err); });
        clearTimeout(timer);
        timer = setTimeout(send, 5000 * tries);
    };
    sock.on('error', e => finish(e));
    sock.on('message', msg => {
        if (msg.length < 8 || msg.readUInt32BE(4) !== tx) return;
        const action = msg.readUInt32BE(0);
        if (action === 3) return finish(new Error(msg.slice(8).toString()));
        if (action === 0 && msg.length >= 16) {
            connId = msg.slice(8, 16);
            tries = 0;
            send();
        } else if (action === 1 && msg.length >= 20) {
            finish(null, { interval: msg.readUInt32BE(8), peers: util.compactPeers(msg.slice(20), false) });
        }
    });
    send();
}

module.exports = { announce: announce };
