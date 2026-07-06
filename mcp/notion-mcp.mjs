#!/usr/bin/env node
// notion-mcp.mjs
//
// A tiny, zero-dependency Model Context Protocol (MCP) server that gives the
// finn agent access to a Notion workspace via the Notion REST API. It uses a
// Notion INTERNAL INTEGRATION TOKEN (a static bearer token, env NOTION_TOKEN) —
// NOT the hosted Notion MCP (mcp.notion.com), which is OAuth-only with a human
// browser flow and so can't drive a headless, Telegram-reached sandbox.
//
// READ tools are always on (search, get_page, get_page_content, query_database,
// get_database, whoami, diagnostics). WRITE tools (create_page, update_page,
// append_blocks) are an explicit opt-in via NOTION_WRITE=1 AND require an
// integration token that has write/insert access in Notion.
//
// WHY zero-dep + plain fetch + the re-exec below (see docs/LEARNINGS.md
// §1, the egress trap): OpenClaw spawns MCP servers with a SCRUBBED env inside the
// gateway's PROXY-ONLY netns (the proxy does TLS interception). A plain fetch()
// to api.notion.com therefore needs HTTPS_PROXY + NODE_EXTRA_CA_CERTS at STARTUP,
// which aren't in our env — so we re-exec ourselves with them inherited from the
// gateway parent. Mirrors mcp/ms-calendar-mcp.mjs exactly.
//
// MCP transport: newline-delimited JSON-RPC 2.0 over stdio. stdout is the protocol
// channel — ALL logging goes to stderr. The token is read from process.env then a
// dotenv-style file (NOTION_ENV_FILE, default /sandbox/.config/notion.env, 0600),
// keeping the secret out of openclaw.json.

