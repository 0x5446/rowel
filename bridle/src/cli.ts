#!/usr/bin/env node
/**
 * The whole computer-side surface of Rowel: one command, sensible defaults, and
 * a first run that ends with a QR code on screen and nothing else to decide.
 *
 * `bridle` finds the harness, starts it if it is not running, opens a tunnel
 * out to the Relay, and prints an invitation. Everything else here is for the
 * days after that.
 */

import { readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import QRCode from 'qrcode'
import { keyFingerprint } from '@rowel/protocol'
import { BridleCore } from './core.ts'
import { DirectServer } from './direct-server.ts'
import { DshClient } from './dsh/client.ts'
import { dshHomeUrl, ensureDsh, probeDsh } from './dsh/discovery.ts'
import { approveClaimant, loadState, overrideState, reloadState, rowelHome, revokePeer, saveState, signingKeys, staticKeys, updateState, withdrawOffer } from './identity.ts'
import { deviceIdFor } from '@rowel/protocol'
import { BackupError, describeBackup, exportIdentity, importIdentity } from './backup.ts'
import { createInvitation, publishInvitation, toHttpUrl, type Invitation } from './pair.ts'
import { RelayClient } from './relay-client.ts'
import { clearRuntime, competingDaemon, readRuntime, writeRuntime } from './runtime.ts'
import { holdsIdentity, listInstances, rememberInstance } from './instances.ts'
import { installService, serviceLogPath, uninstallService } from './service.ts'

const VERSION = readVersion()

/** Parsed command line. */
interface Options {
  command: string
  flags: Map<string, string | true>
}

/**
 * Entry point.
 * @param argv - process arguments after the node binary and script.
 */
async function main(argv: string[]): Promise<void> {
  const options = parse(argv)
  switch (options.command) {
    case 'start':
      await start(options)
      return
    case 'pair':
      await pair(options)
      return
    case 'status':
      await status()
      return
    case 'instances':
      instances()
      return
    case 'reset':
      await reset(options)
      return
    case 'devices':
      devices()
      return
    case 'revoke':
      revoke(options)
      return
    case 'service':
      service(options)
      return
    case 'backup':
      await backup(options)
      return
    case 'restore':
      await restore(options)
      return
    case 'doctor':
      await doctor()
      return
    case 'version':
      process.stdout.write(`${VERSION}\n`)
      return
    case 'help':
      usage()
      return
    default:
      process.stderr.write(`unknown command: ${options.command}\n\n`)
      usage()
      process.exitCode = 1
  }
}

function parse(argv: string[]): Options {
  const flags = new Map<string, string | true>()
  let command = 'start'
  let seenCommand = false
  const positional: string[] = []
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? ''
    if (token.startsWith('--')) {
      const [name, inline] = splitFlag(token.slice(2))
      const next = argv[index + 1]
      if (inline !== undefined) flags.set(name, inline)
      else if (next !== undefined && !next.startsWith('--')) {
        flags.set(name, next)
        index += 1
      } else flags.set(name, true)
      continue
    }
    if (!seenCommand) {
      command = token
      seenCommand = true
      continue
    }
    positional.push(token)
  }
  if (positional.length > 0) flags.set('_', positional.join(' '))
  return { command, flags }
}

function splitFlag(token: string): [string, string | undefined] {
  const at = token.indexOf('=')
  return at < 0 ? [token, undefined] : [token.slice(0, at), token.slice(at + 1)]
}

function flagString(options: Options, name: string): string | undefined {
  const value = options.flags.get(name)
  return typeof value === 'string' ? value : undefined
}

function flagBoolean(options: Options, name: string): boolean {
  return options.flags.has(name) && options.flags.get(name) !== 'false'
}

