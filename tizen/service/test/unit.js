'use strict';
// Offline tests: bencode, .torrent and magnet parsing, zipped subtitles, the slot cache.
//   node tizen/service/test/unit.js

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const bencode = require('../lib/bencode');
const metainfo = require('../lib/metainfo');
const Storage = require('../lib/storage');
const util = require('../lib/util');
const unzip = require('../lib/unzip');

let passed = 0;
function test(name, fn) {
    fn();
    passed++;
    console.log('ok -', name);
}

test('zipped subtitles: the .srt is found and inflated', () => {
    const zip = fs.readFileSync(path.join(__dirname, 'fixtures', 'subtitle.zip'));
    assert.strictEqual(unzip.entries(zip).length, 2);
    const sub = unzip.subtitle(zip);
    assert.strictEqual(sub.name, 'Film-Arabic.srt');
    const text = sub.data.toString('binary');
    assert.ok(text.indexOf('00:00:01,000 --> 00:00:02,500') >= 0);
    assert.strictEqual(sub.data[text.indexOf('FF1111>') + 7], 0xc7);   // the first Arabic letter, in Windows-1256
});

test('bencode round trip', () => {
    const v = { a: 1, list: ['x', 2, { y: util.from('z') }], neg: -5 };
    const enc = bencode.encode(v);
    assert.strictEqual(enc.toString(), 'd1:ai1e4:listl1:xi2ed1:y1:zee3:negi-5ee');
    const dec = bencode.decode(enc).value;
    assert.strictEqual(dec.a, 1);
    assert.strictEqual(dec.neg, -5);
    assert.strictEqual(dec.list[0].toString(), 'x');
    assert.strictEqual(dec.list[2].y.toString(), 'z');
});

// A synthetic multi-file torrent with a BEP 47 padding file.
function makeTorrent() {
    const pieceLength = 32768;
    const a = util.alloc(40000);
    a.fill(1);
    const pad = util.alloc(pieceLength * 2 - 40000);
    const b = util.alloc(50000);
    b.fill(2);
    const all = Buffer.concat([a, pad, b]);
    const hashes = [];
    for (let i = 0; i < all.length; i += pieceLength) hashes.push(util.sha1(all.slice(i, i + pieceLength)));
    const info = {
        name: 'Test Movie',
        'piece length': pieceLength,
        pieces: Buffer.concat(hashes),
        files: [
            { length: a.length, path: ['Movie.mkv'] },
            { length: pad.length, path: ['.pad', String(pad.length)], attr: 'p' },
            { length: b.length, path: ['Subs', 'english.srt'] }
        ]
    };
    return { buf: bencode.encode({ announce: 'udp://tracker.example:80', 'url-list': ['https://example.org/files/'], info: info }), info: info, data: all };
}

test('.torrent parsing, info hash, padding files hidden', () => {
    const t = makeTorrent();
    const parsed = metainfo.parseTorrent(t.buf);
    assert.strictEqual(parsed.infoHash, util.sha1(bencode.encode(t.info)).toString('hex'));
    assert.strictEqual(parsed.files.length, 2);
    assert.strictEqual(parsed.allFiles.length, 3);
    assert.strictEqual(parsed.files[1].path.join('/'), 'Subs/english.srt');
    assert.strictEqual(parsed.files[1].offset, 65536);
    assert.strictEqual(parsed.pieces.length, Math.ceil(t.data.length / 32768));
    assert.deepEqual(parsed.announce, ['udp://tracker.example:80']);
    assert.deepEqual(parsed.urlList, ['https://example.org/files/']);
    assert.strictEqual(metainfo.videoIndex(parsed), 0);
    assert.strictEqual(metainfo.contentType('a/b.MKV'), 'video/x-matroska');
});

test('magnet links: hex and base32 hashes, trackers, web seeds', () => {
    const hex = '6bc1af23a17fd62156ab2f0e41d3c86769c2c66c';
    const m = metainfo.parseMagnet('magnet:?xt=urn:btih:' + hex.toUpperCase() + '&dn=Night+of+the+Living+Dead&tr=udp%3A%2F%2Fa%3A1&tr=http%3A%2F%2Fb%2Fannounce&ws=https%3A%2F%2Farchive.org%2Fdownload%2F');
    assert.strictEqual(m.infoHash, hex);
    assert.strictEqual(m.name, 'Night of the Living Dead');
    assert.deepEqual(m.announce, ['udp://a:1', 'http://b/announce']);
    assert.deepEqual(m.urlList, ['https://archive.org/download/']);
    // Base32 of the same hash.
    const b32 = 'NPA26I5BP7LCCVVLF4HEDU6IM5U4FRTM';
    assert.strictEqual(metainfo.base32ToHex(b32), hex);
    assert.strictEqual(metainfo.parseMagnet('magnet:?xt=urn:btih:' + b32).infoHash, hex);
    assert.throws(() => metainfo.parseMagnet('magnet:?dn=nothing'));
});

// Async, so it reports itself.
(function slotCacheTest() {
    const dir = fs.mkdtempSync ? fs.mkdtempSync(path.join(os.tmpdir(), 'bc-unit-')) : os.tmpdir();
    const s = new Storage(dir, 'unit', 1024);
    const piece = (n) => { const b = util.alloc(1024); b.fill(n); return b; };
    let pending = 3;
    const after = () => {
        if (--pending) return;
        assert.strictEqual(s.count, 3);
        assert.strictEqual(s.fileBytes, 3072);
        s.evict(7);
        s.evict(9); // the highest slot: the file shrinks
        assert.strictEqual(s.fileBytes, 1024);
        s.write(20, piece(20), () => {
            s.read(20, 10, 4, (err, buf) => {
                assert.ifError(err);
                assert.strictEqual(buf[0], 20);
                assert.strictEqual(s.fileBytes, 2048);
                s.read(5, 0, 1024, (e2, b5) => {
                    assert.ifError(e2);
                    assert.strictEqual(b5[100], 5);
                    s.close();
                    assert.strictEqual(fs.existsSync(s.file), false);
                    passed++;
                    console.log('ok - slot cache reuses freed slots and shrinks');
                    console.log(passed + ' unit tests passed on node ' + process.version);
                });
            });
        });
    };
    s.write(5, piece(5), after);
    s.write(7, piece(7), after);
    s.write(9, piece(9), after);
})();
