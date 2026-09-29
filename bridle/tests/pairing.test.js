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
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { generateKeyPair } from '@rowel/protocol'
import {
  approveClaimant,
  createInvitation,
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
    assert.equal(approveClaimant(state, phone.toString('base64url')), false, 'approved a device that was no longer the claimant')
    assert.equal(findPeer(state, intruder), undefined)

    assert.equal(approveClaimant(state, intruder.toString('base64url')), true)
    assert.equal(state.offer, undefined, 'approving must consume the offer')
  })
})

test('an expired claim cannot be approved, and a refused offer stops working', async () => {
  await withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    const phone = generateKeyPair().publicKey
    redeemOffer(state, phone, 'phone', offer.codeToken)
    assert.equal(approveClaimant(state, phone.toString('base64url'), offer.expiresAt + 1), false)

    withdrawOffer(state)
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
    assert.equal(approveClaimant(state, phone.toString('base64url'), Date.now(), mine.code), false)
    assert.equal(findPeer(loadState(), phone), undefined)
  })
})

test('a lock held by a live process is waited on, and one left by a dead process is taken', async () => {
  await withHome(() => {
    const state = loadState()
    const lock = `${statePath()}.lock`
    // A dead holder: a pid that cannot exist.
    writeFileSync(lock, '999999999')
    openPairingOffer(state)
    assert.equal(existsSync(lock), false, 'the lock was left behind')
    // A live holder that is not this process: the parent that ran the tests.
    writeFileSync(lock, String(process.ppid))
    const started = Date.now()
    assert.throws(() => { openPairingOffer(state) }, /held by another bridle/u)
    assert.ok(Date.now() - started >= 1_500, 'a live holder\'s lock was not waited on')
    assert.equal(readFileSync(lock, 'utf8'), String(process.ppid), 'a live holder\'s lock was taken or deleted')
    rmSync(lock)
  })
})
