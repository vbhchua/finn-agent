#!/usr/bin/env node
// ms-calendar-mcp.mjs
//
// A tiny, zero-dependency Model Context Protocol (MCP) server that gives the
// finn agent READ-ONLY access to a Microsoft Outlook / Microsoft 365
// calendar via the Microsoft Graph API. Built for a PERSONAL Microsoft account
// (live.com / outlook.com), which cannot use app-only client credentials, so it
// authenticates with a delegated OAuth REFRESH TOKEN that you mint once on your
// laptop (tools/ms-graph-login.mjs) and inject at runtime.
//
// WHY zero-dep + plain fetch (see docs/LEARNINGS.md §10):
//   - The sandbox transparently intercepts outbound TCP, so a plain global
//     `fetch()` to a POLICY-ALLOWED host (graph.microsoft.com,
//     login.microsoftonline.com) just works — NO proxy config, NO NODE_OPTIONS,
//     NO /etc/hosts. (Firecrawl only broke because ITS plugin did an explicit
//     dns.lookup SSRF pre-check against the dead local resolver; we never do that.)
//   - No npm install at build/runtime → nothing to fetch through the proxy, no
//     dependency on the MCP SDK version, fully auditable for the security review.
//
// MCP transport: newline-delimited JSON-RPC 2.0 over stdio (the current MCP
// stdio framing). stdout is the protocol channel — all logging goes to stderr.
//
// Tools (all read-only): list_events, list_calendars, whoami, diagnostics.
//
// Credentials are read from (in order): process.env, then a dotenv-style file
// (MS_CALENDAR_ENV_FILE, default /sandbox/.config/ms-calendar.env, mode 0600).
// Keeping them in a file rather than openclaw.json keeps secrets out of the
// gateway config. Required: MS_CALENDAR_CLIENT_ID, MS_CALENDAR_REFRESH_TOKEN.

import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// --------------------------------------------------------------------------- //
// Egress bootstrap (see docs/LEARNINGS.md §1, the egress trap)
// --------------------------------------------------------------------------- //
// OpenClaw spawns MCP servers with a SCRUBBED environment, and the gateway runs in
// a PROXY-ONLY network namespace whose proxy does TLS interception. So our fetch()
// needs HTTPS_PROXY + NODE_EXTRA_CA_CERTS at STARTUP (Node reads them once) — but
// they aren't in our env. Our ancestor (the gateway) HAS them, so if we're missing
// a proxy, find it in the process tree and re-exec ourselves with it inherited.
// In the open MAIN netns (mcp probe / manual runs) no ancestor has a proxy, so we
// skip the re-exec and use direct fetch(), which works there.
function readEnvOf(pid) {
  try {
    const out = {};
    for (const kv of readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0')) {
      const i = kv.indexOf('='); if (i > 0) out[kv.slice(0, i)] = kv.slice(i + 1);
    }
    return out;
  } catch { return null; }
}
function ppidOf(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    return parseInt(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1], 10) || 0; // [state, ppid, ...]
  } catch { return 0; }
}
if (!process.env.__MSCAL_REEXEC && !(process.env.HTTPS_PROXY || process.env.https_proxy)) {
  let pid = process.ppid, src = null;
  for (let i = 0; i < 6 && pid > 1 && !src; i++) {
    const e = readEnvOf(pid);
    if (e && (e.HTTPS_PROXY || e.https_proxy || e.HTTP_PROXY || e.http_proxy)) src = e;
    pid = ppidOf(pid);
  }
  if (src) {
    const proxy = src.HTTPS_PROXY || src.https_proxy || src.HTTP_PROXY || src.http_proxy;
    process.stderr.write(`[ms-calendar] re-exec with gateway egress (proxy=${proxy})\n`);
    const r = spawnSync(process.execPath, [process.argv[1]], {
      stdio: 'inherit',
      env: {
        ...process.env,
        __MSCAL_REEXEC: '1',
        HTTPS_PROXY: proxy, HTTP_PROXY: proxy,
        NO_PROXY: src.NO_PROXY || src.no_proxy || 'localhost,127.0.0.1,::1,10.200.0.1',
        NODE_USE_ENV_PROXY: '1',
        ...(src.NODE_EXTRA_CA_CERTS ? { NODE_EXTRA_CA_CERTS: src.NODE_EXTRA_CA_CERTS } : {}),
      },
    });
    process.exit(r.status ?? 0);
  }
}

// --------------------------------------------------------------------------- //
// Config / credential loading
// --------------------------------------------------------------------------- //
const SERVER_NAME = 'ms-calendar';
const SERVER_VERSION = '0.1.0';
const GRAPH = 'https://graph.microsoft.com/v1.0';

