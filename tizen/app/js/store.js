/* Settings and history kept on the TV (localStorage): sources, My List, resume positions. */
var Store = (function () {
    'use strict';

    var EXAMPLE = { id: 'example', name: 'Public Domain Films', url: 'https://samialsubhi.github.io/bobcorn/api' };

    function read(key, fallback) {
        try {
            var v = localStorage.getItem('bobcorn.' + key);
            return v === null ? fallback : JSON.parse(v);
        } catch (e) {
            return fallback;
        }
    }

    function write(key, value) {
        try { localStorage.setItem('bobcorn.' + key, JSON.stringify(value)); } catch (e) { /* storage full or blocked */ }
    }

    return {
        sources: function () { return read('sources', [EXAMPLE]); },
        setSources: function (list) { write('sources', list); },
        addSource: function (name, url) {
            var list = this.sources();
            url = url.replace(/\/+$/, '');
            var src = { id: String(Date.now()), name: name || url.replace(/^https?:\/\//, ''), url: url };
            list.push(src);
            this.setSources(list);
            this.setActiveSource(src.id);
            return src;
        },
        removeSource: function (id) {
            this.setSources(this.sources().filter(function (s) { return s.id !== id; }));
            if (this.activeSourceId() === id) write('activeSource', null);
        },
        activeSourceId: function () { return read('activeSource', null); },
        activeSource: function () {
            var list = this.sources(), id = this.activeSourceId();
            for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
            return list[0] || null;
        },
        setActiveSource: function (id) { write('activeSource', id); },

        // My List: titles you hearted, as listed (enough to draw a poster and reopen the page).
        myList: function () { return read('myList', []); },
        inMyList: function (key) { return this.myList().some(function (t) { return t.key === key; }); },
        toggleMyList: function (title) {
            var list = this.myList(), key = title.key;
            var had = list.some(function (t) { return t.key === key; });
            list = list.filter(function (t) { return t.key !== key; });
            if (!had) list.unshift(Catalog.saved(title));
            write('myList', list);
            return !had;
        },

        // Resume positions in seconds, keyed by title (and episode). Kept until watched to the end.
        resume: function (key) { return (read('resume', {})[key] || {}).seconds || 0; },
        setResume: function (key, seconds, duration, title) {
            var all = read('resume', {});
            var done = duration > 0 && seconds > duration - 120;
            if (done || seconds < 30) delete all[key];
            else all[key] = { seconds: Math.floor(seconds), duration: Math.floor(duration), at: Date.now(), title: title ? Catalog.saved(title) : null };
            write('resume', all);
        },
        continueWatching: function () {
            var all = read('resume', {}), out = [], seen = {};
            Object.keys(all).sort(function (a, b) { return all[b].at - all[a].at; }).forEach(function (k) {
                var t = all[k].title;
                if (t && !seen[t.key]) { seen[t.key] = true; out.push(t); }
            });
            return out;
        },

        // Two-letter codes (OpenSubtitles' kind); '' means subtitles start off.
        subtitleLanguage: function () {
            var v = read('subtitleLanguage', 'ar');
            var old = { ara: 'ar', eng: 'en', fre: 'fr', spa: 'es', ger: 'de' };
            return old[v] !== undefined ? old[v] : v;
        },
        setSubtitleLanguage: function (code) { write('subtitleLanguage', code); },

        // API keys, set in Settings (or baked in at build time from tizen/keys.json).
        key: function (name) {
            var v = read('key.' + name, null);
            if (v === null && window.BOBCORN_KEYS && window.BOBCORN_KEYS[name]) v = window.BOBCORN_KEYS[name];
            v = (v || '').trim();
            // OMDb's welcome email gives the key inside an example address: take it from there.
            var m = /[?&]apikey=([^&\s]+)/i.exec(v);
            return m ? decodeURIComponent(m[1]) : v;
        },
        setKey: function (name, value) { write('key.' + name, (value || '').trim()); },

        // OMDb Tomatometer scores by IMDb ID: {score|null, at}. Kept 14 days, 3 when a title has none.
        rating: function (id) {
            var all = read('ratings', {}), e = all[id];
            if (!e) return undefined;
            var fresh = Date.now() - e.at < (e.score === null ? 3 : 14) * 86400000;
            return fresh ? e.score : undefined;
        },
        setRating: function (id, score) {
            var all = read('ratings', {});
            all[id] = { score: score, at: Date.now() };
            var keys = Object.keys(all);
            if (keys.length > 3000) keys.sort(function (a, b) { return all[a].at - all[b].at; }).slice(0, 500).forEach(function (k) { delete all[k]; });
            write('ratings', all);
        },

        // Downloaded OpenSubtitles files, kept so picking one again costs nothing from the daily quota.
        // Per video: {downloads: [{fileID, label, language}], showing: fileID|null}.
        picked: function (key) { return read('picked', {})[key] || { downloads: [], showing: null }; },
        setPicked: function (key, p) { var all = read('picked', {}); all[key] = p; write('picked', all); },
        subtitleText: function (fileID) { return read('sub.' + fileID, null); },
        setSubtitleText: function (fileID, text) {
            var index = read('subIndex', []);
            index = index.filter(function (id) { return id !== fileID; });
            index.push(fileID);
            while (index.length > 30) { try { localStorage.removeItem('bobcorn.sub.' + index.shift()); } catch (e) {} }
            write('subIndex', index);
            write('sub.' + fileID, text);
        }
    };
})();
