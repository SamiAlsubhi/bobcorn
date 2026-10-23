'use strict';
// Small helpers that work on Node 4.4.3 (no Buffer.from/alloc there) and on modern Node.

const crypto = require('crypto');

function alloc(n) {
    if (typeof Buffer.alloc === 'function') return Buffer.alloc(n);
    const b = new Buffer(n);
    b.fill(0);
    return b;
}

function allocUnsafe(n) {
    if (typeof Buffer.allocUnsafe === 'function') return Buffer.allocUnsafe(n);
    return new Buffer(n);
}

function from(value, encoding) {
    if (typeof Buffer.from === 'function' && Buffer.from !== Uint8Array.from) return Buffer.from(value, encoding);
    return new Buffer(value, encoding);
}

function sha1(buf) {
    return crypto.createHash('sha1').update(buf).digest();
}

// Peer ID: Azureus style, "-BC1000-" plus 12 random bytes.
function peerId() {
    return Buffer.concat([from('-BC1000-'), crypto.randomBytes(12)]);
}

// Compact peers: 6 bytes each (IPv4 + port), or 18 for IPv6.
function compactPeers(buf, v6) {
    const out = [];
    const size = v6 ? 18 : 6;
    if (!Buffer.isBuffer(buf)) return out;
    for (let i = 0; i + size <= buf.length; i += size) {
        let host;
        if (v6) {
            const parts = [];
            for (let j = 0; j < 16; j += 2) parts.push(buf.readUInt16BE(i + j).toString(16));
            host = parts.join(':');
        } else {
            host = buf[i] + '.' + buf[i + 1] + '.' + buf[i + 2] + '.' + buf[i + 3];
        }
        const port = buf.readUInt16BE(i + size - 2);
        if (port > 0) out.push({ host: host, port: port });
    }
    return out;
}

// Percent-encode raw bytes for tracker query strings.
function escapeBytes(buf) {
    let s = '';
    for (let i = 0; i < buf.length; i++) {
        const c = buf[i];
        if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 45 || c === 46 || c === 95 || c === 126) {
            s += String.fromCharCode(c);
        } else {
            s += '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
        }
    }
    return s;
}

// The log: printed, kept in memory (GET /log), and appended to a file when one
// is set, so a TV's log can be read after the fact (tools/sdb.py pull).
const recent = [];
let logFile = null;

function log() {
    const args = Array.prototype.slice.call(arguments);
    args.unshift('[bobcorn]');
    console.log.apply(console, args);
    const line = new Date().toISOString() + ' ' + args.slice(1).map(a => typeof a === 'string' ? a : (a && a.stack) || JSON.stringify(a)).join(' ');
    recent.push(line);
    if (recent.length > 400) recent.shift();
    if (logFile) {
        try {
            const fs = require('fs');
            fs.appendFileSync(logFile, line + '\n');
            if (fs.statSync(logFile).size > 1024 * 1024) fs.renameSync(logFile, logFile + '.1');
        } catch (e) { /* logging never breaks the engine */ }
    }
}

function setLogFile(path) { logFile = path; }
function recentLog() { return recent.join('\n') + '\n'; }

function contains(list, value) {
    return list.indexOf(value) !== -1;
}

module.exports = {
    alloc: alloc,
    allocUnsafe: allocUnsafe,
    from: from,
    sha1: sha1,
    peerId: peerId,
    compactPeers: compactPeers,
    escapeBytes: escapeBytes,
    log: log,
    setLogFile: setLogFile,
    recentLog: recentLog,
    contains: contains
};
