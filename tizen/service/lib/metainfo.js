'use strict';
// .torrent files and magnet links.

const bencode = require('./bencode');
const util = require('./util');

const VIDEO_EXT = ['mkv', 'mp4', 'm4v', 'avi', 'mov', 'webm', 'ts'];

// Parses the bencoded info dictionary (from a .torrent or ut_metadata).
function parseInfo(infoBuf, extra) {
    const info = bencode.decode(infoBuf).value;
    const name = bencode.str(info['name.utf-8']) || bencode.str(info.name) || 'Untitled';
    const pieceLength = info['piece length'];
    const piecesBuf = info.pieces;
    if (!pieceLength || !Buffer.isBuffer(piecesBuf) || piecesBuf.length % 20 !== 0) throw new Error('Invalid torrent: bad pieces');

    const pieces = [];
    for (let i = 0; i < piecesBuf.length; i += 20) pieces.push(piecesBuf.slice(i, i + 20));

    // All files in torrent order, with their byte offset in the torrent.
    // Padding files (BEP 47) take up space but are hidden from the file list.
    const all = [];
    let offset = 0;
    if (Array.isArray(info.files)) {
        info.files.forEach(f => {
            const pathList = (f['path.utf-8'] || f.path || []).map(p => bencode.str(p));
            const attr = bencode.str(f.attr) || '';
            const pad = attr.indexOf('p') !== -1 || /^_____padding_file/.test(pathList[pathList.length - 1] || '');
            all.push({ path: pathList, size: f.length, offset: offset, pad: pad });
            offset += f.length;
        });
    } else {
        all.push({ path: [name], size: info.length, offset: 0, pad: false, single: true });
        offset = info.length;
    }

    const files = [];
    all.forEach(f => {
        if (f.pad) return;
        f.index = files.length;
        files.push(f);
    });

    const t = {
        infoHash: util.sha1(infoBuf).toString('hex'),
        infoBuf: infoBuf,
        name: name,
        pieceLength: pieceLength,
        pieces: pieces,
        length: offset,
        files: files,
        allFiles: all,
        multiFile: Array.isArray(info.files),
        announce: [],
        urlList: []
    };
    if (pieces.length !== Math.ceil(offset / pieceLength)) throw new Error('Invalid torrent: piece count does not match size');
    if (extra) {
        t.announce = extra.announce || [];
        t.urlList = extra.urlList || [];
    }
    return t;
}

// Parses a whole .torrent file.
function parseTorrent(buf) {
    const d = bencode.decode(buf);
    if (d.infoStart < 0) throw new Error('Not a torrent file');
    const root = d.value;
    const announce = [];
    if (Array.isArray(root['announce-list'])) {
        root['announce-list'].forEach(tier => {
            (Array.isArray(tier) ? tier : [tier]).forEach(a => {
                const s = bencode.str(a);
                if (s && announce.indexOf(s) === -1) announce.push(s);
            });
        });
    }
    const a = bencode.str(root.announce);
    if (a && announce.indexOf(a) === -1) announce.unshift(a);

    let urlList = [];
    if (Array.isArray(root['url-list'])) urlList = root['url-list'].map(u => bencode.str(u)).filter(Boolean);
    else if (root['url-list']) urlList = [bencode.str(root['url-list'])];
    urlList = urlList.filter(u => /^https?:\/\//i.test(u));

    return parseInfo(buf.slice(d.infoStart, d.infoEnd), { announce: announce, urlList: urlList });
}

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function base32ToHex(s) {
    let bits = '';
    s.toUpperCase().split('').forEach(ch => {
        const v = BASE32.indexOf(ch);
        if (v < 0) throw new Error('Bad base32 info hash');
        bits += ('00000' + v.toString(2)).slice(-5);
    });
    let hex = '';
    for (let i = 0; i + 4 <= bits.length; i += 4) hex += parseInt(bits.slice(i, i + 4), 2).toString(16);
    return hex;
}

function parseMagnet(link) {
    if (!/^magnet:\?/i.test(link)) throw new Error('Not a magnet link');
    const params = link.slice(link.indexOf('?') + 1).split('&');
    const m = { infoHash: null, name: null, announce: [], urlList: [], exactSource: [] };
    params.forEach(p => {
        const eq = p.indexOf('=');
        if (eq < 0) return;
        const key = p.slice(0, eq).toLowerCase().replace(/\.\d+$/, '');
        let value;
        try { value = decodeURIComponent(p.slice(eq + 1).replace(/\+/g, ' ')); } catch (e) { value = p.slice(eq + 1); }
        if (key === 'xt' && /^urn:btih:/i.test(value)) {
            const h = value.slice(9);
            if (/^[0-9a-f]{40}$/i.test(h)) m.infoHash = h.toLowerCase();
            else if (/^[a-z2-7]{32}$/i.test(h)) m.infoHash = base32ToHex(h);
        } else if (key === 'dn') {
            m.name = value;
        } else if (key === 'tr') {
            if (m.announce.indexOf(value) === -1) m.announce.push(value);
        } else if (key === 'ws') {
            if (/^https?:\/\//i.test(value)) m.urlList.push(value);
        } else if (key === 'xs' || key === 'as') {
            if (/^https?:\/\//i.test(value)) m.exactSource.push(value);
        }
    });
    if (!m.infoHash) throw new Error('Magnet link has no BitTorrent info hash');
    return m;
}

function extension(path) {
    const m = /\.([a-z0-9]+)$/i.exec(path || '');
    return m ? m[1].toLowerCase() : '';
}

function isVideo(path) {
    return VIDEO_EXT.indexOf(extension(path)) !== -1;
}

// The largest video file, or -1.
function videoIndex(t) {
    let best = -1;
    let size = -1;
    t.files.forEach(f => {
        if (isVideo(f.path.join('/')) && f.size > size && !/sample/i.test(f.path.join('/'))) {
            best = f.index;
            size = f.size;
        }
    });
    if (best < 0) {
        t.files.forEach(f => {
            if (isVideo(f.path.join('/')) && f.size > size) { best = f.index; size = f.size; }
        });
    }
    return best;
}

function contentType(path) {
    const types = {
        mkv: 'video/x-matroska', mp4: 'video/mp4', m4v: 'video/mp4', webm: 'video/webm', avi: 'video/x-msvideo',
        mov: 'video/quicktime', ts: 'video/mp2t', srt: 'application/x-subrip', vtt: 'text/vtt', txt: 'text/plain',
        jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', mp3: 'audio/mpeg'
    };
    return types[extension(path)] || 'application/octet-stream';
}

module.exports = {
    parseInfo: parseInfo,
    parseTorrent: parseTorrent,
    parseMagnet: parseMagnet,
    base32ToHex: base32ToHex,
    isVideo: isVideo,
    videoIndex: videoIndex,
    contentType: contentType,
    extension: extension
};