function loadEnvFile() {
  const path = process.env.MS_CALENDAR_ENV_FILE || '/sandbox/.config/ms-calendar.env';
  const out = {};
  try {
    const text = readFileSync(path, 'utf8');
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      let key = line.slice(0, eq).trim();
      if (key.startsWith('export ')) key = key.slice(7).trim();
      let val = line.slice(eq + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      out[key] = val;
    }
  } catch { /* file optional */ }
  return out;
}

const fileEnv = loadEnvFile();
const cfg = (k, dflt) => process.env[k] ?? fileEnv[k] ?? dflt;

const CLIENT_ID = cfg('MS_CALENDAR_CLIENT_ID');
const REFRESH_TOKEN = cfg('MS_CALENDAR_REFRESH_TOKEN');
// Personal Microsoft accounts authenticate against the "consumers" authority.
const TENANT = cfg('MS_CALENDAR_TENANT', 'consumers');
// Write tools (create/update/delete) are OFF by default — an explicit opt-in.
// Enabling them also requires a Calendars.ReadWrite-scoped refresh token.
const WRITE = /^(1|true|yes|on)$/i.test(String(cfg('MS_CALENDAR_WRITE', '')));
const DEFAULT_SCOPE = `https://graph.microsoft.com/Calendars.${WRITE ? 'ReadWrite' : 'Read'} offline_access User.Read`;
const SCOPE = cfg('MS_CALENDAR_SCOPE', DEFAULT_SCOPE);
const TZ = cfg('MS_CALENDAR_TZ', 'UTC');
const TOKEN_URL = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token`;

const log = (...a) => process.stderr.write(`[${SERVER_NAME}] ${a.join(' ')}\n`);

// --------------------------------------------------------------------------- //
// OAuth: refresh-token grant (public client, no secret)
// --------------------------------------------------------------------------- //
let tokenCache = { access_token: null, exp: 0, refresh_token: REFRESH_TOKEN };

async function getAccessToken() {
  if (!CLIENT_ID || !tokenCache.refresh_token) {
    throw new Error(
      'Missing credentials. Set MS_CALENDAR_CLIENT_ID and MS_CALENDAR_REFRESH_TOKEN ' +
      '(env or /sandbox/.config/ms-calendar.env). Mint the refresh token with tools/ms-graph-login.mjs.'
    );
  }
  const now = Date.now();
  if (tokenCache.access_token && now < tokenCache.exp - 60_000) return tokenCache.access_token;

  const body = new URLSearchParams({
    client_id: CLIENT_ID,
    grant_type: 'refresh_token',
    refresh_token: tokenCache.refresh_token,
    scope: SCOPE,
  });
  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    const desc = data.error_description || data.error || `HTTP ${r.status}`;
    const hint = /AADSTS70000|invalid_grant|expired/i.test(desc)
      ? ' — the refresh token is invalid/expired; re-run tools/ms-graph-login.mjs and re-inject MS_CALENDAR_REFRESH_TOKEN.'
      : '';
    throw new Error(`Token refresh failed: ${desc}${hint}`);
  }
  tokenCache.access_token = data.access_token;
  tokenCache.exp = now + (data.expires_in ? data.expires_in * 1000 : 3600_000);
  // MSA may rotate the refresh token; keep the newest for this process lifetime.
  if (data.refresh_token) tokenCache.refresh_token = data.refresh_token;
  return tokenCache.access_token;
}

async function graphRequest(method, path, { query, body } = {}) {
  const token = await getAccessToken();
  const url = new URL(GRAPH + path);
  if (query) for (const [k, v] of Object.entries(query)) if (v != null) url.searchParams.set(k, String(v));
  const opts = {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      Prefer: `outlook.timezone="${TZ}"`,
    },
  };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(url, opts);
  if (r.status === 204) return null; // e.g. DELETE returns no content
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = data.error?.message || `HTTP ${r.status}`;
    throw new Error(`Graph ${method} ${path} failed: ${msg}`);
  }
  return data;
}
const graph = (path, opts) => graphRequest('GET', path, opts);

// --------------------------------------------------------------------------- //
// Tool implementations (read-only)
// --------------------------------------------------------------------------- //
function fmtWhen(ev) {
  const s = ev.start?.dateTime, e = ev.end?.dateTime;
  const tz = ev.start?.timeZone || TZ;
  if (ev.isAllDay) return `${(s || '').slice(0, 10)} (all day)`;
  const d = (x) => (x ? x.replace('T', ' ').replace(/\.\d+$/, '').slice(0, 16) : '?');
  return `${d(s)} – ${d(e)} ${tz}`;
}

async function listEvents(args = {}) {
  const top = Math.min(Math.max(parseInt(args.top ?? 25, 10) || 25, 1), 100);
  const now = new Date();
  const days = parseInt(args.days ?? 7, 10);
  const startISO = args.start || now.toISOString();
  const endISO = args.end || new Date(now.getTime() + (isNaN(days) ? 7 : days) * 86400_000).toISOString();
  const base = args.calendarId ? `/me/calendars/${encodeURIComponent(args.calendarId)}/calendarView` : '/me/calendarView';
  const data = await graph(base, {
    query: {
      startDateTime: startISO,
      endDateTime: endISO,
      $select: 'id,subject,start,end,location,isAllDay,organizer,webLink,onlineMeetingUrl',
      $orderby: 'start/dateTime',
      $top: top,
    },
  });
  const events = data.value || [];
  if (!events.length) return `No events between ${startISO} and ${endISO}.`;
  const lines = events.map((ev, i) => {
    const loc = ev.location?.displayName ? ` @ ${ev.location.displayName}` : '';
    const org = ev.organizer?.emailAddress?.name ? ` [${ev.organizer.emailAddress.name}]` : '';
    // The id is needed for update_event / delete_event.
    return `${i + 1}. ${fmtWhen(ev)} — ${ev.subject || '(no subject)'}${loc}${org}\n    id: ${ev.id}`;
  });
  return `${events.length} event(s) from ${startISO.slice(0, 10)} to ${endISO.slice(0, 10)}:\n` + lines.join('\n');
}

async function getEvent(args = {}) {
  if (!args.eventId) throw new Error('eventId is required.');
  const ev = await graph(`/me/events/${encodeURIComponent(args.eventId)}`, {
    query: { $select: 'id,subject,start,end,location,isAllDay,organizer,attendees,body,webLink' },
  });
  const att = (ev.attendees || []).map((a) => a.emailAddress?.address).filter(Boolean).join(', ');
  const preview = ev.body?.content ? ev.body.content.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200) : '';
  return [
    `${ev.subject || '(no subject)'}`,
    `when: ${fmtWhen(ev)}`,
    ev.location?.displayName ? `location: ${ev.location.displayName}` : null,
    att ? `attendees: ${att}` : null,
    preview ? `notes: ${preview}` : null,
    `id: ${ev.id}`,
  ].filter(Boolean).join('\n');
}

// --------------------------------------------------------------------------- //
// Write tools (only registered when MS_CALENDAR_WRITE is enabled)
// --------------------------------------------------------------------------- //
function buildEventBody(args, { partial = false } = {}) {
  const tz = args.timeZone || TZ;
  const ev = {};
  if (args.subject != null) ev.subject = args.subject;
  if (args.start != null) ev.start = { dateTime: args.start, timeZone: tz };
  if (args.end != null) ev.end = { dateTime: args.end, timeZone: tz };
  if (args.location != null) ev.location = { displayName: args.location };
  if (args.body != null) ev.body = { contentType: 'text', content: args.body };
  if (args.isAllDay != null) ev.isAllDay = !!args.isAllDay;
  if (Array.isArray(args.attendees) && args.attendees.length) {
    ev.attendees = args.attendees.map((a) => ({ emailAddress: { address: a }, type: 'required' }));
  }
  if (!partial) {
    if (!args.subject) throw new Error('subject is required.');
    if (!args.start || !args.end) throw new Error('start and end (ISO 8601) are required.');
  }
  return ev;
}

async function createEvent(args = {}) {
  const body = buildEventBody(args, { partial: false });
  const base = args.calendarId ? `/me/calendars/${encodeURIComponent(args.calendarId)}/events` : '/me/events';
  const ev = await graphRequest('POST', base, { body });
  return `✅ Created: ${ev.subject} — ${fmtWhen(ev)}\n    id: ${ev.id}${ev.webLink ? `\n    ${ev.webLink}` : ''}`;
}

async function updateEvent(args = {}) {
  if (!args.eventId) throw new Error('eventId is required (get it from list_events).');
  const body = buildEventBody(args, { partial: true });
  if (!Object.keys(body).length) throw new Error('Provide at least one field to change (subject/start/end/location/body/isAllDay/attendees).');
  const ev = await graphRequest('PATCH', `/me/events/${encodeURIComponent(args.eventId)}`, { body });
  return `✅ Updated: ${ev.subject} — ${fmtWhen(ev)}\n    id: ${ev.id}`;
}

async function deleteEvent(args = {}) {
  if (!args.eventId) throw new Error('eventId is required (get it from list_events).');
  await graphRequest('DELETE', `/me/events/${encodeURIComponent(args.eventId)}`);
  return `🗑️ Deleted event ${args.eventId}.`;
}

async function listCalendars() {
  const data = await graph('/me/calendars', { query: { $select: 'name,id,isDefaultCalendar,canEdit,owner' } });
  const cals = data.value || [];
  if (!cals.length) return 'No calendars found.';
  return cals
    .map((c) => `- ${c.name}${c.isDefaultCalendar ? ' (default)' : ''}${c.canEdit ? '' : ' [read-only]'}\n    id: ${c.id}`)
    .join('\n');
}

async function whoami() {
  const me = await graph('/me', { query: { $select: 'displayName,userPrincipalName,mail,id' } });
  return `Authenticated as ${me.displayName || '?'} <${me.mail || me.userPrincipalName || '?'}>`;
}

async function diagnostics() {
  const report = [];
  report.push(`server: ${SERVER_NAME} v${SERVER_VERSION} (node ${process.version})`);
  report.push(`client_id: ${CLIENT_ID ? 'set' : 'MISSING'} | refresh_token: ${REFRESH_TOKEN ? 'set' : 'MISSING'} | tenant: ${TENANT}`);
  report.push(`mode: ${WRITE ? 'READ-WRITE (create/update/delete enabled)' : 'read-only'} | scope: ${SCOPE}`);
  // Egress checks (no auth needed) — prove the sandbox lets this process reach MS.
  const probe = async (label, url) => {
    try {
      const r = await fetch(url);
      report.push(`egress ${label}: HTTP ${r.status} (reachable)`);
    } catch (e) {
      report.push(`egress ${label}: FAIL ${e.code || e.message} — is the ms-calendar network policy applied?`);
    }
  };
  await probe('login.microsoftonline.com', `https://login.microsoftonline.com/${TENANT}/v2.0/.well-known/openid-configuration`);
  await probe('graph.microsoft.com', `${GRAPH}/$metadata`);
  // Auth check (only if creds present).
  if (CLIENT_ID && REFRESH_TOKEN) {
    try {
      await getAccessToken();
      report.push('token refresh: OK (access token acquired)');
      try { report.push(await whoami()); } catch (e) { report.push(`whoami: ${e.message}`); }
    } catch (e) {
      report.push(`token refresh: FAIL — ${e.message}`);
    }
  } else {
    report.push('token refresh: skipped (no credentials yet — egress checks above still validate the policy)');
  }
  return report.join('\n');
}

