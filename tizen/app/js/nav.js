/* Remote-control navigation: arrows move focus to the nearest .focusable in that direction,
   OK clicks it, Back pops the screen stack. Screens can take keys first with `onKey`. */
var Nav = (function () {
    'use strict';

    var KEYS = {
        LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, ENTER: 13, BACK: 10009, ESC: 27, BACKSPACE: 8,
        PLAY_PAUSE: 10252, PLAY: 415, PAUSE: 19, STOP: 413, FF: 417, RW: 412,
        RED: 403, GREEN: 404, YELLOW: 405, BLUE: 406, EXIT: 10182,
        IME_DONE: 65376, IME_CANCEL: 65385
    };

    var current = null;   // the focused element
    var handler = null;   // the active screen's key handler, if any

    function visible(el) {
        if (!el.offsetParent && getComputedStyle(el).position !== 'fixed') return false;
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    }

    function candidates() {
        var root = document.querySelector('.modal') || document.getElementById('screen');
        return Array.prototype.filter.call(root.querySelectorAll('.focusable'), visible);
    }

    function focus(el, noScroll) {
        if (!el) return;
        if (current && current !== el) current.classList.remove('focused');
        current = el;
        el.classList.add('focused');
        // Text boxes open the TV keyboard only on OK, not when focus passes over them.
        if (document.activeElement && document.activeElement.tagName === 'INPUT' && document.activeElement !== el) document.activeElement.blur();
        if (!noScroll) scrollIntoView(el);
        if (el.onfocusin) el.onfocusin();
    }

    /* Keeps the focused element on screen, scrolling its nearest scrollable parent smoothly. */
    function scrollIntoView(el) {
        var p = el.parentElement;
        while (p && p !== document.body) {
            var style = getComputedStyle(p);
            if (/(auto|scroll)/.test(style.overflowY) && p.scrollHeight > p.clientHeight) break;
            p = p.parentElement;
        }
        if (!p || p === document.body) return;
        var r = el.getBoundingClientRect(), pr = p.getBoundingClientRect(), margin = 120;
        if (r.top < pr.top + margin) p.scrollTop -= (pr.top + margin - r.top);
        else if (r.bottom > pr.bottom - margin) p.scrollTop += (r.bottom - (pr.bottom - margin));
        var hp = el.parentElement;
        while (hp && hp !== p) {
            if (/(auto|scroll)/.test(getComputedStyle(hp).overflowX) && hp.scrollWidth > hp.clientWidth) {
                var hr = hp.getBoundingClientRect();
                if (r.left < hr.left + 60) hp.scrollLeft -= (hr.left + 60 - r.left);
                else if (r.right > hr.right - 60) hp.scrollLeft += (r.right - (hr.right - 60));
                break;
            }
            hp = hp.parentElement;
        }
    }

    /* The nearest candidate in a direction, preferring ones that overlap on the cross axis. */
    function move(dir) {
        var list = candidates();
        if (!current || list.indexOf(current) < 0) { focus(list[0]); return true; }
        var a = current.getBoundingClientRect();
        var ax = a.left + a.width / 2, ay = a.top + a.height / 2;
        var best = null, bestScore = Infinity;
        list.forEach(function (el) {
            if (el === current) return;
            var b = el.getBoundingClientRect();
            var bx = b.left + b.width / 2, by = b.top + b.height / 2;
            var main, cross, overlap;
            if (dir === 'left') { main = a.left - b.right; cross = Math.abs(ay - by); overlap = b.bottom > a.top && b.top < a.bottom; if (bx >= ax) return; }
            if (dir === 'right') { main = b.left - a.right; cross = Math.abs(ay - by); overlap = b.bottom > a.top && b.top < a.bottom; if (bx <= ax) return; }
            if (dir === 'up') { main = a.top - b.bottom; cross = Math.abs(ax - bx); overlap = b.right > a.left && b.left < a.right; if (by >= ay) return; }
            if (dir === 'down') { main = b.top - a.bottom; cross = Math.abs(ax - bx); overlap = b.right > a.left && b.left < a.right; if (by <= ay) return; }
            var score = Math.max(main, -20) + cross * (overlap ? 0.5 : 3) + (overlap ? 0 : 400);
            if (score < bestScore) { bestScore = score; best = el; }
        });
        if (best) { focus(best); return true; }
        return false;
    }

    function keydown(e) {
        var code = e.keyCode;
        if (handler && handler(code, e) === true) { e.preventDefault(); return; }
        var typing = document.activeElement && document.activeElement.tagName === 'INPUT';
        switch (code) {
            case KEYS.LEFT: if (typing) return; move('left'); break;
            case KEYS.RIGHT: if (typing) return; move('right'); break;
            case KEYS.UP: move('up'); break;
            case KEYS.DOWN: move('down'); break;
            case KEYS.ENTER: case KEYS.IME_DONE:
                if (typing) { document.activeElement.blur(); if (current && current.onsubmit) current.onsubmit(); break; }
                if (current && current.tagName === 'INPUT') { current.focus(); break; }
                if (current) current.click();
                break;
            case KEYS.IME_CANCEL:
                if (typing) document.activeElement.blur();
                break;
            case KEYS.BACK: case KEYS.ESC:
                if (typing && code === KEYS.ESC) { document.activeElement.blur(); break; }
                Views.back();
                break;
            case KEYS.BACKSPACE: if (typing) return; Views.back(); break;
            default: return;
        }
        e.preventDefault();
    }

    function register() {
        if (typeof tizen === 'undefined' || !tizen.tvinputdevice) return;
        var wanted = ['MediaPlayPause', 'MediaPlay', 'MediaPause', 'MediaStop', 'MediaFastForward', 'MediaRewind',
            'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue'];
        try { tizen.tvinputdevice.registerKeyBatch(wanted); } catch (e) {
            wanted.forEach(function (k) { try { tizen.tvinputdevice.registerKey(k); } catch (err) { /* not on this remote */ } });
        }
    }

    return {
        KEYS: KEYS,
        start: function () { register(); document.addEventListener('keydown', keydown); },
        focus: focus,
        current: function () { return current; },
        setHandler: function (fn) { handler = fn; },
        /* Focus the first match of a selector, or the first focusable on screen. */
        focusFirst: function (selector) {
            var el = selector ? document.querySelector(selector) : null;
            focus(el && visible(el) ? el : candidates()[0], false);
        }
    };
})();
