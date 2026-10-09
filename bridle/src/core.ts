/**
 * The long-lived half of a Bridle: identity, the signed-in connection to dsh,
 * and the one stream the Bridle reads for itself — `$events`, to know when a
 * phone that is not attached has to be woken.
 *
 * Tunnels come and go with the phone's radio. This does not.
 */

import { watch, type FSWatcher } from 'node:fs'
import { basename } from 'node:path'
import { DshClient } from './dsh/client.ts'
import type { AgentClient, MuxState, StreamHandle } from './agents/types.ts'
import { identifyDsh, type DshIdentity } from './dsh/identify.ts'
import { cookieFor } from './dsh/credentials.ts'
import { loadState, reloadState, rowelHome, statePath, staticKeys, type BridleState } from './identity.ts'
import type { StaticKeyPair } from '@rowel/protocol'

/**
 * How long dsh has, after a new `$events` stream opens, to re-send what is
 * still waiting. It re-sends every pending approval and question to a new
 * subscriber at once, under the same `eventId`; a ring recorded for one it does
 * not re-send is for a request that is gone.
 */
const RESEND_GRACE_MS = 2_000

/** The two `$events` waterfalls a person has to answer. */
const ASKS = new Set(['approval/request', 'user-questions/request'])

/** Current dsh reachability as the core last observed it. */
export interface DshStatus {
  reachable: boolean
  /** dsh's version, when known. */
  version?: string
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** Everything a tunnel needs from the machine it is attached to. */
export class BridleCore {
  readonly state: BridleState
  readonly keys: StaticKeyPair
  readonly dsh: AgentClient

  private readonly statusListeners = new Set<(status: DshStatus) => void>()
  private status: DshStatus = { reachable: false, detail: 'not connected yet' }
  private identity: DshIdentity | undefined
  private unwatchConnection: (() => void) | undefined
  private events: StreamHandle | undefined

  /**
   * The requests dsh is waiting on a person for right now, by `eventId`.
   *
   * Rebuilt for every `$events` stream: when the stream reopens — dsh restarted,
   * the socket dropped — dsh re-sends whatever is still pending, and nothing
   * from before is kept, so a request answered meanwhile on another device does
   * not linger here and ring someone for nothing.
   */
  private readonly waiting = new Set<string>()

  /**
   * The requests a phone has already been rung for, by `eventId`.
   *
   * Kept across `$events` streams on purpose: dsh re-sends a pending request
   * under the same `eventId`, and a network blip that reopened the stream must
   * not ring the same phone twice for the same question. An id is dropped when
   * its request ends (`cancel`), or when a fresh stream's re-send window closes
   * without it.
   */
  private readonly rung = new Set<string>()
  private resendTimer: NodeJS.Timeout | undefined

  /**
   * Live tunnels, counted rather than listed. The only question anyone asks of
   * it is "is there anybody there", which decides whether a request needs a
   * push to reach a phone or will be seen by one already attached.
   */
  private attachments = 0
  private readonly waitingListeners = new Set<() => void>()

  /**
   * The LAN addresses a phone can dial this machine on right now, best first.
   *
   * A function, not an array: the first version stored the value the direct
   * listener reported when it started, which made every `ready` frame advertise
   * the network the Mac was on at boot. Set by whoever owns the listener.
   */
  directAddresses: () => string[] = () => []
  private watcher: FSWatcher | undefined

  /**
   * @param state - loaded identity state; `dshUrl` selects the harness.
   * @param overrides - injection point for the agent client.
   */
  constructor(state: BridleState = loadState(), overrides: { dsh?: AgentClient } = {}) {
    this.state = state
    this.keys = staticKeys(state)
    this.dsh = overrides.dsh ?? new DshClient({ baseUrl: state.dshUrl })
  }

  /** dsh reachability as of the last change. */
  get dshStatus(): DshStatus {
    return this.status
  }

  /**
   * Connect to dsh and follow its `$events`.
   * @returns once the first identification has finished.
   */
  async start(): Promise<void> {
    this.unwatchConnection = this.dsh.onConnection((state) => { void this.onConnection(state) })
    this.dsh.start()
    await this.identify()
    this.watchState()
  }

