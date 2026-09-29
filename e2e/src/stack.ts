/**
 * A whole Rowel deployment in one process: a Relay on an ephemeral port, a
 * Bridle with its own throwaway identity directory, and whichever DeepSeek
 * Harness the tests were pointed at.
 *
 * Nothing here is mocked. The tests that matter are the ones that would catch a
 * real regression, and a hand-written fake of the harness would only ever
 * confirm my own assumptions about it.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  BridleCore,
  DirectServer,
  DshClient,
  type AgentClient,
  RelayClient,
  createInvitation,
  loadState,
  probeDsh,
  saveState,
  type BridleState,
  type Invitation,
} from '@rowel/bridle'
import { RelayServer } from '@rowel/relay'

/** Options for {@link startStack}. */
export interface StackOptions {
  /** dsh base URL; defaults to `ROWEL_E2E_DSH_URL`, then a port probe. */
  dshUrl?: string
  /** Skip the LAN listener, to force traffic through the Relay. */
  noDirect?: boolean
  /** Machine name the app will see. */
  machineName?: string
  /** Frames the Bridle retains for replay; small values make resync easy to test. */
  eventCapacity?: number
  /**
   * Dial a Relay that is already running somewhere else instead of starting one.
   *
   * The in-process Relay proves the protocol; it does not prove the deployment.
   * A tunnel that drops WebSocket upgrades, a proxy that buffers, a capacity
   * limit set too low — none of that shows up until the traffic crosses a real
   * one. Pointing a test at the deployed Relay is the only way to catch it.
   */
  relayUrl?: string
  /**
   * Stand in for the harness.
   *
   * The seam `docs/architecture.md` §4.1 claims exists. Injecting here lets a
   * test drive things a real harness cannot be made to do on cue — an approval
   * arriving at a chosen moment, a downlink dropping mid-turn — without a model
   * in the loop and without the result depending on what the model felt like
   * doing. Absent, a real dsh is used.
   */
  agent?: AgentClient
}

/** A running stack and the handles a test needs. */
export interface Stack {
  /** Absent when the test was pointed at a Relay it does not own. */
  relay: RelayServer | undefined
  relayUrl: string
  core: BridleCore
  relayClient: RelayClient
  direct: DirectServer | undefined
  state: BridleState
  dshUrl: string
  /** Mint a fresh pairing invitation for this machine. */
  invite: () => Invitation
  /** Wait until the Bridle has registered with the Relay. */
  waitForRelay: (timeoutMs?: number) => Promise<void>
  stop: () => Promise<void>
}

/** Version string the fixtures report. */
const VERSION = '0.1.0-test'

/**
 * Stand up a Relay and a Bridle around a real harness.
 * @param options - which harness, and whether the LAN path is available.
 * @returns the running stack.
 * @throws {@link Error} when no harness can be found.
 */
export async function startStack(options: StackOptions = {}): Promise<Stack> {
  const dshUrl = options.dshUrl ?? process.env['ROWEL_E2E_DSH_URL'] ?? await probeDsh()
  if (dshUrl === undefined) {
    throw new Error('no DeepSeek Harness found; set ROWEL_E2E_DSH_URL to a running web server')
  }

  let relay: RelayServer | undefined
  let relayUrl = options.relayUrl
  if (relayUrl === undefined) {
    relay = new RelayServer({ port: 0, host: '127.0.0.1', recordWakes: true })
    relayUrl = `http://127.0.0.1:${String(await relay.listen())}`
  }

  const home = mkdtempSync(join(tmpdir(), 'rowel-e2e-'))
  const previousHome = process.env['ROWEL_HOME']
  process.env['ROWEL_HOME'] = home
  const state = loadState()
  state.relayUrl = relayUrl
  state.dshUrl = dshUrl
  if (options.machineName !== undefined) state.machineName = options.machineName
  saveState(state)

  const core = new BridleCore(state, {
    dsh: options.agent ?? new DshClient({ baseUrl: dshUrl }),
    ...(options.eventCapacity === undefined ? {} : { eventCapacity: options.eventCapacity }),
  })
  await core.start()

  let direct: DirectServer | undefined
  if (options.noDirect !== true) {
    direct = new DirectServer(core, { version: VERSION, port: 0 })
    await direct.listen()
    // As the CLI and the plugin both do: the ready frame advertises where the
    // machine can be dialled now, and the stack has to be honest about it too.
    core.directAddresses = () => direct?.addresses ?? []
  }

  const relayClient = new RelayClient(core, { version: VERSION })
  relayClient.start()

  const stack: Stack = {
    relay,
    relayUrl,
    core,
    relayClient,
    direct,
    state,
    dshUrl,
    invite: () => createInvitation(state, direct?.addresses ?? []),
    waitForRelay: (timeoutMs = 10_000) => waitFor(() => relayClient.connectionState === 'online', timeoutMs, 'relay registration'),
    stop: async () => {
      relayClient.stop()
      direct?.close()
      core.stop()
      // Only close a Relay this stack started. A deployed one outlives the test.
      await relay?.close()
      if (previousHome === undefined) delete process.env['ROWEL_HOME']
      else process.env['ROWEL_HOME'] = previousHome
      rmSync(home, { recursive: true, force: true })
    },
  }
  return stack
}

/**
 * Poll until a condition holds.
 * @param condition - checked every 25ms.
 * @param timeoutMs - how long to wait.
 * @param what - name used in the timeout message.
 */
export async function waitFor(condition: () => boolean, timeoutMs: number, what: string): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (condition()) return
    await new Promise<void>((resolve) => { setTimeout(resolve, 25) })
  }
  throw new Error(`timed out after ${String(timeoutMs)}ms waiting for ${what}`)
}
