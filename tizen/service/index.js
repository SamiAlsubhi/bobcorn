'use strict';
// Bobcorn's background service on the TV: a streaming BitTorrent engine with an
// HTTP API on 127.0.0.1:8615. Tizen calls onStart when the app launches it.

let instance = null;

module.exports.onStart = function () {
    if (instance) return;
    // Keep one bad torrent or socket from taking the whole service down.
    process.on('uncaughtException', e => require('./lib/util').log('uncaught:', e && (e.stack || e.message)));
    instance = require('./lib/server').createServer();
    instance.listen();
};

module.exports.onRequest = function () {
    // Launched again while running: nothing to do, the server is up.
};

module.exports.onExit = function () {
    if (instance) instance.close();
    instance = null;
};
