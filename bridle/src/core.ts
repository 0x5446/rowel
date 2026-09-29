/**
 * The long-lived half of a Bridle: identity, the loopback dsh client, and the
 * downlink pumps that keep the replay buffer filled whether or not a phone is
 * currently attached.
 *
 * Tunnels come and go with the phone's radio. This does not.
 */

import { watch, type FSWatcher } from 'node:fs'
import { basename } from 'node:path'
import { DshClient, type DshHealth } from './dsh/client.ts'
import type { AgentClient } from './agents/types.ts'
import { EventLog } from './tunnel/event-log.ts'
import { loadState, reloadState, rowelHome, statePath, staticKeys, type BridleState } from './identity.ts'
import type { StaticKeyPair } from '@rowel/protocol'

/**
 * What makes one pending request distinguishable from another.
 *
 * `rpcId` is what dsh routes an answer by, so it is unique per request and
 * stable across the re-sends dsh performs for new subscribers. The approval or
 * question id is the fallback for a frame shaped differently.
 * @param frame - a mux frame, verbatim.
 * @returns a comparable identity, or undefined when the frame carries none.
 */
function identityOf(frame: unknown): string | undefined {
  const outer = frame as { rpcId?: unknown; payload?: { approvalId?: unknown; id?: unknown } }
  if (typeof outer.rpcId === 'string') return outer.rpcId
  if (typeof outer.payload?.approvalId === 'string') return outer.payload.approvalId
  if (typeof outer.payload?.id === 'string') return outer.payload.id
  return undefined
}

/** How long dsh has to re-send its pending requests after the downlink reconnects. */
const RESEND_GRACE_MS = 2_000

/** Current dsh reachability as the core last observed it. */
export interface DshStatus {
  reachable: boolean
  /** `host.describe` value from the last successful probe. */
  host?: unknown
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** How often to re-probe dsh while its downlinks are down. */
const HEALTH_INTERVAL_MS = 5_000

/** Everything a tunnel needs from the machine it is attached to. */
export class BridleCore {
  readonly state: BridleState
  readonly keys: StaticKeyPair
  readonly dsh: AgentClient
  readonly events: EventLog

  private readonly abort = new AbortController()
  private readonly statusListeners = new Set<(status: DshStatus) => void>()
  private readonly connected = new Set<'mux' | 'host'>()
  private status: DshStatus = { reachable: false, detail: 'not probed yet' }

  /**
   * The requests dsh is still waiting on a person for, by session.
   *
   * An approval or a question crosses the wire once, as a live event. A phone
   * that is not attached at that instant never learns the machine has stopped
   * — and "not attached at that instant" is the normal case for this app,
   * whose whole premise is that you are somewhere else. Opening Rowel to find
   * out why the agent went quiet showed a conversation that simply stopped.
   *
   * dsh does not have this problem because it re-sends pending requests to
   * every new subscriber on the mux stream, which is what makes a browser
   * reload work. Bridle's subscription is long-lived, so it collects that
   * re-send only when *it* restarts, never when a phone reconnects. Holding
   * them here puts the same guarantee one layer further out, where the phones
   * actually come and go.
   *
   * Keyed by kind and session because that is the shape of the thing: a
   * session waits on one approval or one question at a time, and the
   * `resolved` event names the session rather than the request it closes.
   */
  private readonly waiting = new Map<string, unknown>()

  /**
   * Live tunnels, counted rather than listed.
   *
   * The only question anyone asks of it is "is there anybody there", which
   * decides whether a request that has stopped the agent needs a push to reach
   * a phone or will be delivered over a socket that already exists. A count
   * answers that; a list would invite someone to start addressing them
   * individually, and the two transports create their sessions in different
   * files.
   */
  private attachments = 0

  private readonly waitingListeners = new Set<() => void>()
  /**
   * Requests held from before the mux downlink last reconnected, and not yet
   * re-sent by dsh since. dsh re-sends everything still pending to a new
   * subscriber, so whatever it does not re-send is gone — dsh restarted, and
   * the request went with it. See {@link BridleCore.sweepUnconfirmed}.
   */
  private readonly unconfirmed = new Set<string>()
  private sweepTimer: NodeJS.Timeout | undefined
  /**
   * The request frames a phone has already been rung for. By frame, because a
   * re-sent request keeps the frame first held (see `trackWaiting`) and a new
   * one replaces it — so nothing here needs forgetting. See {@link BridleCore.dueForRing}.
   */
  private readonly rung = new WeakSet<object>()

