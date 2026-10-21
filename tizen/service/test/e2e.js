'use strict';
// End-to-end test against a real public-domain torrent from the example source
// (Night of the Living Dead on archive.org, streamed through its web seeds).
// Needs the internet. Runs the service with the same node binary:
//   node tizen/service/test/e2e.js            (add "magnet" to also test a magnet link)

const assert = require('assert');
const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const os = require('os');
const path = require('path');

const PORT = 8716;
const TORRENT = 'https://archive.org/download/night_of_the_living_dead_dvd/night_of_the_living_dead_dvd_archive.torrent';
const DIRECT = 'https://archive.org/download/night_of_the_living_dead_dvd/Night.mp4';
const HASH = '6bc1af23a17fd62156ab2f0e41d3c86769c2c66c';
const MiB = 1024 * 1024;
const PIECE = 2 * MiB;
const cacheDir = process.env.BOBCORN_CACHE || path.join(os.tmpdir(), 'bc-e2e-' + process.pid);
const insecure = parseInt(process.version.slice(1), 10) < 8; // Node 4 has outdated root certificates

function call(method, p, body, cb) {
    const data = body ? JSON.stringify(body) : null;
    const req = http.request({ host: '127.0.0.1', port: PORT, path: p, method: method, headers: data ? { 'Content-Type': 'application/json' } : {} }, res => {
        const chunks = [];
        res.on('data', c => chunks.push(c));
        res.on('end', () => {
            const text = Buffer.concat(chunks).toString();
            let parsed = null;
            try { parsed = text ? JSON.parse(text) : null; } catch (e) { parsed = text; }
            cb(res.statusCode, parsed, res.headers);
        });
    });
    req.on('error', e => cb(0, { error: e.message }));
    if (data) req.write(data);
    req.end();
}

function range(p, start, end, cb) {
    const t0 = Date.now();
    http.get({ host: '127.0.0.1', port: PORT, path: p, headers: { Range: 'bytes=' + start + '-' + end } }, res => {
        const chunks = [];
        res.on('data', c => chunks.push(c));
        res.on('end', () => cb(res.statusCode, Buffer.concat(chunks), res.headers, Date.now() - t0));
    });
}

// The same bytes straight from archive.org, to compare with (retried: archive.org is flaky).
function direct(start, end, cb, attempt) {
    attempt = attempt || 0;
    let done = false;
    const retry = (e) => {
        if (done) return;
        done = true;
        if (attempt >= 4) throw e;
        setTimeout(() => direct(start, end, cb, attempt + 1), 2000);
    };
    const get = (u, n) => {
        const req = https.get(Object.assign(require('url').parse(u), {
            headers: { Range: 'bytes=' + start + '-' + end }, rejectUnauthorized: !insecure
        }), res => {
            if (res.statusCode >= 300 && res.statusCode < 400 && n < 5) { res.resume(); return get(require('url').resolve(u, res.headers.location), n + 1); }
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => { if (!done) { done = true; cb(Buffer.concat(chunks)); } });
            res.on('error', retry);
        });
        req.setTimeout(20000, () => req.abort());
        req.on('error', retry);
    };
    get(DIRECT, 0);
}

const sha = b => crypto.createHash('sha1').update(b).digest('hex');
const wait = (ms, fn) => setTimeout(fn, ms);
const steps = [];
const step = (name, fn) => steps.push({ name: name, fn: fn });
const log = function () { console.log.apply(console, arguments); };

let server;
let id;
let fileSize;
let first;

step('service starts', next => {
    server = childProcess.spawn(process.execPath, [path.join(__dirname, '..', 'dev.js')], {
        env: Object.assign({}, process.env, { BOBCORN_CACHE: cacheDir, BOBCORN_PORT: String(PORT) })
    });
    server.stdout.on('data', d => { if (process.env.VERBOSE) process.stdout.write('  | ' + d); });
    server.stderr.on('data', d => process.stdout.write('  ! ' + d));
    const poll = (n) => call('GET', '/ping', null, (code, body) => {
        if (code === 200) { assert.strictEqual(body.ok, true); log('  node', body.node, 'cache', body.cache); return next(); }
        if (n > 50) throw new Error('service did not start');
        wait(200, () => poll(n + 1));
    });
    poll(0);
});

