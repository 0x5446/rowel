/**
 * The state file holds the only long-term secret on the machine, and the list
 * of devices allowed to reach a shell. Both halves are tested here.
 */

import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { deviceIdFor, generateKeyPair } from '@rowel/protocol'
import {
  acceptPeer,
  findPeer,
  loadState,
  offerMatch,
  openPairingOffer,
  overrideState,
  reloadState,
  revokePeer,
  saveState,
  signingKeys,
  statePath,
  staticKeys,
  touchPeer,
} from '../lib/index.js'

/**
 * Run a body against a throwaway ROWEL_HOME.
 * @param {(home: string) => void} body - the test body.
 */
function withHome(body) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-identity-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  try {
    body(home)
  } finally {
    if (previous === undefined) delete process.env.ROWEL_HOME
    else process.env.ROWEL_HOME = previous
    rmSync(home, { recursive: true, force: true })
  }
}

test('first run creates an identity and stores it owner-only', () => {
  withHome(() => {
    const state = loadState()
    assert.equal(staticKeys(state).publicKey.length, 32)
    assert.equal(signingKeys(state).publicKey.length, 32)
    assert.equal(state.peers.length, 0)
    assert.equal(statSync(statePath()).mode & 0o777, 0o600)
  })
})

test('the device id is derived from the signing key, not invented', () => {
  withHome(() => {
    const state = loadState()
    assert.equal(state.deviceId, deviceIdFor(signingKeys(state).publicKey))
  })
})

test('a device id left over from the old derivation is corrected on load', () => {
  withHome(() => {
    // What a state file written before the rename looks like: the keys are
    // fine, but `deviceId` was hashed with the old domain string and no longer
    // matches them. The Relay derives the id from the signature and so never
    // noticed; the pairing bundle reads this field and sent the phone after a
    // machine that could not exist.
    const state = loadState()
    const correct = deviceIdFor(signingKeys(state).publicKey)
    state.deviceId = 'OnNhRs8iOPPZCvoFWM0aQg'
    saveState(state)

    const reloaded = loadState()
    assert.equal(reloaded.deviceId, correct, 'the id has to be derived, not trusted')
    assert.equal(loadState().deviceId, correct, 'and the correction has to be written back')
  })
})

test('a second load returns the same identity', () => {
  withHome(() => {
    const first = loadState()
    const second = loadState()
    assert.equal(second.privateKey, first.privateKey)
    assert.equal(second.deviceId, first.deviceId)
  })
})

test('a state file from a newer bridle is refused rather than misread', () => {
  withHome(() => {
    const state = loadState()
    state.version = 99
    saveState(state)
    assert.throws(() => loadState(), /newer Bridle/)
  })
})

test('an environment override is applied but never written back', () => {
  withHome(() => {
    loadState()
    process.env.ROWEL_DSH_URL = 'http://127.0.0.1:9999'
    try {
      assert.equal(loadState().dshUrl, 'http://127.0.0.1:9999')
    } finally {
      delete process.env.ROWEL_DSH_URL
    }
    assert.notEqual(loadState().dshUrl, 'http://127.0.0.1:9999')
  })
})

test('an outstanding offer accepts its own token and nothing else', () => {
  withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    assert.equal(offerMatch(state, offer.token), 'scanned')
    assert.equal(offerMatch(state, 'some-other-token'), undefined)
  })
})

test('an expired offer is refused', () => {
  withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    assert.equal(offerMatch(state, offer.token, offer.expiresAt + 1), undefined)
  })
})

test('pairing consumes the offer, so one invitation admits one device', () => {
  withHome(() => {
    const state = loadState()
    const offer = openPairingOffer(state)
    const device = generateKeyPair().publicKey
    acceptPeer(state, device, 'Alex iPhone')
    assert.equal(offerMatch(state, offer.token), undefined)
    assert.equal(findPeer(state, device)?.name, 'Alex iPhone')
  })
})

test('pairing the same device twice updates it instead of duplicating it', () => {
  withHome(() => {
    const state = loadState()
    const device = generateKeyPair().publicKey
    acceptPeer(state, device, 'iPhone')
    openPairingOffer(state)
    acceptPeer(state, device, 'iPhone 17 Pro')
    assert.equal(state.peers.length, 1)
    assert.equal(state.peers[0].name, 'iPhone 17 Pro')
  })
})

test('a paired device survives a reload and can be touched', () => {
  withHome(() => {
    const state = loadState()
    const device = generateKeyPair().publicKey
    acceptPeer(state, device, 'iPad', 1000)
    touchPeer(state, device, 2000)
    assert.equal(loadState().peers[0].lastSeen, 2000)
  })
})

test('revoking by prefix removes exactly one device', () => {
  withHome(() => {
    const state = loadState()
    const first = generateKeyPair().publicKey
    acceptPeer(state, first, 'iPhone')
    openPairingOffer(state)
    acceptPeer(state, generateKeyPair().publicKey, 'iPad')
    const removed = revokePeer(state, first.toString('base64url').slice(0, 8))
    assert.equal(removed?.name, 'iPhone')
    assert.equal(loadState().peers.length, 1)
    assert.equal(revokePeer(state, 'nothing-matches-this'), undefined)
  })
})

test('a revoke made by another process survives this one writing afterwards', () => {
  withHome(() => {
    // Two processes, two snapshots: a daemon that loaded before `bridle revoke`
    // ran in another terminal. Writing its whole snapshot back used to bring
    // the revoked phone back from the dead.
    const phone = generateKeyPair().publicKey
    acceptPeer(loadState(), phone, 'phone')
    const daemon = loadState()
    const cli = loadState()

    assert.ok(revokePeer(cli, phone.toString('base64url')), 'the CLI revoked the phone')
    touchPeer(daemon, phone)

    assert.equal(findPeer(loadState(), phone), undefined, 'the revoke has to stick')
    assert.equal(findPeer(daemon, phone), undefined, 'and the daemon has to see it')
  })
})

test('an offer opened by another process is not erased by this one writing', () => {
  withHome(() => {
    const phone = generateKeyPair().publicKey
    acceptPeer(loadState(), phone, 'phone')
    const daemon = loadState()
    const offer = openPairingOffer(loadState())

    touchPeer(daemon, phone)

    assert.equal(loadState().offer?.token, offer.token)
  })
})

test('an environment override is used but never written to the file', () => {
  withHome(() => {
    loadState()
    const previous = process.env.ROWEL_RELAY_URL
    process.env.ROWEL_RELAY_URL = 'ws://127.0.0.1:8787'
    try {
      const state = loadState()
      assert.equal(state.relayUrl, 'ws://127.0.0.1:8787')
      acceptPeer(state, generateKeyPair().publicKey, 'phone')
      assert.equal(state.relayUrl, 'ws://127.0.0.1:8787', 'the override outlives a write')
    } finally {
      if (previous === undefined) delete process.env.ROWEL_RELAY_URL
      else process.env.ROWEL_RELAY_URL = previous
    }
    assert.equal(loadState().relayUrl, 'wss://rowel-relay.novabox.ai', 'one test run must not become the configuration')
  })
})

test('a process override survives a reload of the file', () => {
  withHome(() => {
    const state = loadState()
    overrideState(state, { relayUrl: '' })
    reloadState(state)
    openPairingOffer(state)
    assert.equal(state.relayUrl, '')
    assert.equal(loadState().relayUrl, 'wss://rowel-relay.novabox.ai')
  })
})
