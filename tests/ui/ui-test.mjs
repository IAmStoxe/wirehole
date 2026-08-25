// WireHole - test the web interfaces in a real browser.
//
// The API tests prove that the servers work. This test proves that the
// pages work: the login forms, the dashboard, and the client workflow
// that the README tells a user to follow.
//
// The wrapper script tests/ui-test.sh runs this file in the Playwright
// container. Do not run it with a bare node; it needs the browsers of
// that container.
//
// Environment variables:
//   PIHOLE_URL        default http://127.0.0.1:8080
//   WGEASY_URL        default http://127.0.0.1:51821
//   PIHOLE_PASSWORD   required
//   WGEASY_PASSWORD   required
//   WGEASY_USERNAME   default admin

import { chromium } from 'playwright';

const PIHOLE_URL = process.env.PIHOLE_URL ?? 'http://127.0.0.1:8080';
const WGEASY_URL = process.env.WGEASY_URL ?? 'http://127.0.0.1:51821';
const PIHOLE_PASSWORD = process.env.PIHOLE_PASSWORD;
const WGEASY_PASSWORD = process.env.WGEASY_PASSWORD;
const WGEASY_USERNAME = process.env.WGEASY_USERNAME ?? 'admin';

let pass = 0;
let fail = 0;
const ok = (m) => { console.log(`  [ PASS ] ${m}`); pass++; };
const bad = (m) => { console.log(`  [ FAIL ] ${m}`); fail++; };
const say = (m) => console.log(`\n${m}`);

if (!PIHOLE_PASSWORD || !WGEASY_PASSWORD) {
  console.error('Set PIHOLE_PASSWORD and WGEASY_PASSWORD.');
  process.exit(1);
}

const browser = await chromium.launch();
// Pin a valid locale. The container reports the locale "en-US@posix",
// which is not a valid language tag, and the pages would fail on it in a
// way that no real browser reproduces.
const context = await browser.newContext({ locale: 'en-US' });
const page = await context.newPage();

// A page error is a real front end fault. Collect them all.
const pageErrors = [];
page.on('pageerror', (e) => pageErrors.push(String(e)));

try {
  // -----------------------------------------------------------------------
  say('Pi-hole web interface');
  // -----------------------------------------------------------------------

  await page.goto(`${PIHOLE_URL}/admin/`, { waitUntil: 'networkidle' });
  if (page.url().includes('login')) {
    ok('An unauthenticated visit lands on the login page.');
  } else {
    bad(`An unauthenticated visit landed on ${page.url()} instead of the login page.`);
  }

  // A wrong password must not open the dashboard.
  await page.locator('#current-password').fill('wrong-password-123');
  await page.locator('button[type=submit]').click();
  await page.waitForTimeout(2000);
  if (page.url().includes('login')) {
    ok('A wrong password is refused.');
  } else {
    bad('A wrong password opened the dashboard.');
  }

  await page.locator('#current-password').fill(PIHOLE_PASSWORD);
  await page.locator('button[type=submit]').click();
  await page.waitForURL((u) => !u.href.includes('login'), { timeout: 15000 });
  ok('The real password opens the dashboard.');

  // The dashboard must show the query counters.
  await page.waitForSelector('text=Total queries', { timeout: 15000 });
  ok('The dashboard shows the statistics.');

  // The query log is the page the README points users at.
  await page.goto(`${PIHOLE_URL}/admin/queries`, { waitUntil: 'networkidle' });
  if (page.url().includes('login')) {
    bad('The query log bounced back to the login page.');
  } else {
    ok('The query log page opens.');
  }

  // -----------------------------------------------------------------------
  say('wg-easy web interface');
  // -----------------------------------------------------------------------

  await page.goto(`${WGEASY_URL}/`, { waitUntil: 'networkidle' });
  if (page.url().includes('login')) {
    ok('An unauthenticated visit lands on the login page.');
  } else {
    bad(`An unauthenticated visit landed on ${page.url()} instead of the login page.`);
  }

  const signIn = page.getByRole('button', { name: /sign in/i });
  await page.locator('input[name=username]').fill(WGEASY_USERNAME);
  await page.locator('input[name=password]').fill('wrong-password-123');
  await signIn.click();
  await page.waitForTimeout(2000);
  if (page.url().includes('login')) {
    ok('A wrong password is refused.');
  } else {
    bad('A wrong password opened the panel.');
  }

  await page.locator('input[name=username]').fill(WGEASY_USERNAME);
  await page.locator('input[name=password]').fill(WGEASY_PASSWORD);
  await signIn.click();
  await page.waitForURL((u) => !u.href.includes('login'), { timeout: 15000 });
  ok('The real password opens the panel.');

  // Follow the README: make a client with the "+ New" button.
  const clientName = `ui-test-${Date.now()}`;
  await page.getByRole('button', { name: /new/i }).first().click();
  await page.getByLabel(/name/i).first().fill(clientName);
  await page.getByRole('button', { name: /create|save/i }).first().click();
  await page.waitForSelector(`text=${clientName}`, { timeout: 15000 });
  ok('The page creates a new client.');

  // The QR code is how a phone gets its configuration.
  const row = page.locator(`div:has-text("${clientName}")`).last();
  await row.getByRole('button', { name: /qr/i }).first().click()
    .catch(async () => { await page.locator('[title*="QR" i], [aria-label*="QR" i]').first().click(); });
  await page.waitForSelector('canvas, svg[viewBox], img[src*="qrcode"]', { timeout: 15000 });
  ok('The QR code appears for the new client.');
  await page.keyboard.press('Escape');

  // The configuration download must hold a WireGuard interface.
  const dl = await Promise.all([
    page.waitForEvent('download', { timeout: 15000 }),
    (async () => {
      const btn = page.locator('[title*="download" i], [aria-label*="download" i], a[download]').first();
      await btn.click();
    })(),
  ]).then(([d]) => d).catch(() => null);
  if (dl) {
    const path = await dl.path();
    const fs = await import('node:fs');
    const text = fs.readFileSync(path, 'utf8');
    if (text.includes('[Interface]') && text.includes('[Peer]')) {
      ok('The downloaded configuration is a valid WireGuard file.');
    } else {
      bad('The downloaded file is not a WireGuard configuration.');
    }
  } else {
    bad('The configuration download did not start.');
  }

  // The wrapper script removes the test client through the API after the
  // run. The delete control lives in the client edit page, and driving it
  // adds fragility without testing anything the steps above do not cover.

  // -----------------------------------------------------------------------
  say('JavaScript errors');
  // -----------------------------------------------------------------------
  if (pageErrors.length === 0) {
    ok('No page threw a JavaScript error.');
  } else {
    bad(`The pages threw ${pageErrors.length} JavaScript errors:`);
    for (const e of pageErrors.slice(0, 5)) console.log(`    ${e}`);
  }
} catch (e) {
  bad(`Unexpected: ${e.message}`);
  await page.screenshot({ path: '/work/ui-failure.png', fullPage: true }).catch(() => {});
  console.log('  ....... Screenshot: tests/ui/ui-failure.png');
} finally {
  await browser.close();
}

say(`Result: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
