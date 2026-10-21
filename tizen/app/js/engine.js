/* Talks to the torrent engine, the Node.js service in tizen/service that serves 127.0.0.1:8615.
   In a desktop browser (no `tizen`), ?engine=http://host:8615 points at an engine run with `node tizen/service/dev.js`. */
var Engine = (function () {
    'use strict';

    var onTV = typeof tizen !== 'undefined';
    var param = /[?&]engine=([^&]+)/.exec(location.search);
    var BASE = param ? decodeURIComponent(param[1]) : 'http://127.0.0.1:8615';

    function request(method, path, body, timeout) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open(method, BASE + path);
            xhr.timeout = timeout || 20000;
            if (body !== undefined) xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.onload = function () {
                var data = null;
                try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null; } catch (e) { data = xhr.responseText; }
                if (xhr.status >= 200 && xhr.status < 300) return resolve(data);
                var err = new Error((data && (data.error || data.message)) || ('HTTP ' + xhr.status));
                err.status = xhr.status;
                err.data = data;
                reject(err);
            };
            xhr.onerror = function () { reject(new Error('The engine is not running')); };
            xhr.ontimeout = function () { reject(new Error('The engine took too long to answer')); };
            xhr.send(body === undefined ? null : JSON.stringify(body));
        });
    }

    function bytes(url) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', url);
            xhr.responseType = 'arraybuffer';
            xhr.timeout = 60000;
            xhr.onload = function () {
                if (xhr.status >= 200 && xhr.status < 300) return resolve(xhr.response);
                var msg = 'HTTP ' + xhr.status;
                try { msg = JSON.parse(new TextDecoder().decode(xhr.response)).error || msg; } catch (e) {}
                reject(new Error(msg));
            };
            xhr.onerror = function () { reject(new Error('The engine is not running')); };
            xhr.ontimeout = function () { reject(new Error('The download took too long')); };
            xhr.send();
        });
    }

    function ping() { return request('GET', '/ping', undefined, 1500); }

    function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    /* Starts the service if it isn't answering, then waits for it (up to ~20 s). */
    function ensure() {
        return ping().catch(function () {
            if (onTV) {
                var pkg = tizen.application.getCurrentApplication().appInfo.packageId;
                try {
                    tizen.application.launchAppControl(
                        new tizen.ApplicationControl('http://tizen.org/appcontrol/operation/service'),
                        pkg + '.Engine', function () {}, function (e) { console.error('Engine launch failed', e); });
                } catch (e) { console.error(e); }
            }
            var tries = 0;
            function again() {
                return ping().catch(function (err) {
                    if (++tries > 40) throw new Error('The torrent engine did not start. Restart the TV and try again.');
                    return wait(500).then(again);
                });
            }
            return again();
        });
    }

    return {
        base: BASE,
        VERSION: '1.1.0',   // the engine this app was built with (tizen/service/lib/server.js)
        ensure: ensure,
        /* GET through the engine, which has no CORS limits. Resolves to parsed JSON, or text. */
        fetch: function (url) { return request('GET', '/fetch?url=' + encodeURIComponent(url), undefined, 30000); },
        /* Any request, with its own method, headers and body, sent by the engine. */
        send: function (url, method, headers, body) {
            return request('POST', '/request', { url: url, method: method || 'GET', headers: headers || {}, body: body }, 30000);
        },
        /* The subtitle inside a .zip at url, as raw bytes (an ArrayBuffer) for the app to decode. */
        unzip: function (url) { return bytes(BASE + '/unzip?url=' + encodeURIComponent(url)); },
        /* A file of an open torrent as raw bytes (for subtitle files). */
        fileBytes: function (id, index) { return bytes(BASE + '/torrents/' + id + '/files/' + index); },
        /* OpenSubtitles' hash of a file in an open torrent (its first and last 64 KB). */
        hash: function (id, index) { return request('GET', '/torrents/' + id + '/files/' + index + '/hash', undefined, 60000); },
        open: function (link, runtimeMinutes) {
            return request('POST', '/torrents', { link: link, runtimeMinutes: runtimeMinutes || undefined }, 100000);
        },
        fileURL: function (id, index) { return BASE + '/torrents/' + id + '/files/' + index; },
        position: function (id, file, seconds, duration) {
            return request('POST', '/torrents/' + id + '/position', { file: file, seconds: seconds, duration: duration }).catch(function () {});
        },
        status: function (id) { return request('GET', '/torrents/' + id + '/status', undefined, 4000); },
        close: function (id) { return request('DELETE', '/torrents/' + id).catch(function () {}); }
    };
})();