  /** Disconnect and release timers. */
  stop(): void {
    this.unwatchConnection?.()
    this.events?.cancel()
    this.events = undefined
    if (this.resendTimer !== undefined) clearTimeout(this.resendTimer)
    this.dsh.stop()
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
   * Watch dsh reachability.
   * @param listener - called on every transition.
   * @returns a function that detaches the listener.
   */
  onDshStatus(listener: (status: DshStatus) => void): () => void {
    this.statusListeners.add(listener)
    return (): void => { this.statusListeners.delete(listener) }
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
   * Whether a phone should be rung is a *state*, standing on two facts that
   * both move: something is waiting on a person, and nobody is attached to be
   * told. This fires whenever either changes and the listener decides again.
   * @param listener - called after the change is recorded.
   * @returns a function that detaches the listener.
   */
  onWaitingChanged(listener: () => void): () => void {
    this.waitingListeners.add(listener)
    return (): void => { this.waitingListeners.delete(listener) }
  }

  /**
   * The waiting requests nobody has been rung for yet.
   *
   * A ring is owed once per request, not once per reason to reconsider — and
   * the reasons come often: every attach and detach, every Relay reconnect.
   */
  dueForRing(): string[] {
    return [...this.waiting].filter(id => !this.rung.has(id))
  }

  /** Record that a phone has been rung for everything waiting right now. */
  markRung(): void {
    for (const id of this.waiting) this.rung.add(id)
  }

  private async onConnection(state: MuxState): Promise<void> {
    if (state.connected) {
      // A fresh socket: identify again (dsh may have been upgraded or swapped
      // underneath us) and follow `$events` on it.
      await this.identify()
      this.followEvents()
      return
    }
    this.events = undefined
    this.publish({ reachable: false, ...(state.detail === undefined ? {} : { detail: state.detail }) })
  }

  private async identify(): Promise<void> {
    this.identity = await identifyDsh(this.dsh.baseUrl, cookieFor(this.dsh.baseUrl)).catch(() => undefined)
    const connected = this.dsh.connection.connected
    const version = this.identity?.kind === 'signed-in' ? this.identity.version : undefined
    if (connected) {
      this.publish({ reachable: true, ...(version === undefined ? {} : { version }) })
      return
    }
    this.publish({ reachable: false, detail: this.reasonOffline() })
  }

  /** Why dsh cannot be used, in the words a person needs. */
  private reasonOffline(): string {
    switch (this.identity?.kind) {
      case 'legacy':
        return 'dsh 0.1.1 is running; this Bridle needs dsh 0.2 or later (or keep Bridle 0.1.x)'
      case 'locked':
        return 'dsh asks to sign in — run "bridle plugin install" and restart dsh, or let bridle start dsh'
      default:
        return this.dsh.connection.detail ?? 'dsh is not reachable'
    }
  }

  /**
   * Open the Bridle's own `$events` stream. It only reads: the Bridle never
   * answers an approval or a question, so it cannot race the phone or the
   * browser for them (dsh gives a request to whichever client answers first).
   */
  private followEvents(): void {
    this.events?.cancel()
    // A new stream is a new generation of what is waiting.
    this.waiting.clear()
    this.waitingChanged()
    if (this.resendTimer !== undefined) clearTimeout(this.resendTimer)
    this.resendTimer = setTimeout(() => {
      this.resendTimer = undefined
      // Rings for requests dsh did not re-send are for requests that are gone.
      for (const id of [...this.rung]) if (!this.waiting.has(id)) this.rung.delete(id)
    }, RESEND_GRACE_MS)
    this.resendTimer.unref()
    const reopen = (): void => {
      this.events = undefined
      // dsh ended the stream on a live socket — not the usual way, which is
      // the socket dropping and `onConnection` reopening. Follow it again, or
      // nobody is ever rung until the socket happens to drop.
      if (!this.dsh.connection.connected) return
      setTimeout(() => { if (this.events === undefined && this.dsh.connection.connected) this.followEvents() }, 1_000).unref()
    }
    this.events = this.dsh.open('$events', {}, {
      item: (value) => { this.onEvent(value) },
      end: reopen,
      error: reopen,
    })
  }

  private onEvent(value: unknown): void {
    const event = value as { type?: unknown; event?: unknown; eventId?: unknown }
    if (typeof event.eventId !== 'string') return
    if (event.type === 'waterfall' && typeof event.event === 'string' && ASKS.has(event.event)) {
      if (this.waiting.has(event.eventId)) return
      this.waiting.add(event.eventId)
      this.waitingChanged()
      return
    }
    if (event.type === 'cancel') {
      // Answered — by a phone, the browser, or the turn was cancelled.
      this.rung.delete(event.eventId)
      if (this.waiting.delete(event.eventId)) this.waitingChanged()
    }
  }

  /** Tell every listener the answer may have changed. */
  private waitingChanged(): void {
    for (const listener of this.waitingListeners) {
      try {
        listener()
      } catch {
        // One bad subscriber must not stop the rest.
      }
    }
  }

  /**
   * Pick up pairing offers and revocations made by another `bridle` invocation.
   * The directory is watched rather than the file: `saveState` writes to a
   * temporary and renames it into place, which replaces the inode a file watch
   * is pinned to.
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

  private publish(next: DshStatus): void {
    if (next.reachable === this.status.reachable && next.detail === this.status.detail && next.version === this.status.version) return
    this.status = next
    for (const listener of this.statusListeners) {
      try {
        listener(next)
      } catch {
        // One bad listener must not stall the rest.
      }
    }
  }
}
