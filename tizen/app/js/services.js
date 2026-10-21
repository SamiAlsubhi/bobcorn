/* Online extras with your own free keys, as in the Mac app:
   - Ratings: Rotten Tomatoes' Tomatometer from OMDb (Sources/Bobcorn/Ratings.swift).
   - OpenSubtitles: search by IMDb ID (or file name) and by the file's hash, download as .srt
     (Sources/Bobcorn/OpenSubtitles.swift). A free key downloads 5 a day, so downloads are kept.
   - Subs: .srt / .vtt parsing for the player's own subtitle line. */

var Ratings = (function () {
    'use strict';
    var waiting = [], running = 0, asked = {}, listeners = [], lastError = null;

    function next() {
        var key = Store.key('omdb');
        while (running < 4 && waiting.length && key) {
            var id = waiting.pop();
            running++;
            fetchOne(id, key).then(function (r) {
                Store.setRating(r.id, r.score);
                lastError = null;
                listeners.forEach(function (fn) { fn(r.id, r.score); });
            }, function (err) {
                delete asked[err.id];
                lastError = err.message;
                if (err.badKey) waiting = [];
            }).then(function () { running--; next(); });
        }
    }

    function fetchOne(id, key) {
        return Engine.fetch('https://www.omdbapi.com/?i=' + encodeURIComponent(id) + '&apikey=' + encodeURIComponent(key)).then(function (json) {
            if (typeof json === 'string') { try { json = JSON.parse(json); } catch (e) { json = null; } }
            if (!json) throw tagged(id, 'OMDb sent an answer that isn\'t JSON');
            if (json.Response === 'False') {
                var why = json.Error || 'unknown error';
                if (/not found/i.test(why)) return { id: id, score: null };
                var e = tagged(id, 'OMDb refused the key: ' + why);
                e.badKey = /key|limit/i.test(why);
                throw e;
            }
            var rt = (json.Ratings || []).filter(function (r) { return r.Source === 'Rotten Tomatoes'; })[0];
            return { id: id, score: rt ? parseInt(rt.Value, 10) : null };
        }, function (err) {
            var e = tagged(id, 'OMDb: ' + err.message);
            e.badKey = err.status === 401;
            throw e;
        });
    }
    function tagged(id, msg) { var e = new Error(msg); e.id = id; return e; }

    return {
        /* The known score (a number), null when Rotten Tomatoes has none, undefined when not known yet:
           then it's fetched, and onChange listeners hear about it. */
        get: function (id) {
            if (!/^tt\d+/.test(id || '') || !Store.key('omdb')) return undefined;
            var s = Store.rating(id);
            if (s !== undefined) return s;
            if (!asked[id]) { asked[id] = true; waiting.push(id); next(); }
            return undefined;
        },
        onChange: function (fn) { listeners.push(fn); },
        keyChanged: function () { asked = {}; lastError = null; },
        lastError: function () { return lastError; },
        /* A small tomato (fresh, 60% and up) or splat (rotten), and the score. */
        badge: function (score) {
            if (score === null || score === undefined) return '';
            var icon = score >= 60
                ? '<svg viewBox="0 0 20 20" class="rt"><circle cx="10" cy="11.5" r="7.5" fill="#fa320a"/><path d="M6 4.5c2 .3 3 1.3 4 2.6 1-1.3 2-2.3 4-2.6-1 1.6-2.3 2.6-4 3-1.7-.4-3-1.4-4-3z" fill="#00912d"/></svg>'
                : '<svg viewBox="0 0 20 20" class="rt"><path d="M10 2l1.6 4.2 4.3-1.6-1.7 4.2 4.2 1.6-4.2 1.7 1.6 4.2-4.2-1.6L10 19l-1.6-4.3-4.3 1.6 1.7-4.2L1.6 10.4l4.2-1.7-1.6-4.2 4.2 1.6z" fill="#0ac855"/></svg>';
            return icon + score + '%';
        }
    };
})();