import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// --------------------------------------------------------------------------- //
// Egress bootstrap (see docs/LEARNINGS.md §1, the egress trap) — identical to ms-calendar.
// --------------------------------------------------------------------------- //
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
if (!process.env.__NOTION_REEXEC && !(process.env.HTTPS_PROXY || process.env.https_proxy)) {
  let pid = process.ppid, src = null;
  for (let i = 0; i < 6 && pid > 1 && !src; i++) {
    const e = readEnvOf(pid);
    if (e && (e.HTTPS_PROXY || e.https_proxy || e.HTTP_PROXY || e.http_proxy)) src = e;
    pid = ppidOf(pid);
  }
  if (src) {
    const proxy = src.HTTPS_PROXY || src.https_proxy || src.HTTP_PROXY || src.http_proxy;
    process.stderr.write(`[notion] re-exec with gateway egress (proxy=${proxy})\n`);
    const r = spawnSync(process.execPath, [process.argv[1]], {
      stdio: 'inherit',
      env: {
        ...process.env,
        __NOTION_REEXEC: '1',
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
const SERVER_NAME = 'notion';
const SERVER_VERSION = '0.1.0';
const API = 'https://api.notion.com/v1';

function loadEnvFile() {
  const path = process.env.NOTION_ENV_FILE || '/sandbox/.config/notion.env';
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

const TOKEN = cfg('NOTION_TOKEN');
// 2022-06-28 is the stable, widely-documented API version (search/pages/databases).
const NOTION_VERSION = cfg('NOTION_VERSION', '2022-06-28');
// Write tools (create/update/append) are OFF by default — explicit opt-in. The
// integration ALSO needs Insert/Update content capability in Notion, or writes 403.
const WRITE = /^(1|true|yes|on)$/i.test(String(cfg('NOTION_WRITE', '')));

const log = (...a) => process.stderr.write(`[${SERVER_NAME}] ${a.join(' ')}\n`);

// --------------------------------------------------------------------------- //
// Notion REST helper (static bearer token — no OAuth refresh dance)
// --------------------------------------------------------------------------- //
async function notion(method, path, { query, body } = {}) {
  if (!TOKEN) {
    throw new Error(
      'Missing NOTION_TOKEN. Set it in the environment or /sandbox/.config/notion.env. ' +
      'Create an internal integration at notion.so/profile/integrations, copy the secret, ' +
      'and share the pages/databases you want finn to access with that integration.'
    );
  }
  const url = new URL(API + path);
  if (query) for (const [k, v] of Object.entries(query)) if (v != null) url.searchParams.set(k, String(v));
  const opts = {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Notion-Version': NOTION_VERSION,
      Accept: 'application/json',
    },
  };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(url, opts);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = data.message || data.code || `HTTP ${r.status}`;
    let hint = '';
    if (r.status === 401) hint = ' — token invalid/expired; re-check NOTION_TOKEN.';
    else if (r.status === 403) hint = ' — the integration lacks access. Share the page/database with the integration in Notion (and grant write capability for create/update).';
    else if (r.status === 404) hint = ' — not found, or the integration has not been shared on that page/database.';
    throw new Error(`Notion ${method} ${path} failed: ${msg}${hint}`);
  }
  return data;
}

// --------------------------------------------------------------------------- //
// Small render helpers (Notion's data model → compact readable text)
// --------------------------------------------------------------------------- //
const rich = (arr) => (Array.isArray(arr) ? arr.map((t) => t.plain_text ?? t.text?.content ?? '').join('') : '');

// A page's title lives in whichever property has type 'title'.
function pageTitle(page) {
  const props = page.properties || {};
  for (const p of Object.values(props)) if (p?.type === 'title') return rich(p.title) || '(untitled)';
  return '(untitled)';
}
function objTitle(obj) {
  if (obj.object === 'database') return rich(obj.title) || '(untitled database)';
  if (obj.object === 'page') return pageTitle(obj);
  return obj.id;
}

// Summarise a page's non-title properties compactly (for query_database rows).
function propSummary(page) {
  const out = [];
  for (const [name, p] of Object.entries(page.properties || {})) {
    if (p.type === 'title') continue;
    let v = '';
    switch (p.type) {
      case 'rich_text': v = rich(p.rich_text); break;
      case 'select': v = p.select?.name || ''; break;
      case 'multi_select': v = (p.multi_select || []).map((s) => s.name).join(', '); break;
      case 'status': v = p.status?.name || ''; break;
      case 'number': v = p.number != null ? String(p.number) : ''; break;
      case 'checkbox': v = p.checkbox ? 'yes' : 'no'; break;
      case 'date': v = p.date?.start ? (p.date.end ? `${p.date.start}→${p.date.end}` : p.date.start) : ''; break;
      case 'url': v = p.url || ''; break;
      case 'email': v = p.email || ''; break;
      case 'phone_number': v = p.phone_number || ''; break;
      case 'people': v = (p.people || []).map((x) => x.name).filter(Boolean).join(', '); break;
      case 'relation': v = `${(p.relation || []).length} linked`; break;
      default: v = '';
    }
    if (v) out.push(`${name}: ${v}`);
  }
  return out.join(' | ');
}

// Render a content block to one line of text.
function blockText(b) {
  const t = b.type;
  const body = b[t];
  const txt = body?.rich_text ? rich(body.rich_text) : '';
  switch (t) {
    case 'heading_1': return `# ${txt}`;
    case 'heading_2': return `## ${txt}`;
    case 'heading_3': return `### ${txt}`;
    case 'bulleted_list_item': return `- ${txt}`;
    case 'numbered_list_item': return `1. ${txt}`;
    case 'to_do': return `[${body?.checked ? 'x' : ' '}] ${txt}`;
    case 'quote': return `> ${txt}`;
    case 'code': return '```' + (body?.language || '') + '\n' + txt + '\n```';
    case 'callout': return `(callout) ${txt}`;
    case 'toggle': return `▸ ${txt}`;
    case 'divider': return '---';
    case 'child_page': return `[page] ${b.child_page?.title || ''}`;
    case 'child_database': return `[database] ${b.child_database?.title || ''}`;
    default: return txt || (b.has_children ? `(${t}, has children)` : `(${t})`);
  }
}

// Build Notion paragraph blocks from plain text (one block per non-empty line;
// Notion caps a single rich_text run at 2000 chars).
function textToBlocks(text) {
  return String(text)
    .split('\n')
    .filter((l) => l.trim().length)
    .map((line) => ({
      object: 'block',
      type: 'paragraph',
      paragraph: { rich_text: [{ type: 'text', text: { content: line.slice(0, 2000) } }] },
    }));
}

// --------------------------------------------------------------------------- //
// Tool implementations — read
// --------------------------------------------------------------------------- //
async function search(args = {}) {
  const page_size = Math.min(Math.max(parseInt(args.limit ?? 10, 10) || 10, 1), 50);
  const body = { page_size };
  if (args.query) body.query = String(args.query);
  if (args.type === 'page' || args.type === 'database') body.filter = { value: args.type, property: 'object' };
  const data = await notion('POST', '/search', { body });
  const results = data.results || [];
  if (!results.length) return `No results${args.query ? ` for "${args.query}"` : ''}. (The integration only sees pages/databases shared with it.)`;
  const lines = results.map((o, i) => {
    const kind = o.object === 'database' ? 'DB ' : 'page';
    return `${i + 1}. [${kind}] ${objTitle(o)}\n    id: ${o.id}${o.url ? `\n    ${o.url}` : ''}`;
  });
  return `${results.length} result(s)${data.has_more ? ' (more available)' : ''}:\n` + lines.join('\n');
}

async function getPage(args = {}) {
  if (!args.page_id) throw new Error('page_id is required (from search).');
  const page = await notion('GET', `/pages/${encodeURIComponent(args.page_id)}`);
  const props = propSummary(page);
  return [
    `${pageTitle(page)}${page.archived ? ' [archived]' : ''}`,
    props ? `properties: ${props}` : null,
    page.url ? `url: ${page.url}` : null,
    `id: ${page.id}`,
    'Tip: use get_page_content to read the page body.',
  ].filter(Boolean).join('\n');
}

async function getPageContent(args = {}) {
  if (!args.page_id) throw new Error('page_id (or block id) is required.');
  const page_size = Math.min(Math.max(parseInt(args.limit ?? 50, 10) || 50, 1), 100);
  const data = await notion('GET', `/blocks/${encodeURIComponent(args.page_id)}/children`, { query: { page_size } });
  const blocks = data.results || [];
  if (!blocks.length) return '(no content blocks on this page)';
  const text = blocks.map(blockText).join('\n');
  return text + (data.has_more ? '\n… (more blocks; raise limit or page via the API)' : '');
}

async function getDatabase(args = {}) {
  if (!args.database_id) throw new Error('database_id is required (from search).');
  const db = await notion('GET', `/databases/${encodeURIComponent(args.database_id)}`);
  const schema = Object.entries(db.properties || {}).map(([n, p]) => `${n} (${p.type})`).join(', ');
  return [
    `Database: ${rich(db.title) || '(untitled)'}`,
    schema ? `properties: ${schema}` : null,
    db.url ? `url: ${db.url}` : null,
    `id: ${db.id}`,
    'Tip: use query_database to list rows.',
  ].filter(Boolean).join('\n');
}

async function queryDatabase(args = {}) {
  if (!args.database_id) throw new Error('database_id is required (from search/get_database).');
  const page_size = Math.min(Math.max(parseInt(args.limit ?? 10, 10) || 10, 1), 50);
  const body = { page_size };
  if (args.filter && typeof args.filter === 'object') body.filter = args.filter;   // raw Notion filter object
  if (Array.isArray(args.sorts)) body.sorts = args.sorts;
  const data = await notion('POST', `/databases/${encodeURIComponent(args.database_id)}/query`, { body });
  const rows = data.results || [];
  if (!rows.length) return 'No rows matched.';
  const lines = rows.map((pg, i) => {
    const summary = propSummary(pg);
    return `${i + 1}. ${pageTitle(pg)}${summary ? ` — ${summary}` : ''}\n    id: ${pg.id}`;
  });
  return `${rows.length} row(s)${data.has_more ? ' (more available)' : ''}:\n` + lines.join('\n');
}

async function whoami() {
  const me = await notion('GET', '/users/me');
  const ws = me.bot?.workspace_name;
  return `Authenticated as integration "${me.name || me.id}"${ws ? ` in workspace "${ws}"` : ''} (bot id ${me.id}).`;
}

async function diagnostics() {
  const report = [];
  report.push(`server: ${SERVER_NAME} v${SERVER_VERSION} (node ${process.version})`);
  report.push(`token: ${TOKEN ? 'set' : 'MISSING'} | api-version: ${NOTION_VERSION}`);
  report.push(`mode: ${WRITE ? 'READ-WRITE (create/update/append enabled)' : 'read-only'}`);
  try {
    const r = await fetch(`${API}/users/me`, { headers: { 'Notion-Version': NOTION_VERSION } });
    report.push(`egress api.notion.com: HTTP ${r.status} (reachable)`); // 401 here = reachable but unauthenticated, which is fine
  } catch (e) {
    report.push(`egress api.notion.com: FAIL ${e.code || e.message} — is the notion network policy applied?`);
  }
  if (TOKEN) {
    try { report.push(await whoami()); }
    catch (e) { report.push(`auth: FAIL — ${e.message}`); }
  } else {
    report.push('auth: skipped (no NOTION_TOKEN yet — the egress check above still validates the policy)');
  }
  return report.join('\n');
}

// --------------------------------------------------------------------------- //
// Tool implementations — write (only registered when NOTION_WRITE is enabled)
// --------------------------------------------------------------------------- //
async function createPage(args = {}) {
  const hasParent = args.parent_page_id || args.parent_database_id;
  if (!hasParent) throw new Error('Provide parent_page_id (create a sub-page) or parent_database_id (create a row).');
  const body = { parent: {}, properties: {} };
  if (args.parent_database_id) {
    body.parent = { database_id: args.parent_database_id };
    // For a DB parent, the title property name varies; accept an explicit
    // `properties` object, else default a "Name" title (common default).
    if (args.properties && typeof args.properties === 'object') body.properties = args.properties;
    if (args.title) body.properties[args.title_property || 'Name'] = { title: [{ text: { content: String(args.title) } }] };
    if (!Object.keys(body.properties).length) throw new Error('For a database row, pass `title` (+ optional title_property) or a raw `properties` object.');
  } else {
    body.parent = { page_id: args.parent_page_id };
    body.properties = { title: { title: [{ text: { content: String(args.title || 'Untitled') } }] } };
  }
  if (args.content) body.children = textToBlocks(args.content);
  const page = await notion('POST', '/pages', { body });
  return `✅ Created page "${pageTitle(page)}"\n    id: ${page.id}${page.url ? `\n    ${page.url}` : ''}`;
}

async function updatePage(args = {}) {
  if (!args.page_id) throw new Error('page_id is required.');
  const body = {};
  if (args.properties && typeof args.properties === 'object') body.properties = args.properties;
  if (args.title) {
    // Update the title property (assumes a top-level "title"-typed prop; pass
    // `properties` directly for databases with a custom title property name).
    body.properties = body.properties || {};
    body.properties[args.title_property || 'title'] = { title: [{ text: { content: String(args.title) } }] };
  }
  if (args.archived != null) body.archived = !!args.archived;
  if (!Object.keys(body).length) throw new Error('Provide `title`, a `properties` object, and/or `archived`.');
  const page = await notion('PATCH', `/pages/${encodeURIComponent(args.page_id)}`, { body });
  return `✅ Updated page "${pageTitle(page)}"${page.archived ? ' [archived]' : ''}\n    id: ${page.id}`;
}

async function appendBlocks(args = {}) {
  if (!args.page_id) throw new Error('page_id (or block id) is required.');
  if (!args.content) throw new Error('content (text to append as paragraphs) is required.');
  const children = textToBlocks(args.content);
  if (!children.length) throw new Error('content had no non-empty lines.');
  await notion('PATCH', `/blocks/${encodeURIComponent(args.page_id)}/children`, { body: { children } });
  return `✅ Appended ${children.length} paragraph block(s) to ${args.page_id}.`;
}

// --------------------------------------------------------------------------- //
// Tool registry
// --------------------------------------------------------------------------- //
const READ_TOOLS = [
  {
    name: 'search',
    description: 'Search the Notion workspace for pages and databases the integration can access. Returns titles + ids (ids feed the other tools). Read-only.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Text to search titles for. Omit to list everything shared with the integration.' },
        type: { type: 'string', enum: ['page', 'database'], description: 'Restrict to pages or databases. Optional.' },
        limit: { type: 'integer', description: 'Max results (1–50). Default 10.' },
      },
    },
    run: search,
  },
  {
    name: 'get_page',
    description: 'Get a page\'s title, properties, and url by id. Use get_page_content for the body text. Read-only.',
    inputSchema: { type: 'object', properties: { page_id: { type: 'string', description: 'Page id (from search).' } }, required: ['page_id'] },
    run: getPage,
  },
  {
    name: 'get_page_content',
    description: 'Read the content blocks (body text) of a page, rendered as text. Read-only.',
    inputSchema: {
      type: 'object',
      properties: {
        page_id: { type: 'string', description: 'Page id (or a block id) whose children to read.' },
        limit: { type: 'integer', description: 'Max blocks (1–100). Default 50.' },
      },
      required: ['page_id'],
    },
    run: getPageContent,
  },
  {
    name: 'get_database',
    description: 'Get a database\'s title and property schema by id. Read-only.',
    inputSchema: { type: 'object', properties: { database_id: { type: 'string', description: 'Database id (from search).' } }, required: ['database_id'] },
    run: getDatabase,
  },
  {
    name: 'query_database',
    description: 'List rows (pages) in a Notion database, with their key properties. Optional raw Notion `filter`/`sorts`. Read-only.',
    inputSchema: {
      type: 'object',
      properties: {
        database_id: { type: 'string', description: 'Database id (from search/get_database).' },
        filter: { type: 'object', description: 'Optional raw Notion filter object (see Notion API docs).' },
        sorts: { type: 'array', items: { type: 'object' }, description: 'Optional raw Notion sorts array.' },
        limit: { type: 'integer', description: 'Max rows (1–50). Default 10.' },
      },
      required: ['database_id'],
    },
    run: queryDatabase,
  },
  { name: 'whoami', description: 'Show which Notion integration/workspace the tools are authenticated as.', inputSchema: { type: 'object', properties: {} }, run: whoami },
  { name: 'diagnostics', description: 'Self-test: token presence, read/write mode, egress to api.notion.com, and auth. Use this first if Notion tools fail.', inputSchema: { type: 'object', properties: {} }, run: diagnostics },
];

const WRITE_TOOLS = [
  {
    name: 'create_page',
    description: 'Create a new Notion page — either a sub-page under a parent page, or a row in a database. Requires write mode.',
    inputSchema: {
      type: 'object',
      properties: {
        parent_page_id: { type: 'string', description: 'Create a sub-page under this page id.' },
        parent_database_id: { type: 'string', description: 'Create a row in this database id (instead of parent_page_id).' },
        title: { type: 'string', description: 'Page/row title.' },
        title_property: { type: 'string', description: 'For a database row whose title column is not "Name", its property name.' },
        content: { type: 'string', description: 'Optional body text — each line becomes a paragraph block.' },
        properties: { type: 'object', description: 'Advanced: raw Notion properties object for a database row.' },
      },
    },
    run: createPage,
  },
  {
    name: 'update_page',
    description: 'Update a page: change its title, set raw properties, and/or archive it. Only fields you pass change. Requires write mode.',
    inputSchema: {
      type: 'object',
      properties: {
        page_id: { type: 'string', description: 'Page id to update.' },
        title: { type: 'string', description: 'New title.' },
        title_property: { type: 'string', description: 'Title property name if not "title".' },
        properties: { type: 'object', description: 'Advanced: raw Notion properties object.' },
        archived: { type: 'boolean', description: 'Set true to archive (trash) the page, false to restore.' },
      },
      required: ['page_id'],
    },
    run: updatePage,
  },
  {
    name: 'append_blocks',
    description: 'Append text (as paragraph blocks) to the bottom of a page. Requires write mode.',
    inputSchema: {
      type: 'object',
      properties: {
        page_id: { type: 'string', description: 'Page id (or block id) to append to.' },
        content: { type: 'string', description: 'Text to append — each line becomes a paragraph block.' },
      },
      required: ['page_id', 'content'],
    },
    run: appendBlocks,
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

// Graceful drain: finish in-flight calls before exiting if stdin half-closes.
let pending = 0, stdinEnded = false;
function maybeExit() { if (stdinEnded && pending === 0) process.exit(0); }
function track(p) { pending++; Promise.resolve(p).finally(() => { pending--; maybeExit(); }); }

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  while (/^Content-Length:/im.test(buf)) {
    const m = buf.match(/Content-Length:\s*(\d+)\r?\n(?:[^\r\n]*\r?\n)*\r?\n/i);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const headerEnd = m.index + m[0].length;
    if (buf.length < headerEnd + len) return;
    const body = buf.slice(headerEnd, headerEnd + len);
    buf = buf.slice(headerEnd + len);
    try { track(handle(JSON.parse(body))); } catch (e) { log('parse error (lsp):', e.message); }
  }
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
log(`started (api-version=${NOTION_VERSION}, mode=${WRITE ? 'read-write' : 'read-only'}, tools=${TOOLS.length}, token=${TOKEN ? 'present' : 'absent'})`);
