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
        ({ home: renderHome, details: renderDetails, search: renderSearch, settings: renderSettings, iptvDetails: renderIptvDetails })[top.name](top.data);
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

    /* The tabs a source has: catalog APIs list movies and shows; IPTV adds live TV and calls shows series. */
    function tabsFor(source) {
        return IPTV.isIptv(source) ? [['live', 'Live TV'], ['vod', 'Movies'], ['series', 'Series'], ['mylist', 'My List']]
            : [['movies', 'Movies'], ['shows', 'TV Shows'], ['mylist', 'My List']];
    }
    function fixTab() {
        var ok = tabsFor(Store.activeSource()).map(function (t) { return t[0]; });
        if (ok.indexOf(home.tab) < 0) home.tab = ok[0];
    }

    function header(active) {
        var source = Store.activeSource();
        var tabs = tabsFor(source).map(function (t) {
            return h('div', {
                class: 'tab focusable' + (active === t[0] ? ' active' : ''), text: t[1], 'data-key': 'tab:' + t[0],
                onclick: function () { if (home.tab !== t[0]) { home.tab = t[0]; resetHome(); } }
            });
        });
        var genre = Catalog.GENRES.filter(function (g) { return g.slug === home.genre; })[0] || Catalog.GENRES[0];
        var sort = Catalog.SORTS.filter(function (x) { return x.id === home.sort; })[0];
        var browsing = !IPTV.isIptv(source) && (active === 'movies' || active === 'shows');
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
        fixTab();
        if (IPTV.isIptv(Store.activeSource())) {
            stack = [{ name: 'home', data: {} }];
            render();
            return;
        }
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

    /* list: for a live channel, the channels it sits among (for changing channel in the player). */
    function card(t, list) {
        var q = t.iptv ? null : Catalog.qualities(t)[0];
        var rating = ratingHTML(t);
        return h('div', {
            class: 'card focusable' + (t.iptv && t.kind === 'live' ? ' channel-card' : ''), 'data-key': 'title:' + t.key,
            onclick: function () {
                if (!t.iptv) return push('details', { listed: t });
                if (t.kind === 'live') return playLive(t, list || [t]);
                push('iptvDetails', { item: t });
            }
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
        fixTab();
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
        fixTab();
        if (IPTV.isIptv(Store.activeSource()) && home.tab !== 'mylist') {
            screenEl.removeChild(body);
            renderIptvHome();
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

    // ---- IPTV: categories beside channels or posters ---------------------------------------------------

    // Per source and tab: the chosen category, and the items shown so far (long categories draw in pieces).
    var iptvState = {};
    var IPTV_PAGE = 120;

    function iptvTab() {
        var src = Store.activeSource(), k = src.id + ':' + home.tab;
        if (!iptvState[k]) iptvState[k] = { categories: null, category: null, items: null, shown: 0, loading: false, error: null, account: null };
        return iptvState[k];
    }

    function renderIptvHome() {
        var src = Store.activeSource(), st = iptvTab(), kind = home.tab;
        var cats = h('div', { class: 'iptv-cats' });
        var items = h('div', { class: 'iptv-items' });
        screenEl.appendChild(h('div', { class: 'iptv' }, [cats, items]));

        if (!st.categories && !st.loading) {
            st.loading = true;
            Engine.ensure().then(function () { return IPTV.categories(src, kind); }).then(function (list) {
                st.loading = false; st.categories = list;
                if (!st.category && list.length) st.category = firstUseful(list).id;
                if (isShowing(st)) { render(); if (st.category) loadItems(st); }
            }, function (e) { st.loading = false; st.error = e.message; if (isShowing(st)) render(); });
        }
        if (st.error && !st.categories) {
            cats.appendChild(h('p', { class: 'error pad-s', text: st.error }));
            cats.appendChild(button('Try again', function () { st.error = null; render(); }));
        } else if (!st.categories) cats.appendChild(h('p', { class: 'dim pad-s', text: 'Loading categories…' }));
        else {
            st.categories.forEach(function (c) {
                cats.appendChild(h('div', {
                    class: 'iptv-cat focusable' + (c.id === st.category ? ' active' : ''), 'data-key': 'cat:' + c.id, text: c.name,
                    onclick: function () {
                        if (st.category === c.id) { var first = screenEl.querySelector('.iptv-items .focusable'); if (first) Nav.focus(first); return; }
                        st.category = c.id; st.items = null; st.shown = 0;
                        Array.prototype.forEach.call(cats.querySelectorAll('.iptv-cat'), function (el) { el.classList.toggle('active', el === this); }, this);
                        loadItems(st);
                    }
                }));
            });
        }
        fillItems(st, items);
        restoreFocus(st.items && st.items.length ? '.iptv-items .focusable' : '.iptv-cat.active');
    }

    // Providers often start with an "account information" category: skip to the first real one.
    function firstUseful(list) {
        for (var i = 0; i < list.length; i++) if (!/accou?nt|info/i.test(list[i].name)) return list[i];
        return list[0];
    }
    function isShowing(st) { return stack.length === 1 && stack[0].name === 'home' && IPTV.isIptv(Store.activeSource()) && iptvTab() === st && !Player.active(); }

    function loadItems(st) {
        var src = Store.activeSource(), kind = home.tab, cat = st.category;
        st.items = null; st.error = null; st.shown = 0;
        var box = screenEl.querySelector('.iptv-items');
        if (box) fillItems(st, box);
        IPTV.items(src, kind, cat).then(function (list) {
            if (st.category !== cat) return;
            st.items = list;
            var b = isShowing(st) && screenEl.querySelector('.iptv-items');
            if (b) fillItems(st, b);
        }, function (e) {
            if (st.category !== cat) return;
            st.error = e.message;
            var b = isShowing(st) && screenEl.querySelector('.iptv-items');
            if (b) fillItems(st, b);
        });
    }

    function fillItems(st, box) {
        box.innerHTML = '';
        var cat = (st.categories || []).filter(function (c) { return c.id === st.category; })[0];
        if (cat) box.appendChild(h('h2', { class: 'iptv-title', text: cat.name + (st.items ? ' · ' + st.items.length : '') }));
        if (st.error) { box.appendChild(h('p', { class: 'error pad-s', text: st.error })); return; }
        if (!st.items) { if (st.category) box.appendChild(h('p', { class: 'dim pad-s', text: 'Loading…' })); return; }
        if (!st.items.length) { box.appendChild(h('p', { class: 'dim pad-s', text: 'Nothing in this category.' })); return; }
        var live = home.tab === 'live';
        var holder = h('div', { class: live ? 'channels' : 'grid iptv-grid' });
        box.appendChild(holder);
        st.shown = 0;
        more();
        function more() {
            var next = st.items.slice(st.shown, st.shown + IPTV_PAGE);
            next.forEach(function (it, j) {
                var el = live ? channelRow(it, st.items, st.shown + j) : card(it);
                el.onfocusin = function () { if (st.shown < st.items.length && Array.prototype.indexOf.call(holder.children, el) > holder.children.length - 20) more(); };
                holder.appendChild(el);
            });
            st.shown += next.length;
        }
    }

    function channelRow(it, list, index) {
        return h('div', { class: 'channel focusable', 'data-key': 'title:' + it.key, onclick: function () { playLive(it, list); } }, [
            h('span', { class: 'ch-num', text: String(it.num || index + 1) }),
            h('div', { class: 'ch-logo' }, [it.poster ? h('img', { src: it.poster, loading: 'lazy', alt: '' }) : null]),
            h('span', { class: 'ch-name', text: it.title })
        ]);
    }

    function sourceOf(item) {
        return Store.sources().filter(function (s) { return s.id === item.srcId; })[0] || null;
    }

    function playLive(channel, list) {
        var src = sourceOf(channel);
        if (!src) { toast('That channel\'s source was removed'); return; }
        var top = stack[stack.length - 1];
        top.focusKey = focusKeyOf(Nav.current());
        screenEl.hidden = true;
        Player.play(liveRequest(src, channel, list), function () { screenEl.hidden = false; render(); });
    }

    /* A live channel for the player, with its neighbours for changing channel. */
    function liveRequest(src, channel, list) {
        var channels = (list || [channel]).filter(function (c) { return c.kind === 'live'; });
        return {
            title: channel, live: true, url: IPTV.streamURL(src, channel, null, 'm3u8'), altUrl: IPTV.streamURL(src, channel, null, 'ts'),
            subLine: 'Live', guide: function () { return IPTV.guide(src, channel); },
            channels: channels, channelIndex: Math.max(0, channels.indexOf(channel)),
            makeChannel: function (c) { return liveRequest(src, c, channels); }
        };
    }

    // ---- IPTV details: a movie, or a series with its seasons ------------------------------------------

    function renderIptvDetails(data) {
        var it = data.item, src = sourceOf(it);
        if (!src) { screenEl.appendChild(h('p', { class: 'error pad', text: 'This title\'s source was removed.' })); return; }
        if (!data.info && !data.loading && !data.error) {
            data.loading = true;
            (it.kind === 'series' ? IPTV.seriesInfo(src, it) : IPTV.movieInfo(src, it)).then(function (info) {
                data.info = info; data.loading = false;
                if (it.kind === 'series') data.season = (info.episodes[0] || {}).season;
                if (stack[stack.length - 1].data === data) { stack[stack.length - 1].focusKey = null; render(); }
            }, function (e) {
                data.loading = false; data.error = e.message;
                if (stack[stack.length - 1].data === data) render();
            });
        }
        var info = data.info || {};
        var page = h('div', { class: 'details scroll' });
        var back = info.backdrop || it.poster;
        if (back) page.appendChild(h('div', { class: 'backdrop', style: 'background-image:url("' + back + '")' }));
        var meta = [info.year || it.year, info.duration ? Math.round(info.duration / 60) + ' min' : null, info.genre].filter(Boolean).join(' · ');
        var box = h('div', { class: 'info' }, [
            h('h1', { text: it.title }),
            h('div', { class: 'meta', html: escapeHTML(meta) + (it.rating ? ' &nbsp; ' + stars(it.rating) : '') }),
            info.cast ? h('div', { class: 'genres', text: info.cast }) : null,
            h('p', { class: 'synopsis', text: info.plot || '' })
        ]);
        var actions = h('div', { class: 'actions' });
        box.appendChild(actions);
        page.appendChild(h('div', { class: 'hero' }, [h('div', { class: 'hero-poster' }, [(info.poster || it.poster) ? h('img', { src: info.poster || it.poster, alt: '' }) : null]), box]));
        screenEl.appendChild(page);
        if (data.loading) box.appendChild(h('p', { class: 'dim', text: 'Loading…' }));
        if (data.error) box.appendChild(h('p', { class: 'error', text: data.error }));

        if (it.kind === 'vod' && (data.info || data.error)) {
            var resume = Store.resume(it.key);
            if (resume) {
                actions.appendChild(button('▶ Resume ' + clock(resume), function () { playIptv(src, it, null, resume, info); }, 'primary'));
                actions.appendChild(button('Play from start', function () { playIptv(src, it, null, 0, info); }));
            } else actions.appendChild(button('▶ Watch Now', function () { playIptv(src, it, null, 0, info); }, 'primary'));
        }
        actions.appendChild(myListButton(it));
        if (it.kind === 'series' && data.info) {
            var eps = info.episodes || [];
            if (!eps.length) box.appendChild(h('p', { class: 'dim', text: 'The provider lists no episodes.' }));
            else {
                var seasons = [];
                eps.forEach(function (e) { if (seasons.indexOf(e.season) < 0) seasons.push(e.season); });
                box.appendChild(h('div', { class: 'seasons' }, seasons.map(function (n) {
                    return h('div', {
                        class: 'season focusable' + (n === data.season ? ' active' : ''), 'data-key': 'season:' + n, text: 'Season ' + n,
                        onclick: function () { if (data.season !== n) { data.season = n; stack[stack.length - 1].focusKey = 'season:' + n; render(); } }
                    });
                })));
                box.appendChild(h('div', { class: 'episodes' }, eps.filter(function (e) { return e.season === data.season; }).map(function (e) {
                    var r = Store.resume(e.key);
                    return h('div', { class: 'episode focusable', 'data-key': 'ep:' + e.key, onclick: function () { playIptv(src, it, e, r, info); } }, [
                        h('span', { class: 'ep-tag', text: 'E' + e.episode }),
                        h('div', { class: 'ep-text' }, [h('div', { class: 'ep-title', text: e.title }), e.overview ? h('div', { class: 'ep-overview', text: e.overview }) : null]),
                        h('span', { class: 'ep-right', text: r ? '▶ ' + clock(r) : (e.duration ? Math.round(e.duration / 60) + ' min' : '') })
                    ]);
                })));
            }
        }
        restoreFocus(it.kind === 'series' && data.info && (info.episodes || []).length ? '.episode' : '.actions .btn');
    }

    /* A movie or an episode (with the following episodes chained for autoplay). */
    function playIptv(src, it, episode, startAt, info) {
        function request(ep, at) {
            var req = {
                title: it, episode: ep || null, url: IPTV.streamURL(src, it, ep), startAt: at || 0,
                subLine: ep ? ep.tag + ' · ' + ep.title : (info && info.year ? String(info.year) : ''),
                fileName: ep ? it.title + ' ' + ep.tag : it.title, runtime: ep ? ep.duration : (info && info.duration) || 0,
                tmdbID: ep ? ep.tmdb : (info && info.tmdb) || null
            };
            if (ep) {
                var eps = info.episodes, i = eps.indexOf(ep);
                if (i >= 0 && i + 1 < eps.length) req.nextRequest = function () { return request(eps[i + 1], 0); };
            }
            return req;
        }
        var top = stack[stack.length - 1];
        top.focusKey = focusKeyOf(Nav.current());
        screenEl.hidden = true;
        Player.play(request(episode, startAt), function () { screenEl.hidden = false; render(); });
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
        var input = h('input', { type: 'text', class: 'search-input focusable', placeholder: (IPTV.isIptv(source) ? 'Search channels, films and series in ' : 'Search movies and TV shows in ') + (source.name || 'your source'), value: data.query || '', 'data-key': 'search:input' });
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
        if (IPTV.isIptv(Store.activeSource())) { renderIptvResults(data, body); return; }
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
        if (IPTV.isIptv(source)) { runIptvSearch(data, source); return; }
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

    /* IPTV search: the engine builds an index of the account the first time (a few minutes), then answers at once. */
    function runIptvSearch(data, source) {
        data.loading = true;
        stack[stack.length - 1].focusKey = null;
        render();
        var query = data.query;
        IPTV.search(source, query).then(function (r) {
            if (data.query !== query) return;
            data.loading = false;
            data.results = r;
            if (stack[stack.length - 1].data === data) render();
            // Still indexing: ask again in a few seconds.
            if (r.status === 'building') setTimeout(function () {
                if (stack[stack.length - 1].data === data && data.query === query && !Player.active()) runIptvSearch(data, source);
            }, 4000);
        }, function (err) {
            data.loading = false; data.error = err.message;
            if (stack[stack.length - 1].data === data) render();
        });
    }

    function renderIptvResults(data, body) {
        var r = data.results;
        if (data.loading && !r) body.appendChild(h('p', { class: 'dim pad', text: 'Searching for “' + data.query + '”…' }));
        else if (data.error) body.appendChild(h('p', { class: 'error pad', text: data.error }));
        else if (r && r.status === 'building' && !r.results) {
            var p = r.progress || {};
            body.appendChild(h('p', { class: 'dim pad', text: 'Getting this account ready for search (the first time only; it takes a few minutes): ' +
                (p.live || 0) + ' channels, ' + (p.vod || 0) + ' movies, ' + (p.series || 0) + ' series so far…' }));
        } else if (r && r.status === 'error' && !r.results) body.appendChild(h('p', { class: 'error pad', text: 'Search isn\'t ready: ' + (r.error || 'the provider didn\'t send its lists') }));
        else if (r && r.results) {
            var res = r.results, any = false;
            [['live', 'Live TV'], ['vod', 'Movies'], ['series', 'Series']].forEach(function (sec) {
                var list = res[sec[0]] || [];
                if (!list.length) return;
                any = true;
                var count = (r.counts && r.counts[sec[0]]) || list.length;
                body.appendChild(h('h2', { class: 'section', text: sec[1] + ' · ' + count + (count > list.length ? ' (showing ' + list.length + ')' : '') }));
                body.appendChild(sec[0] === 'live'
                    ? h('div', { class: 'channels pad-x' }, list.map(function (c, i) { return channelRow(c, list, i); }))
                    : h('div', { class: 'grid' }, list.map(function (t) { return card(t); })));
            });
            if (!any) body.appendChild(h('p', { class: 'dim pad', text: 'Nothing matches “' + data.query + '”.' }));
            if (r.status === 'building') body.appendChild(h('p', { class: 'dim pad', text: 'Refreshing this account\'s search in the background.' }));
        } else body.appendChild(h('p', { class: 'dim pad', text: 'Press OK to type a channel, film or series, then OK on the keyboard to search.' }));
        restoreFocus(r && r.results ? '.channel, .card' : '.search-input');
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
            } }, [h('span', { text: src.name }), h('span', { class: 'dim', text: sourceLabel(src) })]);
            page.appendChild(row);
        });
        // The active IPTV account's state, asked of the provider.
        if (active && active.kind === 'xtream') {
            var acct = h('p', { class: 'dim', text: active.name + ': checking the account…' });
            page.appendChild(acct);
            IPTV.account(active).then(function (a) {
                acct.textContent = active.name + ': ' + a.status + (a.expires ? ' until ' + a.expires.toLocaleDateString() : '') +
                    (a.maxConnections ? ' · ' + a.maxConnections + (a.maxConnections === 1 ? ' screen' : ' screens') + ' at a time' : '');
            }, function (e) { acct.textContent = active.name + ': ' + e.message; acct.className = 'error'; });
        }

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

        // IPTV: an Xtream Codes account (host, username, password), or an M3U playlist's address.
        page.appendChild(h('h2', { text: 'IPTV' }));
        var xName = h('input', { type: 'text', class: 'focusable', placeholder: 'Name (optional)', 'data-key': 'xc:name' });
        var xHost = h('input', { type: 'text', class: 'focusable', placeholder: 'Host, http://…', 'data-key': 'xc:host' });
        var xUser = h('input', { type: 'text', class: 'focusable', placeholder: 'Username', 'data-key': 'xc:user' });
        var xPass = h('input', { type: 'password', class: 'focusable', placeholder: 'Password', 'data-key': 'xc:pass' });
        var xAdd = button('Add account', function () {
            var host = xHost.value.trim(), user = xUser.value.trim(), pass = xPass.value;
            if (!host || !user) { toast('Type the host and username'); return; }
            var src = { kind: 'xtream', name: xName.value.trim() || host.replace(/^https?:\/\//, '').replace(/[:\/].*$/, ''), host: host, username: user, password: pass };
            toast('Checking the account…');
            IPTV.account(src).then(function (a) {
                Store.addIptvSource(src);
                toast('Added: ' + a.status + (a.expires ? ' until ' + a.expires.toLocaleDateString() : ''));
                resetHomeState();
                render();
            }, function (e) { toast(e.message); });
        });
        page.appendChild(h('p', { class: 'dim small', text: 'An Xtream Codes (XC) account from your IPTV provider.' }));
        page.appendChild(h('div', { class: 'add-row' }, [xHost, xName]));
        page.appendChild(h('div', { class: 'add-row' }, [xUser, xPass, xAdd]));
        var mName = h('input', { type: 'text', class: 'focusable', placeholder: 'Name (optional)', 'data-key': 'm3u:name' });
        var mURL = h('input', { type: 'text', class: 'focusable', placeholder: 'M3U playlist address, http://…', 'data-key': 'm3u:url' });
        var mAdd = button('Add playlist', function () {
            var u = mURL.value.trim();
            if (!/^https?:\/\/\S+$/i.test(u)) { toast('Type the playlist address, starting with http'); return; }
            Store.addIptvSource({ kind: 'm3u', name: mName.value.trim() || 'Playlist', url: u });
            toast('Added the playlist. It is now the active source.');
            resetHomeState();
            render();
        });
        mURL.onsubmit = function () { mAdd.click(); };
        page.appendChild(h('div', { class: 'add-row' }, [mURL, mName, mAdd]));
        page.appendChild(h('p', { class: 'dim', text: 'Only add IPTV services you are subscribed to.' }));

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

    function sourceLabel(src) {
        if (src.kind === 'xtream') return 'IPTV account · ' + String(src.host || '').replace(/^https?:\/\//, '') + ' · ' + src.username;
        if (src.kind === 'm3u') return 'M3U playlist · ' + String(src.url || '').replace(/^https?:\/\//, '').slice(0, 60);
        return src.url;
    }
    function resetHomeState() { home.titles = []; home.page = 0; home.done = false; home.error = null; fixTab(); }

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
        toast: toast,
        /* Back to a fresh home screen, after settings were restored from the backup. */
        reload: function () {
            if (Player.active()) return;
            home.titles = []; home.page = 0; home.done = false; home.error = null; home.loading = false;
            stack = [{ name: 'home', data: {} }];
            render();
        }
    };
})();