var OpenSubtitles = (function () {
    'use strict';
    var API = 'https://api.opensubtitles.com/api/v1/';
    var UA = 'Bobcorn v1.3.1';

    var NAMES = { ar: 'Arabic', en: 'English', fr: 'French', es: 'Spanish', de: 'German', tr: 'Turkish', it: 'Italian',
        'pt-br': 'Portuguese (BR)', pt: 'Portuguese', ru: 'Russian', fa: 'Persian', ur: 'Urdu', hi: 'Hindi', id: 'Indonesian',
        ms: 'Malay', nl: 'Dutch', pl: 'Polish', sv: 'Swedish', el: 'Greek', he: 'Hebrew', zh: 'Chinese', ja: 'Japanese', ko: 'Korean' };

    function headers() {
        return { 'Api-Key': Store.key('opensubtitles'), 'User-Agent': UA, 'Accept': '*/*', 'Content-Type': 'application/json' };
    }

    function failure(err) {
        var status = err.status, msg = err.data && err.data.message;
        if (status === 401 || status === 403) return new Error('OpenSubtitles refused the API key: ' + (msg || 'HTTP ' + status));
        if (status === 429) return new Error('OpenSubtitles is busy. Try again in a moment.');
        return new Error(msg ? 'OpenSubtitles: ' + msg : 'Couldn\'t reach OpenSubtitles (' + err.message + ').');
    }

    function send(path, method, body, retried) {
        if (!Store.key('opensubtitles')) return Promise.reject(new Error('Add an OpenSubtitles API key in Settings to search for subtitles.'));
        return Engine.send(API + path, method, headers(), body).catch(function (err) {
            if (err.status >= 500 && !retried) return new Promise(function (r) { setTimeout(r, 1000); }).then(function () { return send(path, method, body, true); });
            throw failure(err);
        });
    }

    function imdbNumber(id) {
        var n = parseInt(String(id || '').replace(/^tt/i, ''), 10);
        return n > 0 ? String(n) : null;
    }

    function words(name) {
        var out = {};
        String(name || '').toLowerCase().split(/[^a-z0-9]+/).forEach(function (w) { if (w) out[w] = true; });
        return out;
    }

    return {
        languageName: function (code) { return NAMES[(code || '').toLowerCase()] || (code || '').toUpperCase(); },
        LANGUAGES: Object.keys(NAMES),

        /* q: {imdbID, season, episode, fileName, hash, language}. Ranked as the Mac app does: timed to this file,
           made by people, closest release name, most downloaded. */
        search: function (q) {
            var p = { languages: (q.language || 'en').toLowerCase() };
            if (q.hash) p.moviehash = q.hash;
            var id = imdbNumber(q.imdbID);
            if (id) {
                if (q.season !== null && q.season !== undefined && q.episode !== null && q.episode !== undefined) {
                    p.parent_imdb_id = id; p.season_number = String(q.season); p.episode_number = String(q.episode);
                } else p.imdb_id = id;
            } else if (q.fileName) p.query = q.fileName.toLowerCase();
            // Sorted keys, as the API asks, so it answers without a redirect.
            var query = Object.keys(p).sort().map(function (k) { return k + '=' + encodeURIComponent(p[k]).replace(/%20/g, '+'); }).join('&');
            return send('subtitles?' + query, 'GET').then(function (json) {
                var list = (json && json.data) || [];
                var fileWords = words(q.fileName);
                var subs = list.map(function (item) {
                    var a = item.attributes || {}, files = a.files || [];
                    if (files.length !== 1) return null;   // a subtitle split over CDs
                    var release = (a.release || files[0].file_name || '').trim();
                    var common = 0, w = words(release);
                    Object.keys(w).forEach(function (x) { if (fileWords[x]) common++; });
                    return {
                        fileID: files[0].file_id, language: a.language || '', release: release,
                        downloads: a.download_count || 0, hearingImpaired: !!a.hearing_impaired,
                        machine: !!(a.machine_translated || a.ai_translated), matchesFile: !!a.moviehash_match, common: common
                    };
                }).filter(Boolean);
                subs.sort(function (x, y) {
                    return (y.matchesFile - x.matchesFile) || (x.machine - y.machine) || (y.common - x.common) || (y.downloads - x.downloads);
                });
                return subs;
            });
        },

        /* The subtitle's text: from the TV's store when downloaded before (free), else downloaded (counts
           against the daily quota). Resolves {text, remaining}. */
        download: function (sub) {
            var kept = Store.subtitleText(sub.fileID);
            if (kept) return Promise.resolve({ text: kept, remaining: null });
            return send('download', 'POST', { file_id: sub.fileID }).then(function (answer) {
                if (!answer || !answer.link) throw new Error('OpenSubtitles didn\'t say where to download the subtitle from.');
                return Engine.fetch(answer.link).then(function (text) {
                    if (typeof text !== 'string' || !text.trim()) throw new Error('The subtitle\'s download link didn\'t work. Try again.');
                    Store.setSubtitleText(sub.fileID, text);
                    return { text: text, remaining: answer.remaining };
                });
            });
        },

        label: function (sub) { return this.languageName(sub.language) + ' · ' + sub.release; }
    };
})();

