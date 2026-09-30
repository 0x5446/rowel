/**
 * The Rowel Relay: a content-blind switchboard between phones and the Bridles
 * on people's machines.
 *
 * It exists for one reason. A laptop behind NAT cannot accept an inbound
 * connection, so the Bridle dials out and holds a socket, and the Relay hands
 * phones onto it. Everything it forwards is a Noise ciphertext it has no key
 * for. It stores nothing but a device id, a socket, and a display name.
 *
 * Endpoints:
 * - `GET  /healthz`               liveness and coarse counters
 * - `GET  /install`               the Bridle installer; off unless configured
 * - `GET  /v1/machine/:deviceId`  is that machine online, and what is it called
 * - `POST /v1/pair/offer`         a Bridle parks a short-code pairing bundle
 * - `GET  /v1/pair/claim?code=`   an app collects one, once
 * - `WS   /v1/bridle`             a Bridle registers and carries muxed circuits
 * - `WS   /v1/app?device=`        a phone attaches as one circuit
 */

import { readFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { Duplex } from 'node:stream'
import { WebSocketServer, type RawData, type WebSocket } from 'ws'
import {
  MuxType,
  decodeMux,
  deviceIdFor,
  encodeMux,
  mintNonce,
  normalizeShortCode,
  verifyPairOffer,
  verifyRegistration,
  MAX_FRAME_BYTES,
  type PairingBundle,
} from '@rowel/protocol'
import { OfferStore } from './offers.ts'
import { RateLimiter } from './rate-limit.ts'
import { CapacityError, Registry, type Machine } from './registry.ts'

/**
 * Largest tunnel message the Relay will forward.
 *
 * `MAX_FRAME_BYTES`, not a number of its own. This relay could carry more —
 * it is a Node process with a configurable `ws` — but a Bridle that behaves
 * differently depending on which relay it dialled is worse than one that is
 * uniformly a little smaller, and the smallest ceiling on any deployed path is
 * Cloudflare's 32 MiB. Both ends now refuse an oversized frame before writing
 * it, so this is a backstop rather than the thing anyone should hit.
 */
const MAX_PAYLOAD = MAX_FRAME_BYTES

/** How long a Bridle has to complete registration before its socket is dropped. */
const REGISTER_TIMEOUT_MS = 15_000

/** Carrier keepalive; a silent socket is dropped after two missed rounds. */
const HEARTBEAT_MS = 25_000

/** Options for {@link RelayServer}. */
export interface RelayServerOptions {
  /** TCP port; `0` lets the OS choose. */
  port?: number
  /** Keep the wakes Bridles ask for in {@link RelayServer.wakes}, for tests to read. */
  recordWakes?: boolean
  /** Bind address. */
  host?: string
  /** Progress reporting. */
  log?: (message: string) => void
  /**
   * Path to the Bridle installer served at `GET /install`.
   *
   * The Relay is a dumb pipe and this is the one exception, for a practical
   * reason: the app tells people to paste `curl -fsSL https://<host>/install
   * | sh`, and that URL has to resolve to something. Serving it from the Relay
   * means one host and one deployment instead of a second static site whose
   * only content is a 100-line shell script. Set to `null` to turn it off.
   *
   * **Off unless asked for.** The official deployment does not serve it:
   * putting the install script and the public relay in one deployment unit
   * turns a single relay compromise into supply-chain poisoning for every new
   * user. Self-hosters who want one host for both can point this at their
   * checkout's `install.sh`.
   */
  installScript?: string | null
}

/** Coarse, non-identifying counters for `/healthz`. */
export interface RelayStats {
  machines: number
  circuits: number
  offers: number
  uptimeSeconds: number
}

/** The switchboard. */
export class RelayServer {
  private readonly http: Server
  private readonly bridleSockets = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD })
  private readonly appSockets = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD })
  private readonly registry = new Registry()
  private readonly offers = new OfferStore()
  private readonly claimLimit = new RateLimiter(10, 0.2)
  private readonly attachLimit = new RateLimiter(30, 1)
  // The bridle door was the one unmetered entrance: every other path charged a
  // bucket, while the door that allocates registration state per connection
  // took callers at line rate. A healthy Bridle connects once and redials with
  // backoff, so the same allowance phones get is generous here — the burst
  // absorbs an office of machines reconnecting through one NAT after a blip.
  private readonly bridleLimit = new RateLimiter(30, 1)
  private readonly startedAt = Date.now()
  private readonly log: (message: string) => void
  /** The installer, read once at construction; `undefined` disables the route. */
  private readonly installer: string | undefined
  private heartbeat: NodeJS.Timeout | undefined

  /** @param options - port, bind address, logging, and the installer path. */
  constructor(private readonly options: RelayServerOptions = {}) {
    this.log = options.log ?? ((): void => {})
    this.installer = readInstaller(options.installScript)
    this.http = createServer((request, response) => { this.onRequest(request, response) })
    this.http.on('upgrade', (request, socket, head) => { this.onUpgrade(request, socket, head) })
  }

  /** Live counters. */
  get stats(): RelayStats {
    return {
      machines: this.registry.size,
      circuits: this.registry.circuitCount,
      offers: this.offers.size,
      uptimeSeconds: Math.round((Date.now() - this.startedAt) / 1000),
    }
  }

  /**
   * Start listening.
   * @returns the bound port.
   */
  listen(): Promise<number> {
    return new Promise((resolve, reject) => {
      this.http.once('error', reject)
      this.http.listen(this.options.port ?? 8787, this.options.host ?? '0.0.0.0', () => {
        const address = this.http.address()
        const port = typeof address === 'object' && address !== null ? address.port : 0
        this.log(`relay listening on ${this.options.host ?? '0.0.0.0'}:${String(port)}`)
        this.heartbeat = setInterval(() => { this.sweepSockets() }, HEARTBEAT_MS)
        this.heartbeat.unref()
        resolve(port)
      })
    })
  }

  /** Stop listening and close every socket. */
  close(): Promise<void> {
    if (this.heartbeat !== undefined) clearInterval(this.heartbeat)
    for (const socket of this.bridleSockets.clients) socket.close(1001, 'relay shutting down')
    for (const socket of this.appSockets.clients) socket.close(1001, 'relay shutting down')
    this.bridleSockets.close()
    this.appSockets.close()
    return new Promise((resolve) => { this.http.close(() => { resolve() }) })
  }

  private onRequest(request: IncomingMessage, response: ServerResponse): void {
    const url = new URL(request.url ?? '/', 'http://relay.invalid')
    if (request.method === 'GET' && url.pathname === '/healthz') {
      send(response, 200, this.stats)
      return
    }
    if (request.method === 'GET' && url.pathname === '/install') {
      if (this.installer === undefined) {
        send(response, 404, { error: 'no installer on this relay' })
        return
      }
      // Plain text, not a download: this is being piped into a shell, and a
      // Content-Disposition would make a browser save it instead of showing
      // someone what they are about to run.
      response.writeHead(200, {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'public, max-age=300',
      })
      response.end(this.installer)
      return
    }
    if (request.method === 'GET' && url.pathname.startsWith('/v1/machine/')) {
      const machine = this.registry.find(decodeURIComponent(url.pathname.slice('/v1/machine/'.length)))
      send(response, 200, machine === undefined ? { online: false } : { online: true, name: machine.name, version: machine.version })
      return
    }
    if (request.method === 'POST' && url.pathname === '/v1/pair/offer') {
      void this.onPairOffer(request, response)
      return
    }
    if (request.method === 'GET' && url.pathname === '/v1/pair/claim') {
      this.onPairClaim(request, response, url)
      return
    }
    send(response, 404, { error: 'not found' })
  }

  private async onPairOffer(request: IncomingMessage, response: ServerResponse): Promise<void> {
    let body: {
      code?: unknown
      device?: unknown
      key?: unknown
      signature?: unknown
      bundle?: PairingBundle
      expiresAt?: unknown
    }
    try {
      body = JSON.parse(await readBody(request)) as typeof body
    } catch {
      send(response, 400, { error: 'body must be JSON' })
      return
    }
    const { code, device, key, signature, bundle, expiresAt } = body
    if (typeof code !== 'string' || typeof device !== 'string' || typeof key !== 'string'
      || typeof signature !== 'string' || bundle === undefined || typeof expiresAt !== 'number') {
      send(response, 400, { error: 'code, device, key, signature, bundle, and expiresAt are required' })
      return
    }
    const publicKey = Buffer.from(key, 'base64url')
    // Both checks matter: the signature proves the key holder authorised this
    // code, and the id check proves the key is the one the device id names.
    if (deviceIdFor(publicKey) !== device || !verifyPairOffer(publicKey, code, signature)) {
      send(response, 403, { error: 'offer is not signed by the machine it names' })
      return
    }
    if (bundle.device !== device) {
      send(response, 400, { error: 'bundle names a different machine' })
      return
    }
    if (!this.offers.put(normalizeShortCode(code), device, bundle, expiresAt)) {
      send(response, 429, { error: 'too many outstanding offers for this machine' })
      return
    }
    send(response, 200, { ok: true })
  }

  private onPairClaim(request: IncomingMessage, response: ServerResponse, url: URL): void {
    if (!this.claimLimit.take(clientKey(request))) {
      send(response, 429, { error: 'too many attempts; wait a moment' })
      return
    }
    const code = normalizeShortCode(url.searchParams.get('code') ?? '')
    const bundle = this.offers.claim(code)
    if (bundle === undefined) {
      send(response, 404, { error: 'that code is not valid any more' })
      return
    }
    send(response, 200, { bundle })
  }

  private onUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const url = new URL(request.url ?? '/', 'http://relay.invalid')
    if (url.pathname === '/v1/bridle') {
      this.bridleSockets.handleUpgrade(request, socket, head, (ws) => { this.onBridle(ws, clientKey(request)) })
      return
    }
    if (url.pathname === '/v1/app') {
      const deviceId = url.searchParams.get('device') ?? ''
      this.appSockets.handleUpgrade(request, socket, head, (ws) => { this.onApp(ws, deviceId, clientKey(request)) })
      return
    }
    socket.destroy()
  }

  private onBridle(socket: WebSocket, key: string): void {
    tag(socket)
    // The same refusal the app path gives, for the same reason, and the Bridle
    // already knows what to do with it: the close reads as a disconnect and
    // the redial backs off.
    if (!this.bridleLimit.take(key)) {
      socket.close(4029, 'too many connections; wait a moment')
      return
    }
    const nonce = mintNonce()
    let machine: Machine | undefined
    const timer = setTimeout(() => {
      if (machine === undefined) socket.close(4001, 'registration timed out')
    }, REGISTER_TIMEOUT_MS)
    timer.unref()
    socket.send(JSON.stringify({ t: 'challenge', nonce }))

    socket.on('message', (data: RawData, isBinary: boolean) => {
      if (!isBinary) {
        if (machine !== undefined) return
        machine = this.registerBridle(socket, nonce, toBuffer(data))
        if (machine !== undefined) {
          clearTimeout(timer)
          socket.send(JSON.stringify({ t: 'registered', device: machine.deviceId }))
          this.log(`machine online: ${machine.name} (${machine.deviceId})`)
        }
        return
      }
      if (machine === undefined) {
        socket.close(4001, 'data before registration')
        return
      }
      this.forwardFromBridle(machine, toBuffer(data))
    })

    socket.on('close', () => {
      clearTimeout(timer)
      if (machine === undefined) return
      this.registry.unregister(machine.deviceId, socket)
      this.log(`machine offline: ${machine.name} (${machine.deviceId})`)
    })
    socket.on('error', () => { socket.close() })
  }

  private registerBridle(socket: WebSocket, nonce: string, data: Buffer): Machine | undefined {
    let message: { t?: unknown; device?: unknown; key?: unknown; signature?: unknown; name?: unknown; bridle?: unknown }
    try {
      message = JSON.parse(data.toString('utf8')) as typeof message
    } catch {
      socket.close(4002, 'registration must be JSON')
      return undefined
    }
    const { device, key, signature } = message
    if (message.t !== 'register' || typeof device !== 'string' || typeof key !== 'string' || typeof signature !== 'string') {
      socket.close(4002, 'malformed registration')
      return undefined
    }
    const publicKey = Buffer.from(key, 'base64url')
    if (deviceIdFor(publicKey) !== device || !verifyRegistration(publicKey, nonce, signature)) {
      socket.close(4003, 'registration signature did not verify')
      return undefined
    }
    const name = typeof message.name === 'string' && message.name.length > 0 ? message.name.slice(0, 64) : 'a computer'
    const version = typeof message.bridle === 'string' ? message.bridle.slice(0, 32) : 'unknown'
    try {
      return this.registry.register(device, name, version, socket)
    } catch (error) {
      // A full relay is a capacity fact, not a fault of this machine's. Saying
      // so plainly is what lets the Bridle back off and its owner understand
      // why, instead of retrying into a wall.
      const reason = error instanceof CapacityError ? error.message : 'registration failed'
      this.log(`refused ${device}: ${reason}`)
      socket.close(4004, reason)
      return undefined
    }
  }

  /**
   * The wakes Bridles have asked for, oldest first — kept only when the relay
   * was built with `recordWakes` (the tests). Anything else would have a
   * long-running self-hosted relay holding every APNs token it ever saw.
   */
  readonly wakes: Record<string, unknown>[] = []

  private forwardFromBridle(machine: Machine, bytes: Buffer): void {
    let message
    try {
      message = decodeMux(bytes)
    } catch {
      // A Bridle that speaks a newer mux version will send frames this Relay
      // cannot classify; dropping them is better than dropping the machine.
      return
    }
    if (message.type === MuxType.Wake) {
      // This Relay never rings anyone — it exists so the tests have a Relay,
      // and pushing needs a signing key that belongs to a deployment rather
      // than to a test. What it does is record the ask, which is the part a
      // test can check: that the Bridle decided to ring, and whom.
      if (this.options.recordWakes !== true) return
      try {
        this.wakes.push(JSON.parse(message.payload.toString('utf8')) as Record<string, unknown>)
      } catch {
        // A malformed wake is the Bridle's problem, not a reason to drop it.
      }
      return
    }
    const circuit = machine.circuits.get(message.circuit)
    if (circuit === undefined) return
    if (message.type === MuxType.Data) {
      circuit.socket.send(message.payload, { binary: true })
      return
    }
    if (message.type === MuxType.Close) {
      this.registry.detach(machine, message.circuit)
      circuit.socket.close(4005, message.payload.length > 0 ? message.payload.toString('utf8').slice(0, 120) : 'closed by machine')
    }
  }

  private onApp(socket: WebSocket, deviceId: string, key: string): void {
    tag(socket)
    if (!this.attachLimit.take(key)) {
      socket.close(4029, 'too many connections; wait a moment')
      return
    }
    const machine = this.registry.find(deviceId)
    if (machine === undefined) {
      socket.close(4404, 'that machine is offline')
      return
    }
    const circuit = this.registry.attach(machine, socket)
    if (circuit === undefined) {
      socket.close(4008, 'that machine already has the maximum number of devices attached')
      return
    }
    machine.socket.send(encodeMux(MuxType.Open, circuit.id, Buffer.from(JSON.stringify({ at: circuit.openedAt }), 'utf8')))
    socket.on('message', (data: RawData, isBinary: boolean) => {
      if (!isBinary) return
      machine.socket.send(encodeMux(MuxType.Data, circuit.id, toBuffer(data)))
    })
    const detach = (reason: string): void => {
      if (!machine.circuits.has(circuit.id)) return
      this.registry.detach(machine, circuit.id)
      if (machine.socket.readyState === machine.socket.OPEN) {
        machine.socket.send(encodeMux(MuxType.Close, circuit.id, Buffer.from(reason, 'utf8')))
      }
    }
    socket.on('close', () => { detach('phone disconnected') })
    socket.on('error', () => { detach('phone connection failed') })
  }

  private sweepSockets(): void {
    for (const set of [this.bridleSockets.clients, this.appSockets.clients]) {
      for (const socket of set) {
        const tagged = socket as WebSocket & { isAlive?: boolean }
        if (tagged.isAlive === false) {
          socket.terminate()
          continue
        }
        tagged.isAlive = false
        socket.ping()
      }
    }
  }
}