step('/fetch proxies a catalog page', next => {
    call('GET', '/fetch?url=' + encodeURIComponent('https://samialsubhi.github.io/bobcorn/api/movies/1'), null, (code, body) => {
        assert.strictEqual(code, 200);
        assert.ok(Array.isArray(body) && body.length > 0, 'catalog page is a list');
        next();
    });
});

step('POST /torrents opens the .torrent', next => {
    call('POST', '/torrents', { link: TORRENT, runtimeMinutes: 96 }, (code, body) => {
        assert.strictEqual(code, 200, JSON.stringify(body));
        assert.strictEqual(body.id, HASH);
        assert.strictEqual(body.videoIndex, 5);
        fileSize = body.files[5].size;
        assert.strictEqual(body.files[5].path, 'Night.mp4');
        id = body.id;
        next();
    });
});

step('first 1 MiB matches the original file', next => {
    range('/torrents/' + id + '/files/5', 0, MiB - 1, (code, buf, headers, ms) => {
        assert.strictEqual(code, 206);
        assert.strictEqual(buf.length, MiB);
        assert.strictEqual(headers['content-range'], 'bytes 0-' + (MiB - 1) + '/' + fileSize);
        assert.strictEqual(headers['content-type'], 'video/mp4');
        first = buf;
        direct(0, MiB - 1, d => { assert.strictEqual(sha(buf), sha(d)); log('  ' + ms + ' ms'); next(); });
    });
});

step('last 1 MiB matches (pinned tail)', next => {
    range('/torrents/' + id + '/files/5', fileSize - MiB, fileSize - 1, (code, buf, headers, ms) => {
        assert.strictEqual(code, 206);
        assert.strictEqual(buf.length, MiB);
        direct(fileSize - MiB, fileSize - 1, d => { assert.strictEqual(sha(buf), sha(d)); log('  ' + ms + ' ms'); next(); });
    });
});

const duration = 96 * 60;
let bps;
step('position at 0 s: window is 0 to +15 min', next => {
    call('POST', '/torrents/' + id + '/position', { file: 5, seconds: 0, duration: duration }, code => {
        assert.strictEqual(code, 204);
        bps = fileSize / duration;
        call('GET', '/torrents/' + id + '/status', null, (c, s) => {
            assert.strictEqual(s.windowStart, 0);
            assert.ok(Math.abs(s.windowEnd - 900 * bps) < 2, 'window end ' + s.windowEnd + ' vs ' + 900 * bps);
            log('  window', s.windowStart, '-', s.windowEnd, 'pieces', JSON.stringify(s.pieces));
            next();
        });
    });
});

step('downloads ahead for 15 s', next => {
    wait(15000, () => call('GET', '/torrents/' + id + '/status', null, (c, s) => {
        log('  speed', Math.round(s.downSpeed / 1024), 'KiB/s, web seeds', s.webSeeds, 'peers', s.peers,
            'ahead', s.aheadSeconds, 's, cache', Math.round(s.cacheBytes / MiB), 'MiB, pieces', JSON.stringify(s.pieces));
        assert.ok(s.aheadBytes > MiB, 'something buffered ahead');
        next();
    }));
});

let seekByte;
step('seek to 60 min: window moves, old pieces evicted', next => {
    call('POST', '/torrents/' + id + '/position', { file: 5, seconds: 3600, duration: duration }, () => {
        seekByte = Math.floor(3600 * bps);
        range('/torrents/' + id + '/files/5', seekByte, seekByte + MiB - 1, (code, buf, h, ms) => {
            assert.strictEqual(code, 206);
            direct(seekByte, seekByte + MiB - 1, d => {
                assert.strictEqual(sha(buf), sha(d));
                log('  seek read ' + ms + ' ms');
                wait(3000, () => call('GET', '/torrents/' + id + '/status', null, (c, s) => {
                    assert.ok(Math.abs(s.windowStart - (3600 - 300) * bps) < 2, 'window start moved');
                    assert.ok(Math.abs(s.windowEnd - (3600 + 900) * bps) < 2, 'window end moved');
                    const bound = (s.windowEnd - s.windowStart) + 4 * MiB + 6 * PIECE;
                    assert.ok(s.cacheBytes <= bound, 'cache ' + s.cacheBytes + ' within window ' + bound);
                    log('  cache', Math.round(s.cacheBytes / MiB), 'MiB, window', Math.round((s.windowEnd - s.windowStart) / MiB), 'MiB, pieces', JSON.stringify(s.pieces));
                    next();
                }));
            });
        });
    });
});

