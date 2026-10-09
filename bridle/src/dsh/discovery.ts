/**
 * Finding, and if necessary starting, the dsh a Bridle should serve.
 *
 * The friction this removes is real: a person installing Rowel should not have
 * to know which port their harness picked, or start it by hand before opening
 * the app. Bridle probes the ports dsh actually uses, and can launch one itself
 * when nothing answers.
 */

import { spawn } from 'node:child_process'
import { closeSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { rowelHome } from '../identity.ts'
import { exchangeToken, tokenFrom } from './auth.ts'
import { cookieFor, rememberCookie } from './credentials.ts'
import { identifyDsh, type DshIdentity } from './identify.ts'

/** Ports probed in order: the web profile default, then the range it falls back through. */
const CANDIDATE_PORTS = [3080, 3081, 3082, 3083, 8080, 8791]

/** How long a single TCP probe may take. */
const PROBE_TIMEOUT_MS = 300

/** How long to wait for a freshly spawned dsh to be ready and print its token. */
const LAUNCH_TIMEOUT_MS = 45_000

/** A dsh instance Bridle can talk to. */
export interface DiscoveredDsh {
  /** Loopback base URL. */
  url: string
  /** Whether Bridle started this process itself. */
  launched: boolean
  /** What answered there, signed in with whatever cookie is known. */
  identity: DshIdentity
}

/**
 * Whether anything is listening on a loopback TCP port.
 * @param port - the port to probe.
 * @returns true when the connection is accepted.
 */
export function portOpen(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port })
    const finish = (open: boolean): void => {
      socket.destroy()
      resolve(open)
    }
    socket.setTimeout(PROBE_TIMEOUT_MS)
    socket.once('connect', () => { finish(true) })
    socket.once('timeout', () => { finish(false) })
    socket.once('error', () => { finish(false) })
  })
}

/**
 * Probe the usual dsh ports for one that answers the harness API.
 *
 * The candidate scan exists for dsh's own sake, not for multi-instance
 * convenience: dsh falls back through these ports itself when its default is
 * taken, so a single-dsh machine legitimately answers on 3081 some mornings.
 * What the scan must never do is *silently* move a binding — that decision
 * belongs to the caller, which knows whether the URL was stated by a person
 * (`pinned`) or is just where dsh answered last time.
 * @param preferred - a URL to try before the candidates, e.g. from config.
 * @param pinned - when true, the preferred URL is the *only* one tried. This
 *   is the `--dsh` contract: a person who named a harness gets that harness
 *   or an error, never a quiet substitute fronting a different session
 *   history — on the machines that run more than one dsh, the substitute is
 *   by definition the wrong one.
 * @returns the first dsh that answers, or undefined.
 */
export async function probeDsh(preferred?: string, pinned = false): Promise<string | undefined> {
  const urls = [...(preferred === undefined ? [] : [preferred])]
  if (!pinned || preferred === undefined) {
    for (const port of CANDIDATE_PORTS) urls.push(`http://127.0.0.1:${String(port)}`)
  }
  const seen = new Set<string>()
  for (const url of urls) {
    if (seen.has(url)) continue
    seen.add(url)
    let port: number
    try {
      const parsed = new URL(url)
      port = Number(parsed.port === '' ? (parsed.protocol === 'https:' ? 443 : 80) : parsed.port)
    } catch {
      continue
    }
    if (!await portOpen(port)) continue
    // Something is listening, but it might be any other local service. A dsh
    // either answers or asks to sign in, and asking counts: dsh 0.2 refuses
    // every request without a cookie, and reading that refusal as "not dsh"
    // is what used to send Bridle off to start a second one on a taken port.
    let identity: DshIdentity
    try {
      identity = await identifyDsh(url, cookieFor(url))
    } catch {
      continue
    }
    if (identity.kind !== 'unknown') return url
  }
  return undefined
}

/**
 * The address a DSH_HOME declares for itself, if it declares one.
 *
 * A dsh home can carry its own host and port (`profiles/web/cordis.patch.yml`,
 * entry `webserver`), and a home that does is the strongest binding there is:
 * the port doubles as a single-instance lock — a second boot from the same
 * home dies on EADDRINUSE instead of wandering off to another port — so the
 * URL derived here names the identity, not an incarnation.
 *
 * The parse is deliberately narrow: literal `host:` and `port:` inside the
 * `webserver` block, nothing else. A home without the patch, or one using a
 * `!!js` expression, yields undefined — the caller says so plainly rather
 * than this function guessing. Narrow beats a YAML dependency for reading a
 * file whose one relevant shape is two literal lines.
 * @param home - the DSH_HOME directory.
 * @returns the declared base URL, or undefined when the home does not say.
 */
export function dshHomeUrl(home: string): string | undefined {
  let text: string
  try {
    text = readFileSync(join(home, 'profiles', 'web', 'cordis.patch.yml'), 'utf8')
  } catch {
    return undefined
  }
  // Entries start at column zero with "- "; the webserver block is whatever
  // lies between its header and the next entry.
  const block = text.split(/^- /mu).find(chunk => chunk.startsWith('id: webserver'))
  if (block === undefined) return undefined
  const host = /^\s+host:\s*([\w.-]+)\s*$/mu.exec(block)?.[1]
  const port = /^\s+port:\s*(\d+)\s*$/mu.exec(block)?.[1]
  if (host === undefined || port === undefined) return undefined
  return `http://${host}:${String(Number(port))}`
}