  /**
   * The LAN addresses a phone can dial this machine on right now, best first.
   *
   * A function, not an array, and that is the whole point. The first version
   * stored the value the direct listener reported when it started, which made
   * every `ready` frame advertise the network the Mac was on at boot: a laptop
   * that moved from a hotspot to an office went on telling every phone to dial
   * the hotspot, forever, while `bridle status` — which recomputes — showed the
   * right one. Measured from the phone's own connection log, dialling an
   * address from the night before.
   *
   * Set by whoever owns the listener. The pairing bundle carries a copy too,
   * but that one is frozen at pairing time and this is what corrects it.
   */
  directAddresses: () => string[] = () => []
  private healthTimer: NodeJS.Timeout | undefined
  private watcher: FSWatcher | undefined

  /**
   * @param state - loaded identity state; `dshUrl` selects the harness.
   * @param overrides - injection points for the dsh client and the replay depth.
   */
  constructor(state: BridleState = loadState(), overrides: { dsh?: AgentClient; eventCapacity?: number } = {}) {
    this.state = state
    this.keys = staticKeys(state)
    this.dsh = overrides.dsh ?? new DshClient({ baseUrl: state.dshUrl })
    this.events = overrides.eventCapacity === undefined ? new EventLog() : new EventLog(overrides.eventCapacity)
  }

  /** Every request still waiting on a person, for an app that just attached. */
  get pendingRequests(): unknown[] {
    return [...this.waiting.values()]
  }

  /** Whether any phone currently holds a tunnel, over either transport. */
  get attached(): number {
    return this.attachments
  }

  /**
   * Note a live tunnel.
   * @returns a function that forgets it; safe to call more than once.
   */
  attach(): () => void {
    this.attachments += 1
    this.waitingChanged()
    let released = false
    return (): void => {
      if (released) return
      released = true
      this.attachments -= 1
      // The moment that used to be missed: the last phone leaves while a
      // question it never answered is still outstanding.
      this.waitingChanged()
    }
  }

  /**
   * Watch for any change to whether somebody needs fetching.
   *
   * Not "a request arrived" — that was the first version and it was the wrong
   * event. Whether a phone should be rung is a *state*, standing on two facts
   * that both move: something is waiting on a person, and nobody is attached to
   * be told. A listener fired only when the first became true was wrong in both
   * directions. Asked while the phone was in someone's hand, no ring was ever
   * owed, so putting the phone down without answering left the machine waiting
   * in silence forever. And a ring owed while the Relay was down was still owed
   * when it returned, even if the question had been answered in the browser
   * meanwhile.
   *
   * So this fires whenever either fact changes and the listener decides again.
   * @param listener - called after the change is recorded.
   * @returns a function that detaches the listener.
   */
  onWaitingChanged(listener: () => void): () => void {
    this.waitingListeners.add(listener)
    return (): void => { this.waitingListeners.delete(listener) }
  }

  /** Tell every listener the answer may have changed. */
  private waitingChanged(): void {
    for (const listener of this.waitingListeners) {
      try {
        listener()
      } catch {
        // Same reasoning as every other listener here: one bad subscriber must
        // not stop the rest, and must not stop the event fold.
      }
    }
  }