async function start(options: Options): Promise<void> {
  const startedAt = Date.now()
  const state = loadState()

  // One Bridle per identity, refused before anything is touched. Two of them
  // register at the Relay as the same machine and displace each other in a
  // silent loop at retry speed; the usual way it happens is not running this
  // command twice but running it while the dsh plugin already holds ~/.rowel.
  const incumbent = competingDaemon()
  if (incumbent !== undefined) {
    say(`a Bridle for this identity is already running (pid ${String(incumbent.pid)}, ${incumbent.version}) — likely the dsh plugin or an installed service.`)
    say('Stop that one first, or give this one its own home with ROWEL_HOME.')
    process.exitCode = 1
    return
  }
  // Claimed now, not when the relay comes up: `ensureDsh` below may start dsh,
  // and a dsh that carries the plugin would otherwise read an unclaimed home
  // during exactly that window and start a second Bridle for it.
  writeRuntime({
    pid: process.pid,
    version: VERSION,
    via: 'cli',
    startedAt,
    relayUrl: state.relayUrl,
    relayState: 'offline',
    dshUrl: state.dshUrl,
    dshReachable: false,
    direct: [],
    attached: 0,
  })
  // On the machine's map from the moment the identity is claimed, so
  // `bridle instances` can answer for this home even after this daemon stops.
  rememberInstance()

  const relayOverride = flagString(options, 'relay')
  if (relayOverride !== undefined) {
    updateState(state, (disk) => { disk.relayUrl = relayOverride })
    // Also for this run, over any `ROWEL_RELAY_URL`: the flag is the later word.
    overrideState(state, { relayUrl: relayOverride })
  }
  const dshOverride = flagString(options, 'dsh')

  say(`Rowel Bridle ${VERSION} · ${state.machineName}`)
  // Binding resolution, strongest anchor first:
  //   --dsh <url>        a person named an address        → pinned
  //   --dsh-home <path>  a person named a *world*; its own
  //                      config says where it answers      → pinned, derived
  //   remembered dshUrl  where it answered last time       → races first
  // A home is the strongest anchor because the home *is* the instance — and
  // a home that declares its port also cannot be double-booted (EADDRINUSE
  // is the lock), so the derived URL names the identity, not an incarnation.
  const homeOverride = flagString(options, 'dsh-home') ?? state.dshHome
  let homeUrl: string | undefined
  if (dshOverride === undefined && homeOverride !== undefined) {
    homeUrl = dshHomeUrl(homeOverride)
    if (homeUrl === undefined) {
      say(`${homeOverride} does not declare its address — add a webserver entry (host + port) to`)
      say(`${join(homeOverride, 'profiles/web/cordis.patch.yml')}, or bind by URL with --dsh.`)
      process.exitCode = 1
      return
    }
    if (flagString(options, 'dsh-home') !== undefined && state.dshHome !== homeOverride) {
      updateState(state, (disk) => { disk.dshHome = homeOverride })
    }
  }
  const discovered = await ensureDsh({
    // The remembered binding races first; `--dsh` and `--dsh-home` pin it
    // outright. Without the remembered URL as preferred, every restart
    // re-rolled the binding by port order — a machine running a second dsh
    // could wake up served by the wrong one, silently.
    preferred: dshOverride ?? homeUrl ?? state.dshUrl,
    pinned: dshOverride !== undefined || homeUrl !== undefined,
    autoStart: !flagBoolean(options, 'no-auto-start'),
    ...(flagString(options, 'dsh-command') === undefined ? {} : { command: flagString(options, 'dsh-command') as string }),
    log: say,
  })
  if (discovered.url !== state.dshUrl && dshOverride === undefined) {
    // Adopting a different URL is legitimate — dsh port-falls-back on its
    // own — but it is never silent: on a machine with more than one dsh,
    // "moved" and "wrong harness" look identical from here, and only the
    // person can tell them apart.
    say(`harness   moved: ${state.dshUrl} did not answer; now bound to ${discovered.url}`)
    say('          (a different dsh means different conversations — use --dsh to rebind deliberately)')
  }
  // Remembered, so the next start races this address first — unless it came
  // from `ROWEL_DSH_URL`, which describes this run and not the machine.
  const dshFromEnvironment = (process.env['ROWEL_DSH_URL'] ?? '').length > 0
  if (dshFromEnvironment) overrideState(state, { dshUrl: discovered.url })
  else if (discovered.url !== state.dshUrl) updateState(state, (disk) => { disk.dshUrl = discovered.url })
  const core = new BridleCore(state, { dsh: new DshClient({ baseUrl: discovered.url }) })
  await core.start()
  say(`harness   ${discovered.url}${discovered.launched ? ' (started by bridle)' : ''}`)

  let direct: DirectServer | undefined
  let directAddresses: string[] = []
  if (!flagBoolean(options, 'no-direct')) {
    const port = Number(flagString(options, 'direct-port') ?? '0')
    direct = new DirectServer(core, { version: VERSION, port, log: () => {} })
    await direct.listen()
    directAddresses = direct.addresses
    if (directAddresses.length > 0) say(`local     ${directAddresses[0] ?? ''}`)
  }

  // An address this machine cannot discover for itself: a Cloudflare Tunnel
  // hostname, an ngrok URL, a port-forwarded public address. Interface
  // enumeration finds LAN and tailnet addresses on its own, but a name that
  // resolves to someone else's edge only exists if it is stated.
  //
  // It goes first: someone who set this up did so because it is the path they
  // want used.
  const advertised = (flagString(options, 'advertise') ?? '')
    .split(',')
    .map(entry => entry.trim())
    .filter(entry => entry.length > 0)
  if (advertised.length > 0) {
    directAddresses = [...advertised, ...directAddresses]
    for (const entry of advertised) say(`advertised ${entry}`)
  }
  // Published to every app in the ready frame, so a phone paired on one
  // network learns where this machine lives on the next one.
  core.directAddresses = () => [...advertised, ...(direct?.addresses ?? [])]

  const relay = new RelayClient(core, {
    version: VERSION,
    log: say,
    onState: (next) => { publish(next) },
  })
  relay.start()
  say(`relay     ${state.relayUrl}`)

  function publish(relayState: 'offline' | 'connecting' | 'online' = relay.connectionState): void {
    // A snapshot nobody can write is not worth the daemon. This runs from a
    // five-second timer and from relay state changes, and a throw from either
    // is an uncaught exception — observed in the wild as a full disk (ENOSPC)
    // killing a healthy Bridle mid-heartbeat, over a file that exists only so
    // `bridle status` has something to read. The claim written at startup
    // stays loud; it is the single-instance lock and failing it must stop the
    // start. This one just goes quiet until the disk comes back.
    try {
      unsafePublish(relayState)
    } catch {
      // The next heartbeat retries in five seconds.
    }
  }

  function unsafePublish(relayState: 'offline' | 'connecting' | 'online'): void {
    writeRuntime({
      pid: process.pid,
      version: VERSION,
      via: 'cli',
      startedAt,
      relayUrl: state.relayUrl,
      relayState,
      dshUrl: state.dshUrl,
      dshReachable: core.dshStatus.reachable,
      direct: directAddresses,
      attached: relay.attachedCircuits,
    })
  }
  publish()
  const heartbeat = setInterval(() => { publish() }, 5_000)
  heartbeat.unref()

  if (state.peers.length === 0 || flagBoolean(options, 'pair')) {
    say('')
    const invitation = createInvitation(state, directAddresses)
    await printInvitation(invitation, state, flagBoolean(options, 'link'))
  } else {
    say(`paired    ${String(state.peers.length)} device${state.peers.length === 1 ? '' : 's'} · run "bridle pair" to add another`)
  }

  const shutdown = (): void => {
    clearInterval(heartbeat)
    relay.stop()
    direct?.close()
    core.stop()
    clearRuntime()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
  await new Promise<never>(() => {})
}

async function pair(options: Options): Promise<void> {
  const state = loadState()
  const runtime = readRuntime()
  if (runtime === undefined) {
    say('No bridle is running on this machine. Start one with "bridle start" first,')
    say('or keep this invitation and start it before scanning.')
    say('')
  }
  if (flagBoolean(options, 'code') && runtime === undefined) {
    // The running Bridle is what records the phone's request; without one the
    // phone would wait for a question this command can never ask.
    say('"bridle pair --code" needs a running bridle. Start one with "bridle start", then run this again.')
    process.exitCode = 1
    return
  }
  const invitation = createInvitation(state, runtime?.direct ?? [])
  if (!flagBoolean(options, 'code')) {
    await printInvitation(invitation, state, flagBoolean(options, 'link'))
    return
  }
  await pairByCode(state, invitation)
}

/**
 * The short-code path: publish, then wait here for the phone and ask.
 *
 * The Relay holds the bundle a typed code fetches, so a phone that presents
 * it is only a claim until a person at this Mac says yes (see `pair.ts`). The
 * question is asked in this terminal, which is why this command stays in the
 * foreground until the phone turns up, the offer lapses, or the answer is no.
 */
async function pairByCode(state: ReturnType<typeof loadState>, invitation: Invitation): Promise<void> {
  const code = invitation.code
  if (process.stdin.isTTY !== true) {
    withdrawOffer(state, code)
    say('"bridle pair --code" has to ask you to accept the phone, so it needs a terminal.')
    say('Scan the QR from "bridle pair" instead, or run this where you can answer.')
    process.exitCode = 1
    return
  }
  try {
    await publishInvitation(state, invitation)
  } catch (error) {
    withdrawOffer(state, code)
    say(`The Relay did not take the code: ${error instanceof Error ? error.message : String(error)}`)
    say('Scan the QR from "bridle pair" instead — it does not need the Relay.')
    process.exitCode = 1
    return
  }
  say(`Type this code in the Rowel app:   ${invitation.code}`)
  say(`expires:                           ${new Date(invitation.expiresAt).toLocaleTimeString()}`)
  say('')
  say('Waiting for the phone… (Ctrl-C to give up)')
  // Giving up withdraws the code. Left open, a phone that typed it would wait
  // on "accept this iPhone on your Mac" for the rest of its fifteen minutes,
  // with nothing on the Mac left to ask.
  const giveUp = (): void => {
    withdrawOffer(state, code)
    process.exit(130)
  }
  process.once('SIGINT', giveUp)
  try {
    await awaitClaim(state, code)
  } finally {
    process.removeListener('SIGINT', giveUp)
  }
}

/** Poll for the phone that typed `code`, and ask the person about it. */
async function awaitClaim(state: ReturnType<typeof loadState>, code: string): Promise<void> {
  let asked: string | undefined
  for (;;) {
    await new Promise((resolve) => setTimeout(resolve, CLAIM_POLL_MS))
    reloadState(state)
    const offer = state.offer
    if (offer?.code !== code) {
      // Used by a scan of its QR, withdrawn, or replaced by a newer
      // `bridle pair` — whose offer is not this command's to judge.
      say('This invitation is no longer open.')
      return
    }
    if (offer.expiresAt <= Date.now()) {
      withdrawOffer(state, code)
      say('The code expired before a phone accepted it. Run "bridle pair --code" again.')
      process.exitCode = 1
      return
    }
    const claimant = offer.claimant
    if (claimant === undefined || claimant.key === asked) continue
    asked = claimant.key
    say('')
    // The key first, and the name quoted: the name is whatever the asker sent,
    // and the asker may be the Relay. `session.ts` already strips control
    // characters from it; quoting keeps anything odd that remains visible.
    say(`A phone asks to pair with this Mac. Its key:  ${keyFingerprint(Buffer.from(claimant.key, 'base64url'))}`)
    say(`It calls itself ${JSON.stringify(claimant.name)}.`)
    say('The phone shows its own key while it waits. Accept only if the two are the same:')
    say('anyone holding the code could be asking, including the Relay.')
    const answer = (await readLine('Accept? [y/N] ')).trim().toLowerCase()
    if (answer !== 'y' && answer !== 'yes') {
      withdrawOffer(state, code)
      say('Refused. The code no longer works.')
      return
    }
    if (approveClaimant(state, claimant.key, code)) {
      say(`Paired with ${JSON.stringify(claimant.name)}. The phone connects on its next try, within a few seconds.`)
      return
    }
    // Ask again about whoever is claiming now — even the same phone, which
    // may have been displaced for a moment while the person was deciding.
    asked = undefined
    say('That request changed or expired while you were deciding; still waiting.')
  }
}

/** How often `bridle pair --code` looks for a claiming phone. */
const CLAIM_POLL_MS = 500

async function printInvitation(invitation: Invitation, state: ReturnType<typeof loadState>, forceLink = false): Promise<void> {
  // Block-drawing QR codes only survive a real terminal. Over SSH into a log,
  // in CI, or piped anywhere, the link is the thing that still works.
  const drawable = process.stdout.isTTY === true
  if (drawable) {
    const qr = await QRCode.toString(invitation.link, { type: 'terminal', small: true, errorCorrectionLevel: 'M' })
    say('Scan this in the Rowel app:')
    process.stdout.write(`\n${qr}\n`)
  } else {
    say('Pair the Rowel app with this link:')
  }
  if (forceLink || !drawable) say(`link:                ${invitation.link}`)
  say(`machine:             ${state.machineName}`)
  // A QR code belongs to an identity, and an identity fronts exactly one dsh.
  // Say which one, or the person running two homes has to guess.
  const dshUrl = readRuntime()?.dshUrl ?? state.dshUrl
  say(`harness:             ${dshUrl}${state.dshHome === undefined ? '' : ` · DSH_HOME ${state.dshHome}`}`)
  say(`identity:            ${keyFingerprint(staticKeys(state).publicKey)}`)
  say(`expires:             ${new Date(invitation.expiresAt).toLocaleTimeString()}`)
  say('')
  say('No camera? "bridle pair --code" gives a code to type instead.')
  say('No app yet? Get it at https://rowel.novabox.ai/get')
}

/**
 * Write an encrypted copy of this machine's identity.
 *
 * Without this, `~/.rowel/bridle.json` is a single point of failure with no
 * recovery: lose it and every paired phone stops recognising the machine, with
 * no way to tell them apart from an impostor.
 * @param options - parsed command line; the positional argument is the path.
 */
async function backup(options: Options): Promise<void> {
  const target = flagString(options, '_')
  if (target === undefined) {
    say('Usage: bridle backup <file>')
    process.exitCode = 1
    return
  }
  const state = loadState()
  const passphrase = await readSecret('Passphrase for the backup: ')
  const again = await readSecret('Again: ')
  if (passphrase !== again) {
    say('Those did not match. Nothing was written.')
    process.exitCode = 1
    return
  }
  const deviceId = deviceIdFor(signingKeys(state).publicKey)
  try {
    writeFileSync(target, exportIdentity(state, passphrase, deviceId), { mode: 0o600 })
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }
  say(`Wrote ${target} (0600).`)
  say(`It holds this machine's key and ${String(state.peers.length)} paired device(s).`)
  say('Anyone with this file and its passphrase can become this machine. Store it accordingly.')
}

/**
 * Replace this machine's identity with a saved one.
 *
 * Destructive, so it says exactly what it is about to displace and requires the
 * word "replace" — the person doing this is usually mid-migration and tired.
 * @param options - parsed command line; the positional argument is the path.
 */
async function restore(options: Options): Promise<void> {
  const source = flagString(options, '_')
  if (source === undefined) {
    say('Usage: bridle restore <file>')
    process.exitCode = 1
    return
  }
  let archive: string
  try {
    archive = readFileSync(source, 'utf8')
  } catch {
    say(`Could not read ${source}`)
    process.exitCode = 1
    return
  }

  let summary
  try {
    summary = describeBackup(archive)
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }

  const current = loadState()
  say(`Backup:  ${summary.machineName} · ${String(summary.peerCount)} device(s) · saved ${summary.exportedAt}`)
  say(`Current: ${current.machineName} · ${String(current.peers.length)} device(s)`)
  say('')
  say('Restoring replaces this machine\'s key. Devices paired to the *current*')
  say('identity will stop recognising it, and devices in the backup will start.')
  const confirm = await readLine('Type "replace" to continue: ')
  if (confirm.trim() !== 'replace') {
    say('Nothing changed.')
    return
  }

  const passphrase = await readSecret('Passphrase: ')
  try {
    saveState(importIdentity(archive, passphrase))
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }
  say('Restored. Restart the bridle for it to take effect.')
}

/**
 * Whether the running process predates the code sitting on disk.
 *
 * Node caches a module for the life of the process, and a Bridle that runs as
 * a dsh plugin is started once and left for days. So a rebuild changes the
 * files and changes nothing about what is actually serving phones — and the
 * two disagree silently, because an old Bridle handles a new frame exactly as
 * the protocol says it should: it does not recognise it and ignores it
 * (docs/protocol.md §4.3).
 *
 * Cost a day of debugging once. A phone was sending its push token, a Bridle
 * from thirty hours earlier was dropping it on the floor, and every layer
 * looked correct in isolation — the app sent, the tunnel carried, the machine
 * received. Nothing was broken except which build was in memory.
 * @param startedAt - epoch milliseconds the running process wrote at startup.
 * @returns a human-readable build time when the disk is newer, else undefined.
 */
function builtAfter(startedAt: number): string | undefined {
  const lib = dirname(fileURLToPath(import.meta.url))
  let newest = 0
  const walk = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name.endsWith('.js')) newest = Math.max(newest, statSync(full).mtimeMs)
    }
  }
  try {
    walk(lib)
  } catch (error) {
    // Only a missing or unreadable tree is tolerated — an installation that
    // does not look like a build cannot be judged, and guessing would cry wolf
    // on every status.
    //
    // Narrow on purpose. The first version caught everything, and what it
    // caught was a ReferenceError from two functions this file had never
    // imported: the check silently reported "nothing stale" for every run,
    // which is precisely the failure it exists to prevent. A feature built to
    // expose silent failure is the last place to swallow one.
    const code = (error as NodeJS.ErrnoException).code
    if (code !== 'ENOENT' && code !== 'ENOTDIR' && code !== 'EACCES') throw error
    return undefined
  }
  // A minute of slack: the process writes `startedAt` a moment after the files
  // it loaded were stamped, and a rebuild that happens to land in that window
  // is the one case where the two are genuinely the same code.
  if (newest <= startedAt + 60_000) return undefined
  return new Date(newest).toLocaleString()
}

