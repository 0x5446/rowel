/**
 * Which token pairs a phone, and which only asks.
 *
 * The QR's token never leaves this machine except inside the QR, so presenting
 * it proves the phone scanned this screen. The short code's bundle is handed
 * to the Relay, which can read it — so its token only earns a claim, and a
 * person at the Mac decides. These tests pin that split, including what the
 * Relay is actually sent.
 */

import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { generateKeyPair } from '@rowel/protocol'
import {
  approveClaimant,
  createInvitation,
  deviceName,
  findPeer,
  loadState,
  offerMatch,
  openPairingOffer,
  overrideState,
  publishInvitation,
  redeemOffer,
  reloadState,
  statePath,
  withdrawOffer,
} from '../lib/index.js'

/** Run a body against a throwaway ROWEL_HOME. */
async function withHome(body) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-pairing-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  try {
    await body(home)
  } finally {
    if (previous === undefined) delete process.env.ROWEL_HOME
    else process.env.ROWEL_HOME = previous
    rmSync(home, { recursive: true, force: true })
  }
}

test('the QR token pairs; the short-code token only asks', async () => {
  await withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    assert.notEqual(offer.token, offer.codeToken)
    assert.equal(offerMatch(state, offer.token), 'scanned')
    assert.equal(offerMatch(state, offer.codeToken), 'typed')
  })
})

test('the Relay is never sent the token that pairs without asking', async () => {
  await withHome(async () => {
    let published
    const relay = createServer((request, response) => {
      let body = ''
      request.on('data', (chunk) => { body += chunk })
      request.on('end', () => {
        published = JSON.parse(body)
        response.writeHead(200, { 'content-type': 'application/json' }).end('{"ok":true}')
      })
    })
    await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve))
    try {
      const state = loadState()
      overrideState(state, { relayUrl: `ws://127.0.0.1:${String(relay.address().port)}` })
      const invitation = createInvitation(state)
      await publishInvitation(state, invitation)

      assert.equal(published.bundle.token, invitation.codeToken, 'the Relay should hold the short-code token')
      assert.equal(JSON.stringify(published).includes(invitation.bundle.token), false, 'the QR token reached the Relay')
    } finally {
      relay.close()
    }
  })
})

test('a claim is recorded, and only the device the person was shown can be approved', async () => {
  await withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    const phone = generateKeyPair().publicKey
    const intruder = generateKeyPair().publicKey

    assert.equal(redeemOffer(state, phone, 'phone', offer.codeToken), 'claimed')
    assert.equal(state.offer?.claimant?.key, phone.toString('base64url'))
    assert.equal(findPeer(state, phone), undefined, 'a claim alone paired the device')

    // Someone else claims while the person is reading the prompt.
    assert.equal(redeemOffer(state, intruder, 'not a phone', offer.codeToken), 'claimed')
    assert.equal(approveClaimant(state, phone.toString('base64url'), offer.code), false, 'approved a device that was no longer the claimant')
    assert.equal(findPeer(state, intruder), undefined)

    assert.equal(approveClaimant(state, intruder.toString('base64url'), offer.code), true)
    assert.equal(state.offer, undefined, 'approving must consume the offer')
  })
})

test('an expired claim cannot be approved, and a refused offer stops working', async () => {
  await withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    const phone = generateKeyPair().publicKey
    redeemOffer(state, phone, 'phone', offer.codeToken)
    assert.equal(approveClaimant(state, phone.toString('base64url'), offer.code, offer.expiresAt + 1), false)

    withdrawOffer(state, offer.code)
    assert.equal(offerMatch(state, offer.codeToken), undefined)
  })
})

test('an offer written before the two-token split is dropped on load', async () => {
  await withHome(() => {
    loadState()
    // One token, which older Bridles put in the QR *and* sent to the Relay.
    const disk = JSON.parse(readFileSync(statePath(), 'utf8'))
    disk.offer = { token: 'old-token', code: 'BCDF-GHJK', expiresAt: Date.now() + 600_000 }
    writeFileSync(statePath(), JSON.stringify(disk))

    const state = loadState()
    assert.equal(state.offer, undefined)
    assert.equal(offerMatch(state, 'old-token'), undefined, 'a token the Relay may hold still pairs')
    assert.equal(JSON.parse(readFileSync(statePath(), 'utf8')).offer, undefined, 'and the file still carries it')
  })
})

