/* Boot: keys, player, first screen. The engine starts on first use (Engine.ensure). */
(function () {
    'use strict';
    function start() {
        Nav.start();
        Player.init();
        Views.init();
        Engine.ensure().then(function (p) {
            // After an update the TV can keep the old engine running in the background until it restarts.
            if (p && p.version && p.version < Engine.VERSION) Views.toast('Restart the TV to finish updating Bobcorn (engine ' + p.version + ')');
            if (Store.logSharing()) Engine.shareLog(true).catch(function () {});
            // Settings lost with the app's storage (a reinstall, cleared data) come back from the engine's backup;
            // otherwise the backup is refreshed from what's here.
            return Engine.loadSettings().then(function (saved) {
                if (Store.isEmpty() && saved && Object.keys(saved).length && Store.restore(saved)) {
                    Views.reload();
                    Views.toast('Restored your sources and settings');
                } else if (!Store.isEmpty()) Store.backupNow();
            }, function () { /* an engine without backups (older version) */ });
        }, function (e) { Views.toast(e.message); });
        window.addEventListener('unload', function () { Player.stop(); });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