async function status(): Promise<void> {
  const state = loadState()
  const runtime = readRuntime()
  say(`machine   ${state.machineName}`)
  say(`identity  ${keyFingerprint(staticKeys(state).publicKey)}`)
  say(`device    ${state.deviceId}`)
  say(`state     ${join(rowelHome(), 'bridle.json')}`)
  if (runtime === undefined) {
    say('bridle    not running · start it with "bridle start"')
  } else {
    say(`bridle    running (pid ${String(runtime.pid)}, ${VERSION}${runtime.via === 'plugin' ? ', inside dsh' : ''}) · ${String(runtime.attached)} attached`)
    const stale = builtAfter(runtime.startedAt)
    if (stale !== undefined) {
      say(`          ⚠ running code from before ${stale} — restart to pick up the build on disk`)
    }
    say(`relay     ${runtime.relayState} · ${runtime.relayUrl}`)
    if (runtime.direct.length > 0) say(`local     ${runtime.direct.join(', ')}`)
  }
  const dshUrl = runtime?.dshUrl ?? state.dshUrl
  const health = await new DshClient({ baseUrl: dshUrl }).health()
  say(`harness   ${health.reachable ? 'up' : 'down'} · ${dshUrl}${state.dshHome === undefined ? '' : ` · DSH_HOME ${state.dshHome}`}${health.reachable ? '' : ` (${health.detail ?? 'no answer'})`}`)
  say('')
  printDevices(state)
}