  /**
   * Note a request that has stopped the agent, or forget one that was answered.
   * @param frame - a mux frame, verbatim.
   */
  private trackWaiting(frame: unknown): void {
    const payload = (frame as { payload?: { type?: unknown; sessionId?: unknown } }).payload
    const type = payload?.type
    const sessionId = payload?.sessionId
    if (typeof type !== 'string' || typeof sessionId !== 'string') return
    if (type === 'approval/requested' || type === 'question/requested') {
      const key = `${type}:${sessionId}`
      // The same request or a different one? dsh re-sends everything pending to
      // each new subscriber, and this Bridle resubscribes whenever dsh
      // restarts, so a repeat is usually a replay and ringing again would wake
      // someone for a question they were already woken for an hour ago.
      //
      // Usually, but not always. A downlink that drops can lose the `resolved`
      // event, and then a genuinely new question for the same session looks
      // exactly like a replay of the old one — nobody is rung, and the phone
      // shows the stale card. So the identity of the request decides, not the
      // session it belongs to.
      const identity = identityOf(frame)
      if (this.waiting.has(key) && identityOf(this.waiting.get(key)) === identity) {
        this.unconfirmed.delete(key)
        return
      }
      this.unconfirmed.delete(key)
      this.waiting.set(key, frame)
      for (const listener of this.waitingListeners) {
        try {
          listener()
        } catch {
          // Same reasoning as every other listener here: one bad subscriber
          // must not stop the rest, and must not stop the event fold.
        }
      }
      return
    }
    // Answered — by this phone, another one, or the browser on the machine
    // itself. Whoever it was, nobody should be asked again.
    // Answered — by this phone, another one, or the browser on the machine
    // itself. A listener re-deciding whether to ring has to hear this too:
    // an owed ring that was never sent because the Relay was down must not
    // survive the answer.
    const answered = (type === 'approval/resolved' && this.forget(`approval/requested:${sessionId}`))
      || (type === 'question/resolved' && this.forget(`question/requested:${sessionId}`))
    if (answered) this.waitingChanged()
  }

  /**
   * Stop holding a request for a session that no longer exists.
   *
   * The only way an entry could outlive its answer: a session deleted while it
   * was waiting on someone resolves nothing, so without this it would be
   * offered to every phone that ever attached, forever. Small, but the only
   * part of this bookkeeping that was not already bounded by construction.
   * @param frame - a host-stream frame, verbatim.
   */
  private forgetRemoved(frame: unknown): void {
    const payload = (frame as { payload?: { type?: unknown; sessionId?: unknown } }).payload
    if (payload?.type !== 'host/session-removed') return
    const sessionId = payload.sessionId
    if (typeof sessionId !== 'string') return
    const forgot = [this.forget(`approval/requested:${sessionId}`), this.forget(`question/requested:${sessionId}`)]
    if (forgot.includes(true)) this.waitingChanged()
  }

  /**
   * Drop one held request, with its bookkeeping.
   * @param key - `<type>:<sessionId>`.
   * @returns whether anything was held under that key.
   */
  private forget(key: string): boolean {
    const frame = this.waiting.get(key)
    if (frame === undefined) return false
    this.waiting.delete(key)
    this.unconfirmed.delete(key)
    return true
  }

  /**
   * The held requests nobody has been rung for yet.
   *
   * A ring is owed once per request, not once per reason to reconsider. The
   * reasons come often — every attach and detach, every time the Relay
   * re-registers after a Mac wakes or changes network — and deciding from
   * "is anything pending" alone rang the phone again for a question it had
   * already been rung for, each time.
   */
  dueForRing(): unknown[] {
    return [...this.waiting.values()].filter(frame => !this.rung.has(frame as object))
  }

  /** Record that a phone has been rung for everything held right now. */
  markRung(): void {
    for (const frame of this.waiting.values()) this.rung.add(frame as object)
  }

  /**
   * Forget the requests dsh did not re-send after the downlink came back.
   *
   * A request dies with the dsh process that asked it, and the `resolved`
   * event never comes. Left alone it was offered to every phone that attached
   * and rung on every Relay reconnect, for a question nobody could answer any
   * more. A phone attached right now is told as if it had been answered — the
   * same event it already knows how to fold — so its card goes too.
   */
  private sweepUnconfirmed(): void {
    this.sweepTimer = undefined
    let forgot = false
    for (const key of [...this.unconfirmed]) {
      const sessionId = key.slice(key.indexOf(':') + 1)
      const resolved = key.startsWith('approval/') ? 'approval/resolved' : 'question/resolved'
      if (!this.forget(key)) continue
      forgot = true
      this.events.append('mux', { payload: { type: resolved, sessionId } })
    }
    if (forgot) this.waitingChanged()
  }

  /** dsh reachability as of the last probe or downlink transition. */
  get dshStatus(): DshStatus {
    return this.status
  }

