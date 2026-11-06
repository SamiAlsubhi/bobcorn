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
        if (BACKED_UP.indexOf(key) >= 0) scheduleBackup();
    }

    // ---- Backup in the engine ---------------------------------------------------------------------
    // The TV drops an app's localStorage when the app is reinstalled or its data is cleared. These settings
    // are also copied to the engine, which keeps them in the TV's shared storage, and restored from there
    // when localStorage comes up empty. (Ratings and subtitle files are caches: they aren't backed up.)
    var BACKED_UP = ['sources', 'activeSource', 'myList', 'resume', 'picked', 'subtitleLanguage',
        'key.omdb', 'key.opensubtitles', 'logSharing', 'builtinsSeen'];
    var backupTimer = null;

    function snapshot() {
        var out = {};
        BACKED_UP.forEach(function (k) {
            try { var v = localStorage.getItem('bobcorn.' + k); if (v !== null) out[k] = v; } catch (e) {}
        });
        return out;
    }
    function scheduleBackup() {
        clearTimeout(backupTimer);
        backupTimer = setTimeout(function () {
            if (window.Engine) Engine.saveSettings(snapshot()).catch(function () { /* engine not up yet; the next change retries */ });
        }, 1500);
    }

    // Sources built in from tizen/keys.json ("sources": [{name, url}]), offered when none are saved.
    function builtInSources() {
        var extra = (window.BOBCORN_KEYS && window.BOBCORN_KEYS.sources) || [];
        return [EXAMPLE].concat(extra.filter(function (s) { return s && (s.url || s.host); }).map(function (s, i) {
            if (s.kind === 'xtream') return { id: 'builtin' + i, kind: 'xtream', name: s.name || s.host, host: s.host, username: s.username, password: s.password };
            if (s.kind === 'm3u') return { id: 'builtin' + i, kind: 'm3u', name: s.name || 'Playlist', url: s.url };
            return { id: 'builtin' + i, name: s.name || s.url.replace(/^https?:\/\//, ''), url: String(s.url).replace(/\/+$/, '') };
        }));
    }

    // What identifies a source, whatever its id: its address (and username, for an IPTV account).
    function signature(src) {
        var where = String(src.host || src.url || '').replace(/^https?:\/\//, '').replace(/\/+$/, '').toLowerCase();
        return (src.kind || 'api') + ':' + where + (src.username ? ':' + src.username : '');
    }

    return {
        /* True when this TV's localStorage holds no saved settings (fresh install, or data cleared). */
        isEmpty: function () { return Object.keys(snapshot()).length === 0; },
        /* Puts a backup's values back; resolves true when anything was restored. */
        restore: function (saved) {
            var n = 0;
            BACKED_UP.forEach(function (k) {
                if (saved && typeof saved[k] === 'string') { try { localStorage.setItem('bobcorn.' + k, saved[k]); n++; } catch (e) {} }
            });
            return n > 0;
        },
        backupNow: function () { scheduleBackup(); },

        sources: function () {
            var saved = read('sources', null);
            if (!saved) return builtInSources();
            // A build can bring new built-in sources (an IPTV account, say): add each to a saved list once.
            // Once added it's an ordinary source, so removing it in Settings keeps it removed.
            var seen = read('builtinsSeen', []), added = false;
            builtInSources().forEach(function (b) {
                var sig = signature(b);
                if (seen.indexOf(sig) >= 0) return;
                seen.push(sig);
                added = true;
                if (!saved.some(function (x) { return signature(x) === sig; })) saved.push(b);
            });
            if (added) { write('builtinsSeen', seen); write('sources', saved); }
            return saved;
        },
        setSources: function (list) {
            // The built-ins were on offer when this list was made: one removed here stays removed.
            var seen = read('builtinsSeen', []);
            builtInSources().forEach(function (b) { var sig = signature(b); if (seen.indexOf(sig) < 0) seen.push(sig); });
            write('builtinsSeen', seen);
            write('sources', list);
        },
        addSource: function (name, url) {
            var list = this.sources();
            url = url.replace(/\/+$/, '');
            var src = { id: String(Date.now()), name: name || url.replace(/^https?:\/\//, ''), url: url };
            list.push(src);
            this.setSources(list);
            this.setActiveSource(src.id);
            return src;
        },
        /* An IPTV source: {kind: 'xtream', name, host, username, password} or {kind: 'm3u', name, url}. */
        addIptvSource: function (src) {
            var list = this.sources();
            src.id = 'iptv' + Date.now();
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

        // Troubleshooting: the engine serves its log on the home network while this is on.
        logSharing: function () { return read('logSharing', false) === true; },
        setLogSharing: function (on) { write('logSharing', !!on); },

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