function devices(): void {
  printDevices(loadState())
}

function printDevices(state: ReturnType<typeof loadState>): void {
  if (state.peers.length === 0) {
    say('No paired devices. Run "bridle pair" to add one.')
    return
  }
  say(`Paired devices (${String(state.peers.length)}):`)
  for (const peer of state.peers) {
    const seen = new Date(peer.lastSeen).toLocaleString()
    say(`  ${peer.key.slice(0, 8)}  ${peer.name.padEnd(20)} last seen ${seen}`)
  }
}

function revoke(options: Options): void {
  const target = flagString(options, '_')
  if (target === undefined) {
    say('Usage: bridle revoke <device-id-prefix>   (see "bridle devices")')
    process.exitCode = 1
    return
  }
  const state = loadState()
  const removed = revokePeer(state, target)
  if (removed === undefined) {
    say(`No paired device matches ${target}.`)
    process.exitCode = 1
    return
  }
  say(`Revoked ${removed.name} (${removed.key.slice(0, 8)}).`)
  say('It will be refused at the next handshake; restart bridle to drop a live tunnel.')
}

function service(options: Options): void {
  const action = flagString(options, '_') ?? 'install'
  if (action === 'install') {
    const outcome = installService()
    say(outcome.detail)
    say(`file: ${outcome.path}`)
    say(`log:  ${serviceLogPath()}`)
    return
  }
  if (action === 'uninstall') {
    const outcome = uninstallService()
    say(outcome.detail)
    return
  }
  say('Usage: bridle service install | bridle service uninstall')
  process.exitCode = 1
}