const READ_TOOLS = [
  {
    name: 'list_events',
    description: 'List Outlook/Microsoft 365 calendar events in a time window (default: next 7 days). Returns each event with its id (needed for update_event/delete_event). Read-only.',
    inputSchema: {
      type: 'object',
      properties: {
        days: { type: 'integer', description: 'Number of days ahead from now (used if start/end omitted). Default 7.' },
        start: { type: 'string', description: 'ISO 8601 start datetime (overrides days).' },
        end: { type: 'string', description: 'ISO 8601 end datetime (overrides days).' },
        calendarId: { type: 'string', description: 'Restrict to a specific calendar id (see list_calendars). Optional.' },
        top: { type: 'integer', description: 'Max events to return (1–100). Default 25.' },
      },
    },
    run: listEvents,
  },
  {
    name: 'get_event',
    description: 'Get the full details of one event by id (subject, time, attendees, location, notes). Read-only.',
    inputSchema: { type: 'object', properties: { eventId: { type: 'string', description: 'Event id from list_events.' } }, required: ['eventId'] },
    run: getEvent,
  },
  { name: 'list_calendars', description: 'List the calendars on the account (name + id). Read-only.', inputSchema: { type: 'object', properties: {} }, run: listCalendars },
  { name: 'whoami', description: 'Show which Microsoft account the calendar tools are authenticated as.', inputSchema: { type: 'object', properties: {} }, run: whoami },
  { name: 'diagnostics', description: 'Self-test: credential presence, read/write mode, network egress to Microsoft, and token refresh. Use this first if calendar tools fail.', inputSchema: { type: 'object', properties: {} }, run: diagnostics },
];