  /**
   * Start the downlink pumps and the health probe.
   * @returns once the first health probe has completed.
   */
  async start(): Promise<void> {
    const signal = this.abort.signal
    void this.dsh.pump('mux', frame => {
      this.trackWaiting(frame)
      this.events.append('mux', frame)
    }, (up, detail) => { this.onStream('mux', up, detail) }, signal)
    void this.dsh.pump('host', frame => {
      this.forgetRemoved(frame)
      this.events.append('host', frame)
    }, (up, detail) => { this.onStream('host', up, detail) }, signal)
    await this.probe()
    this.healthTimer = setInterval(() => { void this.probe() }, HEALTH_INTERVAL_MS)
    this.healthTimer.unref()
    this.watchState()
  }

  /** Stop the pumps and release timers. */
  stop(): void {
    this.abort.abort()
    if (this.healthTimer !== undefined) clearInterval(this.healthTimer)
    if (this.sweepTimer !== undefined) clearTimeout(this.sweepTimer)
    this.watcher?.close()
  }

  /**
   * Re-read what another `bridle` invocation may have changed — the paired
   * devices, the outstanding offer, the machine name. The keys are never
   * re-read (see `reloadState`), and this process's overrides survive.
   */
  refreshState(): void {
    try {
      reloadState(this.state)
    } catch {
      // A missing or unreadable file is not a reason to forget who is paired;
      // the in-memory copy is the better answer until the file is back.
    }
  }

  /**
   * Pick up pairing offers and revocations made by another `bridle` invocation.
   * A running daemon and a `bridle pair` in a second terminal are the normal
   * case, so the daemon follows the file rather than owning it.
   *
   * The directory is watched rather than the file: `saveState` writes to a
   * temporary and renames it into place, which replaces the inode a file watch
   * is pinned to and would stop delivering events after the first save.
   */
  private watchState(): void {
    const name = basename(statePath())
    try {
      this.watcher = watch(rowelHome(), { persistent: false }, (_event, filename) => {
        if (filename !== null && filename !== name) return
        this.refreshState()
      })
    } catch {
      // Watching is an optimisation; every handshake re-reads the file anyway.
    }
  }

  /**
   * Watch dsh reachability.
   * @param listener - called on every transition, not on every probe.
   * @returns a function that detaches the listener.
   */
  onDshStatus(listener: (status: DshStatus) => void): () => void {
    this.statusListeners.add(listener)
    return (): void => { this.statusListeners.delete(listener) }
  }

  private onStream(stream: 'mux' | 'host', up: boolean, detail?: string): void {
    if (!up && stream === 'mux' && this.sweepTimer !== undefined) {
      // Gone again before dsh could re-send: silence on a dead downlink says
      // nothing about what is still pending. The next connection starts over.
      clearTimeout(this.sweepTimer)
      this.sweepTimer = undefined
    }
    if (up && stream === 'mux' && this.waiting.size > 0) {
      // dsh re-sends what is still pending as soon as a subscriber arrives;
      // give it a moment, then drop whatever it did not.
      for (const key of this.waiting.keys()) this.unconfirmed.add(key)
      if (this.sweepTimer !== undefined) clearTimeout(this.sweepTimer)
      this.sweepTimer = setTimeout(() => { this.sweepUnconfirmed() }, RESEND_GRACE_MS)
      this.sweepTimer.unref()
    }
    if (up) this.connected.add(stream)
    else this.connected.delete(stream)
    // A live downlink is stronger evidence than a periodic probe, so let it
    // drive the status directly rather than waiting up to five seconds.
    if (up && !this.status.reachable) void this.probe()
    else if (!up && this.connected.size === 0) this.publish({ reachable: false, ...(detail === undefined ? {} : { detail }) })
  }

  private async probe(): Promise<void> {
    const health: DshHealth = await this.dsh.health()
    this.publish(
      health.reachable
        ? { reachable: true, host: health.host }
        : { reachable: false, ...(health.detail === undefined ? {} : { detail: health.detail }) },
    )
  }

  private publish(next: DshStatus): void {
    if (next.reachable === this.status.reachable && next.detail === this.status.detail) {
      // Refresh the cached describe value without waking every listener.
      this.status = next
      return
    }
    this.status = next
    for (const listener of this.statusListeners) {
      try {
        listener(next)
      } catch {
        // Same reasoning as EventLog: one bad listener must not stall the rest.
      }
    }
  }
}
