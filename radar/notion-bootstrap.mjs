#!/usr/bin/env node
// radar/notion-bootstrap.mjs
//
// HOST-SIDE, one-time Notion bootstrap for finn's Conference Radar + Topic-Trend loops
// (Features 4 & 5). Runs on Victor's LAPTOP (not in the sandbox) via the runmod script.
//
// It builds ON TOP of the existing event-intelligence Notion (which was bootstrapped from
// nvidia-dev-rel/round-02/event-intelligence/). It does NOT recreate the conference data:
//   • EVENTS DB   = existing "📅 AI Events — Singapore"  (reused; 3 tracking columns ADDED)
//   • SPEAKERS DB = existing "🎤 Speakers — AI Events SG" (read by the loops; untouched)
//   • HUB page    = existing "AI Events Singapore — BD Intelligence Hub" (parent for new DBs)
//
// Why host-side: the in-sandbox Notion MCP has no create_database / schema-patch tool, and
// keeping DB creation + schema changes OFF the agent surface shrinks the prompt-injection
// blast radius (the recurring agent only ever reads/updates ROWS). The host reaches
// api.notion.com directly (no sandbox netns), so a plain fetch with the integration token works.
//
// What it does (all idempotent):
//   1. Resolve the existing EVENTS DB, SPEAKERS DB, and HUB page (by env id, else by search).
//   2. Add 3 cadence-tracking properties to the EVENTS DB (only if missing):
//        "Last checked" (date), "Next check due" (date), "Latest change" (rich_text).
//   3. Create-or-locate two NEW databases under the HUB page:
//        "finn · Topics"           (the trend watchlist; seeded from radar/seed-topics.json)
//        "finn · Trend snapshots"  (the trend time-series)
//   4. Seed Topics (insert only new rows).
//   5. Seed the t=0 Trend baseline ONCE from REAL data — tally each topic's Theme across the
//      UPCOMING events already in the EVENTS DB (skip if snapshots already exist).
//   6. Set "Next check due" = today on every UPCOMING event that has it empty, so the first
//      daily conf-radar run engages the whole forward backlog.
//   7. Print the resolved ids as JSON on stdout (the runmod bakes them into the cron prompts).
//
// Env:
//   NOTION_TOKEN          (required) ntn_... internal-integration secret
//   NOTION_EVENTS_DB      (optional) explicit "AI Events — Singapore" database id
//   NOTION_SPEAKERS_DB    (optional) explicit "Speakers — AI Events SG" database id
//   NOTION_HUB_PAGE_ID    (optional) explicit hub page id (parent for the new DBs)
//   NOTION_VERSION        (optional) default 2022-06-28
//   SEED_DIR              (optional) default = this file's directory
//   TODAY                 (optional) ISO date; default = host today

import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const TOKEN = process.env.NOTION_TOKEN;
const NOTION_VERSION = process.env.NOTION_VERSION || '2022-06-28';
const SEED_DIR = process.env.SEED_DIR || dirname(fileURLToPath(import.meta.url));
const TODAY = process.env.TODAY || new Date().toISOString().slice(0, 10);

const log = (...a) => console.error(...a);            // progress → stderr (stdout = JSON result)
const die = (m) => { log('ERROR:', m); process.exit(1); };
if (!TOKEN) die('NOTION_TOKEN is not set.');