/**
 * Every identity on this machine, one glance.
 *
 * Everything else in this file speaks about one ROWEL_HOME; this is the
 * command that answers the question that comes before all of them. Read
 * fresh from each home's own files — the index remembers only paths.
 */
function instances(): void {
  const found = listInstances()
  if (found.length === 0) {
    say('no identities on this machine yet · "bridle start" creates one')
    return
  }
  const current = rowelHome()
  for (const instance of found) {
    say(instance.home === current ? `${instance.home}   ← current ROWEL_HOME` : instance.home)
    say(`  machine   ${instance.machineName}`)
    say(`  device    ${instance.deviceId}`)
    if (instance.running === undefined) {
      say('  bridle    not running')
    } else {
      const doorway = instance.running.via === 'plugin' ? 'inside dsh' : 'standalone'
      say(`  bridle    running (pid ${String(instance.running.pid)}, ${doorway}) · relay ${instance.running.relayState}`)
    }
    say(`  harness   ${instance.dshUrl}`)
    say(`  devices   ${String(instance.peers)} paired`)
    say('')
  }
  say('Commands act on one identity at a time:')
  say('  ROWEL_HOME=<path> bridle status | pair | revoke | reset')
}

/**
 * Erase this home's identity, deliberately and loudly.
 *
 * The one thing `rm -rf` was previously the only way to do. Refused while a
 * daemon holds the identity — resetting under a live daemon would leave it
 * signing as a machine that no longer exists on disk — and confirmed by
 * typing the machine's name, because everything downstream of this is
 * one-way: every paired phone keeps a dead entry it must forget by hand.
 */
