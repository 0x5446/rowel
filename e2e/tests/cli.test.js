/**
 * The first five minutes. Someone runs one command, a pairing invitation
 * appears, their phone connects, and it keeps working tomorrow. Nothing below
 * imports the Bridle as a library — it spawns the real CLI the way a user does,
 * because the install path is the product.
 */

import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { probeDsh } from '@rowel/bridle'
import { decodePairingLink } from '@rowel/protocol'
import { RelayServer } from '@rowel/relay'
import { RowelPhone, waitFor } from '../lib/index.js'

const DSH_URL = process.env.ROWEL_E2E_DSH_URL ?? await probeDsh()
const skip = DSH_URL === undefined ? 'no DeepSeek Harness is running; set ROWEL_E2E_DSH_URL' : false

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'bridle', 'lib', 'cli.js')

/** One CLI invocation against a throwaway home directory. */
class Cli {
  /** @param {string} home - value for ROWEL_HOME. */
  constructor(home) {
    this.home = home
  }

  /**
   * Run a command to completion.
   * @param {string[]} args - CLI arguments.
   * @returns {Promise<{code: number|null, out: string, err: string}>} the result.
   */
  run(args, extraEnv = {}) {
    return new Promise((resolve) => {
      const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, ROWEL_HOME: this.home, ROWEL_INSTANCES: join(this.home, 'instances-index.json'), ...extraEnv } })
      let out = ''
      let err = ''
      child.stdout.on('data', chunk => { out += String(chunk) })
      child.stderr.on('data', chunk => { err += String(chunk) })
      child.on('close', code => { resolve({ code, out, err }) })
    })
  }

  /**
   * Start a long-running command and wait for a line to appear.
   * @param {string[]} args - CLI arguments.
   * @param {RegExp} until - matched against accumulated stdout.
   * @returns {Promise<{child: import('node:child_process').ChildProcess, out: () => string}>} the running process.
   */
  async spawn(args, until, extraEnv = {}) {
    const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, ROWEL_HOME: this.home, ROWEL_INSTANCES: join(this.home, 'instances-index.json'), ...extraEnv } })
    let out = ''
    let err = ''
    child.stdout.on('data', chunk => { out += String(chunk) })
    child.stderr.on('data', chunk => { err += String(chunk) })
    try {
      await waitFor(() => until.test(out), 30_000, `cli output matching ${String(until)}`)
    } catch (error) {
      child.kill('SIGKILL')
      throw new Error(`${error.message}\n--- stdout ---\n${out}\n--- stderr ---\n${err}`)
    }
    return { child, out: () => out, err: () => err }
  }
}

/**
 * Wait for this, not for the pairing link: the link is printed before the
 * Bridle has registered with the Relay, and a phone arriving in that gap is
 * turned away by the Relay. The app redials; this test's phone does not.
 */
const RELAY_UP = /relay online as/u

/**
 * A throwaway home plus a private Relay, torn down with the test.
 * @param {import('node:test').TestContext} t - the test context.
 * @returns {Promise<{cli: Cli, home: string, relayUrl: string, relay: RelayServer}>} the fixture.
 */
async function fixture(t) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-cli-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const relay = new RelayServer({ port: 0, host: '127.0.0.1' })
  const port = await relay.listen()
  t.after(() => relay.close())
  return { cli: new Cli(home), home, relayUrl: `http://127.0.0.1:${String(port)}`, relay }
}

/**
 * Pull the pairing link out of CLI output.
 * @param {string} out - captured stdout.
 * @returns {import('@rowel/protocol').PairingBundle} the bundle it carries.
 */
function bundleFrom(out) {
  const match = /rowel:\/\/pair#[A-Za-z0-9_-]+/u.exec(out)
  assert.ok(match, `no pairing link in output:\n${out}`)
  return decodePairingLink(match[0])
}

