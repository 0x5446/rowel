/**
 * The public site, which is a different deployment from the relay.
 *
 * They shared a hostname for a day and these assertions lived in the relay
 * suite, keyed off whether the relay happened to be behind the site's name.
 * That was wrong in both directions: pointing the relay suite at a standby
 * address made "the site is up" fail for reasons that were never about the
 * site, and once the two were properly split the condition would have silently
 * skipped these forever.
 *
 * So they are their own file with their own address. Nothing here needs a
 * relay, a harness, or a phone.
 *
 *   node --test e2e/tests/site.test.js
 *   ROWEL_E2E_SITE_URL=http://127.0.0.1:8788 node --test e2e/tests/site.test.js
 */

import assert from 'node:assert/strict'
import test from 'node:test'

/**
 * Where the site is. Defaulted rather than required, because unlike the relay
 * there is nothing to stand up first — the pages either answer or the
 * deployment is broken, and that is worth knowing without being asked.
 */
const SITE = process.env.ROWEL_E2E_SITE_URL ?? 'https://rowel.novabox.ai'

const TIMEOUT_MS = 30_000

test('every page the app links to is served', { timeout: TIMEOUT_MS }, async () => {
  // `Links.swift` sends people to these. A 404 behind the app's Privacy button
  // is also a rejected App Store submission.
  for (const path of ['/', '/privacy', '/_/site.css']) {
    const response = await fetch(new URL(path, SITE), { signal: AbortSignal.timeout(15_000) })
    assert.equal(response.status, 200, `${path} should be served`)
  }
})

test('the old page addresses land on their sections', { timeout: TIMEOUT_MS }, async () => {
  // The site is one page now, but `/help` is the app's Help button and the App
  // Store's support URL, and `/get` is printed by the CLI and in the README —
  // addresses that cannot be corrected once they have been read.
  for (const [path, anchor] of [['/help', '/#help'], ['/get', '/#get']]) {
    const response = await fetch(new URL(path, SITE), { redirect: 'manual', signal: AbortSignal.timeout(15_000) })
    assert.equal(response.status, 301, `${path} should be a permanent redirect`)
    assert.equal(new URL(response.headers.get('location') ?? '', SITE).href, new URL(anchor, SITE).href, `${path} should land on ${anchor}`)
  }
})

test('the installer comes from the repository, not from a relay', { timeout: TIMEOUT_MS }, async () => {
  // A relay that also hands out the installer turns one compromise into a
  // supply-chain event, so the edge redirects and ROWEL_INSTALL_SCRIPT stays
  // empty. `redirect: 'manual'` matters: following the hop would land on
  // GitHub and pass even if something local had started serving the script.
  const response = await fetch(new URL('/install', SITE), {
    redirect: 'manual',
    signal: AbortSignal.timeout(15_000),
  })
  assert.equal(response.status, 302, '/install should be an edge redirect')
  assert.match(
    response.headers.get('location') ?? '',
    /^https:\/\/raw\.githubusercontent\.com\//u,
    'the redirect must point at the repository',
  )
})

test('the site host serves no relay', { timeout: TIMEOUT_MS }, async () => {
  // The point of the split. The site is public marketing and the relay is
  // infrastructure, and every zone-level control — a cache rule, a WAF rule,
  // an "under attack" toggle — applies per hostname. If the relay ever comes
  // back to this name, one rule aimed at these pages takes it down with them.
  for (const path of ['/healthz', '/v1/bridle', '/v1/pair/claim?code=aaaaaaaa']) {
    const response = await fetch(new URL(path, SITE), { signal: AbortSignal.timeout(15_000) })
    assert.equal(response.status, 404, `${path} must not be answered by the site host`)
  }
})
