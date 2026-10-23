'use strict';
// HTTP(S) requests with redirects and timeouts, on Node core only.

const http = require('http');
const https = require('https');
const url = require('url');
const util = require('./util');

// Node 4's built-in certificate store predates today's roots (Let's Encrypt
// among them), so on such old runtimes certificate checks would fail for most
// sites. There we skip them: torrent data is SHA1-checked against the info hash
// either way. Modern Node keeps full verification.
const MAJOR = parseInt(process.version.slice(1), 10);
const VERIFY_TLS = MAJOR >= 8 && process.env.BOBCORN_INSECURE_TLS !== '1';

const agents = {
    http: new http.Agent({ keepAlive: true, maxSockets: 8 }),
    https: new https.Agent({ keepAlive: true, maxSockets: 8, rejectUnauthorized: VERIFY_TLS })
};

// cb(err, res, finalUrl). res is the response stream; the caller must consume it.
function request(target, opts, cb) {
    opts = opts || {};
    let redirects = opts.maxRedirects === undefined ? 5 : opts.maxRedirects;
    const timeout = opts.timeout || 20000;
    let done = false;
    const finish = (err, res, finalUrl) => {
        if (done) return;
        done = true;
        cb(err, res, finalUrl);
    };

    const go = (current) => {
        let u;
        try { u = url.parse(current); } catch (e) { return finish(new Error('Bad URL')); }
        if (u.protocol !== 'http:' && u.protocol !== 'https:') return finish(new Error('Only http and https URLs are supported'));
        const mod = u.protocol === 'https:' ? https : http;
        const headers = { 'User-Agent': 'Bobcorn-TV/1.0', 'Accept-Encoding': 'identity' };
        if (opts.headers) Object.keys(opts.headers).forEach(k => { headers[k] = opts.headers[k]; });
        // A body goes with the first request only; a redirect after a POST becomes a GET.
        const body = current === target && opts.body ? (Buffer.isBuffer(opts.body) ? opts.body : util.from(String(opts.body), 'utf8')) : null;
        if (body) headers['Content-Length'] = body.length;
        const req = mod.request({
            protocol: u.protocol,
            hostname: u.hostname,
            port: u.port,
            path: u.path,
            method: current === target && opts.method ? opts.method : 'GET',
            headers: headers,
            agent: u.protocol === 'https:' ? agents.https : agents.http,
            rejectUnauthorized: VERIFY_TLS
        }, res => {
            const code = res.statusCode;
            if (code >= 300 && code < 400 && res.headers.location) {
                res.resume();
                if (redirects-- <= 0) return finish(new Error('Too many redirects'));
                return go(url.resolve(current, res.headers.location));
            }
            res.setTimeout && res.setTimeout(timeout, () => res.destroy(new Error('Timed out')));
            finish(null, res, current);
        });
        req.setTimeout(timeout, () => {
            req.abort();
            finish(new Error('Timed out'));
        });
        req.on('error', e => finish(e));
        if (opts.onRequest) opts.onRequest(req);
        req.end(body || undefined);
    };
    go(target);
}

// Whole body as a Buffer. cb(err, body, res, finalUrl).
function getBuffer(target, opts, cb) {
    opts = opts || {};
    const max = opts.maxBytes || 20 * 1024 * 1024;
    request(target, opts, (err, res, finalUrl) => {
        if (err) return cb(err);
        const chunks = [];
        let size = 0;
        let failed = false;
        res.on('data', c => {
            size += c.length;
            if (size > max && !failed) {
                failed = true;
                res.destroy();
                cb(new Error('Response too large'));
                return;
            }
            chunks.push(c);
        });
        res.on('end', () => { if (!failed) cb(null, Buffer.concat(chunks), res, finalUrl); });
        res.on('error', e => { if (!failed) { failed = true; cb(e); } });
    });
}

module.exports = { request: request, getBuffer: getBuffer, VERIFY_TLS: VERIFY_TLS };
