/**
 * The Bridle, as a plugin dsh loads itself.
 *
 * Same Bridle, second doorway. `bridle` the command is right for someone who
 * wants it supervised separately, or who will point it at a different agent
 * later; this is right for the common case, where the answer to "what do I
 * install" should be one line and the thing should start and stop with dsh.
 *
 *   dsh plugin --profile web add @rowel/bridle-plugin
 *
 * It still speaks to dsh over loopback HTTP rather than reaching into the
 * process it is running inside. That looks wasteful and is not: the call never
 * leaves the machine, it is the same path the standalone binary uses and the
 * same path every test covers, and it keeps this file a lifecycle wrapper
 * instead of a second implementation that can drift.
 *
 * What it does NOT do is change the security model. The listener it opens
 * speaks only the Noise tunnel, exactly as before — dsh's own API stays bound
 * to loopback and stays unreachable to anything that has not completed a
 * handshake.
 */

import {
  BridleCore,
  DirectServer,
  RelayClient,
  clearRuntime,
  competingDaemon,
  loadState,
  overrideState,
  rememberInstance,
  writeRuntime,
  type BridleState,
} from '@rowel/bridle'

/** How often to refresh the snapshot `bridle status` reads. */
const HEARTBEAT_MS = 5_000

/** Shown in dsh's plugin list and in diagnostics. */
export const name = 'rowel-bridle'

/** What the plugin page writes, and what `cordis.yml` can set by hand. */
export interface BridlePluginConfig {
  /** Relay to dial out to. Empty disables the relay and leaves only direct paths. */
  relay?: string
  /** dsh's own address. Defaults to the loopback web profile. */
  dsh?: string
  /** Fixed port for the local-network listener; `0` lets the OS choose. */
  directPort?: number
  /** Turn off the local-network listener entirely. */
  noDirect?: boolean
  /**
   * Extra addresses to put in the pairing code — a tunnel hostname the machine
   * cannot discover for itself. LAN and Tailscale addresses are found by
   * enumerating interfaces and do not belong here.
   */
  advertise?: string[]
}

/** The version reported to a paired app; overridden by the build. */
const VERSION = '0.1.2'

/**
 * Cordis entry point.
 * @param ctx - the plugin context; its dispose hook owns teardown.
 * @param config - plugin settings, all optional.
 */
