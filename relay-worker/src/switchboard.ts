/**
 * One Bridle's socket, and the phones switched onto it.
 *
 * This is the part of the Node Relay that actually moves bytes, and the reason
 * it is one object per Bridle connection rather than one per machine: the
 * device id is not known when the socket is upgraded. docs/protocol.md §6.1
 * puts it in a signed message sent *after* the upgrade, so the object that
 * receives the socket has to be chosen before anyone can know which machine it
 * belongs to. It registers itself with the Exchange once the signature checks
 * out, and phones are routed here afterwards.
 *
 * Both ends of a circuit live in this one object, so forwarding a frame is a
 * memory operation. That is the whole reason for the arrangement: any design
 * where the phone and the Bridle land in different objects pays a network hop
 * per frame, and the Relay's only job is frames.
 *
 * **Hibernation is mandatory, not an optimisation.** A Durable Object holding a
 * socket the ordinary way bills wall-clock duration for as long as the socket
 * is open, so one Bridle idling overnight would spend most of a free day's
 * budget doing nothing. `acceptWebSocket` lets the runtime evict this object
 * between frames and bring it back when one arrives — which means every field
 * below is either derived from the sockets themselves or carried in their
 * attachments, because in-memory state does not survive.
 */

import { DurableObject } from 'cloudflare:workers'
import type { Env } from './env.ts'
import { exchangeOf } from './env.ts'
import { TokenBuckets } from './bucket.ts'
import { deviceIdFor, mintNonce, verifyRegistration } from './identity.ts'
import { MAX_CIRCUITS_PER_MACHINE, MAX_WAKE_MACHINE_CHARS, REGISTER_TIMEOUT_MS, WAKE_LIMIT } from './limits.ts'
import { MuxType, decodeMux, decodeText, encodeMux, encodeText, fromBase64Url } from './wire.ts'
import { wake, type WakeTarget } from './apns.ts'

/**
 * What each socket carries across a hibernation.
 *
 * The `gone` role is an idempotence marker rather than a state: a socket can be
 * closed by this object *and* report its own closure, and detaching twice would
 * tell the Bridle about a circuit it has already forgotten and decrement the
 * census twice.
 */
type Attachment =
  | { role: 'pending'; nonce: string }
  | { role: 'bridle'; deviceId: string; name: string; version: string; since: number; nextCircuit: number }
  | { role: 'app'; deviceId: string; circuit: number }
  | { role: 'gone' }

/** The switchboard. */
export class Switchboard extends DurableObject<Env> {
  /**
   * This machine's wake allowance. In memory: an object that hibernates comes
   * back with a full bucket, which errs toward ringing — the right way for a
   * limit whose job is to stop abuse, not to ration a real machine.
   */
  private readonly wakes = new TokenBuckets()