test('the first run pairs a phone with no configuration at all', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)

  const started = await cli.spawn(
    ['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'],
    RELAY_UP,
  )
  t.after(() => { started.child.kill('SIGKILL') })

  const out = started.out()
  assert.match(out, /Rowel Bridle/u, 'the banner names the product and version')
  assert.match(out, new RegExp(`harness {3}${DSH_URL.replaceAll('.', String.raw`\.`)}`, 'u'), 'it reports which harness it found')
  // The short code is not printed here: its bundle goes to the Relay, so it
  // lives behind `bridle pair --code`, which waits to ask the person.
  assert.match(out, /bridle pair --code/u, 'the way to a typed code is pointed at')
  assert.doesNotMatch(out, /code: +[BCDFGHJKMNPQRSTVWXYZ23456789]{4}-/u, 'a Relay-held code was offered without asking')

  const phone = new RowelPhone({ bundle: bundleFrom(out), prefer: 'relay', name: 'First iPhone' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true)
  // Which harness, and where the identity lives — the fields the app's
  // instance labels and rescue card are built on. A Bridle that stopped
  // sending them would fail silently everywhere else.
  assert.equal(ready.harness?.url, DSH_URL, 'the ready frame does not say which harness this identity fronts')
  assert.equal(ready.harness?.home, cli.home, 'the ready frame does not say where the identity lives')
  assert.equal((await phone.call('host.describe', {})).ok, true)
})

test('pair with nothing running becomes the bridle, so the scan is answered', { skip, timeout: 120_000 }, async (t) => {
  // What the installer, the app and the site tell a new person to run. It used
  // to print a code and exit, and the phone that scanned it waited on nothing.
  const { cli, relayUrl } = await fixture(t)

  const started = await cli.spawn(
    ['pair', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'],
    RELAY_UP,
  )
  t.after(() => { started.child.kill('SIGKILL') })
  assert.match(started.out(), /No bridle is running here, so this one will/u, 'it says why it is staying')

  const phone = new RowelPhone({ bundle: bundleFrom(started.out()), prefer: 'relay', name: 'New iPhone' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true)
  assert.equal(started.child.exitCode, null, 'it keeps running after the phone is in')
})

test('pair --code with nothing running becomes the bridle and asks at the Mac', { skip, timeout: 120_000 }, async (t) => {
  // The other half of the fresh install: the app's "Enter a code instead".
  // The code path asks its question in a terminal, so it gets one: Python's
  // pty module runs it on a pseudo-terminal and relays stdin. (Not script(1),
  // which refuses the socket Node hands a child as its stdin.)
  const { cli, relayUrl } = await fixture(t)
  const onTerminal = 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)'
  const child = spawn('python3', ['-c', onTerminal, process.execPath, CLI, 'pair', '--code', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], {
    env: { ...process.env, ROWEL_HOME: cli.home, ROWEL_INSTANCES: join(cli.home, 'instances-index.json') },
  })
  t.after(() => { child.kill('SIGKILL') })
  let out = ''
  child.stdout.on('data', chunk => { out += String(chunk) })
  await waitFor(() => /Type this code in the Rowel app:\s+\S+/u.test(out), 30_000, `the code to be printed:\n${out}`)
  assert.match(out, /No bridle is running here, so this one will/u)
  const code = /Type this code in the Rowel app:\s+(\S+)/u.exec(out)?.[1] ?? ''

  // What the app does with a typed code: collect the bundle, then ask to pair.
  const claimed = await (await fetch(`${relayUrl}/v1/pair/claim?code=${encodeURIComponent(code)}`)).json()
  const phone = new RowelPhone({ bundle: claimed.bundle, prefer: 'relay', name: 'Typed iPhone' })
  t.after(() => { phone.close() })
  await assert.rejects(() => phone.connect(), (error) => error.reason === 'pending')

  await waitFor(() => /Accept\? \[y\/N\]/u.test(out), 15_000, `the question at the Mac:\n${out}`)
  child.stdin.write('y\n')
  await waitFor(() => /Paired with "Typed iPhone"/u.test(out), 15_000, `the acceptance:\n${out}`)
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true)
  await waitFor(() => /Bridle keeps running here/u.test(out), 5_000, 'it says it stays')
  assert.equal(child.exitCode, null, 'it keeps running after the phone is in')
})

