'use strict';
// Reads the files in a .zip (stored or deflated), enough for subtitle archives.
// Node core only: zlib's raw inflate does the decompression.

const zlib = require('zlib');

// [{name, data}] for every file in the archive.
function entries(buf) {
    // The end-of-central-directory record is in the last 64 KiB + 22 bytes.
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
        if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error('Not a zip archive');
    const count = buf.readUInt16LE(eocd + 10);
    let p = buf.readUInt32LE(eocd + 16);
    const out = [];
    for (let n = 0; n < count; n++) {
        if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('Broken zip directory');
        const method = buf.readUInt16LE(p + 10);
        const size = buf.readUInt32LE(p + 20);
        const nameLen = buf.readUInt16LE(p + 28);
        const extraLen = buf.readUInt16LE(p + 30);
        const commentLen = buf.readUInt16LE(p + 32);
        const local = buf.readUInt32LE(p + 42);
        const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
        p += 46 + nameLen + extraLen + commentLen;
        if (/\/$/.test(name)) continue;
        if (buf.readUInt32LE(local) !== 0x04034b50) throw new Error('Broken zip entry');
        const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
        const raw = buf.slice(start, start + size);
        let data;
        if (method === 0) data = raw;
        else if (method === 8) data = zlib.inflateRawSync(raw);
        else continue;   // other methods don't occur in subtitle archives
        out.push({ name: name, data: data });
    }
    return out;
}

// The subtitle in an archive: an .srt or .vtt (the biggest, when there are several), else the first file.
function subtitle(buf) {
    const files = entries(buf);
    const subs = files.filter(f => /\.(srt|vtt|sub|ass|ssa)$/i.test(f.name)).sort((a, b) => b.data.length - a.data.length);
    return subs[0] || files[0] || null;
}

module.exports = { entries: entries, subtitle: subtitle };