async function reset(options: Options): Promise<void> {
  const home = rowelHome()
  if (!holdsIdentity(home)) {
    say(`nothing to reset · ${home} holds no identity`)
    return
  }
  const running = readRuntime()
  if (running !== undefined) {
    const doorway = running.via === 'plugin' ? 'the dsh plugin — restart dsh without it, or stop dsh' : `pid ${String(running.pid)} — stop it`
    say(`this identity is in use by ${doorway} first.`)
    process.exitCode = 1
    return
  }
  const state = loadState()
  say(`This erases the identity in ${home}:`)
  say(`  machine   ${state.machineName}`)
  say(`  devices   ${String(state.peers.length)} paired — each phone will keep a dead entry it must forget by hand`)
  if (!flagBoolean(options, 'force')) {
    const typed = await readLine(`Type the machine name (${state.machineName}) to continue: `)
    if (typed.trim() !== state.machineName) {
      say('names did not match; nothing was touched.')
      process.exitCode = 1
      return
    }
  }
  for (const entry of ['bridle.json', 'runtime.json', 'secrets']) {
    rmSync(join(home, entry), { recursive: true, force: true })
  }
  say('erased. The next "bridle start" here creates a fresh identity with a new pairing.')
}

async function doctor(): Promise<void> {
  const state = loadState()
  const major = Number(process.versions.node.split('.')[0] ?? '0')
  check(major >= 22, `node ${process.versions.node}`, 'Rowel needs Node 22 or newer')
  const found = await probeDsh(state.dshUrl)
  check(found !== undefined, `harness at ${found ?? state.dshUrl}`, 'no dsh web server answered; "bridle start" can launch one')
  let relayReachable = false
  let relayDetail = ''
  try {
    const response = await fetch(new URL('/healthz', toHttpUrl(state.relayUrl)), { signal: AbortSignal.timeout(5_000) })
    relayReachable = response.ok
    relayDetail = `HTTP ${String(response.status)}`
  } catch (error) {
    relayDetail = error instanceof Error ? error.message : String(error)
  }
  check(relayReachable, `relay ${state.relayUrl}`, `relay unreachable (${relayDetail}); the local network path still works`)
  check(state.peers.length > 0, `${String(state.peers.length)} paired device(s)`, 'nothing paired yet; run "bridle pair"')
}

