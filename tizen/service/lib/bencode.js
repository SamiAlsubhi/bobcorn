'use strict';
// Bencode. Strings decode to Buffers; `decode` also reports where the top-level
// "info" dictionary sits, since the info hash is the SHA1 of those exact bytes.

const util = require('./util');

function decode(buf, start) {
    const state = { buf: buf, pos: start || 0, info: null, depth: 0 };
    const value = next(state);
    return { value: value, end: state.pos, infoStart: state.info ? state.info[0] : -1, infoEnd: state.info ? state.info[1] : -1 };
}

function next(s) {
    const c = s.buf[s.pos];
    if (c === 0x69) { // i
        const end = s.buf.indexOf(0x65, s.pos);
        if (end < 0) throw new Error('bencode: unterminated integer');
        const n = parseInt(s.buf.toString('ascii', s.pos + 1, end), 10);
        s.pos = end + 1;
        return n;
    }
    if (c === 0x6c) { // l
        s.pos++;
        s.depth++;
        const list = [];
        while (s.buf[s.pos] !== 0x65) {
            if (s.pos >= s.buf.length) throw new Error('bencode: unterminated list');
            list.push(next(s));
        }
        s.pos++;
        s.depth--;
        return list;
    }
    if (c === 0x64) { // d
        s.pos++;
        s.depth++;
        const dict = {};
        while (s.buf[s.pos] !== 0x65) {
            if (s.pos >= s.buf.length) throw new Error('bencode: unterminated dictionary');
            const key = next(s).toString('utf8');
            const valueStart = s.pos;
            dict[key] = next(s);
            if (key === 'info' && s.depth === 1) s.info = [valueStart, s.pos];
        }
        s.pos++;
        s.depth--;
        return dict;
    }
    if (c >= 0x30 && c <= 0x39) { // string: <len>:<bytes>
        const colon = s.buf.indexOf(0x3a, s.pos);
        if (colon < 0) throw new Error('bencode: bad string');
        const len = parseInt(s.buf.toString('ascii', s.pos, colon), 10);
        const begin = colon + 1;
        if (begin + len > s.buf.length) throw new Error('bencode: string past end');
        s.pos = begin + len;
        return s.buf.slice(begin, begin + len);
    }
    throw new Error('bencode: unexpected byte ' + c + ' at ' + s.pos);
}

function encode(value) {
    const parts = [];
    put(value, parts);
    return Buffer.concat(parts);
}

function put(v, parts) {
    if (Buffer.isBuffer(v)) {
        parts.push(util.from(v.length + ':'), v);
    } else if (typeof v === 'string') {
        const b = util.from(v, 'utf8');
        parts.push(util.from(b.length + ':'), b);
    } else if (typeof v === 'number') {
        parts.push(util.from('i' + Math.floor(v) + 'e'));
    } else if (Array.isArray(v)) {
        parts.push(util.from('l'));
        v.forEach(item => put(item, parts));
        parts.push(util.from('e'));
    } else if (v && typeof v === 'object') {
        parts.push(util.from('d'));
        Object.keys(v).sort().forEach(k => {
            if (v[k] === undefined || v[k] === null) return;
            put(k, parts);
            put(v[k], parts);
        });
        parts.push(util.from('e'));
    } else {
        throw new Error('bencode: cannot encode ' + typeof v);
    }
}

// Buffer or undefined -> string.
function str(v) {
    return Buffer.isBuffer(v) ? v.toString('utf8') : (typeof v === 'string' ? v : undefined);
}

module.exports = { decode: decode, encode: encode, str: str };