/** How Bridle should behave when no dsh is running. */
export interface EnsureOptions {
  /** Configured dsh URL, tried first. */
  preferred?: string
  /** Only the preferred URL counts; see {@link probeDsh}. */
  pinned?: boolean
  /** Start dsh when nothing answers. */
  autoStart: boolean
  /** Command to start dsh; defaults to the published CLI via npx. */
  command?: string
  /** Arguments for that command. */
  args?: string[]
  /** Port a launched dsh should bind on loopback. */
  port?: number
  /** Progress reporting for the CLI. */
  log?: (message: string) => void
}

/**
 * Return a reachable dsh, launching one if allowed.
 * @param options - discovery and auto-start behaviour.
 * @returns the discovered or launched instance.
 * @throws {@link Error} when nothing answers and auto-start is off or fails.
 */
export async function ensureDsh(options: EnsureOptions): Promise<DiscoveredDsh> {
  const log = options.log ?? ((): void => {})
  const found = await probeDsh(options.preferred, options.pinned ?? false)
  if (found !== undefined) return { url: found, launched: false, identity: await identifyDsh(found, cookieFor(found)) }
  if (!options.autoStart) {
    // Naming the flag they already passed, not an `--auto-start` that does not
    // exist: launching is the default, `--no-auto-start` is the only switch,
    // and advice to add a flag that nothing reads sends someone looking for a
    // bug in their command line instead of starting a harness.
    throw new Error(
      'no dsh web server is running; start one, or drop --no-auto-start and let bridle launch it')
  }
  // A pinned URL is also where a launched dsh must live: starting the
  // default port when the person said 3081 would bind them to a harness they
  // explicitly did not name.
  const pinnedPort = options.pinned === true && options.preferred !== undefined
    ? Number((() => { try { return new URL(options.preferred).port } catch { return '' } })() || '3080')
    : undefined
  const port = options.port ?? pinnedPort ?? 3080
  const command = options.command ?? 'dsh'
  // Never `--public-url`: the token line would then show that address, and
  // nothing here needs anything from the line but the token.
  const args = options.args ?? ['web', '--host', '127.0.0.1', '--port', String(port), '--no-open']
  log(`starting dsh on 127.0.0.1:${String(port)}`)
  // dsh prints its token once, on stdout, and outlives this process. A pipe
  // would break the moment Bridle exits and fail dsh's next write, so stdout
  // goes to a private file instead — read for the token line, then deleted;
  // dsh keeps writing to its open descriptor, and nobody can read the token
  // back off the disk.
  const directory = join(rowelHome(), 'secrets')
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  // Left behind by a Bridle killed between launch and cleanup. Each holds a
  // token that may still be live; none is any use to anyone now.
  for (const name of readdirSync(directory)) {
    if (/^dsh-launch-\d+\.log$/u.test(name)) rmSync(join(directory, name), { force: true })
  }
  const output = join(directory, `dsh-launch-${String(process.pid)}.log`)
  const descriptor = openSync(output, 'w', 0o600)
  let child: ReturnType<typeof spawn>
  try {
    child = spawn(command, args, { stdio: ['ignore', descriptor, 'ignore'], detached: true })
  } finally {
    closeSync(descriptor)
  }
  child.unref()
  const url = `http://127.0.0.1:${String(port)}`
  let spawnFailed: string | undefined
  child.once('error', (error: Error) => { spawnFailed = error.message })
  const deadline = Date.now() + LAUNCH_TIMEOUT_MS
  // The last failed exchange, if any. Retried until the deadline: once the file
  // is gone the token is gone with it, and a dsh left running without it can
  // only be signed in to by restarting it.
  let exchangeFailed: string | undefined
  try {
    while (Date.now() < deadline) {
      if (spawnFailed !== undefined) {
        throw new Error(`could not start dsh with ${JSON.stringify(command)}: ${spawnFailed}`)
      }
      const identity = await identifyDsh(url, cookieFor(url))
      if (identity.kind === 'legacy' || identity.kind === 'signed-in') {
        log(`dsh is up at ${url}`)
        return { url, launched: true, identity }
      }
      if (identity.kind === 'locked') {
        const token = tokenLine(output)
        if (token !== undefined) {
          try {
            rememberCookie(url, await exchangeToken(url, token))
            const signedIn = await identifyDsh(url, cookieFor(url))
            log(`dsh is up at ${url}`)
            return { url, launched: true, identity: signedIn }
          } catch (error) {
            exchangeFailed = error instanceof Error ? error.message : String(error)
          }
        }
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 500) })
    }
  } finally {
    rmSync(output, { force: true })
  }
  if (exchangeFailed !== undefined) {
    throw new Error(`dsh started at ${url}, but bridle could not sign in to it (${exchangeFailed}); stop that dsh and start bridle again`)
  }
  throw new Error(`dsh did not answer at ${url} within ${String(LAUNCH_TIMEOUT_MS / 1000)}s`)
}

/**
 * The token from the `dsh web:` line in a launched dsh's output, once printed.
 * @param path - the file its stdout goes to.
 * @returns the token, or undefined until the line appears.
 */
function tokenLine(path: string): string | undefined {
  let text: string
  try {
    text = readFileSync(path, 'utf8')
  } catch {
    return undefined
  }
  const line = text.split('\n').find(entry => entry.startsWith('dsh web: '))
  return line === undefined ? undefined : tokenFrom(line)
}
