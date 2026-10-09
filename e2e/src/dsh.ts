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
 * The environment alone only reaches dsh's built-in DeepSeek provider. When
 * `ROWEL_E2E_DSH_SETTINGS` names a dsh 0.1 `settings.yaml`, its `llm-pi-ai`
 * routes and `agent-default-model` come along as profile rows — 0.2's default
 * profile does not compose the pi-ai adapter, so importing the file itself
 * drops them. Routes name their keys by environment variable (`apiKeyEnv`),
 * so no secret is copied.
 *
 * Nor the developer's home. dsh reads skills and instruction files from under
 * `HOME` (`~/.agents/skills`, global agent instructions) and puts them in every
 * system prompt; a throwaway dsh with the real `HOME` would carry someone's
 * private setup into test output and into the fixtures committed from it.
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
  const settings = process.env['ROWEL_E2E_DSH_SETTINGS']
  const routes = options.model === true && settings !== undefined && settings.length > 0
    ? modelRows(readFileSync(settings, 'utf8'))
    : ''
  const patch = [options.profilePatch ?? '', routes].filter(part => part.length > 0).join('\n')
  if (patch.length > 0) {
    mkdirSync(join(home, 'profiles', 'web'), { recursive: true })
    writeFileSync(join(home, 'profiles', 'web', 'cordis.patch.yml'), patch)
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

/**
 * Profile rows for the model routes in a dsh 0.1 `settings.yaml`.
 *
 * By text rather than by a YAML library, because only two top-level sections
 * move and each moves whole: its body is re-indented under a `config:`.
 * @param text - the settings file.
 * @returns rows to append to a profile patch, or an empty string.
 */
export function modelRows(text: string): string {
  const section = (name: string, indent: string): string | undefined => {
    const lines = text.split('\n')
    const start = lines.indexOf(`${name}:`)
    if (start < 0) return undefined
    const body: string[] = []
    for (const line of lines.slice(start + 1)) {
      if (line.length > 0 && !line.startsWith(' ')) break
      body.push(line.length > 0 ? indent + line : line)
    }
    return body.join('\n')
  }
  const rows: string[] = []
  const pi = section('llm-pi-ai', '      ')
  if (pi !== undefined) {
    rows.push(['- insert:', '    - id: llm-pi-ai', "      name: '@deepseek-ai/dsh-llm-pi-ai'", '      config:', pi].join('\n'))
  }
  const model = section('agent-default-model', '  ')
  if (model !== undefined) rows.push(['- id: agent-default-model', '  config:', model].join('\n'))
  return rows.join('\n')
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
