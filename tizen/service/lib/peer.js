'use strict';
// One peer connection: the BitTorrent wire protocol with the extension
// protocol (BEP 10) and ut_metadata (BEP 9). We only download.

const net = require('net');
const EventEmitter = require('events').EventEmitter;
const bencode = require('./bencode');
const util = require('./util');

const PSTR = util.from('BitTorrent protocol');
const UT_METADATA_ID = 3; // the id we ask peers to use when sending us ut_metadata

class Peer extends EventEmitter {
    constructor(host, port, infoHash, peerId) {
        super();
        this.host = host;
        this.port = port;
        this.key = host + ':' + port;
        this.infoHash = infoHash;
        this.peerId = peerId;
        this.socket = null;
        this.buffer = util.alloc(0);
        this.handshaken = false;
        this.choked = true; // the peer is choking us
        this.bitfield = null; // Buffer, MSB first
        this.haves = new Set(); // haves seen before the bitfield could be sized
        this.requests = new Map(); // "index:begin" -> { index, begin, length, at }
        this.extended = false;
        this.utMetadata = 0; // the peer's message id for ut_metadata
        this.metadataSize = 0;
        this.maxRequests = 250;
        this.downloaded = 0;
        this.closed = false;
        this.keepAlive = null;
        this.lastData = Date.now();
    }

    connect(timeout) {
        const s = net.connect({ host: this.host, port: this.port });
        this.socket = s;
        s.setTimeout(timeout || 10000);
        s.on('connect', () => {
            s.setTimeout(120000);
            s.setNoDelay(true);
            this.sendHandshake();
        });
        s.on('timeout', () => this.destroy('timeout'));
        s.on('error', e => this.destroy(e.code || e.message));
        s.on('close', () => this.destroy('closed'));
        s.on('data', d => this.onData(d));
        this.keepAlive = setInterval(() => this.send(util.alloc(4)), 60000);
    }

    destroy(reason) {
        if (this.closed) return;
        this.closed = true;
        clearInterval(this.keepAlive);
        if (this.socket) this.socket.destroy();
        this.emit('close', reason);
    }

    send(buf) {
        if (!this.closed && this.socket && this.socket.writable) this.socket.write(buf);
    }

    sendHandshake() {
        const reserved = util.alloc(8);
        reserved[5] |= 0x10; // extension protocol
        this.send(Buffer.concat([util.from([19]), PSTR, reserved, this.infoHash, this.peerId]));
    }

    message(id, payload) {
        const len = 1 + (payload ? payload.length : 0);
        const head = util.alloc(5);
        head.writeUInt32BE(len, 0);
        head[4] = id;
        this.send(payload ? Buffer.concat([head, payload]) : head);
    }

    interested() { this.message(2); }

    request(index, begin, length) {
        const p = util.alloc(12);
        p.writeUInt32BE(index, 0);
        p.writeUInt32BE(begin, 4);
        p.writeUInt32BE(length, 8);
        this.requests.set(index + ':' + begin, { index: index, begin: begin, length: length, at: Date.now() });
        this.message(6, p);
    }

    cancel(index, begin, length) {
        const k = index + ':' + begin;
        if (!this.requests.has(k)) return;
        this.requests.delete(k);
        const p = util.alloc(12);
        p.writeUInt32BE(index, 0);
        p.writeUInt32BE(begin, 4);
        p.writeUInt32BE(length, 8);
        this.message(8, p);
    }

    has(index) {
        if (this.bitfield) {
            const byte = index >> 3;
            if (byte < this.bitfield.length && (this.bitfield[byte] & (0x80 >> (index & 7)))) return true;
        }
        return this.haves.has(index);
    }

    requestMetadata(piece) {
        if (!this.utMetadata) return;
        const payload = Buffer.concat([util.from([this.utMetadata]), bencode.encode({ msg_type: 0, piece: piece })]);
        this.message(20, payload);
    }

    onData(data) {
        this.lastData = Date.now();
        this.buffer = this.buffer.length ? Buffer.concat([this.buffer, data]) : data;
        while (!this.closed) {
            if (!this.handshaken) {
                if (this.buffer.length < 68) return;
                if (this.buffer[0] !== 19 || !this.buffer.slice(1, 20).equals(PSTR)) return this.destroy('bad handshake');
                if (!this.buffer.slice(28, 48).equals(this.infoHash)) return this.destroy('wrong torrent');
                this.extended = !!(this.buffer[25] & 0x10);
                this.buffer = this.buffer.slice(68);
                this.handshaken = true;
                if (this.extended) {
                    const hs = bencode.encode({ m: { ut_metadata: UT_METADATA_ID }, v: 'Bobcorn TV 1.0', reqq: 250 });
                    this.message(20, Buffer.concat([util.from([0]), hs]));
                }
                this.interested();
                this.emit('handshake');
                continue;
            }
            if (this.buffer.length < 4) return;
            const len = this.buffer.readUInt32BE(0);
            if (len > 2 * 1024 * 1024) return this.destroy('message too large');
            if (this.buffer.length < 4 + len) return;
            const msg = this.buffer.slice(4, 4 + len);
            this.buffer = this.buffer.slice(4 + len);
            if (len > 0) this.handle(msg);
        }
    }

    handle(msg) {
        const id = msg[0];
        const p = msg.slice(1);
        switch (id) {
            case 0: // choke: outstanding requests are dropped by the peer
                this.choked = true;
                this.emit('choke');
                break;
            case 1:
                this.choked = false;
                this.emit('unchoke');
                break;
            case 4:
                if (p.length >= 4) {
                    const i = p.readUInt32BE(0);
                    this.haves.add(i);
                    this.emit('have', i);
                }
                break;
            case 5:
                this.bitfield = util.from(p);
                this.emit('bitfield');
                break;
            case 7: {
                if (p.length < 8) break;
                const index = p.readUInt32BE(0);
                const begin = p.readUInt32BE(4);
                const block = p.slice(8);
                const k = index + ':' + begin;
                if (!this.requests.has(k)) break; // cancelled or unasked for
                this.requests.delete(k);
                this.downloaded += block.length;
                this.emit('block', index, begin, block);
                break;
            }
            case 20:
                this.handleExtended(p);
                break;
            default:
                break; // interested, request (we don't serve), cancel, port, fast-extension...
        }
    }

    handleExtended(p) {
        if (!p.length) return;
        const ext = p[0];
        let d;
        try { d = bencode.decode(p, 1); } catch (e) { return; }
        if (ext === 0) {
            const m = d.value && d.value.m;
            if (m && typeof m.ut_metadata === 'number') this.utMetadata = m.ut_metadata;
            if (typeof d.value.metadata_size === 'number') this.metadataSize = d.value.metadata_size;
            if (typeof d.value.reqq === 'number') this.maxRequests = Math.max(4, Math.min(500, d.value.reqq));
            this.emit('extended');
        } else if (ext === UT_METADATA_ID) {
            const v = d.value || {};
            if (v.msg_type === 1) this.emit('metadata', v.piece, p.slice(d.end), v.total_size);
            else if (v.msg_type === 2) this.emit('metadata-reject', v.piece);
            else if (v.msg_type === 0 && this.utMetadata) {
                // We don't serve metadata: reject politely.
                this.message(20, Buffer.concat([util.from([this.utMetadata]), bencode.encode({ msg_type: 2, piece: v.piece })]));
            }
        }
    }
}

module.exports = Peer;