test('a token from an offer that was replaced redeems nothing, even if memory still holds it', async () => {
  await withHome(() => {
    // The daemon's view is a moment old: another `bridle pair` has since
    // replaced the offer on disk. The decision is made on disk, under the lock.
    const daemon = loadState()
    const old = openPairingOffer(daemon)
    openPairingOffer(loadState())
    const phone = generateKeyPair().publicKey
    assert.equal(redeemOffer(daemon, phone, 'phone', old.token), undefined, 'a replaced offer\'s token paired a device')
    assert.equal(findPeer(loadState(), phone), undefined)
    assert.notEqual(loadState().offer, undefined, 'the newer offer was consumed by the old token')
  })
})

test('an old-format offer that arrives while running is refused too', async () => {
  await withHome(() => {
    const state = loadState()
    const disk = JSON.parse(readFileSync(statePath(), 'utf8'))
    disk.offer = { token: 'old-token', code: 'BCDF-GHJK', expiresAt: Date.now() + 600_000 }
    writeFileSync(statePath(), JSON.stringify(disk))
    reloadState(state)
    assert.equal(redeemOffer(state, generateKeyPair().publicKey, 'relay', 'old-token'), undefined)
  })
})

test('a bridle pair cannot withdraw or approve an offer that replaced its own', async () => {
  await withHome(() => {
    const state = loadState()
    const mine = openPairingOffer(state)
    const newer = openPairingOffer(loadState())
    const phone = generateKeyPair().publicKey
    redeemOffer(loadState(), phone, 'phone', newer.codeToken)

    withdrawOffer(state, mine.code)
    assert.equal(loadState().offer?.code, newer.code, 'the older command took down the newer offer')
    assert.equal(approveClaimant(state, phone.toString('base64url'), mine.code), false)
    assert.equal(findPeer(loadState(), phone), undefined)
  })
})

test('a fresh lock is waited on, and one left behind long ago is taken', async () => {
  await withHome(() => {
    const state = loadState()
    const lock = `${statePath()}.lock`
    // Abandoned: written well past the few microseconds a writer holds it.
    writeFileSync(lock, '999999999')
    const past = (Date.now() - 60_000) / 1000
    utimesSync(lock, past, past)
    openPairingOffer(state)
    assert.equal(existsSync(lock), false, 'an abandoned lock was left behind')
    // Held right now, whoever holds it — even a pid that no longer exists,
    // because after a reboot a pid says nothing about the holder.
    writeFileSync(lock, '999999999')
    const started = Date.now()
    assert.throws(() => { openPairingOffer(state) }, /held by another bridle/u)
    assert.ok(Date.now() - started >= 1_500, 'a fresh lock was not waited on')
    assert.equal(readFileSync(lock, 'utf8'), '999999999', 'a fresh lock was taken or deleted')
    rmSync(lock)
  })
})

test('a device name cannot draw on the terminal that asks a person to compare keys', () => {
  // The short-code token may be presented by the Relay, which then chooses the
  // name printed beside the fingerprint. Escape sequences and newlines could
  // paint a fake "its key" line and hide the real one.
  const forged = 'iPhone" asks to pair.\nIts key:  AAAA-BBBB-CCCC-DDDD\n\u001b[8m‮'
  const shown = deviceName(forged)
  assert.equal(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮]/u.test(shown), false, `control or format characters survived: ${JSON.stringify(shown)}`)
  assert.equal(shown.includes('\n'), false)
  assert.ok(Array.from(deviceName('x'.repeat(500))).length <= 64, 'a name has no length limit')
  assert.equal(deviceName('\u0007\u001b\u200b'), 'iPhone', 'a name made only of control characters should fall back')
  assert.equal(deviceName(undefined), 'iPhone')
  assert.equal(deviceName('Alex’s iPhone 17 👍'), 'Alex’s iPhone 17 👍', 'an ordinary name was mangled')
})
