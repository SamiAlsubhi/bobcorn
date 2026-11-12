'use strict';
// Reads a huge JSON array one element at a time, without holding the whole document: each top-level
// object is cut out of the stream and parsed on its own. IPTV providers send 50-100 MB lists.

const StringDecoder = require('string_decoder').StringDecoder;

// onItem(object) for each object in the top-level array.
function ArrayStream(onItem) {
    this.onItem = onItem;
    this.decoder = new StringDecoder('utf8');
    this.depth = 0;
    this.inString = false;
    this.escape = false;
    this.current = null;   // the text of the object being read
}

ArrayStream.prototype.write = function (chunk) {
    const text = typeof chunk === 'string' ? chunk : this.decoder.write(chunk);
    let start = this.current !== null ? 0 : -1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (this.inString) {
            if (this.escape) this.escape = false;
            else if (c === '\\') this.escape = true;
            else if (c === '"') this.inString = false;
            continue;
        }
        if (c === '"') { this.inString = true; continue; }
        if (c === '{' || c === '[') {
            this.depth++;
            if (this.depth === 2 && c === '{') { this.current = ''; start = i; }
        } else if (c === '}' || c === ']') {
            if (this.depth === 2 && c === '}' && this.current !== null) {
                const json = this.current + text.slice(start, i + 1);
                this.current = null;
                start = -1;
                let item = null;
                try { item = JSON.parse(json); } catch (e) { /* skip a broken element */ }
                if (item) this.onItem(item);
            }
            this.depth--;
        }
    }
    if (this.current !== null && start >= 0) this.current += text.slice(start);
};

module.exports = ArrayStream;