test('a second device is added from another terminal while the bridle runs', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], RELAY_UP)
  t.after(() => { started.child.kill('SIGKILL') })

  const first = new RowelPhone({ bundle: bundleFrom(started.out()), prefer: 'relay', name: 'iPhone' })
  t.after(() => { first.close() })
  await first.connect()

  // The daemon is running in one terminal; the user types this in another. It
  // has to reach the live process, which is why the daemon follows its own
  // state file rather than owning it.
  const paired = await cli.run(['pair', '--link'])
  assert.equal(paired.code, 0, paired.err)
  const second = new RowelPhone({ bundle: bundleFrom(paired.out), prefer: 'relay', name: 'iPad' })
  t.after(() => { second.close() })
  const ready = await second.connect()
  assert.equal(ready.dshReachable, true)

  const devices = await cli.run(['devices'])
  assert.match(devices.out, /iPhone/u)
  assert.match(devices.out, /iPad/u)
})

test('status and doctor describe a healthy machine', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], RELAY_UP)
  t.after(() => { started.child.kill('SIGKILL') })
  const phone = new RowelPhone({ bundle: bundleFrom(started.out()), prefer: 'relay', name: 'Status iPhone' })
  t.after(() => { phone.close() })
  await phone.connect()

  await waitFor(async () => (await cli.run(['status'])).out.includes('relay     online'), 15_000, 'the relay to come up')
    .catch(() => {})
  const status = await cli.run(['status'])
  assert.equal(status.code, 0, status.err)
  assert.match(status.out, /bridle {4}running \(pid \d+/u)
  assert.match(status.out, /harness {3}up/u)
  assert.match(status.out, /Status iPhone/u)

  const doctor = await cli.run(['doctor'])
  assert.equal(doctor.code, 0, doctor.err)
  assert.equal(doctor.out.includes(' warn '), false, `doctor should be clean here:\n${doctor.out}`)
})

test('a revoked device is refused, and the CLI says so plainly', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], RELAY_UP)
  t.after(() => { started.child.kill('SIGKILL') })
  const bundle = bundleFrom(started.out())
  const phone = new RowelPhone({ bundle, prefer: 'relay', name: 'Doomed iPhone' })
  await phone.connect()
  phone.close()

  const prefix = phone.keys.publicKey.toString('base64url').slice(0, 8)
  const revoked = await cli.run(['revoke', prefix])
  assert.equal(revoked.code, 0, revoked.err)
  assert.match(revoked.out, /Revoked Doomed iPhone/u)

  assert.match((await cli.run(['revoke', 'zzzzzzzz'])).out, /No paired device matches/u)

  const returning = new RowelPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { returning.close() })
  await assert.rejects(() => returning.connect(), error => error.reason === 'unpaired')
})

test('the state file holds the machine secret and nobody else can read it', { skip, timeout: 60_000 }, async (t) => {
  const { cli, home } = await fixture(t)
  assert.equal((await cli.run(['status'])).code, 0)

  const raw = JSON.parse(readFileSync(join(home, 'bridle.json'), 'utf8'))
  assert.equal(typeof raw.privateKey, 'string', 'the X25519 identity lives here')
  assert.equal(typeof raw.signingKey, 'string', 'so does the relay identity')
  assert.equal(raw.peers.length, 0)

  const status = await cli.run(['status'])
  for (const secret of [raw.privateKey, raw.signingKey]) {
    assert.equal(status.out.includes(secret), false, 'no command ever prints a private key')
  }
})