/**
 * Load the installer once, at startup.
 *
 * Reading it per request would turn a public unauthenticated endpoint into a
 * disk read, and the file only changes when the Relay is redeployed anyway.
 * @param configured - explicit path, `null` to disable, or `undefined` for the default.
 * @returns the script text, or `undefined` when there is none to serve.
 */
function readInstaller(configured: string | null | undefined): string | undefined {
  // Absent means off, not "find one nearby". An earlier version defaulted to
  // the checkout's install.sh, which meant every relay served an installer
  // whether its operator intended to or not.
  if (configured === null || configured === undefined || configured.length === 0) return undefined
  try {
    return readFileSync(configured, 'utf8')
  } catch {
    return undefined
  }
}

function tag(socket: WebSocket): void {
  const tagged = socket as WebSocket & { isAlive?: boolean }
  tagged.isAlive = true
  socket.on('pong', () => { tagged.isAlive = true })
}

function send(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(Buffer.byteLength(payload)),
    'cache-control': 'no-store',
  })
  response.end(payload)
}

async function readBody(request: IncomingMessage, limit = 64 * 1024): Promise<string> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of request) {
    const buffer = chunk as Buffer
    total += buffer.length
    if (total > limit) throw new Error('request body is too large')
    chunks.push(buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}

function clientKey(request: IncomingMessage): string {
  const forwarded = request.headers['x-forwarded-for']
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded
  return (first?.split(',')[0] ?? request.socket.remoteAddress ?? 'unknown').trim()
}

function toBuffer(data: RawData): Buffer {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data)
  return Buffer.from(data)
}