async function notion(method, path, body) {
  const res = await fetch(`https://api.notion.com/v1${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Notion-Version': NOTION_VERSION,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data; try { data = JSON.parse(text); } catch { data = { raw: text }; }
  if (!res.ok) die(`${method} ${path} → HTTP ${res.status}: ${data.message || text}`);
  return data;
}

// --- Notion value helpers ---------------------------------------------------
const rt = (s) => (s == null || s === '') ? { rich_text: [] }
  : { rich_text: [{ text: { content: String(s).slice(0, 1900) } }] };
const title = (s) => ({ title: [{ text: { content: String(s ?? '').slice(0, 1900) } }] });
const sel = (s) => (s == null || s === '') ? { select: null } : { select: { name: String(s) } };
const date = (s) => (s == null || s === '') ? { date: null } : { date: { start: String(s) } };
const num = (n) => ({ number: (n == null || n === '') ? null : Number(n) });
const dateRange = (s, e) => (s == null || s === '') ? { date: null }
  : { date: { start: String(s), ...(e ? { end: String(e) } : {}) } };
const plain = (arr) => (arr || []).map((x) => x.plain_text || x.text?.content || '').join('');
const periodFor = (start) => {
  if (!start) return '';
  const y = start.slice(0, 4); const m = parseInt(start.slice(5, 7), 10) || 1;
  if (['2025', '2026'].includes(y)) return `${y} ${m >= 7 ? 'H2' : 'H1'}`;
  return y; // 2027+ are single-value Period options
};

// --- Resolve an existing object by id or by title search --------------------
async function resolve(kind, envId, titleNeedle) {
  if (envId) { log(`  ${kind}: ${envId} (from env)`); return envId.replace(/-/g, ''); }
  const r = await notion('POST', '/search', {
    query: titleNeedle,
    filter: { value: kind === 'page' ? 'page' : 'database', property: 'object' },
    page_size: 25,
  });
  const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const needle = norm(titleNeedle);
  const hit = (r.results || []).find((o) => {
    const t = kind === 'page'
      ? plain(o.properties?.title?.title || o.properties?.Name?.title || [])
      : plain(o.title || []);
    return norm(t).includes(needle);
  }) || (r.results || [])[0];
  if (!hit) die(`Could not find ${kind} matching "${titleNeedle}" shared with this integration.`);
  log(`  ${kind} "${titleNeedle}": ${hit.id}`);
  return hit.id;
}

// --- Add missing properties to an existing database (non-destructive) --------
async function ensureProps(dbId, props) {
  const db = await notion('GET', `/databases/${dbId}`);
  const have = new Set(Object.keys(db.properties || {}));
  const missing = {};
  for (const [name, schema] of Object.entries(props)) if (!have.has(name)) missing[name] = schema;
  if (!Object.keys(missing).length) { log(`  EVENTS DB already has the tracking columns.`); return; }
  await notion('PATCH', `/databases/${dbId}`, { properties: missing });
  log(`  EVENTS DB: + added ${Object.keys(missing).join(', ')}.`);
}

// --- Create-or-locate a NEW database under the hub page ---------------------
async function ensureDb(parentPageId, def) {
  const r = await notion('POST', '/search', {
    query: def.title, filter: { value: 'database', property: 'object' }, page_size: 25,
  });
  const existing = (r.results || []).find((d) => plain(d.title).trim() === def.title);
  if (existing) { log(`  ✓ found "${def.title}" (${existing.id})`); return existing.id; }
  const created = await notion('POST', '/databases', {
    parent: { type: 'page_id', page_id: parentPageId },
    title: [{ type: 'text', text: { content: def.title } }],
    properties: def.properties,
  });
  log(`  + created "${def.title}" (${created.id})`);
  return created.id;
}

// Iterate all rows of a database (handles pagination), optional filter.
async function* rows(dbId, filter) {
  let cursor;
  do {
    const body = { page_size: 100, ...(filter ? { filter } : {}), ...(cursor ? { start_cursor: cursor } : {}) };
    const r = await notion('POST', `/databases/${dbId}/query`, body);
    for (const row of r.results || []) yield row;
    cursor = r.has_more ? r.next_cursor : null;
  } while (cursor);
}

function loadSeed(name, key) {
  const p = join(SEED_DIR, name);
  if (!existsSync(p)) { log(`  (no ${name}; skipping)`); return []; }
  return JSON.parse(readFileSync(p, 'utf8'))[key] || [];
}

// --- New-DB schemas ---------------------------------------------------------
const TOPICS_DEF = {
  title: 'finn · Topics',
  properties: {
    'Topic': { title: {} },
    'Theme': { rich_text: {} },               // the exact 'Themes' option this maps to ('' = search-only)
    'Aliases': { rich_text: {} },
    'Status': { select: { options: ['Watched', 'Proposed', 'Muted'].map((name) => ({ name })) } },
    'Why it matters': { rich_text: {} },
  },
};
const TRENDS_DEF = {
  title: 'finn · Trend snapshots',
  properties: {
    'Topic': { title: {} },
    'Date': { date: {} },
    'Upcoming events': { number: {} },        // # of UPCOMING events tagged with this topic's Theme
    'Search signal': { select: { options: ['surging', 'steady', 'quiet'].map((name) => ({ name })) } },
    'Score': { number: {} },
    'Delta vs last': { select: { options: ['↑ up', '→ flat', '↓ down'].map((name) => ({ name })) } },
    'Band': { select: { options: ['Emerging', 'Rising', 'Hot', 'Cooling'].map((name) => ({ name })) } },
    'Sources': { rich_text: {} },
    'Note': { rich_text: {} },
  },
};

const bandFor = (n) => n >= 6 ? 'Hot' : n >= 3 ? 'Rising' : 'Emerging';

// --- Seeders ----------------------------------------------------------------
async function seedTopics(dbId) {
  const seeds = loadSeed('seed-topics.json', 'topics');
  if (!seeds.length) return [];
  const seen = new Set();
  for await (const r of rows(dbId)) seen.add(plain(r.properties?.Topic?.title).trim().toLowerCase());
  let added = 0;
  for (const t of seeds) {
    if (seen.has(String(t.topic).trim().toLowerCase())) continue;
    await notion('POST', '/pages', {
      parent: { database_id: dbId },
      properties: {
        'Topic': title(t.topic),
        'Theme': rt(t.theme || ''),
        'Aliases': rt(t.aliases),
        'Status': sel(t.status || 'Watched'),
        'Why it matters': rt(t.why_it_matters),
      },
    });
    added++;
  }
  log(`  Topics: +${added} new (${seen.size} already present).`);
  return seeds;
}

// Tally each topic's Theme across UPCOMING events → the real t=0 baseline.
async function seedTrendBaseline(trendsDb, eventsDb, topicSeeds) {
  for await (const _ of rows(trendsDb)) { log('  Trend baseline: snapshots already exist; skipping.'); return; }
  // Count Themes among upcoming events.
  const counts = new Map();
  let upcoming = 0;
  for await (const ev of rows(eventsDb, { property: 'Status', select: { equals: 'Upcoming' } })) {
    upcoming++;
    for (const opt of ev.properties?.Themes?.multi_select || []) {
      counts.set(opt.name, (counts.get(opt.name) || 0) + 1);
    }
  }
  log(`  Trend baseline: tallying themes across ${upcoming} upcoming events…`);
  let added = 0;
  for (const t of topicSeeds.filter((x) => (x.status || 'Watched') === 'Watched')) {
    const n = t.theme ? (counts.get(t.theme) || 0) : 0;     // search-only topics start at 0
    await notion('POST', '/pages', {
      parent: { database_id: trendsDb },
      properties: {
        'Topic': title(t.topic),
        'Date': date(TODAY),
        'Upcoming events': num(n),
        'Search signal': sel('steady'),
        'Score': num(n),                                     // baseline score = the tally
        'Delta vs last': sel('→ flat'),
        'Band': sel(t.theme ? bandFor(n) : 'Emerging'),
        'Sources': rt('Baseline from "📅 AI Events — Singapore" Themes tally.'),
        'Note': rt(`t=0 baseline ${TODAY}: ${n} upcoming event(s) tagged "${t.theme || '(search-only)'}".`),
      },
    });
    added++;
  }
  log(`  Trend baseline: +${added} snapshot rows from real Theme tallies.`);
}

// Seed curated APAC (ex-Singapore) events as Status='Proposed' — Victor approves in the digest.
async function seedApacProposed(eventsDb) {
  if ((process.env.SKIP_APAC || '0') === '1') { log('  APAC proposals: skipped (SKIP_APAC=1).'); return; }
  const seeds = loadSeed('seed-conferences-apac.json', 'conferences');
  if (!seeds.length) return;
  const seen = new Set();
  for await (const r of rows(eventsDb)) seen.add(plain(r.properties?.Event?.title).trim().toLowerCase());
  let added = 0;
  for (const c of seeds) {
    if (seen.has(String(c.name).trim().toLowerCase())) continue;
    await notion('POST', '/pages', {
      parent: { database_id: eventsDb },
      properties: {
        'Event': title(c.name),
        'Tier': sel(c.tier),
        'Status': sel('Proposed'),                          // auto-created select option
        'Date': dateRange(c.event_start, c.event_end),
        'Period': sel(periodFor(c.event_start)),
        // Notion select options cannot contain commas → swap ", " for " · ".
        'Venue': sel(String(c.venue || '').replace(/,\s*/g, ' · ')),

        'Organiser': rt(c.organiser),
        'Source': c.source ? { url: c.source } : { url: null },
        'NVIDIA Angle': rt(c.nvidia_angle),
        'Themes': { multi_select: (c.themes || []).map((name) => ({ name })) },
        'Next check due': date(TODAY),
        'Latest change': rt(`Proposed by Phase-0 APAC research on ${TODAY} (date confidence: ${c.date_confidence}). Confirm + set Status=Upcoming to track.`),
      },
    });
    added++;
  }
  log(`  APAC proposals: +${added} new Status=Proposed (review them in the weekly digest).`);
}

// Prime "Next check due" on upcoming events so the first daily run engages them.
async function primeNextDue(eventsDb) {
  let primed = 0;
  for await (const ev of rows(eventsDb, { property: 'Status', select: { equals: 'Upcoming' } })) {
    const due = ev.properties?.['Next check due']?.date?.start;
    if (due) continue;
    await notion('PATCH', `/pages/${ev.id}`, { properties: { 'Next check due': date(TODAY) } });
    primed++;
  }
  log(`  Primed "Next check due"=${TODAY} on ${primed} upcoming event(s).`);
}

// --- Main -------------------------------------------------------------------
log('Resolving existing event-intelligence Notion objects…');
const eventsDb = await resolve('database', process.env.NOTION_EVENTS_DB, 'AI Events Singapore');
const speakersDb = await resolve('database', process.env.NOTION_SPEAKERS_DB, 'Speakers AI Events SG');
const hubPage = await resolve('page', process.env.NOTION_HUB_PAGE_ID, 'AI Events Singapore BD Intelligence Hub');

log('Adding cadence-tracking columns to the EVENTS DB…');
await ensureProps(eventsDb, {
  'Last checked': { date: {} },
  'Next check due': { date: {} },
  'Latest change': { rich_text: {} },
});

log('Ensuring the new trend databases under the hub page…');
const topicsDb = await ensureDb(hubPage, TOPICS_DEF);
const trendsDb = await ensureDb(hubPage, TRENDS_DEF);

log('Seeding…');
const topicSeeds = await seedTopics(topicsDb);
await seedTrendBaseline(trendsDb, eventsDb, topicSeeds);
await seedApacProposed(eventsDb);
await primeNextDue(eventsDb);

process.stdout.write(JSON.stringify({
  events_db: eventsDb,
  speakers_db: speakersDb,
  hub_page: hubPage,
  topics_db: topicsDb,
  trends_db: trendsDb,
}) + '\n');
log('Done.');
