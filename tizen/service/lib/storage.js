'use strict';
// The piece cache: one file per torrent, cut into piece-sized slots. A map says
// which slot holds which piece; evicting a piece just frees its slot, so the
// file never grows past the most pieces held at once.

const fs = require('fs');
const path = require('path');
const util = require('./util');

class Storage {
    constructor(dir, name, pieceLength) {
        this.file = path.join(dir, name + '.cache');
        this.pieceLength = pieceLength;
        this.slots = new Map(); // piece index -> slot
        this.lengths = new Map(); // piece index -> bytes in that piece
        this.free = []; // freed slot numbers, reused lowest first
        this.nextSlot = 0;
        this.fd = fs.openSync(this.file, 'w+');
        this.closed = false;
    }

    has(index) { return this.slots.has(index); }

    get count() { return this.slots.size; }

    get bytes() {
        let n = 0;
        this.lengths.forEach(l => { n += l; });
        return n;
    }

    // Size of the cache file on disk (slots ever used).
    get fileBytes() {
        try { return fs.fstatSync(this.fd).size; } catch (e) { return 0; }
    }

    write(index, data, cb) {
        if (this.closed) return cb(new Error('closed'));
        if (this.slots.has(index)) return cb(null);
        let slot;
        if (this.free.length) {
            this.free.sort((a, b) => a - b);
            slot = this.free.shift();
        } else {
            slot = this.nextSlot++;
        }
        fs.write(this.fd, data, 0, data.length, slot * this.pieceLength, err => {
            if (err) {
                this.free.push(slot);
                return cb(err);
            }
            if (this.closed) return cb(new Error('closed'));
            this.slots.set(index, slot);
            this.lengths.set(index, data.length);
            cb(null);
        });
    }

    // Reads `length` bytes at `offset` inside piece `index`.
    read(index, offset, length, cb) {
        if (this.closed) return cb(new Error('closed'));
        if (!this.slots.has(index)) return cb(new Error('piece not cached'));
        const buf = util.allocUnsafe(length);
        fs.read(this.fd, buf, 0, length, this.slots.get(index) * this.pieceLength + offset, (err, n) => {
            if (err) return cb(err);
            cb(null, n === length ? buf : buf.slice(0, n));
        });
    }

    evict(index) {
        if (!this.slots.has(index)) return;
        this.free.push(this.slots.get(index));
        this.slots.delete(index);
        this.lengths.delete(index);
        // When the highest slots are free, shrink the file back.
        this.free.sort((a, b) => a - b);
        let shrunk = false;
        while (this.free.length && this.free[this.free.length - 1] === this.nextSlot - 1) {
            this.free.pop();
            this.nextSlot--;
            shrunk = true;
        }
        if (shrunk) {
            try { fs.ftruncateSync(this.fd, this.nextSlot * this.pieceLength); } catch (e) { /* best effort */ }
        }
    }

    forEach(fn) { this.slots.forEach((slot, index) => fn(index)); }

    close() {
        if (this.closed) return;
        this.closed = true;
        try { fs.closeSync(this.fd); } catch (e) { /* closed */ }
        try { fs.unlinkSync(this.file); } catch (e) { /* gone */ }
        this.slots.clear();
        this.lengths.clear();
    }
}

module.exports = Storage;
