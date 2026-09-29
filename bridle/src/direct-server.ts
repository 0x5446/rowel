/**
 * LAN listener. When the phone and the machine are on the same network, going
 * through a Relay on the far side of the internet is a waste of a round trip,
 * and it makes the product useless on a plane or in a lab with no egress.
 *
 * The tunnel is the same Noise channel either way, so binding this to the LAN
 * is safe: an unpaired device gets refused at the handshake, and a paired one
 * is cryptographically the same peer it would be over the Relay. The app tries
 * this address first and falls back to the Relay when it does not answer.
 */

import { createServer, type Server } from 'node:http'
import { networkInterfaces } from 'node:os'
import { WebSocketServer, type WebSocket } from 'ws'
import { MAX_FRAME_BYTES } from '@rowel/protocol'
import { TunnelSession } from './tunnel/session.ts'
import type { BridleCore } from './core.ts'

/** Path the app dials for a direct tunnel. */
export const DIRECT_PATH = '/v1/tunnel'

/** Options for {@link DirectServer}. */
export interface DirectServerOptions {
  /** Bridle package version reported to the app. */
  version: string
  /** Port to bind; `0` lets the OS choose. */
  port?: number
  /** Progress reporting. */
  log?: (message: string) => void
}

/** Connections that have not completed a handshake, at most, at once. */
const MAX_UNAUTHENTICATED = 8

/** How long a connection has to complete the handshake. */
const HANDSHAKE_TIMEOUT_MS = 10_000

/** Paired phones one machine serves at once, as the relay path caps circuits. */
const MAX_PHONES = 8

/** A WebSocket listener on the local network. */
export class DirectServer {
  private readonly http: Server
  private readonly wss: WebSocketServer
  private readonly sessions = new Set<TunnelSession>()

  /**
   * @param core - the machine being served.
   * @param options - port and reporting hooks.
   */
  constructor(private readonly core: BridleCore, private readonly options: DirectServerOptions) {
    this.http = createServer((_request, response) => {
      // Anything that is not the tunnel upgrade gets a flat refusal; this
      // server is not a web server and should not look like one.
      response.writeHead(426, { 'content-type': 'text/plain' })
      response.end('rowel bridle: websocket upgrade required\n')
    })
    // The same bounds for the stretch before the upgrade, which `attach` never
    // sees: a stranger dribbling out an HTTP request is held to the handshake
    // deadline, and no more sockets are accepted than a full house of phones
    // plus the strangers `attach` allows.
    this.http.headersTimeout = HANDSHAKE_TIMEOUT_MS
    this.http.requestTimeout = HANDSHAKE_TIMEOUT_MS
    this.http.maxConnections = MAX_UNAUTHENTICATED + MAX_PHONES
    // The tunnel's own ceiling, as on the relay path. This listener answers
    // anyone on the network before they have proved anything, so a message
    // allowance twice the tunnel's was only room for a stranger to fill.
    this.wss = new WebSocketServer({ server: this.http, path: DIRECT_PATH, maxPayload: MAX_FRAME_BYTES })
    this.wss.on('connection', (socket: WebSocket) => { this.attach(socket) })
    // `ws` re-emits the HTTP server's failures, and an 'error' event with no
    // listener takes the process down. This one is a guest inside dsh.
    this.wss.on('error', (error: Error) => { this.options.log?.(`direct tunnel: ${error.message}`) })
  }

  /**
   * Start listening.
   *
   * A requested port that is already taken falls back to one the OS picks
   * rather than failing. The pinned port is a convenience — it keeps a phone's
   * stored direct address valid across restarts — and a convenience must not
   * be able to stop the listener existing at all. It very nearly did: a
   * restart that overlapped its predecessor hit EADDRINUSE, the `ws` server
   * re-emitted it as an unhandled `error`, and the whole harness this runs
   * inside went down with it.
   *
   * Losing the pinned port costs one failed dial: the phone tries the address
   * it remembers, misses, connects by relay, and is told the new one in the
   * `ready` frame.
   * @returns the bound port.
   */
  async listen(): Promise<number> {
    const wanted = this.options.port ?? 0
    try {
      return await this.bind(wanted)
    } catch (error) {
      const code = (error as { code?: string }).code
      if (wanted === 0 || code !== 'EADDRINUSE') throw error
      this.options.log?.(`port ${String(wanted)} is taken; letting the OS choose one`)
      return this.bind(0)
    }
  }

  private bind(port: number): Promise<number> {
    return new Promise((resolve, reject) => {
      const onError = (error: Error): void => {
        this.http.removeListener('listening', onListening)
        reject(error)
      }
      const onListening = (): void => {
        this.http.removeListener('error', onError)
        const address = this.http.address()
        const bound = typeof address === 'object' && address !== null ? address.port : 0
        this.options.log?.(`direct tunnel listening on ${String(bound)}`)
        resolve(bound)
      }
      this.http.once('error', onError)
      this.http.once('listening', onListening)
      this.http.listen(port, '0.0.0.0')
    })
  }