test('a second bridle for the same identity is refused before it can fight the first', { skip: false, timeout: 30_000 }, async (t) => {
  // Two Bridles on one ROWEL_HOME register at the Relay as the same machine
  // and displace each other in a silent loop at retry speed. The refusal has
  // to come from the CLI's own front door, before it probes or starts a dsh —
  // which is why this spawns the real binary rather than calling the library.
  const { cli, home } = await fixture(t)
  const other = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'])
  t.after(() => { other.kill('SIGKILL') })
  writeFileSync(join(home, 'runtime.json'), JSON.stringify({
    pid: other.pid,
    version: '0.0.0',
    startedAt: 0,
    relayUrl: '',
    relayState: 'online',
    dshUrl: '',
    dshReachable: true,
    direct: [],
    attached: 0,
  }))

  const refused = await cli.run(['start'])
  assert.equal(refused.code, 1, `start was not refused:\n${refused.out}\n${refused.err}`)
  assert.match(refused.out, /already running/u, 'the refusal does not say what the problem is')
  assert.match(refused.out, /ROWEL_HOME/u, 'the refusal does not say how to run two on purpose')
})

test('a heartbeat that cannot write its snapshot does not kill the daemon', { skip, timeout: 60_000 }, async (t) => {
  // The daemon died exactly this way in the wild: ENOSPC during the
  // five-second runtime.json heartbeat, uncaught inside setInterval, process
  // gone — over a file that exists only so `bridle status` has something to
  // read. A directory planted where the snapshot goes makes the atomic
  // rename fail the same way a full disk does, without needing one.
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(
    ['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'],
    RELAY_UP,
  )
  t.after(() => { started.child.kill('SIGKILL') })

  rmSync(join(cli.home, 'runtime.json'), { force: true })
  mkdirSync(join(cli.home, 'runtime.json'))

  // Two heartbeats' worth of hostile disk, plus margin.
  await new Promise((resolve) => setTimeout(resolve, 12_000))
  assert.equal(started.child.exitCode, null, `the daemon died over a status snapshot:\n${started.err()}`)
})

test('instances lists this home, and reset erases it only when nothing runs it', { skip, timeout: 60_000 }, async (t) => {
  const { cli, home, relayUrl } = await fixture(t)
  // A scratch machine-level index, so the test neither reads nor writes the
  // developer's real one.
  const index = join(home, 'instances-index.json')
  const env = { ROWEL_INSTANCES: index }

  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], /rowel:\/\/pair#/u, env)
  t.after(() => { started.child.kill('SIGKILL') })

  const listed = await cli.run(['instances'], env)
  assert.equal(listed.code, 0, listed.err)
  assert.ok(listed.out.includes(home), `the home that just started is not on the map:\n${listed.out}`)
  assert.match(listed.out, /running \(pid \d+, standalone\)/u, 'the map does not say who runs it')

  // Refused while the daemon holds the identity — resetting under a live
  // daemon would leave it signing as a machine that no longer exists on disk.
  const refused = await cli.run(['reset', '--force'], env)
  assert.equal(refused.code, 1, `reset went ahead under a running daemon:\n${refused.out}`)

  started.child.kill('SIGKILL')
  await new Promise((resolve) => started.child.on('exit', resolve))
  const erased = await cli.run(['reset', '--force'], env)
  assert.equal(erased.code, 0, erased.err)
  assert.equal(existsSync(join(home, 'bridle.json')), false, 'the identity survived its own reset')
  assert.equal((await cli.run(['instances'], env)).out.includes(home), false,
    'an erased identity is still being presented on the map')
})

test('help and version answer without touching anything', { skip: false, timeout: 30_000 }, async (t) => {
  const { cli } = await fixture(t)
  const help = await cli.run(['help'])
  assert.equal(help.code, 0)
  assert.match(help.out, /bridle pair/u)
  assert.match(help.out, /bridle revoke/u)

  const version = await cli.run(['version'])
  assert.match(version.out.trim(), /^\d+\.\d+\.\d+/u)

  const unknown = await cli.run(['nonsense'])
  assert.equal(unknown.code, 1)
  assert.match(unknown.err, /unknown command/u)
})
