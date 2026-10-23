/* The screens: Home (Movies, TV Shows, My List), Details, Search and Settings, on a stack Back pops. */
var Views = (function () {
    'use strict';

    var screenEl, toastEl;
    var stack = [];          // [{name, data, render, focusKey}]
    var home = { tab: 'movies', genre: null, sort: 'trending', titles: [], page: 0, done: false, loading: false, error: null, focusKey: null };

    function h(tag, attrs, children) {
        var el = document.createElement(tag);
        Object.keys(attrs || {}).forEach(function (k) {
            if (k === 'class') el.className = attrs[k];
            else if (k === 'text') el.textContent = attrs[k];
            else if (k === 'html') el.innerHTML = attrs[k];
            else if (k.slice(0, 2) === 'on') el[k] = attrs[k];
            else el.setAttribute(k, attrs[k]);
        });
        (children || []).forEach(function (c) { if (c) el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
        return el;
    }
    function button(label, onclick, cls) { return h('div', { class: 'btn focusable ' + (cls || ''), onclick: onclick, html: label }); }
    function stars(rating) {
        if (!rating) return '';
        return '<span class="star">★</span> ' + (rating / 20).toFixed(1);
    }

    function toast(msg) {
        toastEl.textContent = msg;
        toastEl.hidden = false;
        clearTimeout(toast.t);
        toast.t = setTimeout(function () { toastEl.hidden = true; }, 3500);
    }

    // ---- Stack -------------------------------------------------------------------------------------

    function push(name, data) {
        var top = stack[stack.length - 1];
        if (top) top.focusKey = focusKeyOf(Nav.current());
        stack.push({ name: name, data: data || {} });
        render();
    }
    function back() {
        if (document.querySelector('.modal')) { closeModal(); return; }
        if (stack.length > 1) { stack.pop(); render(); return; }
        // Back on the home screen leaves the app.
        if (typeof tizen !== 'undefined') try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
    }
    function replaceTop(data) { stack[stack.length - 1].data = data; render(); }
    function focusKeyOf(el) { return el ? el.getAttribute('data-key') : null; }
    function restoreFocus(fallback) {
        var top = stack[stack.length - 1];
        var el = top.focusKey && screenEl.querySelector('[data-key="' + cssEscape(top.focusKey) + '"]');
        Nav.focus(el || screenEl.querySelector(fallback || '.focusable'));
    }
    function cssEscape(s) { return String(s).replace(/["\\]/g, '\\$&'); }

    function render() {
        var top = stack[stack.length - 1];
        screenEl.innerHTML = '';
        screenEl.scrollTop = 0;
        ({ home: renderHome, details: renderDetails, search: renderSearch, settings: renderSettings })[top.name](top.data);
    }

    // ---- Modal picker (source, genre, sort, subtitle language) ---------------------------------------

    function pick(title, items, selected, onPick) {
        closeModal();
        var list = h('div', { class: 'modal-list' }, items.map(function (it, i) {
            return h('div', { class: 'modal-item focusable' + (i === selected ? ' selected' : ''), text: it, onclick: function () { closeModal(); onPick(i); } });
        }));
        var modal = h('div', { class: 'modal' }, [h('div', { class: 'modal-box' }, [h('h2', { text: title }), list])]);
        modal.previous = Nav.current();
        document.body.appendChild(modal);
        Nav.focus(list.children[Math.max(0, selected)]);
    }
    function closeModal() {
        var m = document.querySelector('.modal');
        if (!m) return;
        var prev = m.previous;
        m.parentNode.removeChild(m);
        if (prev && document.body.contains(prev)) Nav.focus(prev);
    }

    // ---- Home ----------------------------------------------------------------------------------------

    function header(active) {
        var source = Store.activeSource();
        var tabs = [['movies', 'Movies'], ['shows', 'TV Shows'], ['mylist', 'My List']].map(function (t) {
            return h('div', {
                class: 'tab focusable' + (active === t[0] ? ' active' : ''), text: t[1], 'data-key': 'tab:' + t[0],
                onclick: function () { if (home.tab !== t[0]) { home.tab = t[0]; resetHome(); } }
            });
        });
        var genre = Catalog.GENRES.filter(function (g) { return g.slug === home.genre; })[0] || Catalog.GENRES[0];
        var sort = Catalog.SORTS.filter(function (x) { return x.id === home.sort; })[0];
        var browsing = active === 'movies' || active === 'shows';
        return h('header', { class: 'bar' }, [
            h('div', { class: 'logo', html: '<img src="../icon.png" alt="">Bobcorn' }),
            h('nav', { class: 'tabs' }, tabs),
            h('div', { class: 'pickers' }, [
                h('div', { class: 'picker focusable', 'data-key': 'pick:source', html: '<span>Source</span> ' + escapeHTML(source ? source.name : 'None'), onclick: chooseSource }),
                browsing ? h('div', { class: 'picker focusable', 'data-key': 'pick:genre', html: '<span>Genre</span> ' + genre.title, onclick: chooseGenre }) : null,
                browsing ? h('div', { class: 'picker focusable', 'data-key': 'pick:sort', html: '<span>Sort by</span> ' + sort.title, onclick: chooseSort }) : null
            ]),
            h('div', { class: 'icons' }, [
                h('div', { class: 'icon focusable', 'data-key': 'icon:search', html: '⌕', title: 'Search', onclick: function () { push('search', { query: '' }); } }),
                h('div', { class: 'icon focusable', 'data-key': 'icon:settings', html: '⚙', title: 'Settings', onclick: function () { push('settings'); } })
            ])
        ]);
    }

    function chooseSource() {
        var list = Store.sources();
        var cur = Store.activeSource();
        var items = list.map(function (s) { return s.name; }).concat(['＋ Add a source…']);
        pick('Source', items, list.indexOf(cur), function (i) {
            if (i === list.length) { push('settings', { focus: 'add' }); return; }
            Store.setActiveSource(list[i].id);
            resetHome();
        });
    }
    function chooseGenre() {
        var i = 0;
        Catalog.GENRES.forEach(function (g, j) { if (g.slug === home.genre) i = j; });
        pick('Genre', Catalog.GENRES.map(function (g) { return g.title; }), i, function (j) { home.genre = Catalog.GENRES[j].slug; resetHome(); });
    }
    function chooseSort() {
        var i = 0;
        Catalog.SORTS.forEach(function (x, j) { if (x.id === home.sort) i = j; });
        pick('Sort by', Catalog.SORTS.map(function (x) { return x.title; }), i, function (j) { home.sort = Catalog.SORTS[j].id; resetHome(); });
    }

    function resetHome() {
        home.titles = []; home.page = 0; home.done = false; home.error = null; home.loading = false;
        stack = [{ name: 'home', data: {} }];
        stack[0].focusKey = focusKeyOf(Nav.current());
        render();
        if (home.tab !== 'mylist') loadMore();
    }

    function loadMore() {
        var source = Store.activeSource();
        if (!source || home.loading || home.done) return;
        home.loading = true;
        home.error = null;
        var q = { type: home.tab, sort: home.sort, genre: home.genre, search: '' };
        var tab = home.tab;
        updateGridFooter();
        Engine.ensure().then(function () { return Catalog.page(source, q, home.page + 1); }).then(function (titles) {
            if (home.tab !== tab) return;
            var known = {};
            home.titles.forEach(function (t) { known[t.id] = true; });
            var fresh = titles.filter(function (t) { return !known[t.id]; });
            home.titles = home.titles.concat(fresh);
            home.page++;
            home.done = fresh.length === 0;
            home.loading = false;
            if (stack.length === 1) appendCards(fresh);
        }, function (err) {
            home.loading = false;
            home.error = err.message;
            updateGridFooter();
        });
    }

    /* The poster's corner: stars, and Rotten Tomatoes' score once OMDb has it. */
    function ratingHTML(t) {
        return (t.rating ? stars(t.rating) : '') + Ratings.badge(Ratings.get(t.id));
    }

    function card(t) {
        var q = Catalog.qualities(t)[0];
        var rating = ratingHTML(t);
        return h('div', {
            class: 'card focusable', 'data-key': 'title:' + t.key,
            onclick: function () { push('details', { listed: t }); }
        }, [
            h('div', { class: 'poster' }, [
                t.poster ? h('img', { src: t.poster, loading: 'lazy', alt: '' }) : h('div', { class: 'noposter', text: t.title }),
                q ? h('span', { class: 'badge', text: q }) : null,
                h('span', { class: 'rating', 'data-imdb': t.id, 'data-stars': t.rating ? stars(t.rating) : '', html: rating, style: rating ? '' : 'display:none' })
            ]),
            h('div', { class: 'card-title', text: t.title }),
            h('div', { class: 'card-year', text: t.year ? String(t.year) : '' })
        ]);
    }

    function appendCards(titles) {
        var grid = screenEl.querySelector('.grid');
        if (!grid) return;
        titles.forEach(function (t) {
            var c = card(t);
            c.onfocusin = function () {
                // Near the end of what's loaded: fetch the next page.
                var cards = grid.children, idx = Array.prototype.indexOf.call(cards, c);
                if (idx > cards.length - 14) loadMore();
            };
            grid.appendChild(c);
        });
        updateGridFooter();
        if (!Nav.current() || !document.body.contains(Nav.current())) restoreFocus('.card');
    }

    function updateGridFooter() {
        var foot = screenEl.querySelector('.grid-footer');
        if (!foot) return;
        foot.innerHTML = '';
        if (home.error) {
            foot.appendChild(h('p', { class: 'error', text: home.error }));
            foot.appendChild(button('Try again', function () { loadMore(); }));
        } else if (home.loading) foot.appendChild(h('p', { class: 'dim', text: 'Loading…' }));
        else if (home.done && !home.titles.length) foot.appendChild(h('p', { class: 'dim', text: 'Nothing here.' }));
    }

    function renderHome() {
        screenEl.appendChild(header(home.tab));
        var body = h('div', { class: 'scroll' });
        screenEl.appendChild(body);
        if (!Store.activeSource()) {
            body.appendChild(h('div', { class: 'empty' }, [
                h('h1', { text: 'Add a source' }),
                h('p', { text: 'Bobcorn ships with no catalog of its own. Add a catalog API in Settings.' }),
                button('Open Settings', function () { push('settings', { focus: 'add' }); }, 'primary')
            ]));
            restoreFocus('.btn');
            return;
        }
        if (home.tab === 'mylist') {
            var watching = Store.continueWatching(), saved = Store.myList();
            if (watching.length) {
                body.appendChild(h('h2', { class: 'section', text: 'Continue Watching' }));
                body.appendChild(h('div', { class: 'grid' }, watching.map(card)));
            }
            body.appendChild(h('h2', { class: 'section', text: 'My List' }));
            body.appendChild(saved.length ? h('div', { class: 'grid' }, saved.map(card))
                : h('p', { class: 'dim pad', text: 'Titles you add with ♥ appear here.' }));
            restoreFocus('.card') ;
            return;
        }
        body.appendChild(h('div', { class: 'grid' }));
        body.appendChild(h('div', { class: 'grid-footer' }));
        appendCards(home.titles);
        restoreFocus('.card');
        if (!home.titles.length && !home.loading && !home.error) loadMore();
        else updateGridFooter();
    }

    // ---- Details -----------------------------------------------------------------------------------

    function renderDetails(data) {
        var t = data.full || data.listed;
        if (!data.full && !data.loading && !data.error) {
            data.loading = true;
            Catalog.details(data.listed).then(function (full) {
                data.full = full; data.loading = false;
                data.season = full.episodes.length ? firstUnwatchedSeason(full) : null;
                if (stack[stack.length - 1].data === data) {
                    // Keep focus where the viewer moved it while loading; otherwise land on Play (or the first episode).
                    var key = focusKeyOf(Nav.current());
                    stack[stack.length - 1].focusKey = key === 'mylist' ? null : key;
                    render();
                }
            }, function (err) {
                data.loading = false; data.error = err.message;
                if (stack[stack.length - 1].data === data) render();
            });
        }
        var page = h('div', { class: 'details scroll' });
        if (t.fanart) page.appendChild(h('div', { class: 'backdrop', style: 'background-image:url("' + t.fanart + '")' }));
        var meta = [t.year, t.runtime ? t.runtime + ' min' : null, t.certification, t.seasons ? t.seasons + (t.seasons === 1 ? ' season' : ' seasons') : null]
            .filter(Boolean).join(' · ');
        var info = h('div', { class: 'info' }, [
            h('h1', { text: t.title }),
            h('div', { class: 'meta', 'data-imdb': t.id, html: escapeHTML(meta) + (t.rating ? ' &nbsp; ' + stars(t.rating) + ' &nbsp;' + Math.round(t.rating) + '%' : '') +
                '<span class="tomato">' + Ratings.badge(Ratings.get(t.id)) + '</span>' }),
            t.genres && t.genres.length ? h('div', { class: 'genres', text: t.genres.join(' · ') }) : null,
            h('p', { class: 'synopsis', text: t.synopsis || (data.loading ? '' : '') })
        ]);
        var actions = h('div', { class: 'actions' });
        info.appendChild(actions);
        page.appendChild(h('div', { class: 'hero' }, [
            h('div', { class: 'hero-poster' }, [t.poster ? h('img', { src: t.poster, alt: '' }) : null]), info
        ]));
        screenEl.appendChild(page);

        if (data.loading) { info.appendChild(h('p', { class: 'dim', text: 'Loading…' })); }
        if (data.error) { info.appendChild(h('p', { class: 'error', text: data.error })); }

        var full = data.full;
        if (full && full.type === 'movies') {
            var best = Catalog.best(full.options);
            var resume = Store.resume(full.key);
            if (best) {
                if (resume) {
                    actions.appendChild(button('▶ Resume ' + clock(resume), function () { play(full, null, best, resume); }, 'primary'));
                    actions.appendChild(button('Play from start', function () { play(full, null, best, 0); }));
                } else actions.appendChild(button('▶ Watch Now', function () { play(full, null, best, 0); }, 'primary'));
            } else info.appendChild(h('p', { class: 'dim', text: 'The source lists no torrents for this title.' }));
        }
        actions.appendChild(myListButton(t));
        if (full && full.type === 'movies' && full.options.length) {
            info.appendChild(h('h3', { text: 'Torrents' }));
            info.appendChild(optionsList(full, null, full.options));
        }
        if (full && full.type === 'shows') renderEpisodes(info, full, data);
        restoreFocus(full && full.type === 'shows' && full.episodes.length ? '.episode' : '.actions .btn');
    }

    function myListButton(t) {
        var b = button(Store.inMyList(t.key) ? '♥ In My List' : '♡ My List', function () {
            var now = Store.toggleMyList(t);
            b.innerHTML = now ? '♥ In My List' : '♡ My List';
            toast(now ? 'Added to My List' : 'Removed from My List');
        });
        b.setAttribute('data-key', 'mylist');
        return b;
    }

    function optionsList(title, episode, options) {
        var sorted = options.slice().sort(function (a, b) { return (b.seeds || -1) - (a.seeds || -1); });
        return h('div', { class: 'options' }, sorted.map(function (o) {
            return h('div', {
                class: 'option focusable', 'data-key': 'opt:' + o.link,
                onclick: function () { play(title, episode, o, episode ? Store.resume(episode.key) : Store.resume(title.key)); }
            }, [
                h('span', { class: 'q', text: o.quality }),
                h('span', { class: 'name', text: o.name }),
                h('span', { class: 'size', text: Catalog.size(o.size) }),
                h('span', { class: 'seeds', html: o.seeds !== null ? '<i class="dot ' + (o.seeds > 0 ? 'ok' : '') + '"></i>' + o.seeds + ' seeds' : '' })
            ]);
        }));
    }

    function firstUnwatchedSeason(full) {
        var seasons = seasonsOf(full);
        return seasons[0];
    }
    function seasonsOf(full) {
        var s = {};
        full.episodes.forEach(function (e) { s[e.season] = true; });
        return Object.keys(s).map(Number).sort(function (a, b) { return a - b; });
    }

    function renderEpisodes(info, full, data) {
        if (!full.episodes.length) { info.appendChild(h('p', { class: 'dim', text: 'The source lists no episodes.' })); return; }
        info.appendChild(h('div', { class: 'seasons' }, seasonsOf(full).map(function (n) {
            return h('div', {
                class: 'season focusable' + (n === data.season ? ' active' : ''), 'data-key': 'season:' + n, text: 'Season ' + n,
                onclick: function () { if (data.season !== n) { data.season = n; stack[stack.length - 1].focusKey = 'season:' + n; render(); } }
            });
        })));
        var eps = full.episodes.filter(function (e) { return e.season === data.season; });
        info.appendChild(h('div', { class: 'episodes' }, eps.map(function (e) {
            var resume = Store.resume(e.key);
            var opt = Catalog.best(e.options);
            return h('div', {
                class: 'episode focusable' + (opt ? '' : ' disabled'), 'data-key': 'ep:' + e.key,
                onclick: function () { if (opt) play(full, e, opt, resume); else toast('No torrent for this episode'); }
            }, [
                h('span', { class: 'ep-tag', text: 'E' + e.episode }),
                h('div', { class: 'ep-text' }, [
                    h('div', { class: 'ep-title', text: e.title }),
                    e.overview ? h('div', { class: 'ep-overview', text: e.overview }) : null
                ]),
                h('span', { class: 'ep-right', text: resume ? '▶ ' + clock(resume) : (opt ? opt.quality : '') })
            ]);
        })));
    }

    function nextEpisode(full, episode) {
        var i = full.episodes.indexOf(episode);
        for (var j = i + 1; j < full.episodes.length; j++) {
            var opt = Catalog.best(full.episodes[j].options, null);
            if (opt) return { title: full, episode: full.episodes[j], option: opt, startAt: 0 };
        }
        return null;
    }

    function play(full, episode, option, startAt) {
        var req = { title: full, episode: episode, option: option, startAt: startAt || 0 };
        if (episode) {
            // Chain the following episodes for autoplay.
            var link = function (r) { var n = nextEpisode(full, r.episode); if (n) { r.next = n; link(n); } };
            var n = nextEpisode(full, episode);
            if (n) { req.next = n; link(n); }
        }
        var top = stack[stack.length - 1];
        top.focusKey = focusKeyOf(Nav.current());
        screenEl.hidden = true;
        Player.play(req, function () { screenEl.hidden = false; render(); });
    }

    // ---- Search ------------------------------------------------------------------------------------

    /* Searches movies and TV shows together; results come in two sections. */
    function renderSearch(data) {
        var source = Store.activeSource() || {};
        var input = h('input', { type: 'text', class: 'search-input focusable', placeholder: 'Search movies and TV shows in ' + (source.name || 'your source'), value: data.query || '', 'data-key': 'search:input' });
        input.onsubmit = function () {
            var q = input.value.trim();
            if (!q) return;
            data.query = q; data.results = null; data.error = null;
            runSearch(data);
        };
        var go = button('Search', function () { input.onsubmit(); });
        go.setAttribute('data-key', 'search:go');
        screenEl.appendChild(h('div', { class: 'search-bar' }, [input, go]));
        var body = h('div', { class: 'scroll' });
        screenEl.appendChild(body);
        var r = data.results;
        if (data.loading) body.appendChild(h('p', { class: 'dim pad', text: 'Searching movies and TV shows for “' + data.query + '”…' }));
        else if (data.error) body.appendChild(h('p', { class: 'error pad', text: data.error }));
        else if (r) {
            if (!r.movies.length && !r.shows.length) body.appendChild(h('p', { class: 'dim pad', text: 'No movies or TV shows match “' + data.query + '”.' }));
            [['Movies', r.movies], ['TV Shows', r.shows]].forEach(function (sec) {
                if (!sec[1].length) return;
                body.appendChild(h('h2', { class: 'section', text: sec[0] + ' · ' + sec[1].length }));
                body.appendChild(h('div', { class: 'grid' }, sec[1].map(card)));
            });
            if (r.local) body.appendChild(h('p', { class: 'dim pad', text: 'This source doesn\'t search by itself, so Bobcorn matched titles from its first pages.' }));
        } else body.appendChild(h('p', { class: 'dim pad', text: 'Press OK to type a title, then OK on the keyboard to search movies and TV shows.' }));
        restoreFocus(r && (r.movies.length || r.shows.length) ? '.card' : '.search-input');
    }

    function runSearch(data) {
        var source = Store.activeSource();
        if (!data.query || !source) return;
        data.loading = true;
        stack[stack.length - 1].focusKey = null;
        render();
        Catalog.search(source, data.query).then(function (r) {
            data.loading = false; data.results = r;
            if (stack[stack.length - 1].data === data) render();
        }, function (err) {
            data.loading = false; data.error = err.message;
            if (stack[stack.length - 1].data === data) render();
        });
    }

    // ---- Settings ----------------------------------------------------------------------------------

    function languages() {
        return OpenSubtitles.LANGUAGES.map(function (c) { return [c, OpenSubtitles.languageName(c)]; }).concat([['', 'Off']]);
    }

    /* A key field: shows whether a key is set, and saves on OK from the TV keyboard. */
    function keyRow(name, label, help, after) {
        var current = Store.key(name);
        var input = h('input', { type: 'text', class: 'focusable', placeholder: current ? 'Key set · type a new one to replace it' : label + ' API key', 'data-key': 'key:' + name });
        var save = button('Save', function () {
            var v = input.value.trim();
            if (!v) { toast(current ? 'The key is unchanged' : 'Type the key first'); return; }
            Store.setKey(name, v);
            if (after) after();
            toast(label + ' key saved');
            render();
        });
        input.onsubmit = function () { save.click(); };
        var clear = current ? button('Remove', function () { Store.setKey(name, ''); if (after) after(); toast(label + ' key removed'); render(); }) : null;
        return [
            h('div', { class: 'row-label', html: '<b>' + label + '</b> ' + (current ? '<span class="ok">✓ key set</span>' : '<span class="dim">no key</span>') + '<div class="dim small">' + help + '</div>' }),
            h('div', { class: 'add-row' }, [input, save, clear])
        ];
    }

    function renderSettings(data) {
        var page = h('div', { class: 'settings scroll' });
        screenEl.appendChild(page);
        page.appendChild(h('h1', { text: 'Settings' }));

        page.appendChild(h('h2', { text: 'Sources' }));
        var active = Store.activeSource();
        Store.sources().forEach(function (src) {
            var row = h('div', { class: 'row focusable' + (active && active.id === src.id ? ' active' : ''), 'data-key': 'src:' + src.id, onclick: function () {
                pick(src.name, ['Use this source', 'Remove'], 0, function (i) {
                    if (i === 0) { Store.setActiveSource(src.id); toast('Using ' + src.name); home.titles = []; home.page = 0; home.done = false; render(); }
                    else { Store.removeSource(src.id); home.titles = []; home.page = 0; home.done = false; render(); }
                });
            } }, [h('span', { text: src.name }), h('span', { class: 'dim', text: src.url })]);
            page.appendChild(row);
        });

        var name = h('input', { type: 'text', class: 'focusable', placeholder: 'Name (optional)', 'data-key': 'add:name' });
        var url = h('input', { type: 'text', class: 'focusable', placeholder: 'Catalog API address, https://…', 'data-key': 'add' });
        var add = button('Add source', function () {
            var u = url.value.trim();
            if (!/^https?:\/\/\S+$/i.test(u)) { toast('Type the API address, starting with https://'); Nav.focus(url); return; }
            Store.addSource(name.value.trim(), u);
            home.titles = []; home.page = 0; home.done = false;
            toast('Added. It is now the active source.');
            render();
        });
        url.onsubmit = function () { add.click(); };
        page.appendChild(h('div', { class: 'add-row' }, [url, name, add]));
        page.appendChild(h('p', { class: 'dim', text: 'Only add sources and open torrents you have the right to download.' }));

        page.appendChild(h('h2', { text: 'Ratings and subtitles' }));
        keyRow('omdb', 'OMDb', 'Rotten Tomatoes scores on posters. A free key from omdbapi.com/apikey.aspx.', Ratings.keyChanged)
            .forEach(function (el) { page.appendChild(el); });
        if (Ratings.lastError()) page.appendChild(h('p', { class: 'error', text: Ratings.lastError() }));
        keyRow('opensubtitles', 'OpenSubtitles', 'Optional. Films already find subtitles on YIFY Subtitles without a key; an OpenSubtitles key adds TV episodes and subtitles timed to your exact file. A free key from opensubtitles.com/consumers downloads 5 a day.')
            .forEach(function (el) { page.appendChild(el); });

        page.appendChild(h('h2', { text: 'Open a link' }));
        var link = h('input', { type: 'text', class: 'focusable wide', placeholder: 'magnet:?xt=… or https://….torrent', 'data-key': 'link' });
        var open = button('Play', function () {
            var l = link.value.trim();
            if (!/^(magnet:|https?:\/\/)/i.test(l)) { toast('Type a magnet link or a .torrent address'); return; }
            var t = { key: 'link:' + l, id: l, type: 'movies', title: l.indexOf('dn=') > 0 ? decodeURIComponent((/dn=([^&]+)/.exec(l) || [])[1] || '').replace(/\+/g, ' ') : 'Torrent', options: [] };
            play(t, null, { link: l, quality: '' }, 0);
        });
        link.onsubmit = function () { open.click(); };
        page.appendChild(h('div', { class: 'add-row' }, [link, open]));

        page.appendChild(h('h2', { text: 'Playback' }));
        var lang = Store.subtitleLanguage(), LANGS = languages();
        var langName = (LANGS.filter(function (l) { return l[0] === lang; })[0] || [lang, lang || 'Off'])[1];
        page.appendChild(h('div', { class: 'row focusable', 'data-key': 'sublang', onclick: function () {
            var i = 0;
            LANGS.forEach(function (l, j) { if (l[0] === lang) i = j; });
            pick('Subtitle language', LANGS.map(function (l) { return l[1]; }), i, function (j) { Store.setSubtitleLanguage(LANGS[j][0]); render(); });
        } }, [h('span', { text: 'Subtitle language' }), h('span', { class: 'dim', text: langName })]));
        page.appendChild(h('p', { class: 'dim', text: 'Subtitles in this language turn on by themselves, and OpenSubtitles searches in it first. In the player, press ▼ for Subtitles, Audio and Next episode. Bobcorn keeps only 5 minutes behind and 15 minutes ahead of what you watch, never the whole film.' }));

        var engineRow = h('p', { class: 'dim', text: 'Engine: checking…' });
        page.appendChild(h('h2', { text: 'About' }));
        page.appendChild(engineRow);

        // Troubleshooting: lets a computer on the same network read the engine's log.
        var sharing = Store.logSharing(), ip = '';
        try { ip = (typeof webapis !== 'undefined' && webapis.network) ? webapis.network.getIp() : ''; } catch (e) { ip = ''; }
        page.appendChild(h('div', { class: 'row focusable', 'data-key': 'sharelog', onclick: function () {
            var on = !Store.logSharing();
            Store.setLogSharing(on);
            Engine.ensure().then(function () { return Engine.shareLog(on); }).then(function () {
                toast(on ? 'Sharing the engine log on your network' : 'Stopped sharing the engine log');
                render();
            }, function (e) { toast(e.message); });
        } }, [h('span', { text: 'Share the engine\'s log on my home network' }), h('span', { class: sharing ? 'ok' : 'dim', text: sharing ? 'On' : 'Off' })]));
        page.appendChild(h('p', { class: 'dim', text: sharing
            ? 'For troubleshooting: a computer on your network can read it at http://' + (ip || '<this TV\'s IP>') + ':8616/log. It shows what Bobcorn streams; turn it off when you\'re done.'
            : 'For troubleshooting playback problems. Off by default.' }));
        Engine.ensure().then(function (p) { engineRow.textContent = 'Engine ' + p.version + ' running on Node ' + p.node + '.'; },
            function (e) { engineRow.textContent = 'Engine: ' + e.message; });

        stack[stack.length - 1].focusKey = stack[stack.length - 1].focusKey || (data.focus === 'add' ? 'add' : null);
        restoreFocus('.row');
    }

    // ---- Helpers -----------------------------------------------------------------------------------

    function clock(sec) {
        sec = Math.floor(sec);
        var hh = Math.floor(sec / 3600), m = Math.floor(sec / 60) % 60, x = sec % 60;
        return (hh ? hh + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (x < 10 ? '0' : '') + x;
    }
    function escapeHTML(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

    return {
        init: function () {
            screenEl = document.getElementById('screen');
            toastEl = document.getElementById('toast');
            stack = [{ name: 'home', data: {} }];
            // OMDb answers arrive after the posters are drawn: fill in their scores.
            Ratings.onChange(function (id, score) {
                Array.prototype.forEach.call(document.querySelectorAll('[data-imdb="' + cssEscape(id) + '"]'), function (el) {
                    if (el.classList.contains('rating')) {
                        el.innerHTML = (el.getAttribute('data-stars') || '') + Ratings.badge(score);
                        el.style.display = el.innerHTML ? '' : 'none';
                    } else {
                        var t = el.querySelector('.tomato');
                        if (t) t.innerHTML = Ratings.badge(score);
                    }
                });
            });
            render();
        },
        back: back,
        toast: toast
    };
})();