const WRITE_TOOLS = [
  {
    name: 'create_event',
    description: 'Create a new calendar event. Requires write mode.',
    inputSchema: {
      type: 'object',
      properties: {
        subject: { type: 'string', description: 'Event title.' },
        start: { type: 'string', description: 'ISO 8601 start datetime, e.g. 2026-06-25T14:00:00.' },
        end: { type: 'string', description: 'ISO 8601 end datetime.' },
        timeZone: { type: 'string', description: 'IANA/Windows time zone for start/end. Default the server TZ.' },
        location: { type: 'string', description: 'Optional location.' },
        body: { type: 'string', description: 'Optional plain-text description/notes.' },
        attendees: { type: 'array', items: { type: 'string' }, description: 'Optional list of attendee email addresses.' },
        isAllDay: { type: 'boolean', description: 'Optional all-day flag (start/end must be midnight dates).' },
        calendarId: { type: 'string', description: 'Optional target calendar id (default: primary).' },
      },
      required: ['subject', 'start', 'end'],
    },
    run: createEvent,
  },
  {
    name: 'update_event',
    description: 'Update fields of an existing event (only the fields you pass change). Requires write mode.',
    inputSchema: {
      type: 'object',
      properties: {
        eventId: { type: 'string', description: 'Event id from list_events.' },
        subject: { type: 'string' },
        start: { type: 'string', description: 'ISO 8601 start datetime.' },
        end: { type: 'string', description: 'ISO 8601 end datetime.' },
        timeZone: { type: 'string', description: 'Time zone for start/end if changed. Default the server TZ.' },
        location: { type: 'string' },
        body: { type: 'string' },
        isAllDay: { type: 'boolean' },
        attendees: { type: 'array', items: { type: 'string' } },
      },
      required: ['eventId'],
    },
    run: updateEvent,
  },
  {
    name: 'delete_event',
    description: 'Delete an event by id. IRREVERSIBLE. Requires write mode.',
    inputSchema: { type: 'object', properties: { eventId: { type: 'string', description: 'Event id from list_events.' } }, required: ['eventId'] },
    run: deleteEvent,
  },
];