step('pinned head is still cached after the seek', next => {
    const t0 = Date.now();
    range('/torrents/' + id + '/files/5', 0, MiB - 1, (code, buf) => {
        assert.strictEqual(sha(buf), sha(first));
        assert.ok(Date.now() - t0 < 1500, 'served from cache');
        next();
    });
});

step('no downloading past playhead + 15 min', next => {
    // A long duration makes the window tiny (a few pieces) so it fills fast.
    const longDuration = 5760 * 40;
    call('POST', '/torrents/' + id + '/position', { file: 5, seconds: 1000, duration: longDuration }, () => {
        const smallBps = fileSize / longDuration;
        const sample = (n, prev) => wait(4000, () => call('GET', '/torrents/' + id + '/status', null, (c, s) => {
            log('  t+' + (n * 4) + 's downloaded', Math.round(s.downloaded / MiB), 'MiB, window', s.pieces.have + '/' + s.pieces.want, 'cache', Math.round(s.cacheBytes / MiB), 'MiB');
            if (s.pieces.have < s.pieces.want && n < 15) return sample(n + 1, s);
            assert.ok(Math.abs(s.windowEnd - (1000 + 900) * smallBps) < 2);
            assert.ok(s.cacheBytes <= (s.windowEnd - s.windowStart) + 4 * MiB + 4 * PIECE, 'cache within window + pins');
            // Window full: downloading must stop.
            wait(6000, () => call('GET', '/torrents/' + id + '/status', null, (c2, s2) => {
                const extra = s2.downloaded - s.downloaded;
                log('  after the window filled: +' + Math.round(extra / 1024) + ' KiB in 6 s, speed', s2.downSpeed);
                assert.ok(extra <= 2 * PIECE, 'kept downloading ' + extra + ' bytes past the window');
                next();
            }));
        }));
        sample(1, null);
    });
});

step('DELETE closes and wipes the cache', next => {
    call('DELETE', '/torrents/' + id, null, code => {
        assert.strictEqual(code, 204);
        wait(300, () => {
            const left = fs.readdirSync(cacheDir).filter(n => /\.cache$/.test(n));
            assert.strictEqual(left.length, 0);
            next();
        });
    });
});

if (process.argv.indexOf('magnet') !== -1) {
    step('magnet link: metadata from peers (ut_metadata)', next => {
        const magnet = 'magnet:?xt=urn:btih:' + HASH + '&dn=night&tr=' + encodeURIComponent('http://bt1.archive.org:6969/announce') +
            '&tr=' + encodeURIComponent('http://bt2.archive.org:6969/announce') + '&ws=' + encodeURIComponent('https://archive.org/download/');
        const t0 = Date.now();
        call('POST', '/torrents', { link: magnet }, (code, body) => {
            if (code !== 200) {
                log('  no metadata from peers after', Math.round((Date.now() - t0) / 1000), 's:', JSON.stringify(body));
                return next();
            }
            log('  metadata in', Math.round((Date.now() - t0) / 1000), 's:', body.name, body.files.length, 'files');
            assert.strictEqual(body.id, HASH);
            range('/torrents/' + HASH + '/files/' + body.videoIndex, 0, 256 * 1024 - 1, (c, buf) => {
                assert.strictEqual(sha(buf), sha(first.slice(0, 256 * 1024)));
                call('GET', '/torrents/' + HASH + '/status', null, (c2, s) => {
                    log('  peers', s.peers, 'web seeds', s.webSeeds);
                    next();
                });
            });
        });
    });
}

let k = 0;
function run() {
    if (k >= steps.length) {
        log('all ' + steps.length + ' e2e steps passed on node ' + process.version);
        server.kill();
        return;
    }
    const s = steps[k++];
    log('- ' + s.name);
    s.fn(run);
}
process.on('uncaughtException', e => {
    console.log('FAILED:', e.stack || e.message);
    if (server) server.kill();
    process.exit(1);
});
run();
