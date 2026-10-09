/**
 * A real dsh 0.2 for the end-to-end tests, started fresh and thrown away.
 *
 * Isolated the way docs/dsh-0.2-migration.md D8 asks: its own `DSH_HOME` in a
 * temporary directory and its own free port, so a test run never touches the
 * dsh someone is using — not its sessions, not its settings, not port 3080.
 * dsh prints its launch token once, on stdout; this reads it, so a stack can
 * sign in with it.
 *
 * Which dsh: `ROWEL_E2E_DSH_BIN`, a path to its `dsh` executable. CI installs a
 * pinned version and points this at it; a developer points it at whichever
 * one they want to check. Unset, the tests that need a real dsh skip, and say
 * so.
 *
 * And with no model, unless asked for one. dsh takes provider credentials from
 * its environment (a `COMMANDCODE_API_KEY` is enough to run turns), so a dsh
 * that inherited a developer's shell would quietly spend their account on
 * every contract test. It gets a bare environment instead; a test that needs a
 * real turn passes `{ model: true }`, and only runs when `ROWEL_E2E_MODEL=1`.
 *
 * Nor the developer's home. dsh reads skills and instruction files from under
 * `HOME` (`~/.agents/skills`, global agent instructions) and puts them in every
 * system prompt; a throwaway dsh with the real `HOME` would carry someone's
 * private setup into test output and into the fixtures committed from it.
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** A running throwaway dsh. */
export interface ThrowawayDsh {
  /** Loopback base URL. */
  url: string
  /** The launch token it printed. */
  token: string
  /** Its `DSH_HOME`. */
  home: string
  /** Stop it and delete its home. */
  stop: () => Promise<void>
}

/** The dsh executable the suite was told to use, if any. */
export function dshBinary(): string | undefined {
  const bin = process.env['ROWEL_E2E_DSH_BIN']
  return bin === undefined || bin.length === 0 ? undefined : bin
}

/**
 * Whether the suite may run real model turns (`ROWEL_E2E_MODEL=1`).
 * @returns true when a developer asked for them.
 */
export function modelAllowed(): boolean {
  return process.env['ROWEL_E2E_MODEL'] === '1'
}

/**
 * Start a throwaway dsh 0.2.
 * @param options - `model: true` to hand it this process's environment,
 *   provider credentials included; `timeoutMs` to wait for its token line;
 *   `profilePatch` to write as its web profile's `cordis.patch.yml`, the
 *   file a person edits to compose plugins in or out.
 * @returns the running instance.
 * @throws {@link Error} when `ROWEL_E2E_DSH_BIN` is unset or dsh does not come up.
 */
export async function startDsh(options: { model?: boolean; timeoutMs?: number; profilePatch?: string } = {}): Promise<ThrowawayDsh> {
  const timeoutMs = options.timeoutMs ?? 60_000
  const bin = dshBinary()
  if (bin === undefined) throw new Error('ROWEL_E2E_DSH_BIN is not set')
  const home = mkdtempSync(join(tmpdir(), 'rowel-e2e-dsh-'))
  const port = await freePort()
  const userHome = join(home, 'user')
  mkdirSync(userHome, { recursive: true })
  if (options.profilePatch !== undefined) {
    mkdirSync(join(home, 'profiles', 'web'), { recursive: true })
    writeFileSync(join(home, 'profiles', 'web', 'cordis.patch.yml'), options.profilePatch)
  }
  const bare: Record<string, string> = { DSH_HOME: home, HOME: userHome, DSH_TELEMETRY_DISABLED: '1' }
  for (const name of ['PATH', 'TMPDIR', 'LANG']) {
    const value = process.env[name]
    if (value !== undefined) bare[name] = value
  }
  const child = spawn(bin, ['web', '--host', '127.0.0.1', '--port', String(port), '--no-open'], {
    env: options.model === true ? { ...process.env, DSH_HOME: home } : bare,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let output = ''
  const token = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`dsh printed no token within ${String(timeoutMs / 1000)}s:\n${output.slice(-2000)}`))
    }, timeoutMs)
    const read = (chunk: Buffer): void => {
      output += chunk.toString()
      const match = /^dsh web: \S*[?&]token=([^\s&]+)/mu.exec(output)
      if (match?.[1] !== undefined) {
        clearTimeout(timer)
        resolve(match[1])
      }
    }
    child.stdout?.on('data', read)
    child.stderr?.on('data', (chunk: Buffer) => { output += chunk.toString() })
    child.once('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`dsh exited with ${String(code)} before it was ready:\n${output.slice(-2000)}`))
    })
  })
  // Keep reading, or a full pipe would stall dsh's next write.
  child.stdout?.resume()
  child.stderr?.resume()
  return { url: `http://127.0.0.1:${String(port)}`, token, home, stop: () => stopDsh(child, home) }
}

async function stopDsh(child: ChildProcess, home: string): Promise<void> {
  if (child.exitCode === null) {
    const exited = new Promise<void>((resolve) => { child.once('exit', () => { resolve() }) })
    child.kill('SIGTERM')
    const forced = setTimeout(() => { child.kill('SIGKILL') }, 5_000)
    await exited
    clearTimeout(forced)
  }
  rmSync(home, { recursive: true, force: true })
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      const port = typeof address === 'object' && address !== null ? address.port : 0
      server.close(() => { resolve(port) })
    })
  })
}