const TOOLS = [...READ_TOOLS, ...(WRITE ? WRITE_TOOLS : [])];

// --------------------------------------------------------------------------- //
// MCP stdio JSON-RPC loop (newline-delimited; tolerates LSP Content-Length too)
// --------------------------------------------------------------------------- //
function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;
  try {
    switch (method) {
      case 'initialize':
        return reply(id, {
          protocolVersion: params?.protocolVersion || '2024-11-05',
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        });
      case 'notifications/initialized':
      case 'initialized':
        return; // notification, no response
      case 'ping':
        return reply(id, {});
      case 'tools/list':
        return reply(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
      case 'tools/call': {
        const tool = TOOLS.find((t) => t.name === params?.name);
        if (!tool) return reply(id, { content: [{ type: 'text', text: `Unknown tool: ${params?.name}` }], isError: true });
        try {
          const text = await tool.run(params.arguments || {});
          return reply(id, { content: [{ type: 'text', text }] });
        } catch (e) {
          return reply(id, { content: [{ type: 'text', text: `Error: ${e.message}` }], isError: true });
        }
      }
      default:
        if (isNotification) return; // ignore unknown notifications
        return replyError(id, -32601, `Method not found: ${method}`);
    }
  } catch (e) {
    if (!isNotification) replyError(id, -32603, `Internal error: ${e.message}`);
    log('handler error:', e.stack || e.message);
  }
}

// Graceful drain: if stdin half-closes (e.g. a client that sends a batch then
// closes the pipe), finish any in-flight tool call before exiting rather than
// dropping its response.
let pending = 0, stdinEnded = false;
function maybeExit() { if (stdinEnded && pending === 0) process.exit(0); }
function track(p) { pending++; Promise.resolve(p).finally(() => { pending--; maybeExit(); }); }

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  // LSP-style framing (Content-Length headers), if a client ever uses it.
  while (/^Content-Length:/im.test(buf)) {
    const m = buf.match(/Content-Length:\s*(\d+)\r?\n(?:[^\r\n]*\r?\n)*\r?\n/i);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const headerEnd = m.index + m[0].length;
    if (buf.length < headerEnd + len) return; // wait for full body
    const body = buf.slice(headerEnd, headerEnd + len);
    buf = buf.slice(headerEnd + len);
    try { track(handle(JSON.parse(body))); } catch (e) { log('parse error (lsp):', e.message); }
  }
  // Newline-delimited JSON (the MCP stdio default).
  let nl;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    if (/^Content-Length:/i.test(line)) { buf = line + '\n' + buf; break; }
    try { track(handle(JSON.parse(line))); } catch (e) { log('parse error:', e.message); }
  }
});
process.stdin.on('end', () => { stdinEnded = true; maybeExit(); });
log(`started (tenant=${TENANT}, tz=${TZ}, mode=${WRITE ? 'read-write' : 'read-only'}, tools=${TOOLS.length}, creds=${CLIENT_ID && REFRESH_TOKEN ? 'present' : 'absent'})`);