function check(ok: boolean, good: string, bad: string): void {
  say(`${ok ? '  ok  ' : ' warn '} ${ok ? good : bad}`)
}

function usage(): void {
  process.stdout.write(`Rowel Bridle ${VERSION} — reach your local DeepSeek Harness from your phone.

  bridle                    start the bridle (and pair, on first run)
  bridle pair               show a new pairing QR (--code: a code to type instead)
  bridle status             machine, relay, harness, and paired devices
  bridle devices            list paired devices
  bridle instances          every identity on this machine, and who runs it
  bridle reset              erase this identity (ROWEL_HOME picks which)
  bridle revoke <prefix>    remove a paired device
  bridle service install    keep the bridle running after login
  bridle service uninstall  remove the background service
  bridle backup <file>      save this machine's identity, encrypted
  bridle restore <file>     put a saved identity back (replaces the current one)
  bridle doctor             check this machine's setup

Options for start:
  --relay <url>       Relay to dial out to (default: the public Relay)
  --dsh <url>         harness address, if it is not on a usual port
  --dsh-home <path>   bind to the dsh living in this DSH_HOME; its own config
                      (webserver host+port) says where it answers
  --dsh-command <cmd> how to launch the harness (default: dsh)
  --direct-port <n>   fixed port for the local-network tunnel
  --advertise <url>   extra address(es) to put in the pairing code, comma
                      separated. For a tunnel hostname the machine cannot
                      discover itself, e.g. wss://rowel.example.com. LAN and
                      Tailscale addresses are found automatically.
  --no-direct         do not listen on the local network
  --no-auto-start     never launch the harness
  --pair              show a pairing invitation even if devices are paired
  --link              also print the raw pairing link (useful over SSH)
`)
}