  /** The bound port, or `0` before {@link listen} resolves. */
  get port(): number {
    const address = this.http.address()
    return typeof address === 'object' && address !== null ? address.port : 0
  }

  /** The `ws://…` addresses a phone on the same network can reach. */
  get addresses(): string[] {
    const port = this.port
    if (port === 0) return []
    return localAddresses().map(host => `ws://${host}:${String(port)}`)
  }

  /** Stop listening and end every direct tunnel. */
  close(): void {
    for (const session of [...this.sessions]) session.dispose('bridle is shutting down')
    this.sessions.clear()
    this.wss.close()
    this.http.close()
  }

  private attach(socket: WebSocket): void {
    // Anyone on the same Wi-Fi can open a socket here, paired or not. The relay
    // path caps circuits per machine; this one had no cap and no deadline, so
    // a stranger could hold any number of silent sockets open indefinitely —
    // inside dsh's own process, with the plugin.
    const strangers = [...this.sessions].filter(session => session.peerKey === undefined).length
    if (strangers >= MAX_UNAUTHENTICATED) {
      socket.close(1013, 'too many unauthenticated connections')
      return
    }
    const deadline = setTimeout(() => {
      if (session.peerKey === undefined) session.dispose('no handshake in time')
    }, HANDSHAKE_TIMEOUT_MS)
    deadline.unref()
    const session = new TunnelSession(this.core, {
      send: (bytes: Buffer) => { socket.send(bytes, { binary: true }) },
      close: () => { socket.close() },
    }, {
      version: this.options.version,
      onAuthenticated: (_key, name) => { this.options.log?.(`${name} attached over the local network`) },
      onClosed: () => {
        clearTimeout(deadline)
        this.sessions.delete(session)
      },
    })
    this.sessions.add(session)
    socket.on('message', (data: Buffer | ArrayBuffer | Buffer[]) => {
      session.receive(Buffer.isBuffer(data) ? data : Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data))
    })
    socket.on('close', () => { session.dispose('phone disconnected') })
    socket.on('error', (error: Error) => { session.dispose(error.message) })
  }
}

/**
 * Addresses of this machine a phone could dial, best candidate first.
 *
 * Every non-internal IPv4 the host has, minus the ones that provably cannot
 * work. A wrong guess is cheap — the app tries each in turn and a dead address
 * costs one failed connect — but a *missing* one is not, because it is the
 * difference between the tunnel working off-network and not.
 *
 * Tailscale is the case worth naming: its interface carries a 100.64/10 address
 * and the listener already binds every interface, so a phone on the same tailnet
 * reaches the machine from anywhere with no relay and no configuration. It is in
 * this list for free.
 * @returns dialable `ws://host:port` candidates.
 */
export function localAddresses(): string[] {
  return dialableAddresses(networkInterfaces())
}

/**
 * The selection and ordering, separated from the host so it can be tested
 * against interface sets this machine does not have.
 * @param interfaces - as returned by `os.networkInterfaces()`.
 * @returns dialable addresses, best first.
 */
export function dialableAddresses(
  interfaces: Record<string, { family: string; internal: boolean; address: string }[] | undefined>,
): string[] {
  const found: string[] = []
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family !== 'IPv4' || entry.internal) continue
      // 169.254/16 is what an interface gives itself when DHCP failed. It is
      // never routable off that link, so advertising it only buys a timeout.
      if (entry.address.startsWith('169.254.')) continue
      found.push(entry.address)
    }
  }
  return found.sort((a, b) => rank(a) - rank(b))
}

/** Lower sorts first. */
function rank(address: string): number {
  // The home or café network, which is the common case and the fastest path.
  if (address.startsWith('192.168.')) return 0
  if (address.startsWith('10.')) return 1
  // Tailscale and other CGNAT overlays: slower than the LAN when both work, but
  // the only one of these that still works after you leave the building.
  if (isTailnet(address)) return 2
  // 172.16/12 is private, but on a developer's machine it is usually a Docker
  // bridge or a VPN leg that a phone cannot reach.
  if (isCarrierPrivate(address)) return 3
  return 4
}

function isTailnet(address: string): boolean {
  const [first, second] = address.split('.').map(Number)
  return first === 100 && second !== undefined && second >= 64 && second <= 127
}

function isCarrierPrivate(address: string): boolean {
  const [first, second] = address.split('.').map(Number)
  return first === 172 && second !== undefined && second >= 16 && second <= 31
}
