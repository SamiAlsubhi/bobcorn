'use strict';
// Runs the service on a computer, for testing:
//   BOBCORN_CACHE=/tmp/bc node tizen/service/dev.js
// BOBCORN_HOST and BOBCORN_PORT change where it listens.

const service = require('./index');
service.onStart();
process.on('SIGINT', () => {
    service.onExit();
    process.exit(0);
});
