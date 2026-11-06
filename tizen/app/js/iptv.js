/* IPTV sources: Xtream Codes accounts (host, username, password) and M3U playlists.
   Live channels, movies and series are browsed a category at a time (providers' full lists run to 50-100 MB);
   search goes through the engine, which keeps a compact index of the account. Streams play directly with
   AVPlay, not through the torrent engine. */
var IPTV = (function () {
    'use strict';

    var cache = {};   // per source and request: categories and category listings, for this session

    function isIptv(src) { return !!src && (src.kind === 'xtream' || src.kind === 'm3u'); }

    function base(src) {
        var h = String(src.host || '').trim();
        if (!/^https?:\/\//i.test(h)) h = 'http://' + h;
        return h.replace(/\/+$/, '');
    }
    function auth(src) { return 'username=' + encodeURIComponent(src.username) + '&password=' + encodeURIComponent(src.password); }

    function json(data) {
        if (typeof data === 'string') { try { return JSON.parse(data); } catch (e) { return null; } }
        return data;
    }

    function api(src, action, params) {
        var url = base(src) + '/player_api.php?' + auth(src) + (action ? '&action=' + action : '') + (params || '');
        return Engine.fetch(url).then(function (data) {
            data = json(data);
            if (data === null || data === undefined) throw new Error('The IPTV server sent an answer Bobcorn can\'t read.');
            return data;
        }, function (err) {
            throw new Error('Couldn\'t reach the IPTV server: ' + err.message);
        });
    }

    function cached(key, make) {
        if (!cache[key]) cache[key] = make().catch(function (e) { delete cache[key]; throw e; });
        return cache[key];
    }

    var ACTION = {
        live: ['get_live_categories', 'get_live_streams'],
        vod: ['get_vod_categories', 'get_vod_streams'],
        series: ['get_series_categories', 'get_series']
    };

    /* One listed thing: a channel, movie or series, in the shape the screens use. */
    function item(src, kind, x) {
        var id = kind === 'series' ? x.series_id : x.stream_id;
        var r = Number(x.rating);
        return {
            iptv: true, kind: kind, srcId: src.id, id: String(id), num: x.num,
            key: 'iptv:' + src.id + ':' + kind + ':' + id,
            title: x.name || x.title || 'Untitled',
            poster: (kind === 'series' ? x.cover : x.stream_icon) || null,
            rating: r > 0 ? Math.min(100, r * 10) : null,   // providers rate out of 10; the screens use 0-100
            ext: x.container_extension || null,
            year: (/\((\d{4})\)/.exec(x.name || '') || [])[1] || null,
            category: x.category_id !== undefined && x.category_id !== null ? String(x.category_id) : '',
            epgId: x.epg_channel_id || null
        };
    }

    // ---- M3U playlists ------------------------------------------------------------------------------

    /* The playlist parsed into {live, vod, series}, each {categories: [{id, name}], items: {categoryId: [...]}}. */
    function playlist(src) {
        return cached(src.id + ':m3u', function () {
            return Engine.fetch(src.url).then(function (text) {
                if (typeof text !== 'string' || text.indexOf('#EXTM3U') < 0) throw new Error('That address isn\'t an M3U playlist.');
                var out = { live: group(), vod: group(), series: group() };
                var lines = text.split(/\r?\n/), info = null;
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line.indexOf('#EXTINF') === 0) info = line;
                    else if (line && line[0] !== '#' && info) {
                        var attr = function (name) { var m = new RegExp(name + '="([^"]*)"').exec(info); return m ? m[1] : ''; };
                        var title = info.slice(info.lastIndexOf(',') + 1).trim() || attr('tvg-name') || 'Untitled';
                        var kind = /\/movie\//.test(line) ? 'vod' : /\/series\//.test(line) ? 'series' : 'live';
                        var cat = attr('group-title') || 'Other';
                        var g = out[kind];
                        if (!g.items[cat]) { g.items[cat] = []; g.categories.push({ id: cat, name: cat }); }
                        g.items[cat].push({
                            iptv: true, kind: kind === 'series' ? 'vod' : kind, srcId: src.id, id: line,
                            key: 'iptv:' + src.id + ':' + line, title: title, poster: attr('tvg-logo') || null,
                            url: line, category: cat, epgId: attr('tvg-id') || null, rating: null, year: null
                        });
                        info = null;
                    }
                }
                return out;
            });
        });
        function group() { return { categories: [], items: {} }; }
    }

    // ---- Public ------------------------------------------------------------------------------------

    return {
        isIptv: isIptv,

        /* The account's state: {active, status, expires (Date), maxConnections, activeConnections, formats}. */
        account: function (src) {
            if (src.kind !== 'xtream') return Promise.resolve({ active: true, status: 'Playlist' });
            return api(src).then(function (a) {
                var u = (a && a.user_info) || {};
                if (String(u.auth) !== '1') throw new Error('The IPTV server refused this username and password.');
                return {
                    active: u.status === 'Active', status: u.status || '?',
                    expires: u.exp_date ? new Date(Number(u.exp_date) * 1000) : null,
                    maxConnections: Number(u.max_connections) || null, activeConnections: Number(u.active_cons) || 0,
                    formats: u.allowed_output_formats || []
                };
            });
        },

        /* [{id, name}] for 'live', 'vod' or 'series'. */
        categories: function (src, kind) {
            if (src.kind === 'm3u') return playlist(src).then(function (p) { return p[kind].categories; });
            return cached(src.id + ':cats:' + kind, function () {
                return api(src, ACTION[kind][0]).then(function (list) {
                    return (Array.isArray(list) ? list : []).map(function (c) { return { id: String(c.category_id), name: String(c.category_name || '').trim() || 'Untitled' }; });
                });
            });
        },

        /* What a category holds. */
        items: function (src, kind, categoryId) {
            if (src.kind === 'm3u') return playlist(src).then(function (p) { return p[kind].items[categoryId] || []; });
            return cached(src.id + ':items:' + kind + ':' + categoryId, function () {
                return api(src, ACTION[kind][1], '&category_id=' + encodeURIComponent(categoryId)).then(function (list) {
                    return (Array.isArray(list) ? list : []).map(function (x) { return item(src, kind, x); });
                });
            });
        },

        /* A movie's details: {plot, genre, cast, director, duration, year, backdrop, ext}. */
        movieInfo: function (src, it) {
            if (src.kind !== 'xtream') return Promise.resolve({});
            return api(src, 'get_vod_info', '&vod_id=' + encodeURIComponent(it.id)).then(function (r) {
                var i = (r && r.info) || {}, d = (r && r.movie_data) || {};
                return {
                    plot: i.plot || i.description || '', genre: i.genre || '', cast: i.cast || i.actors || '', director: i.director || '',
                    duration: Number(i.duration_secs) || 0, year: (i.releasedate || i.release_date || '').slice(0, 4) || it.year,
                    backdrop: (i.backdrop_path && i.backdrop_path[0]) || i.cover_big || it.poster, poster: i.movie_image || it.poster,
                    ext: d.container_extension || it.ext || 'mp4', tmdb: i.tmdb_id || null
                };
            });
        },

        /* A series' details and episodes: {plot, genre, cast, backdrop, episodes: [{id, season, episode, tag, title, ...}]}. */
        seriesInfo: function (src, it) {
            return api(src, 'get_series_info', '&series_id=' + encodeURIComponent(it.id)).then(function (r) {
                var i = (r && r.info) || {}, eps = [];
                Object.keys((r && r.episodes) || {}).forEach(function (season) {
                    (r.episodes[season] || []).forEach(function (e) {
                        var s = Number(e.season || season), n = Number(e.episode_num) || 0, ei = e.info || {};
                        eps.push({
                            id: String(e.id), season: s, episode: n, ext: e.container_extension || 'mp4',
                            tag: 'S' + (s < 10 ? '0' : '') + s + 'E' + (n < 10 ? '0' : '') + n,
                            key: it.key + ':' + e.id,
                            title: String(e.title || '').replace(/^.*?S\d+E\d+\s*-\s*/i, '') || 'Episode ' + n,
                            overview: ei.plot || '', duration: Number(ei.duration_secs) || 0, image: ei.movie_image || null,
                            tmdb: ei.tmdb_id ? String(ei.tmdb_id) : null
                        });
                    });
                });
                eps.sort(function (a, b) { return a.season - b.season || a.episode - b.episode; });
                return {
                    plot: i.plot || '', genre: i.genre || '', cast: i.cast || '', year: (i.releaseDate || i.releasedate || '').slice(0, 4),
                    backdrop: (i.backdrop_path && i.backdrop_path[0]) || it.poster, episodes: eps
                };
            });
        },

        /* Now and next on a channel: [{title, start (Date), end (Date)}]. */
        guide: function (src, channel) {
            if (src.kind !== 'xtream') return Promise.resolve([]);
            return api(src, 'get_short_epg', '&stream_id=' + encodeURIComponent(channel.id) + '&limit=2').then(function (r) {
                return ((r && r.epg_listings) || []).map(function (e) {
                    var title = e.title || '';
                    try { title = decodeURIComponent(escape(atob(title))); } catch (x) { /* already plain text */ }
                    return { title: title, start: new Date(Number(e.start_timestamp) * 1000), end: new Date(Number(e.stop_timestamp) * 1000) };
                }).filter(function (e) { return e.title; });
            }, function () { return []; });
        },

        /* Where a channel, movie or episode streams. Live prefers HLS, with MPEG-TS as the fallback. */
        streamURL: function (src, it, episode, format) {
            if (it.url && !episode) return it.url;
            var b = base(src) + '/', a = encodeURIComponent(src.username) + '/' + encodeURIComponent(src.password) + '/';
            if (episode) return b + 'series/' + a + episode.id + '.' + (episode.ext || 'mp4');
            if (it.kind === 'live') return b + 'live/' + a + it.id + '.' + (format || 'm3u8');
            return b + 'movie/' + a + it.id + '.' + (it.ext || 'mp4');
        },

        /* Search: {status: 'building'|'ready'|'error', progress, results: {live, vod, series}, counts}. For an
           account the engine searches its index (built the first time, which takes a few minutes); for a playlist,
           the parsed playlist is searched here. */
        search: function (src, query) {
            var words = Catalog.normalize(query).split(' ').filter(Boolean);
            if (src.kind === 'm3u') {
                return playlist(src).then(function (p) {
                    var out = { status: 'ready', results: {}, counts: {} };
                    ['live', 'vod', 'series'].forEach(function (k) {
                        var found = [];
                        Object.keys(p[k].items).forEach(function (c) {
                            p[k].items[c].forEach(function (x) {
                                var n = Catalog.normalize(x.title);
                                if (words.every(function (w) { return n.indexOf(w) >= 0; })) found.push(x);
                            });
                        });
                        out.counts[k] = found.length;
                        out.results[k] = found.slice(0, 60);
                    });
                    return out;
                });
            }
            return Engine.iptvSearch(src, query).then(function (r) {
                if (r.results) Object.keys(r.results).forEach(function (k) {
                    r.results[k] = r.results[k].map(function (x) {
                        return item(src, k, { name: x.n, stream_id: x.i, series_id: x.i, category_id: x.c, stream_icon: x.l, cover: x.l, container_extension: x.e, rating: x.r ? x.r : 0 });
                    });
                });
                return r;
            });
        },

        /* Forget loaded categories, after an account changes. */
        forget: function (src) { Object.keys(cache).forEach(function (k) { if (k.indexOf(src.id + ':') === 0) delete cache[k]; }); }
    };
})();
