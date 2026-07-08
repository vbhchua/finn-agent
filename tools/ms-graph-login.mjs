#!/usr/bin/env node
// ms-graph-login.mjs
//
// Run this ONCE on YOUR LAPTOP (not in the sandbox) to mint a Microsoft Graph
// REFRESH TOKEN for your personal Microsoft account (live.com / outlook.com),
// using the OAuth 2.0 device-code flow. The sandbox can't do an interactive
// browser sign-in, so we acquire the long-lived refresh token here and inject
// it into finn (see setup-finn.sh's calendar layer).
//
// PREREQUISITE — a free Entra ID (Azure AD) app registration (no admin needed):
//   1. https://entra.microsoft.com  ->  Applications  ->  App registrations  ->  New registration
//        - Supported account types: "Personal Microsoft accounts only"
//          (or "...any org directory and personal Microsoft accounts")
//   2. Authentication  ->  "Allow public client flows"  ->  YES (enables device code)
//   3. API permissions  ->  Microsoft Graph  ->  Delegated:  Calendars.ReadWrite, User.Read, offline_access
//        - Calendars.ReadWrite covers reading AND creating/updating/deleting events.
//          (Use Calendars.Read + set MS_CALENDAR_SCOPE if you want a read-only token.)
//        - offline_access is what makes Microsoft return a refresh token.
//   4. Copy the "Application (client) ID".
//
// Usage:
//   node ms-graph-login.mjs <CLIENT_ID>
//   # or:  MS_CALENDAR_CLIENT_ID=<id> node ms-graph-login.mjs
//
// Optional env: MS_CALENDAR_TENANT (default "consumers" for personal accounts),
//               MS_CALENDAR_SCOPE  (default "...Calendars.ReadWrite offline_access User.Read";
//                                   set "...Calendars.Read ..." for a read-only token).

const CLIENT_ID = process.argv[2] || process.env.MS_CALENDAR_CLIENT_ID;
const TENANT = process.env.MS_CALENDAR_TENANT || 'consumers';
const SCOPE = process.env.MS_CALENDAR_SCOPE || 'https://graph.microsoft.com/Calendars.ReadWrite offline_access User.Read';
const AUTHORITY = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0`;

if (!CLIENT_ID) {
  console.error('ERROR: pass your Entra app CLIENT_ID as the first argument (or set MS_CALENDAR_CLIENT_ID).');
  console.error('Usage: node ms-graph-login.mjs <CLIENT_ID>');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // 1) Request a device code.
  const dcRes = await fetch(`${AUTHORITY}/devicecode`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: CLIENT_ID, scope: SCOPE }),
  });
  const dc = await dcRes.json();
  if (!dcRes.ok) {
    console.error('Device-code request failed:', dc.error_description || dc.error || dcRes.status);
    process.exit(1);
  }

  console.error('\n' + '='.repeat(64));
  console.error(dc.message || `Go to ${dc.verification_uri} and enter code: ${dc.user_code}`);
  console.error('='.repeat(64) + '\n');
  console.error(`Waiting for you to sign in (expires in ${Math.round((dc.expires_in || 900) / 60)} min)...`);

  // 2) Poll for the token.
  let interval = (dc.interval || 5) * 1000;
  const deadline = Date.now() + (dc.expires_in || 900) * 1000;
  while (Date.now() < deadline) {
    await sleep(interval);
    const tRes = await fetch(`${AUTHORITY}/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        client_id: CLIENT_ID,
        device_code: dc.device_code,
      }),
    });
    const t = await tRes.json();
    if (tRes.ok) {
      if (!t.refresh_token) {
        console.error('\nSigned in, but no refresh_token returned. Add the "offline_access" delegated permission and retry.');
        process.exit(1);
      }
      // Success — print the refresh token to STDOUT so it can be captured/piped.
      console.error('\n✅ Success. Refresh token below (treat it like a password).');
      console.error('   Scopes granted:', t.scope || SCOPE);
      console.error('   Next: put these in .env, then apply the calendar layer:\n');
      console.error(`     MS_CALENDAR_CLIENT_ID='${CLIENT_ID}'`);
      console.error("     MS_CALENDAR_REFRESH_TOKEN='<the token printed below>'");
      console.error("     ONLY='calendar' ./setup-finn.sh\n");
      console.log(t.refresh_token);
      process.exit(0);
    }
    switch (t.error) {
      case 'authorization_pending': break;            // keep waiting
      case 'slow_down': interval += 5000; break;       // back off
      case 'expired_token':
      case 'code_expired':
        console.error('\nThe device code expired before sign-in. Re-run to get a fresh code.');
        process.exit(1);
      case 'authorization_declined':
        console.error('\nSign-in was declined.');
        process.exit(1);
      default:
        console.error('\nToken poll error:', t.error_description || t.error);
        process.exit(1);
    }
  }
  console.error('\nTimed out waiting for sign-in.');
  process.exit(1);
}

main().catch((e) => { console.error('Unexpected error:', e.message); process.exit(1); });
