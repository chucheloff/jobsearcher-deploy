#!/usr/bin/env node
// processed.js — tiny RESP client for the job-search "already-processed" set.
// Stored in Valkey at key `jobsearch:processed` (a SET).
//
// Usage:
//   node processed.js list                # one id per line
//   node processed.js has <job_id>        # exit 0 if member, 1 otherwise
//   node processed.js add <job_id> [...]  # SADD ids; prints count of new adds
//   node processed.js remove <job_id>     # SREM one id; prints 1 or 0
//
// Reaches valkey via the docker network alias `valkey:6379` (no auth).
// Used by the `job-search` and `job-search-reply` skills so dedupe persists
// across days and survives memory.md edits.

const net = require('net');

const HOST = process.env.VALKEY_HOST || 'valkey';
const PORT = parseInt(process.env.VALKEY_PORT || '6379', 10);
const KEY  = process.env.JOBSEARCH_PROCESSED_KEY || 'jobsearch:processed';

function encode(args) {
  let s = `*${args.length}\r\n`;
  for (const a of args) {
    const b = Buffer.from(String(a));
    s += `$${b.length}\r\n${b.toString()}\r\n`;
  }
  return s;
}

// Minimal RESP parser — enough for SADD/SCARD/SMEMBERS/SREM/SISMEMBER replies.
function parse(buf) {
  const t = buf[0];
  if (t === 0x2b /*+*/ || t === 0x2d /*-*/) {
    const i = buf.indexOf('\r\n');
    return { value: buf.slice(1, i).toString(), rest: buf.slice(i + 2) };
  }
  if (t === 0x3a /*:*/) {
    const i = buf.indexOf('\r\n');
    return { value: parseInt(buf.slice(1, i).toString(), 10), rest: buf.slice(i + 2) };
  }
  if (t === 0x24 /*$*/) {
    const i = buf.indexOf('\r\n');
    const len = parseInt(buf.slice(1, i).toString(), 10);
    if (len === -1) return { value: null, rest: buf.slice(i + 2) };
    const body = buf.slice(i + 2, i + 2 + len).toString();
    return { value: body, rest: buf.slice(i + 2 + len + 2) };
  }
  if (t === 0x2a /***/) {
    const i = buf.indexOf('\r\n');
    const n = parseInt(buf.slice(1, i).toString(), 10);
    let rest = buf.slice(i + 2);
    const out = [];
    for (let k = 0; k < n; k++) {
      const r = parse(rest);
      out.push(r.value);
      rest = r.rest;
    }
    return { value: out, rest };
  }
  throw new Error(`unknown RESP type 0x${t.toString(16)} in: ${buf.slice(0, 40).toString()}`);
}

function call(args) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(PORT, HOST);
    let chunks = Buffer.alloc(0);
    sock.on('connect', () => sock.write(encode(args)));
    sock.on('data', d => {
      chunks = Buffer.concat([chunks, d]);
      // Try to parse a complete top-level reply; if successful we're done.
      try {
        const { value } = parse(chunks);
        sock.destroy();
        resolve(value);
      } catch (_) { /* incomplete — wait for more bytes */ }
    });
    sock.on('error', reject);
    sock.setTimeout(5000, () => sock.destroy(new Error('timeout')));
  });
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (!cmd) {
    console.error('usage: node processed.js list|has|add|remove [job_id ...]');
    process.exit(2);
  }
  if (cmd === 'list') {
    const r = await call(['SMEMBERS', KEY]);
    for (const id of (r || []).sort()) console.log(id);
    return;
  }
  if (cmd === 'has') {
    if (!args[0]) { console.error('usage: has <job_id>'); process.exit(2); }
    const r = await call(['SISMEMBER', KEY, args[0]]);
    process.exit(r === 1 ? 0 : 1);
  }
  if (cmd === 'add') {
    if (!args.length) { console.error('usage: add <job_id> [...]'); process.exit(2); }
    const r = await call(['SADD', KEY, ...args]);
    console.log(r);
    return;
  }
  if (cmd === 'remove') {
    if (!args[0]) { console.error('usage: remove <job_id>'); process.exit(2); }
    const r = await call(['SREM', KEY, args[0]]);
    console.log(r);
    return;
  }
  console.error(`unknown cmd: ${cmd}`);
  process.exit(2);
}

main().catch(e => { console.error('error:', e.message); process.exit(1); });