export function apply(
  ctx: {
    on: (event: 'dispose', handler: () => void) => void
    logger?: { error?: (message: string) => void }
  },
  config: BridlePluginConfig = {},
): void {
  // One Bridle per identity, refused before anything else exists. A second one
  // for the same ROWEL_HOME registers at the Relay as the same machine, and
  // the two displace each other in a silent loop at retry speed — the usual
  // way is a standalone `bridle` service still running when the plugin is
  // installed. Checked before the heartbeat is created, because a refused
  // instance that still heartbeats would overwrite the incumbent's snapshot
  // every five seconds, and its dispose would delete it.
  const incumbent = competingDaemon()
  if (incumbent !== undefined) {
    ctx.logger?.error?.(
      `rowel-bridle did not start: another Bridle is already serving this identity (pid ${String(incumbent.pid)}, ${incumbent.version}). `
      + 'Stop it and restart dsh, or give it its own home with ROWEL_HOME.',
    )
    return
  }

  const state: BridleState = loadState()
  // For this process only — never written to the machine's state file. An
  // empty `relay` is a setting in its own right: it turns the Relay off.
  overrideState(state, {
    ...(config.relay === undefined ? {} : { relayUrl: config.relay }),
    ...(config.dsh !== undefined && config.dsh.length > 0 ? { dshUrl: config.dsh } : {}),
  })

  const core = new BridleCore(state)
  const startedAt = Date.now()
  let direct: DirectServer | undefined
  let relay: RelayClient | undefined

  // The same snapshot the standalone daemon publishes, for the same reason.
  //
  // `bridle status`, `bridle doctor` and `bridle pair` are typed in a second
  // terminal and read this file to find the Bridle that is already running.
  // Without it they conclude there is no Bridle at all — which, once the plugin
  // is the recommended way to install, means the three commands the help page
  // sends people to when something is broken all lie about the one thing they
  // exist to report. The file is keyed by pid, and this pid is dsh's, so a
  // stale file is still detected the same way.
  function publish(relayState: 'offline' | 'connecting' | 'online' = relay?.connectionState ?? 'offline'): void {
    // Never a throw, at any cost. This runs from a five-second timer inside
    // dsh's own process, and an uncaught exception here does not kill a
    // plugin — it kills the harness and every session in it. The standalone
    // CLI died exactly this way in the wild: a full disk (ENOSPC) took the
    // whole daemon down over a status snapshot. In this doorway the same
    // throw costs someone their running agent, so even the startup claim is
    // tolerant here — a guest must fail alone, and a disk too full for a
    // snapshot will announce itself through louder channels than ours.
    try {
      writeRuntime({
        pid: process.pid,
        version: VERSION,
        via: 'plugin',
        startedAt,
        relayUrl: state.relayUrl,
        relayState,
        dshUrl: state.dshUrl,
        dshReachable: core.dshStatus.reachable,
        direct: direct?.addresses ?? [],
        attached: relay?.attachedCircuits ?? 0,
      })
    } catch {
      // The next heartbeat retries in five seconds.
    }
  }

  // Claimed now rather than on the first heartbeat: until this file carries
  // our pid, a `bridle start` typed in the next five seconds would pass its
  // own competing-daemon check and the two would fight for the identity.
  publish()
  // And onto the machine's map, so `bridle instances` knows this home exists
  // even when it is only ever run by dsh.
  rememberInstance()

  const heartbeat = setInterval(() => { publish() }, HEARTBEAT_MS)
  heartbeat.unref()

  // Nothing here awaits: Cordis mounts plugins concurrently and a plugin that
  // blocks its apply() holds up the harness it is meant to be a guest in.
  //
  // And nothing here may throw. `void` on a rejecting promise is an unhandled
  // rejection, which Node treats as fatal — so a Bridle that cannot start
  // would take dsh with it. That is not theoretical: a restart overlapping its
  // predecessor could not bind the direct port, and the harness died rather
  // than the plugin. A guest that fails should fail alone and say so.
  void (async () => {
    try {
      await start()
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error)
      ctx.logger?.error?.(`rowel-bridle failed to start: ${detail}`)
      publish('offline')
    }
  })()

  async function start(): Promise<void> {
    await core.start()

    if (config.noDirect !== true) {
      direct = new DirectServer(core, { version: VERSION, port: config.directPort ?? 0, log: () => {} })
      await direct.listen()
    }
    // Asked fresh on every ready frame, so a laptop that changes network stops
    // advertising the one it booted on.
    core.directAddresses = () => [...(config.advertise ?? []), ...(direct?.addresses ?? [])]

    if (state.relayUrl.length > 0) {
      relay = new RelayClient(core, { version: VERSION, log: () => {}, onState: (next) => { publish(next) } })
      relay.start()
    }
    publish()
  }

  ctx.on('dispose', () => {
    // Reverse order, and every step tolerant: a plugin that throws on unload
    // takes the reload with it.
    clearInterval(heartbeat)
    try { relay?.stop() } catch { /* already down */ }
    try { direct?.close() } catch { /* already down */ }
    try { core.stop() } catch { /* already down */ }
    // Removed on unload, so a `bridle status` after `dsh plugin remove` says
    // nothing is running rather than pointing at a live dsh that no longer
    // has a Bridle in it.
    try { clearRuntime() } catch { /* already gone */ }
  })
}

/**
 * The addresses a phone can currently reach this machine on.
 *
 * Exported so the plugin's settings page can show them, and so `bridle pair`
 * run in another terminal can find them without a second listener.
 * @param direct - the running listener, if there is one.
 * @returns `ws://host:port` candidates, best first.
 */
export function reachableAddresses(direct: DirectServer | undefined): string[] {
  return direct?.addresses ?? []
}