  /**
   * Take one socket, either end.
   * @param request - the upgrade, forwarded by the Worker with a role in its path.
   * @returns the 101, or a refusal.
   */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
      return new Response('expected a websocket upgrade', { status: 426 })
    }
    const url = new URL(request.url)
    if (url.pathname === '/bridle') return this.acceptBridle()
    if (url.pathname === '/app') return await this.acceptApp(url.searchParams.get('device') ?? '')
    return new Response('not found', { status: 404 })
  }

  /**
   * Hang up on behalf of a newer connection for the same machine.
   *
   * Called by the Exchange, which is the only party that can know this object
   * has been superseded — a laptop that suspends leaves a socket here that
   * still looks alive from the inside.
   */
  async displace(): Promise<void> {
    this.evict(4000, 'replaced by a newer connection')
  }

  /**
   * Whether this object still holds a registered Bridle socket.
   *
   * Asked by the Exchange's sweep. A directory row is only meaningful while
   * the object it names still has the socket, and the close that would retract
   * it is not guaranteed to arrive — a Worker evicted mid-flight, a laptop that
   * vanished, a runtime that never delivered the event. Rows left by those go
   * on being counted forever, which is how a Relay ends up claiming three
   * machines while serving one.
   * @returns true while a registered Bridle is attached here.
   */
  async holdsBridle(): Promise<boolean> {
    const bridle = this.bridleSocket()
    return bridle !== undefined && this.attachmentOf(bridle)?.role === 'bridle'
  }

  /** Registration ran out of time. */
  override async alarm(): Promise<void> {
    const bridle = this.bridleSocket()
    if (bridle === undefined) return
    if (this.attachmentOf(bridle)?.role !== 'pending') return
    bridle.close(4001, 'registration timed out')
  }

  /**
   * Forward one message, or complete a registration.
   * @param ws - the socket it arrived on.
   * @param message - text for control, binary for traffic.
   */
  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = this.attachmentOf(ws)
    if (attachment === undefined || attachment.role === 'gone') return

    if (attachment.role === 'app') {
      // A phone's socket *is* one circuit, so its bytes are the tunnel message
      // with nothing around them. Anything textual is not this protocol.
      if (typeof message === 'string') return
      this.bridleSocket()?.send(encodeMux(MuxType.Data, attachment.circuit, new Uint8Array(message)))
      return
    }

    if (typeof message === 'string') {
      // Text after registration is ignored rather than fatal: a Bridle that
      // learns to send a new control message should not be disconnected by a
      // Relay that has not.
      if (attachment.role === 'pending') await this.completeRegistration(ws, attachment.nonce, message)
      return
    }
    if (attachment.role === 'pending') {
      ws.close(4001, 'data before registration')
      return
    }
    this.forwardFromBridle(message)
  }

  /**
   * A socket reported its own closure.
   * @param ws - the socket that closed.
   */
  override async webSocketClose(ws: WebSocket): Promise<void> {
    await this.hangUp(ws, 'phone disconnected')
  }

  /**
   * A socket failed.
   * @param ws - the socket that failed.
   */
  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.hangUp(ws, 'phone connection failed')
  }

  private acceptBridle(): Response {
    const pair = new WebSocketPair()
    const server = pair[1]
    const nonce = mintNonce()
    // Tagged `bridle` from the start even though it has proven nothing yet:
    // tags are fixed at accept time, and this object only ever holds one
    // Bridle socket. What it has proven lives in the attachment instead.
    this.ctx.acceptWebSocket(server, ['bridle'])
    server.serializeAttachment({ role: 'pending', nonce } satisfies Attachment)
    server.send(JSON.stringify({ t: 'challenge', nonce }))
    // An alarm rather than a timer: this object is expected to be evicted
    // between frames, and an evicted timer never fires. Measured late under
    // `wrangler dev` — consistently ten seconds late, which looks like the
    // local scheduler rather than the protocol — so treat this as a backstop
    // against a socket nobody ever registers, not as a deadline. The Bridle
    // enforces its own fifteen seconds from the other end (`relay-client.ts`).
    void this.ctx.storage.setAlarm(Date.now() + REGISTER_TIMEOUT_MS)
    return new Response(null, { status: 101, webSocket: pair[0] })
  }

  private async completeRegistration(ws: WebSocket, nonce: string, body: string): Promise<void> {
    let message: { t?: unknown; device?: unknown; key?: unknown; signature?: unknown; name?: unknown; bridle?: unknown }
    try {
      message = JSON.parse(body) as typeof message
    } catch {
      ws.close(4002, 'registration must be JSON')
      return
    }
    const { device, key, signature } = message
    if (message.t !== 'register' || typeof device !== 'string' || typeof key !== 'string' || typeof signature !== 'string') {
      ws.close(4002, 'malformed registration')
      return
    }
    const publicKey = fromBase64Url(key)
    // Both checks matter: the signature proves the key holder authorised this
    // socket, and the id check proves the key is the one the device id names.
    if (publicKey === undefined || await deviceIdFor(publicKey) !== device || !await verifyRegistration(publicKey, nonce, signature)) {
      ws.close(4003, 'registration signature did not verify')
      return
    }
    const name = typeof message.name === 'string' && message.name.length > 0 ? message.name.slice(0, 64) : 'a computer'
    const version = typeof message.bridle === 'string' ? message.bridle.slice(0, 32) : 'unknown'

    const admitted = await exchangeOf(this.env).register(device, name, version, this.ctx.id.toString())
    if (!admitted.ok) {
      // A full relay is a capacity fact, not a fault of this machine's. Saying
      // so plainly is what lets the Bridle back off and its owner understand
      // why, instead of retrying into a wall.
      ws.close(4004, admitted.reason)
      return
    }
    ws.serializeAttachment({ role: 'bridle', deviceId: device, name, version, since: Date.now(), nextCircuit: 1 } satisfies Attachment)
    await this.ctx.storage.deleteAlarm()
    ws.send(JSON.stringify({ t: 'registered', device }))
  }

  private async acceptApp(deviceId: string): Promise<Response> {
    const bridle = this.bridleSocket()
    const machine = bridle === undefined ? undefined : this.attachmentOf(bridle)
    // A directory entry can outlive the socket it names by the width of one
    // disconnect, so the phone is turned away here rather than trusted through
    // — and the entry that sent it here is retracted on the way out, because
    // otherwise a Bridle that never comes back is counted online forever.
    if (bridle === undefined || machine?.role !== 'bridle' || machine.deviceId !== deviceId) {
      await exchangeOf(this.env).unregister(deviceId, this.ctx.id.toString())
      return refuse(4404, 'that machine is offline')
    }
    if (this.ctx.getWebSockets('app').length >= MAX_CIRCUITS_PER_MACHINE) {
      return refuse(4008, 'that machine already has the maximum number of devices attached')
    }

    const circuit = machine.nextCircuit
    const nextCircuit = circuit >= 0xffffffff ? 1 : circuit + 1
    bridle.serializeAttachment({ ...machine, nextCircuit } satisfies Attachment)

    const pair = new WebSocketPair()
    // Two tags: one to count phones with, one to find *this* phone with when a
    // frame arrives addressed to its circuit.
    this.ctx.acceptWebSocket(pair[1], ['app', `c:${String(circuit)}`])
    pair[1].serializeAttachment({ role: 'app', deviceId, circuit } satisfies Attachment)
    bridle.send(encodeMux(MuxType.Open, circuit, encodeText(JSON.stringify({ at: Date.now() }))))
    // Awaited, not deferred: `/healthz` is how the deployment is verified, and
    // a phone that finishes its handshake before the census hears about it
    // makes that check flaky for no reason.
    await exchangeOf(this.env).circuits(deviceId, this.ctx.id.toString(), 1)
    return new Response(null, { status: 101, webSocket: pair[0] })
  }

  /**
   * Ask APNs to ring a phone, and tell the Bridle if the token is dead.
   *
   * Reported back rather than logged, because the Bridle is the only place that
   * can act on it: APNs says `BadDeviceToken` when an app has been reinstalled
   * or restored onto a different phone, and a Bridle that never hears will keep
   * ringing a number that no longer exists for as long as the pairing lasts.
   * @param payload - the JSON `WakeRequest` the Bridle sent.
   */
  private async ring(payload: Uint8Array): Promise<void> {
    if (!this.wakes.take('wake', WAKE_LIMIT)) return
    let target: WakeTarget
    try {
      const parsed: unknown = JSON.parse(decodeText(payload))
      const { token, machine } = parsed as Partial<WakeTarget>
      if (typeof token !== 'string') return
      target = { token, ...(typeof machine === 'string' ? { machine: machine.slice(0, MAX_WAKE_MACHINE_CHARS) } : {}) }
    } catch {
      return
    }
    const outcome = await wake(this.env, target)
    if (outcome.ok) return
    // Only Apple saying the device is gone travels back, because that is the
    // only answer the Bridle can act on — and acting on the others would be
    // destructive. Everything that is not a 200 used to come back as one
    // undifferentiated refusal, so a rate limit or an expired signing key made
    // the Bridle permanently delete a working address.
    if (outcome.reason === 'dead') {
      this.bridleSocket()?.send(encodeMux(MuxType.Wake, 0, encodeText(JSON.stringify({ token: target.token, dead: true }))))
      return
    }
    // Said out loud rather than swallowed. A push that fails leaves no trace
    // anywhere else: nothing errors, no user sees anything, the phone simply
    // stays quiet. A half-finished deployment or an expired key would be
    // invisible until someone noticed they had stopped being notified.
    console.error(`rowel-relay: wake failed (${outcome.reason}): ${outcome.detail}`)
  }

  private forwardFromBridle(bytes: ArrayBuffer): void {
    let message
    try {
      message = decodeMux(bytes)
    } catch {
      // A Bridle that speaks a newer mux version will send frames this Relay
      // cannot classify; dropping them is better than dropping the machine.
      return
    }
    // Before the circuit lookup, because a wake has no circuit — that it has
    // nobody to talk to is the entire reason it was sent.
    if (message.type === MuxType.Wake) {
      this.ctx.waitUntil(this.ring(message.payload))
      return
    }
    const target = this.ctx.getWebSockets(`c:${String(message.circuit)}`)[0]
    if (target === undefined) return
    if (message.type === MuxType.Data) {
      target.send(message.payload)
      return
    }
    if (message.type === MuxType.Close) {
      // Marked gone before the close so the phone's own close event does not
      // send this circuit's obituary back to the Bridle that wrote it.
      target.serializeAttachment({ role: 'gone' } satisfies Attachment)
      this.ctx.waitUntil(this.countCircuits(-1))
      target.close(4005, message.payload.byteLength > 0 ? decodeText(message.payload).slice(0, 120) : 'closed by machine')
    }
  }

  private async hangUp(ws: WebSocket, reason: string): Promise<void> {
    const attachment = this.attachmentOf(ws)
    if (attachment === undefined || attachment.role === 'gone') return
    ws.serializeAttachment({ role: 'gone' } satisfies Attachment)

    if (attachment.role === 'app') {
      const bridle = this.bridleSocket()
      if (bridle !== undefined && this.attachmentOf(bridle)?.role === 'bridle') {
        bridle.send(encodeMux(MuxType.Close, attachment.circuit, encodeText(reason)))
      }
      await exchangeOf(this.env).circuits(attachment.deviceId, this.ctx.id.toString(), -1)
      return
    }

    // The Bridle went away, so every circuit on it is dead whether or not the
    // phone holding it knows yet.
    this.evict(4004, 'machine went offline')
    if (attachment.role === 'bridle') {
      await exchangeOf(this.env).unregister(attachment.deviceId, this.ctx.id.toString())
    }
    // Nothing here outlives the Bridle's socket. Objects are created per
    // connection, so leaving a registration alarm behind would leak one row
    // per reconnect, forever.
    await this.ctx.storage.deleteAll()
  }

  private evict(bridleCode: number, phoneReason: string): void {
    for (const socket of this.ctx.getWebSockets('app')) {
      if (this.attachmentOf(socket)?.role === 'gone') continue
      socket.serializeAttachment({ role: 'gone' } satisfies Attachment)
      socket.close(4004, phoneReason)
    }
    const bridle = this.bridleSocket()
    if (bridle === undefined) return
    if (this.attachmentOf(bridle)?.role === 'gone') return
    bridle.serializeAttachment({ role: 'gone' } satisfies Attachment)
    bridle.close(bridleCode, phoneReason)
  }

  private async countCircuits(delta: number): Promise<void> {
    const bridle = this.bridleSocket()
    const machine = bridle === undefined ? undefined : this.attachmentOf(bridle)
    if (machine?.role !== 'bridle') return
    await exchangeOf(this.env).circuits(machine.deviceId, this.ctx.id.toString(), delta)
  }

  private bridleSocket(): WebSocket | undefined {
    return this.ctx.getWebSockets('bridle')[0]
  }

  private attachmentOf(ws: WebSocket): Attachment | undefined {
    return (ws.deserializeAttachment() as Attachment | null) ?? undefined
  }
}

/**
 * Turn a phone away with a reason it can show someone.
 *
 * The upgrade is completed and then closed, rather than answered with an HTTP
 * error, because the app reads these close codes: `WebSocketCarrier.swift`
 * turns 4404 into "That Mac is offline." A 503 would reach it as an unhelpful
 * transport failure indistinguishable from no signal.
 * @param code - the close code from docs/protocol.md.
 * @param reason - the text shown to the user.
 * @returns the 101 that carries the refusal.
 */
function refuse(code: number, reason: string): Response {
  const pair = new WebSocketPair()
  pair[1].accept()
  pair[1].close(code, reason)
  return new Response(null, { status: 101, webSocket: pair[0] })
}
