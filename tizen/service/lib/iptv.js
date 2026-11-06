'use strict';
// Search for IPTV (Xtream Codes) accounts. Their full lists are huge (a 50 MB movie list and a 100 MB series
// list are normal), far too much for the TV's web app, so the engine reads them once, a piece at a time,
// keeps only what search needs (name, id, category, picture), saves that on disk and refreshes it daily.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const fetch = require('./fetch');
const ArrayStream = require('./jsonstream');
const util = require('./util');

const KINDS = [
    { kind: 'live', action: 'get_live_streams' },
    { kind: 'vod', action: 'get_vod_streams' },
    { kind: 'series', action: 'get_series' }
];
const FRESH_MS = 24 * 3600 * 1000;
const MAX_RESULTS = 60;

function base(host) {
    let h = String(host || '').trim();
    if (!/^https?:\/\//i.test(h)) h = 'http://' + h;
    return h.replace(/\/+$/, '');
}

// Lowercase, without accents or punctuation, so "Amélie!" matches "amelie".
function normalize(s) {
    s = String(s || '').toLowerCase();
    try { s = s.normalize('NFD').replace(/[̀-ͯ]/g, ''); } catch (e) { /* old runtime without normalize */ }
    return s.replace(/[^a-z0-9؀-ۿ]+/g, ' ').trim();
}

function compact(kind, x) {
    const name = x.name || x.title;
    if (!name) return null;
    const out = { n: String(name), c: x.category_id === undefined || x.category_id === null ? '' : String(x.category_id) };
    if (kind === 'series') {
        out.i = x.series_id;
        if (x.cover) out.l = x.cover;
    } else {
        out.i = x.stream_id;
        if (x.stream_icon) out.l = x.stream_icon;
    }
    if (kind === 'vod' && x.container_extension) out.e = x.container_extension;
    if (kind !== 'live' && x.rating !== undefined && x.rating !== '' && Number(x.rating) > 0) out.r = Number(x.rating);
    if (out.i === undefined || out.i === null) return null;
    return out;
}

function IptvIndex(dir) {
    this.dir = dir;
    this.accounts = new Map();   // key -> {status, progress, error, builtAt, items}
    try { fs.mkdirSync(dir); } catch (e) { /* exists */ }
}

IptvIndex.prototype.key = function (acc) {
    return crypto.createHash('sha1').update(base(acc.host) + '|' + acc.username).digest('hex').slice(0, 16);
};

IptvIndex.prototype.file = function (key) { return path.join(this.dir, 'iptv-' + key + '.json'); };

// The account's index state, loaded from disk the first time.
IptvIndex.prototype.state = function (acc) {
    const key = this.key(acc);
    let st = this.accounts.get(key);
    if (st) return st;
    st = { key: key, status: 'idle', progress: { live: 0, vod: 0, series: 0 }, error: null, builtAt: 0, items: null };
    try {
        const saved = JSON.parse(fs.readFileSync(this.file(key), 'utf8'));
        st.items = saved.items;
        st.builtAt = saved.builtAt;
        st.status = 'ready';
    } catch (e) { /* none yet */ }
    // One account in memory at a time: the TV is short of it.
    this.accounts.forEach((other, k) => { if (k !== key) other.items = null; });
    this.accounts.set(key, st);
    return st;
};

IptvIndex.prototype.build = function (acc) {
    const st = this.state(acc);
    if (st.status === 'building') return;
    st.status = 'building';
    st.error = null;
    const items = { live: [], vod: [], series: [] };
    st.progress = { live: 0, vod: 0, series: 0 };
    const started = Date.now();
    const next = (k) => {
        if (k >= KINDS.length) {
            st.items = items;
            st.builtAt = Date.now();
            st.status = 'ready';
            try { fs.writeFileSync(this.file(st.key), JSON.stringify({ builtAt: st.builtAt, items: items })); } catch (e) { util.log('iptv: could not save the index:', e.message); }
            util.log('iptv: index built in', Math.round((Date.now() - started) / 1000) + ' s:', items.live.length, 'channels,', items.vod.length, 'movies,', items.series.length, 'series');
            return;
        }
        const kind = KINDS[k].kind;
        const target = base(acc.host) + '/player_api.php?username=' + encodeURIComponent(acc.username) +
            '&password=' + encodeURIComponent(acc.password) + '&action=' + KINDS[k].action;
        const stream = new ArrayStream(x => {
            const c = compact(kind, x);
            if (c) { items[kind].push(c); st.progress[kind] = items[kind].length; }
        });
        fetch.request(target, { timeout: 180000 }, (err, res) => {
            if (err || res.statusCode !== 200) {
                if (res) res.resume();
                st.status = st.items ? 'ready' : 'error';   // keep an older index if there is one
                st.error = err ? err.message : 'The provider answered HTTP ' + res.statusCode;
                util.log('iptv: index of', kind, 'failed:', st.error);
                return;
            }
            res.on('data', chunk => stream.write(chunk));
            res.on('end', () => next(k + 1));
            res.on('error', e => {
                st.status = st.items ? 'ready' : 'error';
                st.error = e.message;
            });
        });
    };
    next(0);
};

// {status, progress, error, builtAt, results: {live, vod, series}}. Starts (or refreshes) the index as needed;
// while it's built for the first time there are no results yet and the app asks again.
IptvIndex.prototype.search = function (acc, query) {
    const st = this.state(acc);
    if (st.status !== 'building' && (!st.items || Date.now() - st.builtAt > FRESH_MS)) this.build(acc);
    const out = { status: st.status, progress: st.progress, error: st.error, builtAt: st.builtAt, results: null };
    if (!st.items) return out;
    const words = normalize(query).split(' ').filter(Boolean);
    if (!words.length) return out;
    const phrase = words.join(' ');
    out.results = {};
    Object.keys(st.items).forEach(kind => {
        const found = [];
        const list = st.items[kind];
        for (let i = 0; i < list.length; i++) {
            const name = normalize(list[i].n);
            if (words.every(w => name.indexOf(w) >= 0)) found.push({ item: list[i], name: name });
        }
        // Names that start with the query first, then the closest in length.
        found.sort((a, b) => (b.name.indexOf(phrase) === 0) - (a.name.indexOf(phrase) === 0) || a.name.length - b.name.length);
        out.results[kind] = found.slice(0, MAX_RESULTS).map(f => f.item);
        out.counts = out.counts || {};
        out.counts[kind] = found.length;
    });
    return out;
};

module.exports = { IptvIndex: IptvIndex, normalize: normalize, compact: compact };