function say(message: string): void {
  process.stdout.write(`${message}\n`)
}

/**
 * Read one line from the terminal.
 * @param prompt - shown before the cursor.
 * @returns what was typed, without the newline.
 */
let lines: AsyncIterator<string> | undefined

async function readLine(prompt: string): Promise<string> {
  process.stdout.write(prompt)
  // One interface for the whole process, created lazily. A fresh
  // `createInterface` per prompt reads ahead and swallows the lines the *next*
  // prompt was going to get — invisible on a terminal, and it silently ate the
  // second line of every piped `printf 'pass\npass\n' | bridle backup`.
  lines ??= createInterface({ input: process.stdin, terminal: false })[Symbol.asyncIterator]()
  const next = await lines.next()
  return next.done === true ? '' : next.value
}

/**
 * Read a line without echoing it.
 *
 * Falls back to a visible read when stdin is not a terminal — a pipe has no
 * echo to suppress, and refusing there would break scripted restores.
 * @param prompt - shown before the cursor.
 * @returns what was typed.
 */
async function readSecret(prompt: string): Promise<string> {
  if (!process.stdin.isTTY) return readLine(prompt)
  process.stdout.write(prompt)
  process.stdin.setRawMode(true)
  process.stdin.resume()
  let value = ''
  try {
    for await (const chunk of process.stdin) {
      const text = String(chunk)
      // Ctrl-C and Ctrl-D during a passphrase prompt mean "stop", not "submit
      // what I have so far".
      if (text.includes('\u0003') || text.includes('\u0004')) {
        process.stdout.write('\n')
        process.exit(130)
      }
      if (text.includes('\r') || text.includes('\n')) {
        value += text.split(/[\r\n]/u)[0] ?? ''
        break
      }
      // Backspace, so a typo is recoverable without restarting the command.
      if (text === '\u007f' || text === '\b') {
        value = value.slice(0, -1)
        continue
      }
      value += text
    }
  } finally {
    process.stdin.setRawMode(false)
    process.stdin.pause()
    process.stdout.write('\n')
  }
  return value
}

function readVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url))
    const manifest = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8')) as { version?: string }
    return manifest.version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

main(process.argv.slice(2)).catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(1)
})
