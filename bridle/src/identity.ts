/**
 * Bridle on-disk identity: the machine's long-term Noise key, the devices it
 * has accepted, and the pairing offer currently outstanding. The file is the
 * only secret this process owns, so it is created 0600 inside a 0700 directory
 * and rewritten atomically.
 */

import { chmodSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { hostname, homedir, userInfo } from 'node:os'
import { join } from 'node:path'
import {
  deviceIdFor,
  generateKeyPair,
  generateSigningKeyPair,
  mintPairingToken,
  mintShortCode,
  publicKeyOf,
  signingPublicKeyOf,
  PAIRING_TTL_MS,
  type SigningKeyPair,
  type StaticKeyPair,
} from '@rowel/protocol'

/** On-disk format version; a newer file refuses to load on an older Bridle. */
const STATE_VERSION = 1

/** One device this Bridle has accepted. */
export interface PairedPeer {
  /** Raw static public key, base64url. */
  key: string
  /** Device name the app reported at pairing time. */
  name: string
  /** Epoch milliseconds of the pairing. */
  pairedAt: number
  /** Epoch milliseconds of the most recent successful handshake. */
  lastSeen: number
  /**
   * Where to ring this device when it is not attached.
   *
   * Learned inside the Noise channel and kept here rather than at the Relay,
   * so the Relay is handed a token only at the instant a push is sent and has
   * no standing list of who can be reached. Absent until the app offers one,
   * and removed when it withdraws it or Apple says the device is gone.
   *
   * Just the token: which APNs host minted it is Apple's question to answer,
   * not something three components should carry around.
   */
  push?: string
}

/** A pairing offer waiting to be claimed. */
export interface PairingOffer {
  /**
   * One-time token embedded in the QR payload. **Never leaves this machine**
   * except inside that QR, so presenting it proves the phone scanned the code.
   */
  token: string
  /**
   * The token inside the bundle the Relay holds for the short code. The Relay
   * can read it, so it proves nothing about who presents it: a phone that
   * does is recorded as {@link PairingOffer.claimant} and waits for a person
   * at the Mac to accept it.
   */
  codeToken: string
  /** Typed alternative to scanning. */
  code: string
  /** Epoch milliseconds after which the offer is refused. */
  expiresAt: number
  /** The latest device to present `codeToken`, awaiting approval on the Mac. */
  claimant?: PairingClaimant
}

/** A device that asked to pair through the short code. */
export interface PairingClaimant {
  /** Raw static public key, base64url. */
  key: string
  /** Device name the app reported. */
  name: string
  /** Epoch milliseconds of its latest attempt. */
  at: number
}

/** The complete persisted state. */
export interface BridleState {
  version: number
  /** Stable machine id the Relay uses to pair sockets; derived from {@link BridleState.signingKey}. */
  deviceId: string
  /** Raw X25519 static private key, base64url. Authenticates the tunnel. */
  privateKey: string
  /** Raw Ed25519 private key, base64url. Claims the Relay device slot. */
  signingKey: string
  /** Display name of this machine. */
  machineName: string
  /** Relay base URL this Bridle dials out to. */
  relayUrl: string
  /** dsh base URL on loopback. */
  dshUrl: string
  /**
   * The DSH_HOME this identity fronts, when binding by home.
   *
   * The home is the instance's identity — its sessions, config, and (when it
   * declares one) its port all live there — so a binding recorded as a home
   * is anchored to the world itself, and `dshUrl` becomes a derived cache of
   * where that world answers. Optional: a plain URL binding works as before.
   */
  dshHome?: string
  peers: PairedPeer[]
  offer?: PairingOffer
}

/** Default public Relay. Overridable per install; the Relay never sees plaintext either way. */
export const DEFAULT_RELAY_URL = 'wss://rowel-relay.novabox.ai'

/**
 * Addresses this project used to ship as the default, and no longer serves.
 *
 * These are deliberately the *old* spellings, including the ones from before
 * the project was called Rowel. A list whose whole job is to remember names
 * that no longer work is the one place a rename must not reach — rewriting
 * these to the current hostname would turn the migration into a no-op and
 * leave every older install dialling a name with no record behind it.
 *
 * Two moves are recorded here. The relay left `reins.novabox.ai` so that the
 * public site and the infrastructure would stop sharing a hostname — one cache
 * rule, one WAF rule, or one "under attack" toggle aimed at the marketing pages
 * would otherwise take the relay with it, and the relay is the half that must
 * not go down. Then the project itself was renamed, and the relay moved again.
 *
 * Migrated on load rather than left to break, because the address lives in a
 * file written months ago and nobody would connect a silent connection failure
 * to a hostname they never chose. **Only these exact strings are rewritten** —
 * an address someone set themselves, or pointed at their own relay, is theirs
 * and is left alone.
 */
const RETIRED_RELAY_URLS: readonly string[] = [
  'wss://reins.novabox.ai',
  'wss://relay.novabox.ai',
  'wss://reins-relay.novabox.ai',
]

/** Default dsh loopback address, matching the web profile's own default port. */
export const DEFAULT_DSH_URL = 'http://127.0.0.1:3080'

/**
 * Resolve the Bridle home directory.
 * @returns `$ROWEL_HOME`, else `~/.rowel`.
 */
export function rowelHome(): string {
  return process.env['ROWEL_HOME'] ?? join(homedir(), '.rowel')
}

/**
 * Absolute path of the state file.
 * @returns `<ROWEL_HOME>/bridle.json`.
 */
export function statePath(): string {
  return join(rowelHome(), 'bridle.json')
}

function defaultMachineName(): string {
  const host = hostname().replace(/\.local$/u, '')
  if (host.length > 0) return host
  return `${userInfo().username}'s Mac`
}

/**
 * Load the persisted state, creating a fresh identity on first run.
 * @returns the current state, already written to disk.
 */
export function loadState(): BridleState {
  const home = rowelHome()
  mkdirSync(home, { recursive: true, mode: 0o700 })
  const path = statePath()
  let raw: string | undefined
  try {
    raw = readFileSync(path, 'utf8')
  } catch (error) {
    // Any read failure other than absence is a real problem worth reporting;
    // absence is the ordinary first-run path.
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  if (raw !== undefined) {
    const parsed = JSON.parse(raw) as BridleState
    if (parsed.version > STATE_VERSION) {
      throw new Error(`${path} was written by a newer Bridle (format ${String(parsed.version)})`)
    }
    // An offer from before the two-token split carries one token that went
    // both into the QR and to the Relay — so the Relay may be holding the one
    // token this Bridle would accept without asking anybody. Drop it; the
    // person makes a new one with `bridle pair`.
    if (parsed.offer !== undefined && typeof parsed.offer.codeToken !== 'string') {
      delete parsed.offer
      mutateDisk((disk) => { delete disk.offer })
    }
    if (RETIRED_RELAY_URLS.includes(parsed.relayUrl)) {
      parsed.relayUrl = DEFAULT_RELAY_URL
      mutateDisk((disk) => { disk.relayUrl = DEFAULT_RELAY_URL })
    }
    // `deviceId` is derived from the signing key, and a derived value kept on
    // disk can go stale. This one did: the hash is domain-separated by the
    // project's name, so the rename changed every machine's id while the copy
    // written into this file stayed on the old one.
    //
    // Nothing failed loudly, because the two readers disagree in the worst
    // possible way. The Relay never trusts this field — it verifies a signature
    // and derives the id itself — so registration kept working. The pairing
    // bundle handed to the phone reads the stored copy, so the phone went
    // looking for a machine that could not exist, and the only thing anyone saw
    // was "that machine is offline" about a Mac sitting right there.
    //
    // Derived here rather than trusted, and written back so one load fixes it.
    const derived = deviceIdFor(signingPublicKeyOf(Buffer.from(parsed.signingKey, 'base64url')))
    if (parsed.deviceId !== derived) {
      parsed.deviceId = derived
      // Only the one field, on top of whatever is on disk now: this snapshot
      // may be seconds old, and writing it whole would undo a device the
      // daemon paired in that gap. A correction that cannot be written is not
      // worth failing a load over — the next load redoes it.
      try {
        mutateDisk((disk) => { disk.deviceId = derived })
      } catch {
        // See above.
      }
    }
    return applyEnvironment(parsed)
  }
  const keys = generateKeyPair()
  const signing = generateSigningKeyPair()
  const state: BridleState = {
    version: STATE_VERSION,
    deviceId: deviceIdFor(signing.publicKey),
    privateKey: keys.privateKey.toString('base64url'),
    signingKey: signing.privateKey.toString('base64url'),
    machineName: defaultMachineName(),
    relayUrl: DEFAULT_RELAY_URL,
    dshUrl: DEFAULT_DSH_URL,
    peers: [],
  }
  saveState(state)
  return applyEnvironment(state)
}

/** Settings that apply to one process and must never reach the file. */
export type StateOverrides = Partial<Pick<BridleState, 'relayUrl' | 'dshUrl'>>

/** The overrides each in-memory state carries, reapplied after every reload. */
const overridesOf = new WeakMap<BridleState, StateOverrides>()

/**
 * Apply settings to this process's view of the state without persisting them.
 *
 * A `ROWEL_RELAY_URL` set for one test run, or a plugin's `relay` setting,
 * describes how *this* process should run, not what the machine is. They live
 * beside the state rather than in it: every write goes through
 * {@link updateState}, which edits what is on disk and never this object, so
 * nothing here can leak into the file however the state is later saved.
 * @param state - the in-memory state.
 * @param overrides - the values to hold for the life of this process.
 */
export function overrideState(state: BridleState, overrides: StateOverrides): void {
  const held = { ...overridesOf.get(state), ...overrides }
  overridesOf.set(state, held)
  Object.assign(state, held)
}

function applyEnvironment(state: BridleState): BridleState {
  const relay = process.env['ROWEL_RELAY_URL']
  const dsh = process.env['ROWEL_DSH_URL']
  overrideState(state, {
    ...(relay !== undefined && relay.length > 0 ? { relayUrl: relay } : {}),
    ...(dsh !== undefined && dsh.length > 0 ? { dshUrl: dsh } : {}),
  })
  return state
}

/**
 * Change the state file and this process's view of it, as one transaction.
 *
 * The file has more than one writer by design — a daemon and a `bridle pair`
 * or `bridle revoke` in another terminal — and each used to write its whole
 * in-memory snapshot back. A snapshot taken before the other process wrote
 * then undid that write: a revoked phone came back, a fresh offer vanished.
 * So a change is a function applied to what is on disk *now*, under a lock,
 * and the in-memory state is replaced by the result rather than trusted.
 * @param state - the in-memory state, refreshed from the file afterwards.
 * @param mutate - edits the on-disk copy; its return value is passed through.
 * @returns whatever `mutate` returned.
 */
export function updateState<T>(state: BridleState, mutate: (disk: BridleState) => T): T {
  let result: T | undefined
  const disk = mutateDisk((current) => { result = mutate(current) })
  adopt(state, disk)
  return result as T
}

/**
 * Replace this process's view with what is on disk, keeping its overrides.
 * @param state - the in-memory state.
 */
export function reloadState(state: BridleState): void {
  adopt(state, readDisk())
}

/**
 * The identity a running process was started with. Never re-read: a key file
 * swapped underneath a daemon (a restore from backup, say) must take effect on
 * the next start, not silently halfway through this one.
 */
const IDENTITY_FIELDS: ReadonlySet<string> = new Set(['privateKey', 'signingKey', 'deviceId'])

function adopt(state: BridleState, disk: BridleState): void {
  for (const key of Object.keys(state)) {
    if (!IDENTITY_FIELDS.has(key) && !(key in disk)) Reflect.deleteProperty(state, key)
  }
  for (const [key, value] of Object.entries(disk)) {
    if (!IDENTITY_FIELDS.has(key)) Reflect.set(state, key, value)
  }
  Object.assign(state, overridesOf.get(state))
}

function readDisk(): BridleState {
  return JSON.parse(readFileSync(statePath(), 'utf8')) as BridleState
}

function mutateDisk(mutate: (disk: BridleState) => void): BridleState {
  return withStateLock(() => {
    const disk = readDisk()
    mutate(disk)
    writeDisk(disk)
    return disk
  })
}

/** How long a writer waits for another one before giving up. */
const LOCK_WAIT_MS = 2_000
/** A lock with no readable holder older than this was left by a process that died writing it. */
const LOCK_STALE_MS = 10_000

/**
 * Run `body` holding the state file's lock.
 *
 * An exclusive-create lock file, because the writers are separate processes
 * (and one of them may be dsh itself, with the plugin) and nothing else in
 * Node is shared between them. Held for one read and one write — microseconds
 * — so waiting synchronously is cheaper than making every caller async.
 */
function withStateLock<T>(body: () => T): T {
  mkdirSync(rowelHome(), { recursive: true, mode: 0o700 })
  const lock = `${statePath()}.lock`
  const deadline = Date.now() + LOCK_WAIT_MS
  for (;;) {
    try {
      writeFileSync(lock, String(process.pid), { flag: 'wx', mode: 0o600 })
      break
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      if (reclaimIfAbandoned(lock)) continue
      if (Date.now() > deadline) throw new Error(`${lock} is held by another bridle`)
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5)
    }
  }
  try {
    return body()
  } finally {
    // Only ours. A lock taken over after we were presumed dead is somebody
    // else's now, and deleting it would let a third writer in beside them.
    try {
      if (readFileSync(lock, 'utf8') === String(process.pid)) unlinkSync(lock)
    } catch {
      // Already gone; nothing to release.
    }
  }
}

/**
 * Remove a lock whose holder is gone.
 *
 * By whether the process that wrote it still exists, not by its age: a live
 * holder paused for a while (a laptop lid, a debugger) must keep its lock, or
 * two writers end up inside at once. Age decides only for a lock whose holder
 * cannot be read — written by something that died between create and write.
 * @param lock - the lock file.
 * @returns whether it was removed, so the caller should try again at once.
 */
function reclaimIfAbandoned(lock: string): boolean {
  let holder: string
  try {
    holder = readFileSync(lock, 'utf8')
  } catch {
    return true // released between our create and this read
  }
  const pid = Number(holder)
  const abandoned = Number.isInteger(pid) && pid > 0
    ? !processExists(pid)
    : lockAge(lock) > LOCK_STALE_MS
  if (!abandoned) return false
  // Read-then-unlink is not atomic: two writers recovering the same dead
  // holder's lock in the same instant could, in principle, see one remove the
  // lock the other has just taken. Node has no cross-process flock to close
  // that gap, and it needs a Bridle to have died mid-write *and* two writers
  // to race for the lock within microseconds of each other.
  try {
    if (readFileSync(lock, 'utf8') === holder) unlinkSync(lock)
  } catch {
    // Someone else cleared it first; either way, try again.
  }
  return true
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    // EPERM: it exists, it just is not ours to signal.
    return (error as NodeJS.ErrnoException).code === 'EPERM'
  }
}

