/* Full-screen playback with Samsung's AVPlay (which plays MKV, MP4, AVI, TS natively, so nothing is remuxed),
   or a <video> element in a desktop browser. It reports the playhead to the engine every 2 s: that is what
   moves the engine's window of 5 minutes behind to 15 minutes ahead.

   Controls: any key shows them. On the seek bar ◀ ▶ seek and OK pauses; ▼ goes to the buttons (play/pause,
   subtitles, audio, next episode), where OK opens their menus. Colour keys are shortcuts, not required. */
var Player = (function () {
    'use strict';

    var av = (typeof webapis !== 'undefined' && webapis.avplay) ? webapis.avplay : null;
    var video = null, osd = null, subtitleEl = null;
    var s = null;            // the session: what's playing and its state
    var timers = [];

    function $(id) { return document.getElementById(id); }
    function clock(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        var h = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, x = sec % 60;
        return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
    }
    function every(ms, fn) { timers.push(setInterval(fn, ms)); }
    function clearTimers() { timers.forEach(clearInterval); timers = []; }
    function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
    function toast(msg) { if (window.Views) Views.toast(msg); }

    // ---- The two backends: AVPlay on the TV, <video> elsewhere --------------------------------

    var backend = {
        open: function (url, onReady, onError) {
            if (av) {
                try { av.close(); } catch (e) { /* nothing open */ }
                av.open(url);
                av.setDisplayRect(0, 0, 1920, 1080);
                av.setListener({
                    onbufferingstart: function () { if (s) { s.buffering = true; render(); } },
                    onbufferingprogress: function () {},
                    onbufferingcomplete: function () { if (s) { s.buffering = false; render(); } },
                    oncurrentplaytime: function (ms) { if (s) s.time = ms / 1000; },
                    onstreamcompleted: function () { finished(); },
                    onerror: function (e) { streamError(String(e)); },
                    onsubtitlechange: function (duration, text) { if (s && s.sub && s.sub.kind === 'embedded') showLine(text, duration); },
                    onevent: function () {}
                });
                av.prepareAsync(function () { onReady(); }, function (e) { onError(String((e && (e.name || e.message)) || e)); });
            } else {
                video.src = url;
                video.onloadedmetadata = function () { video.onloadedmetadata = null; onReady(); };
                // Codes as AVPlay names them, so a dropped connection is retried the same way.
                video.onerror = function () {
                    var c = video.error ? video.error.code : 0;
                    if (s && s.loading === 'Starting…' && c === 4) return fail('This browser cannot play this file. On the TV, MKV plays.');
                    (s && s.loading === 'Starting…' ? onError : streamError)(c === 2 ? 'PLAYER_ERROR_CONNECTION_FAILED' : 'MEDIA_ERR_' + c);
                };
                video.ontimeupdate = function () { if (s) s.time = video.currentTime; };
                video.onwaiting = function () { if (s) { s.buffering = true; render(); } };
                video.onplaying = function () { if (s) { s.buffering = false; render(); } };
                video.onended = function () { finished(); };
                video.load();
            }
        },
        play: function () { if (av) av.play(); else video.play(); },
        pause: function () { if (av) av.pause(); else video.pause(); },
        paused: function () { return av ? av.getState() === 'PAUSED' : video.paused; },
        duration: function () { return av ? av.getDuration() / 1000 : (video.duration || 0); },
        time: function () { return av ? av.getCurrentTime() / 1000 : video.currentTime; },
        seek: function (sec, done) {
            if (av) av.seekTo(Math.max(0, Math.floor(sec * 1000)), function () { if (done) done(); }, function () { if (done) done(); });
            else { video.currentTime = sec; if (done) done(); }
        },
        stop: function () {
            if (av) { try { av.stop(); } catch (e) {} try { av.close(); } catch (e) {} }
            else { video.pause(); video.removeAttribute('src'); video.load(); }
        },
        tracks: function (type) {
            if (!av) return [];
            try {
                return av.getTotalTrackInfo().filter(function (t) { return t.type === type; }).map(function (t, n) {
                    var info = {};
                    try { info = JSON.parse(t.extra_info); } catch (e) {}
                    var lang = info.track_lang || info.language || '';
                    return { index: t.index, language: lang, label: languageLabel(lang) || ((type === 'AUDIO' ? 'Track ' : 'Subtitle ') + (n + 1)) };
                });
            } catch (e) { return []; }
        },
        selectTrack: function (type, index) { if (av) try { av.setSelectTrack(type, index); } catch (e) { console.error(e); } },
        embeddedOff: function (off) { if (av) try { av.setSilentSubtitle(off); } catch (e) {} }
    };

    // ISO 639-2 (what MKV tracks carry) to the two-letter codes OpenSubtitles and Settings use.
    var THREE = { ara: 'ar', eng: 'en', fre: 'fr', fra: 'fr', spa: 'es', ger: 'de', deu: 'de', tur: 'tr', ita: 'it', por: 'pt',
        rus: 'ru', per: 'fa', fas: 'fa', urd: 'ur', hin: 'hi', ind: 'id', may: 'ms', msa: 'ms', dut: 'nl', nld: 'nl', pol: 'pl',
        swe: 'sv', gre: 'el', ell: 'el', heb: 'he', chi: 'zh', zho: 'zh', jpn: 'ja', kor: 'ko' };
    function two(lang) { lang = (lang || '').toLowerCase(); return THREE[lang] || lang.slice(0, 2); }
    function languageLabel(lang) { return lang ? OpenSubtitles.languageName(two(lang)) : ''; }

    // ---- Subtitles: off, embedded (AVPlay draws the text through onsubtitlechange), or a file we time ourselves --

    var lineTimer = null;
    function showLine(text, duration) {
        subtitleEl.innerHTML = esc(text || '').replace(/\n/g, '<br>').replace(/&lt;(\/?)(i|b)&gt;/g, '<$1$2>');
        clearTimeout(lineTimer);
        if (duration) lineTimer = setTimeout(function () { subtitleEl.innerHTML = ''; }, Math.max(500, duration));
    }

    function setSubtitle(sub) {
        s.sub = sub;
        s.cues = null;
        subtitleEl.innerHTML = '';
        if (!sub) { backend.embeddedOff(true); return; }
        if (sub.kind === 'embedded') { backend.selectTrack('TEXT', sub.index); backend.embeddedOff(false); return; }
        backend.embeddedOff(true);
        s.cues = Subs.parse(sub.text);
        if (!s.cues.length) toast('That subtitle file has no lines Bobcorn can read');
    }

    function tickSubtitle() {
        if (!s || !s.cues) return;
        var text = Subs.at(s.cues, backend.time());
        if (text !== s.lastLine) { s.lastLine = text; showLine(text, 0); }
    }

    function subtitleFiles() {
        if (!s.torrent) return [];
        var video = (s.file && s.file.path) || '';
        var base = video.replace(/\.[^.\/]+$/, '').split('/').pop().toLowerCase();
        return s.torrent.files.filter(function (f) { return /\.(srt|vtt)$/i.test(f.path); }).sort(function (a, b) {
            // The episode's own file first, then by name.
            return (b.path.toLowerCase().indexOf(base) >= 0) - (a.path.toLowerCase().indexOf(base) >= 0) || (a.path < b.path ? -1 : 1);
        });
    }

    function loadTorrentSubtitle(f) {
        var lang = Store.subtitleLanguage();
        return Engine.fileBytes(s.torrent.id, f.index).then(function (buf) { return Subs.decode(buf, lang); });
    }

    /* At start: the subtitle shown last time for this video, else an embedded track in the preferred language. */
    function chooseInitialSubtitle() {
        s.embedded = backend.tracks('TEXT');
        s.audios = backend.tracks('AUDIO');
        s.audioIndex = 0;
        var picked = Store.picked(s.resumeKey);
        if (picked.showing) {
            var d = picked.downloads.filter(function (x) { return x.fileID === picked.showing; })[0];
            var text = Store.subtitleText(picked.showing);
            if (d && text) { setSubtitle({ kind: 'file', id: 'os:' + d.fileID, label: d.label, text: text }); return; }
        }
        var want = Store.subtitleLanguage();
        var match = want ? s.embedded.filter(function (t) { return two(t.language) === want; })[0] : null;
        if (match) setSubtitle({ kind: 'embedded', id: 'emb:' + match.index, index: match.index, label: match.label });
        else setSubtitle(null);
    }

    function rememberShowing(fileID) {
        var p = Store.picked(s.resumeKey);
        p.showing = fileID;
        Store.setPicked(s.resumeKey, p);
    }

    function subtitleLabel() { return s.sub ? s.sub.label : 'Off'; }

    // ---- Menus (subtitles, audio, OpenSubtitles results), drawn over the video -----------------

    function openMenu(title, items, focusIndex) {
        s.menu = { title: title, items: items, index: Math.max(0, focusIndex || 0) };
        showOSD();
    }
    function closeMenu() { s.menu = null; showOSD(); }

    function subtitleMenu() {
        var cur = s.sub ? s.sub.id : null;
        var items = [{ label: 'Off', selected: !s.sub, run: function () { setSubtitle(null); rememberShowing(null); closeMenu(); } }];
        s.embedded.forEach(function (t) {
            var id = 'emb:' + t.index;
            items.push({ label: t.label, note: 'in the video', selected: cur === id, run: function () {
                setSubtitle({ kind: 'embedded', id: id, index: t.index, label: t.label });
                rememberShowing(null);
                if (t.language) Store.setSubtitleLanguage(two(t.language));
                closeMenu();
            } });
        });
        subtitleFiles().forEach(function (f) {
            var id = 'tor:' + f.index, name = f.path.split('/').pop();
            items.push({ label: name, note: 'in the torrent', selected: cur === id, run: function () {
                toast('Loading ' + name + '…');
                loadTorrentSubtitle(f).then(function (text) {
                    if (!s) return;
                    setSubtitle({ kind: 'file', id: id, label: name, text: text });
                    rememberShowing(null);
                    closeMenu();
                }, function (e) { toast(e.message); });
            } });
        });
        Store.picked(s.resumeKey).downloads.forEach(function (d) {
            var id = 'os:' + d.fileID;
            if (!Store.subtitleText(d.fileID)) return;
            items.push({ label: d.label, note: 'downloaded', selected: cur === id, run: function () {
                setSubtitle({ kind: 'file', id: id, label: d.label, text: Store.subtitleText(d.fileID) });
                rememberShowing(d.fileID);
                closeMenu();
            } });
        });
        var lang = Store.subtitleLanguage() || 'en';
        items.push({ label: 'Search subtitles · ' + OpenSubtitles.languageName(lang), note: searchNote(), action: true, run: function () { searchSubtitles(lang); } });
        items.push({ label: 'Search in another language…', action: true, run: languageMenu });
        var focus = 0;
        items.forEach(function (it, i) { if (it.selected) focus = i; });
        openMenu('Subtitles', items, focus);
    }

    function languageMenu() {
        var langs = OpenSubtitles.LANGUAGES;
        openMenu('Search subtitles in', langs.map(function (code) {
            return { label: OpenSubtitles.languageName(code), selected: code === Store.subtitleLanguage(), run: function () { searchSubtitles(code); } };
        }), Math.max(0, langs.indexOf(Store.subtitleLanguage())));
    }

    /* Which services a search asks: YIFY Subtitles for films (no key), OpenSubtitles when it has a key. */
    function services() {
        var imdb = /^tt\d+/.test(s.title.id || '') ? s.title.id : null;
        return { yify: !!imdb && !s.episode, os: !!Store.key('opensubtitles'), imdb: imdb };
    }
    function searchNote() {
        var sv = services(), names = [];
        if (sv.yify) names.push('YIFY Subtitles');
        if (sv.os) names.push('OpenSubtitles');
        if (names.length) return names.join(' and ');
        return s.episode ? 'Episodes need an OpenSubtitles key (Settings)' : 'This title has no IMDb ID to search by';
    }

    function searchSubtitles(lang) {
        var sv = services();
        if (!sv.yify && !sv.os) {
            openMenu('Subtitles', [{ label: searchNote(), action: true, run: closeMenu }], 0);
            return;
        }
        openMenu('Searching ' + searchNote() + '…', [], 0);
        var session = s, fileName = (s.file.path || '').split('/').pop().replace(/\.[^.]+$/, ''), errors = [];
        function soft(p, name) { return p.catch(function (e) { errors.push(name + ': ' + e.message); return []; }); }
        var yify = sv.yify ? soft(YifySubs.search(sv.imdb, lang, fileName), 'YIFY Subtitles') : Promise.resolve([]);
        var os = !sv.os ? Promise.resolve([]) : soft((s.hash ? Promise.resolve(s.hash) : Engine.hash(s.torrent.id, s.fileIndex).then(function (r) { return r.hash; }, function () { return null; })).then(function (h) {
            if (s !== session) return [];
            s.hash = h;
            var ep = s.episode;
            return OpenSubtitles.search({
                imdbID: sv.imdb, season: ep ? ep.season : null, episode: ep ? ep.episode : null,
                fileName: fileName, hash: h, language: lang
            }).then(function (list) { list.forEach(function (x) { x.source = 'os'; }); return list; });
        }), 'OpenSubtitles');
        Promise.all([os, yify]).then(function (r) {
            if (s !== session) return;
            var osList = r[0], yifyList = r[1];
            // Timed to this very file first (OpenSubtitles' hash match), then YIFY's, then the rest of OpenSubtitles.
            var subs = osList.filter(function (x) { return x.matchesFile; }).concat(yifyList, osList.filter(function (x) { return !x.matchesFile; }));
            if (!subs.length) {
                var none = [{ label: 'Search in another language…', action: true, run: languageMenu }];
                errors.forEach(function (e) { none.unshift({ label: e, action: true, run: closeMenu }); });
                openMenu('No ' + OpenSubtitles.languageName(lang) + ' subtitles found', none, 0);
                return;
            }
            openMenu(OpenSubtitles.languageName(lang) + ' subtitles · ' + subs.length + ' found', subs.slice(0, 60).map(function (sub) {
                var notes = [];
                if (sub.source === 'yify') {
                    notes.push('YIFY');
                    if (sub.rating) notes.push('rating ' + sub.rating);
                    if (sub.uploader) notes.push('by ' + sub.uploader);
                } else {
                    notes.push('OpenSubtitles');
                    if (sub.matchesFile) notes.push('✓ made for this file');
                    if (sub.machine) notes.push('machine-translated');
                    if (sub.hearingImpaired) notes.push('HI');
                    notes.push(sub.downloads + ' downloads');
                }
                return { label: sub.release || 'Subtitle', note: notes.join(' · '), selected: Store.subtitleText(sub.fileID) !== null, run: function () { pickDownload(sub); } };
            }), 0);
        });
    }

    function pickDownload(sub) {
        var session = s, service = sub.source === 'yify' ? YifySubs : OpenSubtitles;
        openMenu('Downloading…', [], 0);
        service.download(sub).then(function (r) {
            if (s !== session) return;
            var label = service.label(sub);
            var p = Store.picked(s.resumeKey);
            if (!p.downloads.some(function (d) { return d.fileID === sub.fileID; })) p.downloads.push({ fileID: sub.fileID, label: label, language: sub.language });
            p.showing = sub.fileID;
            Store.setPicked(s.resumeKey, p);
            Store.setSubtitleLanguage(sub.language);
            setSubtitle({ kind: 'file', id: 'os:' + sub.fileID, label: label, text: r.text });
            closeMenu();
            if (r.remaining !== null && r.remaining !== undefined) toast(r.remaining + ' OpenSubtitles downloads left today');
        }, function (e) {
            if (s === session) openMenu('Subtitles', [{ label: e.message, action: true, run: closeMenu }], 0);
        });
    }

    function audioMenu() {
        if (s.audios.length < 2) { toast('This file has one audio track'); return; }
        openMenu('Audio', s.audios.map(function (t, i) {
            return { label: t.label, selected: i === s.audioIndex, run: function () {
                s.audioIndex = i;
                backend.selectTrack('AUDIO', t.index);
                closeMenu();
            } };
        }), s.audioIndex);
    }

    // ---- On-screen display ----------------------------------------------------------------------

    function buttons() {
        var list = [
            { id: 'play', label: backend.paused() ? '▶ Play' : '❚❚ Pause', run: togglePause },
            { id: 'subs', label: 'Subtitles: ' + subtitleLabel(), run: subtitleMenu },
            { id: 'audio', label: 'Audio' + (s.audios && s.audios.length > 1 ? ': ' + s.audios[s.audioIndex].label : ''), run: audioMenu }
        ];
        if (s.next) list.push({ id: 'next', label: '⏭ Next: ' + s.next.episode.tag, run: playNext });
        return list;
    }

    var osdTimer = null;
    function showOSD() {
        if (!s) return;
        osd.hidden = false;
        render();
        clearTimeout(osdTimer);
        // Stays up while paused, loading, or in a menu; otherwise fades after a few seconds without keys.
        osdTimer = setTimeout(function () {
            if (s && !s.menu && !s.loading && !s.error && !backend.paused()) { osd.hidden = true; s.focus = 'bar'; }
        }, 6000);
    }

    function render() {
        if (!s || !osd || s.error) return;
        var duration = s.duration || backend.duration() || 0;
        var time = s.seekTarget !== null ? s.seekTarget : (s.time || 0);
        var st = s.status || {};
        var line = s.loading ? s.loading : (s.buffering ? 'Buffering' + (st.peers !== undefined ? ' · ' : '') : '') + peersText(st);
        var ahead = '';
        if (duration && st.aheadSeconds !== undefined) {
            var from = Math.min(100, time / duration * 100);
            var to = Math.min(100, (time + st.aheadSeconds) / duration * 100);
            ahead = '<div class="osd-ahead" style="left:' + from + '%;width:' + Math.max(0, to - from) + '%"></div>';
        }
        var btns = s.loading ? '' : '<div class="osd-buttons">' + buttons().map(function (b, i) {
            return '<span class="osd-btn' + (s.focus === 'buttons' && s.btn === i ? ' focused' : '') + '">' + esc(b.label) + '</span>';
        }).join('') + '</div>';
        var menu = '';
        if (s.menu) {
            var m = s.menu, first = Math.max(0, Math.min(m.index - 4, m.items.length - 9));
            menu = '<div class="osd-menu"><h3>' + esc(m.title) + '</h3>' + (m.items.length ? m.items.slice(first, first + 9).map(function (it, j) {
                var i = first + j;
                return '<div class="osd-item' + (i === m.index ? ' focused' : '') + (it.selected ? ' selected' : '') + (it.action ? ' action' : '') + '">' +
                    '<div>' + esc(it.label) + '</div>' + (it.note ? '<div class="osd-note">' + esc(it.note) + '</div>' : '') + '</div>';
            }).join('') : '<div class="osd-note">Please wait…</div>') +
                (m.items.length > 9 ? '<div class="osd-note">' + (m.index + 1) + ' of ' + m.items.length + '</div>' : '') + '</div>';
        }
        osd.innerHTML =
            '<div class="osd-top"><div class="osd-title">' + esc(s.label) + '</div><div class="osd-sub">' + esc(s.subLine || '') + '</div></div>' + menu +
            '<div class="osd-bottom">' +
            '<div class="osd-bar' + (s.focus === 'bar' && !s.menu ? ' focused' : '') + '">' + ahead +
            '<div class="osd-played" style="width:' + (duration ? Math.min(100, time / duration * 100) : 0) + '%"></div></div>' +
            '<div class="osd-row"><span>' + (backend.paused() && !s.loading ? '❚❚ ' : '') + clock(time) + '</span>' +
            '<span class="osd-status">' + esc(line) + '</span><span>' + (duration ? clock(duration) : '') + '</span></div>' +
            btns + '</div>';
    }

    function peersText(st) {
        if (st.peers === undefined) return '';
        var parts = [st.peers + (st.peers === 1 ? ' peer' : ' peers')];
        if (st.webSeeds) parts.push(st.webSeeds + ' web seed' + (st.webSeeds === 1 ? '' : 's'));
        if (st.downSpeed) parts.push(Catalog.size(st.downSpeed) + '/s');
        if (st.aheadSeconds) parts.push(clock(st.aheadSeconds) + ' ahead');
        return parts.join(' · ');
    }

    // ---- Seeking: presses add up, and the seek happens once they stop ----------------------------

    var seekTimer = null;
    function nudge(delta) {
        if (!s || s.loading) return;
        var duration = s.duration || backend.duration();
        var from = s.seekTarget !== null ? s.seekTarget : backend.time();
        s.seekTarget = Math.max(0, Math.min(duration ? duration - 5 : Infinity, from + delta));
        showOSD();
        clearTimeout(seekTimer);
        seekTimer = setTimeout(function () {
            var target = s.seekTarget;
            s.seekTarget = null;
            s.time = target;
            report();     // move the engine's window before the player asks for the bytes
            backend.seek(target);
        }, 700);
    }

    // ---- Keys ----------------------------------------------------------------------------------

    function keys(code) {
        var K = Nav.KEYS;
        if (!s) return false;
        if (s.error) { if (code === K.ENTER || code === K.BACK || code === K.ESC) stop(); return true; }
        if (code === K.STOP) { stop(); return true; }

        if (s.menu) {
            var m = s.menu;
            if (code === K.UP) m.index = Math.max(0, m.index - 1);
            else if (code === K.DOWN) m.index = Math.min(m.items.length - 1, m.index + 1);
            else if (code === K.ENTER) { var it = m.items[m.index]; if (it) it.run(); return true; }
            else if (code === K.BACK || code === K.ESC || code === K.LEFT) closeMenu();
            showOSD();
            return true;
        }

        // Shortcuts that work anywhere.
        switch (code) {
            case K.PLAY_PAUSE: togglePause(); return true;
            case K.PLAY: if (backend.paused()) togglePause(); return true;
            case K.PAUSE: if (!backend.paused()) togglePause(); return true;
            case K.RW: nudge(-60); return true;
            case K.FF: nudge(60); return true;
            case K.GREEN: subtitleMenu(); return true;
            case K.YELLOW: audioMenu(); return true;
            case K.BLUE: if (s.next) playNext(); return true;
            case K.BACK: case K.ESC: stop(); return true;
        }

        var hidden = osd.hidden;
        if (s.focus === 'buttons' && !hidden) {
            var list = buttons();
            if (code === K.LEFT) s.btn = Math.max(0, s.btn - 1);
            else if (code === K.RIGHT) s.btn = Math.min(list.length - 1, s.btn + 1);
            else if (code === K.UP) s.focus = 'bar';
            else if (code === K.ENTER) { list[Math.min(s.btn, list.length - 1)].run(); return true; }
            else if (code !== K.DOWN) return false;
            showOSD();
            return true;
        }
        // On the seek bar (or with the controls hidden).
        if (code === K.LEFT) nudge(-10);
        else if (code === K.RIGHT) nudge(10);
        else if (code === K.ENTER) { if (hidden) showOSD(); else togglePause(); }
        else if (code === K.DOWN) { if (!hidden) { s.focus = 'buttons'; s.btn = s.btn || 0; } showOSD(); }
        else if (code === K.UP) showOSD();
        else return false;
        return true;
    }

    function togglePause() {
        if (!s || s.loading) return;
        if (backend.paused()) backend.play(); else backend.pause();
        showOSD();
    }

    // ---- Lifecycle --------------------------------------------------------------------------------

    function report() {
        if (!s || !s.torrent) return;
        var duration = s.duration || backend.duration();
        var t = s.time || backend.time();
        if (duration) Engine.position(s.torrent.id, s.fileIndex, t, duration);
        if (duration && t > 0) Store.setResume(s.resumeKey, t, duration, s.title);
    }

    function poll() {
        if (!s || !s.torrent) return;
        Engine.status(s.torrent.id).then(function (st) { if (s) { s.status = st; if (!osd.hidden) render(); } }, function () {});
    }

    function finished() {
        if (!s) return;
        Store.setResume(s.resumeKey, 0, 0);
        if (s.next) playNext(); else stop();
    }

    function playNext() {
        var next = s.next, onExit = s.onExit;
        teardown(false);
        start(next, onExit);
    }

    function fail(msg) {
        if (!s) return;
        s.error = msg;
        s.loading = null;
        osd.hidden = false;
        osd.innerHTML = '<div class="osd-error"><h2>Can\'t play this</h2><p>' + esc(msg) + '</p><p class="dim">Press OK or Back to return.</p></div>';
    }

    function teardown(closeTorrent) {
        clearTimers();
        clearTimeout(seekTimer);
        clearTimeout(osdTimer);
        clearTimeout(lineTimer);
        if (s) {
            if (!s.error && !s.loading) report();
            if (closeTorrent && s.torrent) Engine.close(s.torrent.id);
        }
        backend.stop();
        subtitleEl.innerHTML = '';
        osd.hidden = true;
        document.body.classList.remove('playing');
        Nav.setHandler(null);
        s = null;
    }

    function stop() {
        var onExit = s && s.onExit;
        teardown(true);
        if (onExit) onExit();
    }

    /* req: {title, episode?, option, startAt?, next?} where next is the same shape, for autoplay. */
    function start(req, onExit) {
        var ep = req.episode;
        s = {
            title: req.title, episode: ep || null, label: req.title.title, subLine: ep ? ep.tag + ' · ' + ep.title : (req.option.quality || ''),
            resumeKey: ep ? ep.key : req.title.key, next: req.next || null, onExit: onExit, req: req, retries: 0,
            loading: 'Finding the torrent…', buffering: false, time: 0, seekTarget: null, status: null,
            embedded: [], audios: [], audioIndex: 0, sub: null, cues: null, focus: 'bar', btn: 0, menu: null
        };
        document.body.classList.add('playing');
        Nav.setHandler(keys);
        showOSD();
        every(1000, function () {
            poll();
            // Until the torrent is open, show who's connecting (the buffering step writes its own line).
            if (s && s.status && /^(Finding|Connecting)/.test(s.loading || '')) { s.loading = 'Connecting · ' + peersText(s.status); render(); }
        });
        every(200, tickSubtitle);
        var session = s;
        Engine.ensure().then(function () {
            return Engine.open(req.option.link, req.title.runtime);
        }).then(function (torrent) {
            if (s !== session) return;
            s.torrent = torrent;
            var file = Catalog.fileToPlay(torrent.files, ep ? ep.season : null, ep ? ep.episode : null);
            if (!file) throw new Error('This torrent has no video file the TV can play.');
            s.file = file;
            s.fileIndex = file.index;
            var startAt = req.startAt || 0;
            return prebuffer(session, startAt).then(function () {
                if (s !== session) return;
                openStream(session, startAt, true);
                every(2000, report);
            });
        }).catch(function (err) { if (s === session) fail(err.message || String(err)); });
    }

    /* Waits until the engine holds what the TV's player reads first: the file's start and end (the container's
       header and index) and a few MB from where playback starts. AVPlay gives up on slow first reads
       (PLAYER_ERROR_CONNECTION_FAILED), where a browser's player would simply wait. Up to 2 minutes. */
    function prebuffer(session, at) {
        var name = s.file.path.split('/').pop(), started = Date.now(), runtime = (s.title.runtime || 0) * 60;
        var want = Math.min(4 * 1024 * 1024, s.file.size);
        // Put the engine's window where playback will start.
        Engine.position(s.torrent.id, s.fileIndex, at, s.duration || runtime);
        return new Promise(function (resolve, reject) {
            (function check() {
                if (s !== session) return resolve();
                Engine.status(s.torrent.id).then(function (st) {
                    if (s !== session) return resolve();
                    s.status = st;
                    var ready = st.headReady && st.tailReady && st.aheadBytes >= want;
                    if (ready) return resolve();
                    var waited = Date.now() - started;
                    if (waited > 120000) {
                        if (!st.peers && !st.webSeeds) return reject(new Error('Nobody is sharing this torrent right now. Try another quality, or try again later.'));
                        return resolve();   // slow, but data is coming: let the player try
                    }
                    // Start, index and the first MB each count a third.
                    var pct = Math.round(((st.headReady ? 1 : 0) + (st.tailReady ? 1 : 0) + Math.min(1, st.aheadBytes / want)) / 3 * 100);
                    s.loading = 'Buffering ' + pct + '% · ' + (peersText(st) || 'finding peers…') + ' · ' + name;
                    render();
                    setTimeout(check, 1000);
                }, function () {
                    // The engine stopped answering: start it again (the torrent is reopened by the caller's retry).
                    if (Date.now() - started > 120000) return reject(new Error('The torrent engine stopped. Restart the TV and try again.'));
                    Engine.ensure().then(function () { setTimeout(check, 1000); }, reject);
                });
            })();
        });
    }

    /* Hands the engine's stream to the player and starts at `at` seconds. */
    function openStream(session, at, first) {
        s.loading = 'Starting…';
        render();
        backend.open(Engine.fileURL(s.torrent.id, s.fileIndex), function () {
            if (s !== session) return;
            s.duration = backend.duration();
            if (first) chooseInitialSubtitle();
            else if (s.sub) setSubtitle(s.sub);
            function go() { s.loading = null; s.playingSince = Date.now(); backend.play(); showOSD(); }
            if (at > 0) { s.time = at; report(); backend.seek(at, go); } else go();
        }, function (code) { streamError(code); });
    }

    /* The player lost the stream. Connection problems are retried (3 times, then a minute of good playback
       resets the count): the engine is restarted if it stopped, the torrent reopened, and playback continues
       where it was. Anything else is a real playback error. */
    function streamError(code) {
        if (!s || s.error) return;
        var session = s, at = s.time || 0;
        if (s.playingSince && Date.now() - s.playingSince > 60000) s.retries = 0;
        var network = /CONNECTION|NETWORK|TIMEOUT|TIMED_OUT|INVALID_STATE|NO_RESPONSE|HTTP/i.test(code);
        if (!network || (s.retries || 0) >= 3) {
            fail('The TV could not play this file (' + code + ').' + (network ? ' The torrent may be too slow right now; try another quality.' : ''));
            return;
        }
        s.retries = (s.retries || 0) + 1;
        s.playingSince = 0;
        backend.stop();
        s.loading = 'Reconnecting (' + s.retries + ' of 3)…';
        showOSD();
        Engine.ensure().then(function () {
            return Engine.open(s.req.option.link, s.title.runtime);
        }).then(function (torrent) {
            if (s !== session) return;
            s.torrent = torrent;
            return prebuffer(session, at).then(function () { if (s === session) openStream(session, at, false); });
        }).catch(function (err) { if (s === session) fail(err.message || String(err)); });
    }

    return {
        init: function () {
            video = $('html-player'); osd = $('osd'); subtitleEl = $('subtitle');
            if (av) video.style.display = 'none'; else $('avplayer').style.display = 'none';
            document.addEventListener('visibilitychange', function () {
                // Leaving the app (Home button) pauses and saves the place.
                if (document.hidden && s && !s.loading && !backend.paused()) { backend.pause(); report(); }
            });
        },
        play: start,
        active: function () { return !!s; },
        stop: function () { if (s) stop(); }
    };
})();