/* YIFY Subtitles (yts-subs.com): films only, by IMDb ID, and no key needed. Pages are HTML; each subtitle
   downloads as a .zip, which the engine opens. */
var YifySubs = (function () {
    'use strict';
    var SITE = 'https://yts-subs.com';
    // The names YIFY uses, where they differ from ours.
    var ALIASES = { fa: ['farsi/persian', 'persian', 'farsi'], 'pt-br': ['brazilian portuguese'], zh: ['chinese', 'chinese bg code'] };

    function names(code) {
        return (ALIASES[code] || []).concat([OpenSubtitles.languageName(code).toLowerCase()]);
    }
    function textOf(html) { var d = document.createElement('div'); d.innerHTML = html; return (d.textContent || '').replace(/\s+/g, ' ').trim(); }

    return {
        search: function (imdbID, lang, fileName) {
            var want = names(lang);
            return Engine.fetch(SITE + '/movie-imdb/' + encodeURIComponent(imdbID)).then(function (html) {
                if (typeof html !== 'string') return [];
                var words = {};
                String(fileName || '').toLowerCase().split(/[^a-z0-9]+/).forEach(function (w) { if (w) words[w] = true; });
                var rows = html.match(/<tr[^>]*data-id="\d+"[\s\S]*?<\/tr>/g) || [];
                return rows.map(function (row) {
                    var language = (/class="sub-lang">([^<]*)/.exec(row) || [])[1] || '';
                    var link = (/href="(\/subtitles\/[^"]+)"/.exec(row) || [])[1];
                    if (!link || want.indexOf(language.trim().toLowerCase()) < 0) return null;
                    // One subtitle can list several releases, a line each: label with the first, match on all.
                    var releases = ((/<a href="\/subtitles\/[^"]+">([\s\S]*?)<\/a>/.exec(row) || [])[1] || '').split(/<br\s*\/?>/i)
                        .map(function (x) { return textOf(x).replace(/^subtitle\s*/i, ''); }).filter(Boolean);
                    var release = (releases[0] || '') + (releases.length > 1 ? '  +' + (releases.length - 1) + ' more' : '');
                    var common = 0;
                    releases.join(' ').toLowerCase().split(/[^a-z0-9]+/).forEach(function (w) { if (w && words[w]) common++; });
                    return {
                        source: 'yify', fileID: 'yify:' + (/data-id="(\d+)"/.exec(row) || [])[1], page: SITE + link,
                        language: lang, release: release, rating: parseInt((/label[^>]*>(-?\d+)</.exec(row) || [])[1] || '0', 10),
                        uploader: textOf((/uploader-cell">([\s\S]*?)<\/td>/.exec(row) || [])[1] || ''), common: common
                    };
                }).filter(Boolean).sort(function (a, b) { return (b.common - a.common) || (b.rating - a.rating); });
            });
        },

        /* Resolves {text}: from the TV's store when downloaded before, else the zip's subtitle, decoded. */
        download: function (sub) {
            var kept = Store.subtitleText(sub.fileID);
            if (kept) return Promise.resolve({ text: kept });
            return Engine.fetch(sub.page).then(function (html) {
                var b64 = (/data-link="([^"]+)"/.exec(String(html)) || [])[1];
                if (!b64) throw new Error('YIFY Subtitles changed its page; this subtitle can\'t be downloaded.');
                return Engine.unzip(atob(b64));
            }).then(function (buf) {
                var text = Subs.decode(buf, sub.language);
                Store.setSubtitleText(sub.fileID, text);
                return { text: text };
            });
        },

        label: function (sub) { return OpenSubtitles.languageName(sub.language) + ' · ' + (sub.release.replace(/\s+\+\d+ more$/, '') || 'YIFY'); }
    };
})();

var Subs = (function () {
    'use strict';
    // Older subtitle files use their language's Windows code page rather than UTF-8.
    var CODEPAGE = { ar: 'windows-1256', fa: 'windows-1256', ur: 'windows-1256', ru: 'windows-1251', bg: 'windows-1251',
        uk: 'windows-1251', el: 'windows-1253', tr: 'windows-1254', he: 'windows-1255', pl: 'windows-1250', cs: 'windows-1250',
        hu: 'windows-1250', ro: 'windows-1250', vi: 'windows-1258', zh: 'gbk', ja: 'shift_jis', ko: 'euc-kr' };
    function time(t) {
        var m = /(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})/.exec(t);
        if (!m) return null;
        return (parseInt(m[1] || '0', 10) * 3600) + parseInt(m[2], 10) * 60 + parseInt(m[3], 10) + parseInt((m[4] + '00').slice(0, 3), 10) / 1000;
    }
    return {
        /* Subtitle bytes → text: UTF-8 when the bytes are valid UTF-8, else the language's code page. */
        decode: function (buf, lang) {
            try { return new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { /* not UTF-8 */ }
            var cp = CODEPAGE[(lang || '').toLowerCase()] || 'windows-1252';
            try { return new TextDecoder(cp).decode(buf); } catch (e) { return new TextDecoder('windows-1252').decode(buf); }
        },

        /* SRT or WebVTT text → [{start, end, text}] sorted by start. */
        parse: function (text) {
            var cues = [];
            String(text || '').replace(/\r/g, '').replace(/^﻿/, '').split(/\n\s*\n/).forEach(function (block) {
                var lines = block.split('\n').filter(function (l) { return l.trim() !== ''; });
                for (var i = 0; i < lines.length; i++) {
                    var m = /([\d:.,]+)\s*-->\s*([\d:.,]+)/.exec(lines[i]);
                    if (m) {
                        var s = time(m[1]), e = time(m[2]);
                        // Keep italics and bold; drop colours, positions and other markup.
                        var text = lines.slice(i + 1).join('\n').replace(/\{\\[^}]*\}/g, '').replace(/<(?!\/?[ib]>)[^>]*>/gi, '');
                        if (s !== null && e !== null) cues.push({ start: s, end: e, text: text });
                        break;
                    }
                }
            });
            return cues.sort(function (a, b) { return a.start - b.start; });
        },
        /* The text showing at second t, or ''. */
        at: function (cues, t) {
            var lo = 0, hi = cues.length - 1, found = -1;
            while (lo <= hi) {   // the last cue starting at or before t
                var mid = (lo + hi) >> 1;
                if (cues[mid].start <= t) { found = mid; lo = mid + 1; } else hi = mid - 1;
            }
            var out = [];
            for (var i = found; i >= 0 && i > found - 4; i--) if (cues[i].end > t) out.unshift(cues[i].text);
            return out.join('\n');
        }
    };
})();