function lockAge(lock: string): number {
  try {
    return Date.now() - statSync(lock).mtimeMs
  } catch {
    return 0
  }
}

function writeDisk(state: BridleState): void {
  const path = statePath()
  const temporary = `${path}.${String(process.pid)}.tmp`
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

/**
 * Replace the whole state file: a fresh identity, or one restored from backup.
 * Anything that changes part of the state goes through {@link updateState}.
 * @param state - the complete state to write.
 */
export function saveState(state: BridleState): void {
  withStateLock(() => { writeDisk(state) })
}

/**
 * The static key pair for this machine.
 * @param state - loaded state.
 * @returns the raw key pair.
 */
export function staticKeys(state: BridleState): StaticKeyPair {
  const privateKey = Buffer.from(state.privateKey, 'base64url')
  return { privateKey, publicKey: publicKeyOf(privateKey) }
}

/**
 * The Relay signing identity for this machine.
 * @param state - loaded state.
 * @returns the raw Ed25519 key pair whose hash is {@link BridleState.deviceId}.
 */
export function signingKeys(state: BridleState): SigningKeyPair {
  const privateKey = Buffer.from(state.signingKey, 'base64url')
  return { privateKey, publicKey: signingPublicKeyOf(privateKey) }
}

/**
 * Create (or refresh) the outstanding pairing offer.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param now - current epoch milliseconds.
 * @returns the offer to render as a QR and a typed code.
 */
export function openPairingOffer(state: BridleState, now: number = Date.now()): PairingOffer {
  const offer: PairingOffer = {
    token: mintPairingToken(),
    codeToken: mintPairingToken(),
    code: mintShortCode(),
    expiresAt: now + PAIRING_TTL_MS,
  }
  updateState(state, (disk) => { disk.offer = offer })
  return offer
}

/**
 * Which of the outstanding offer's tokens a phone presented, if either.
 * @param state - loaded state.
 * @param token - token presented by the app.
 * @param now - current epoch milliseconds.
 * @returns `scanned` for the QR token, `typed` for the short-code token,
 *   undefined for anything else or an expired offer.
 */
export function offerMatch(state: BridleState, token: string, now: number = Date.now()): 'scanned' | 'typed' | undefined {
  const offer = state.offer
  if (offer === undefined || offer.expiresAt <= now) return undefined
  // An offer without a `codeToken` was written by an older Bridle, which sent
  // its one token to the Relay too. `loadState` drops such an offer, but one
  // can also arrive mid-run — an older `bridle pair` beside this daemon — so
  // the match refuses it wherever it came from.
  if (typeof offer.codeToken !== 'string') return undefined
  // The tokens are high-entropy and single-use; a length-varying compare here
  // leaks nothing an attacker cannot already measure by trying.
  if (offer.token === token) return 'scanned'
  if (offer.codeToken === token) return 'typed'
  return undefined
}

/**
 * Act on a token a new device presented, deciding and writing in one step.
 *
 * Deciding from memory and writing afterwards let an offer replaced in between
 * — another `bridle pair` — be consumed or claimed with the old one's token.
 * The decision is made again on what is on disk, under the lock.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param key - the device's raw static public key.
 * @param name - the device name it reported.
 * @param token - the token it presented.
 * @param now - current epoch milliseconds.
 * @returns `paired` for the QR token, `claimed` for the short-code token,
 *   undefined when neither matches the offer on disk.
 */
export function redeemOffer(state: BridleState, key: Buffer, name: string, token: string, now: number = Date.now()): 'paired' | 'claimed' | undefined {
  // Most tokens that match nothing are strangers; turn them away without
  // taking the lock or touching the disk.
  const guess = offerMatch(state, token, now)
  if (guess === undefined) return undefined
  if (guess === 'typed' && state.offer?.claimant?.key === key.toString('base64url') && now - state.offer.claimant.at < CLAIM_REFRESH_MS) {
    return 'claimed'
  }
  const encoded = key.toString('base64url')
  return updateState(state, (disk) => {
    const presented = offerMatch(disk, token, now)
    if (presented === 'scanned') {
      const existing = disk.peers.find(peer => peer.key === encoded)
      if (existing !== undefined) {
        existing.name = name
        existing.lastSeen = now
      } else {
        disk.peers.push({ key: encoded, name, pairedAt: now, lastSeen: now })
      }
      delete disk.offer
      return 'paired'
    }
    if (presented === 'typed' && disk.offer !== undefined) {
      disk.offer.claimant = { key: encoded, name, at: now }
      return 'claimed'
    }
    return undefined
  })
}

/** How often a waiting claimant's retries are written back, at most. */
const CLAIM_REFRESH_MS = 30_000

/**
 * Accept the device waiting on the short code — only if it is still the one
 * the person was shown.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param key - base64url key of the claimant the person approved.
 * @param now - current epoch milliseconds.
 * @param code - the short code of the offer the person was looking at; a
 *   different offer on disk means theirs was replaced, and nothing is approved.
 * @returns whether that device is now paired.
 */
export function approveClaimant(state: BridleState, key: string, now: number = Date.now(), code?: string): boolean {
  return updateState(state, (disk) => {
    const claimant = disk.offer?.claimant
    if (code !== undefined && disk.offer?.code !== code) return false
    if (claimant === undefined || claimant.key !== key || (disk.offer?.expiresAt ?? 0) <= now) return false
    disk.peers.push({ key: claimant.key, name: claimant.name, pairedAt: now, lastSeen: now })
    delete disk.offer
    return true
  })
}

/**
 * Withdraw the outstanding offer: a refused claim, or a person who gave up.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param code - withdraw only the offer with this short code, so a `bridle
 *   pair` that lost track of time cannot take down a newer one.
 */
export function withdrawOffer(state: BridleState, code?: string): void {
  updateState(state, (disk) => {
    if (code === undefined || disk.offer?.code === code) delete disk.offer
  })
}

/**
 * Record a newly paired device and consume the offer.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param key - the device's raw static public key.
 * @param name - the device name reported by the app.
 * @param now - current epoch milliseconds.
 */
export function acceptPeer(state: BridleState, key: Buffer, name: string, now: number = Date.now()): void {
  const encoded = key.toString('base64url')
  updateState(state, (disk) => {
    const existing = disk.peers.find(peer => peer.key === encoded)
    if (existing !== undefined) {
      existing.name = name
      existing.lastSeen = now
    } else {
      disk.peers.push({ key: encoded, name, pairedAt: now, lastSeen: now })
    }
    delete disk.offer
  })
}

/**
 * Look up an already-paired device.
 * @param state - loaded state.
 * @param key - the device's raw static public key.
 * @returns the peer record, or undefined when the device is unknown.
 */
export function findPeer(state: BridleState, key: Buffer): PairedPeer | undefined {
  const encoded = key.toString('base64url')
  return state.peers.find(peer => peer.key === encoded)
}

/**
 * Update a peer's last-seen stamp.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param key - the device's raw static public key.
 * @param now - current epoch milliseconds.
 */
export function touchPeer(state: BridleState, key: Buffer, now: number = Date.now()): void {
  if (findPeer(state, key) === undefined) return
  updateState(state, (disk) => {
    const peer = findPeer(disk, key)
    if (peer !== undefined) peer.lastSeen = now
  })
}

/**
 * Remove a paired device.
 * @param state - loaded state; the change is written through {@link updateState}.
 * @param keyPrefix - full key or a unique base64url prefix.
 * @returns the removed peer, or undefined when nothing matched.
 */
export function revokePeer(state: BridleState, keyPrefix: string): PairedPeer | undefined {
  return updateState(state, (disk) => {
    const index = disk.peers.findIndex(peer => peer.key.startsWith(keyPrefix))
    if (index < 0) return undefined
    return disk.peers.splice(index, 1)[0]
  })
}
