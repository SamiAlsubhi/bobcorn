/* Catalog API sources, as the Mac app reads them (Sources/Bobcorn/CatalogAPI.swift):
   /movies/<page>, /shows/<page>, /movie/<imdb_id>, /show/<imdb_id>, with sort, order, genre and keywords. */
var Catalog = (function () {
    'use strict';

    var SORTS = [
        { id: 'trending', title: 'Trending' }, { id: 'views', title: 'Popularity' },
        { id: 'rating', title: 'Rating' }, { id: 'year', title: 'Year' }, { id: 'name', title: 'Title' }
    ];
    var GENRES = [['All', null], ['Action', 'action'], ['Adventure', 'adventure'], ['Animation', 'animation'],
        ['Comedy', 'comedy'], ['Crime', 'crime'], ['Documentary', 'documentary'], ['Drama', 'drama'],
        ['Family', 'family'], ['Fantasy', 'fantasy'], ['History', 'history'], ['Horror', 'horror'],
        ['Music', 'music'], ['Mystery', 'mystery'], ['Romance', 'romance'], ['Sci-Fi', 'sci-fi'],
        ['Thriller', 'thriller'], ['War', 'war'], ['Western', 'western']
    ].map(function (g) { return { title: g[0], slug: g[1] }; });

    function text(v) {
        if (v === null || v === undefined) return null;
        if (typeof v === 'string') return v.trim() || null;
        if (typeof v === 'number') return String(v);
        return null;
    }
    function num(v) {
        var n = typeof v === 'number' ? v : parseFloat(v);
        return isFinite(n) ? n : null;
    }
    function clean(html) {
        if (!html) return null;
        var d = document.createElement('div');
        d.innerHTML = html.replace(/<br\s*\/?>/gi, '\n');
        return (d.textContent || '').trim() || null;
    }
    function image(v, base) {
        var s = text(v);
        if (!s || s.indexOf('posterholder') >= 0) return null;
        try { return new URL(s, base + '/').href; } catch (e) { return null; }
    }
    function pad(n) { return (n < 10 ? '0' : '') + n; }

    /* Lowercase, accents and punctuation removed, single spaces: "Amélie!" → "amelie". */
    function normalize(s) {
        s = String(s || '').toLowerCase();
        if (s.normalize) s = s.normalize('NFD').replace(/[̀-ͯ]/g, '');
        return s.replace(/[^a-z0-9؀-ۿ]+/g, ' ').trim();
    }

    /* A magnet's dn= name, for the option list. */
    function magnetName(link) {
        var m = /[?&]dn=([^&]+)/.exec(link);
        try { return m ? decodeURIComponent(m[1].replace(/\+/g, ' ')) : null; } catch (e) { return null; }
    }

    function qualityRank(q) { return q === '4K' || q === '2160p' ? 2160 : (parseInt(q, 10) || 0); }

    /* Every torrent in a `torrents` object, one option per link. Movies group by language then quality,
       episodes by quality alone; "0" repeats an episode's default quality. */
    function options(torrents, fallbackName) {
        var flat = [];
        Object.keys(torrents || {}).forEach(function (key) {
            var node = torrents[key];
            if (!node || typeof node !== 'object') return;
            if (node.url || node.magnet) flat.push({ quality: key, language: null, t: node });
            else Object.keys(node).forEach(function (q) {
                var t = node[q];
                if (t && typeof t === 'object' && (t.url || t.magnet)) flat.push({ quality: q, language: key, t: t });
            });
        });
        var languages = {};
        flat.forEach(function (f) { if (f.language) languages[f.language] = true; });
        var multiLanguage = Object.keys(languages).length > 1;
        flat.sort(function (a, b) {
            return (a.quality === '0') - (b.quality === '0') || (a.quality < b.quality ? -1 : a.quality > b.quality ? 1 : 0);
        });
        var seen = {}, out = [];
        flat.forEach(function (f) {
            var link = String(f.t.url || f.t.magnet || '').trim();
            if (!link || seen[link]) return;
            seen[link] = true;
            var label = f.quality === '0' ? 'SD' : f.quality;
            var name = magnetName(link) || (/^magnet:/i.test(link) ? null : decodeURIComponent(link.split('/').pop().split('?')[0])) ||
                ((fallbackName || '') + ' ' + label);
            if (multiLanguage && f.language) name += ' · ' + f.language.toUpperCase();
            var size = num(f.t.size) || num(f.t.filesize);
            out.push({
                link: link, name: name, quality: label, language: f.language,
                size: size && size > 0 ? size : null,
                seeds: num(f.t.seed !== undefined ? f.t.seed : f.t.seeds),
                peers: num(f.t.peer !== undefined ? f.t.peer : f.t.peers)
            });
        });
        return out;
    }

    function title(raw, type, base) {
        var id = text(raw.imdb_id) || text(raw._id), name = text(raw.title);
        if (!id || !name) return null;
        var images = raw.images || {}, rating = raw.rating || {};
        var pct = num(rating.percentage), runtime = num(raw.runtime);
        var genres = Array.isArray(raw.genres) ? raw.genres : [];
        return {
            key: 'api:' + id, id: id, type: type, title: name, year: num(raw.year),
            synopsis: clean(text(raw.synopsis)), runtime: runtime > 0 ? runtime : null,
            rating: pct > 0 ? pct : null, certification: text(raw.certification),
            poster: image(images.poster, base), fanart: image(images.fanart, base) || image(images.banner, base),
            genres: genres.filter(function (g) { return typeof g === 'string'; }).map(function (g) {
                return g === g.toLowerCase() ? g.replace(/-/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); }) : g;
            }),
            seasons: num(raw.num_seasons),
            options: options(raw.torrents, name),
            base: base
        };
    }

    function episode(raw, show) {
        var s = num(raw.season), e = num(raw.episode);
        if (s === null || e === null) return null;
        var tag = 'S' + pad(s) + 'E' + pad(e);
        var aired = num(raw.first_aired);
        return {
            season: s, episode: e, tag: tag, key: show.key + ':s' + s + 'e' + e,
            title: clean(text(raw.title)) || 'Episode ' + e,
            overview: clean(text(raw.overview)),
            aired: aired ? new Date(aired * 1000) : null,
            options: options(raw.torrents, show.title + ' ' + tag)
        };
    }

    /* A page is an array of titles; a single title is an object, or an array holding one. */
    function decode(data) {
        if (typeof data === 'string') { try { data = JSON.parse(data); } catch (e) { data = null; } }
        if (Array.isArray(data)) return data.filter(function (r) { return r && typeof r === 'object'; });
        if (data && typeof data === 'object' && (data.imdb_id || data._id)) return [data];
        throw new Error("That address didn't answer with a list of movies or shows.");
    }

    return {
        SORTS: SORTS,
        GENRES: GENRES,

        /* One page of a listing; pages count from 1, an empty page is the end. */
        page: function (source, q, page) {
            var params = ['sort=' + q.sort, 'order=' + (q.sort === 'name' ? 1 : -1)];
            if (q.genre) params.push('genre=' + encodeURIComponent(q.genre));
            if (q.search) params.push('keywords=' + encodeURIComponent(q.search));
            var url = source.url + '/' + q.type + '/' + page + '?' + params.join('&');
            return Engine.fetch(url).then(function (data) {
                var seen = {};
                return decode(data).map(function (r) { return title(r, q.type, source.url); })
                    .filter(function (t) { return t && !seen[t.id] && (seen[t.id] = true); });
            }, function (err) {
                if (page > 1 && /404/.test(err.message)) return [];
                throw err;
            });
        },

        /* Movies and TV shows matching a query, searched together: {movies, shows, local}.
           Some sources (static ones, like the example) ignore `keywords` and send their whole listing back.
           That's noticed by comparing with the listing without keywords; then Bobcorn reads the listing's
           first pages and matches titles itself (`local` is true). */
        search: function (source, query) {
            var self = this;
            var words = normalize(query).split(' ').filter(Boolean);
            function matches(t) {
                var hay = normalize(t.title) + ' ' + (t.year || '');
                return words.every(function (w) { return hay.indexOf(w) >= 0; });
            }
            function one(type) {
                var q = { type: type, sort: 'trending', genre: null, search: query };
                return Promise.all([self.page(source, q, 1), self.page(source, { type: type, sort: 'trending', genre: null, search: '' }, 1)])
                    .then(function (r) {
                        var found = r[0], all = r[1];
                        var ignored = found.length > 0 && found.length === all.length &&
                            found.every(function (t, i) { return t.id === all[i].id; }) && !found.every(matches);
                        if (!ignored) return { titles: found, local: false };
                        // The source ignored the search: page through its listing (up to 10 pages) and match here.
                        var out = all.filter(matches), page = 1;
                        function more() {
                            if (page >= 10) return Promise.resolve();
                            page++;
                            return self.page(source, { type: type, sort: 'trending', genre: null, search: '' }, page).then(function (list) {
                                if (!list.length) return;
                                out = out.concat(list.filter(matches));
                                return more();
                            }, function () { /* stop at the first page that fails */ });
                        }
                        return more().then(function () { return { titles: out, local: true }; });
                    });
            }
            return Promise.all([one('movies'), one('shows').catch(function () { return { titles: [], local: false }; })]).then(function (r) {
                return { movies: r[0].titles, shows: r[1].titles, local: r[0].local || r[1].local };
            });
        },

        /* Full metadata, and a show's episodes with their torrents (one per episode, the best-stocked). */
        details: function (listed) {
            var url = listed.base + '/' + (listed.type === 'movies' ? 'movie' : 'show') + '/' + listed.id;
            return Engine.fetch(url).then(function (data) {
                var raw = decode(data)[0];
                var full = raw && title(raw, listed.type, listed.base);
                if (!full) throw new Error('The source has no details for this title.');
                if (!full.options.length && listed.options && listed.options.length) full.options = listed.options;
                var byID = {};
                (raw.episodes || []).forEach(function (r) {
                    var e = r && episode(r, full);
                    if (e && (!byID[e.key] || byID[e.key].options.length < e.options.length)) byID[e.key] = e;
                });
                full.episodes = Object.keys(byID).map(function (k) { return byID[k]; })
                    .sort(function (a, b) { return a.season - b.season || a.episode - b.episode; });
                return full;
            });
        },

        /* The best-seeded option, in this quality when one has seeds. */
        best: function (opts, quality) {
            var same = opts.filter(function (o) { return o.quality === quality && (o.seeds === null || o.seeds > 0); });
            var pool = same.length ? same : opts;
            return pool.slice().sort(function (a, b) {
                var sa = a.seeds === null ? -1 : a.seeds, sb = b.seeds === null ? -1 : b.seeds;
                return sb - sa || qualityRank(b.quality) - qualityRank(a.quality);
            })[0] || null;
        },

        /* The episode's own file when a season pack names it, otherwise the main video (not a sample).
           Mirrors PlaybackController.fileToPlay; the TV plays MKV, MP4, AVI, MOV, TS and WebM natively. */
        fileToPlay: function (files, season, episodeNo) {
            var videos = files.filter(function (f) { return /\.(mkv|mp4|m4v|avi|mov|ts|m2ts|webm|mpg|mpeg|wmv|flv)$/i.test(f.path); });
            function best(pool) {
                var largest = Math.max.apply(null, pool.map(function (f) { return f.size; }).concat([0]));
                var native = pool.filter(function (f) { return /\.(mkv|mp4|m4v|mov|ts|webm)$/i.test(f.path) && f.size * 4 >= largest; });
                return (native.length ? native : pool).sort(function (a, b) { return b.size - a.size; })[0] || null;
            }
            if (season !== undefined && season !== null && videos.length > 1) {
                var re1 = new RegExp('(^|[^\\d])s0*' + season + '[ ._-]?e0*' + episodeNo + '(?!\\d)', 'i');
                var re2 = new RegExp('(^|[^\\d])0*' + season + 'x0*' + episodeNo + '(?!\\d)', 'i');
                var named = videos.filter(function (f) { var n = f.path.split('/').pop(); return re1.test(n) || re2.test(n); });
                if (named.length) return best(named);
            }
            var features = videos.filter(function (f) { return !/sample/i.test(f.path); });
            return best(features.length ? features : videos);
        },

        /* What My List and Continue Watching keep: enough to draw a poster and reopen the page. */
        saved: function (t) {
            return { key: t.key, id: t.id, type: t.type, title: t.title, year: t.year, poster: t.poster, base: t.base, options: [] };
        },

        qualities: function (t) {
            var q = {};
            (t.options || []).forEach(function (o) { q[o.quality] = true; });
            return Object.keys(q).sort(function (a, b) { return qualityRank(b) - qualityRank(a); });
        },

        size: function (bytes) {
            if (!bytes) return '';
            var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
            while (bytes >= 1000 && i < u.length - 1) { bytes /= 1000; i++; }
            return (i >= 3 ? bytes.toFixed(1) : Math.round(bytes)) + ' ' + u[i];
        }
    };
})();
