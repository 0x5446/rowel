/**
 * A stand-in for dsh 0.2 at the seam the Bridle talks to (`AgentClient`), for
 * the unit tests: a connection that can be dropped and restored, unary calls
 * that answer from a table, streams that tests drive by hand, and `$events`
 * with the levers push bookkeeping needs. The e2e suite has a fuller one; this
 * is the smallest that lets a test hold one moment still.
 */

/**
 * @param {object} [overrides] - replace any member, e.g. `export`.
 * @returns {object} the agent and its levers.
 */
export function fakeAgent(overrides = {}) {
  const listeners = new Set()
  /** Every stream opened, newest last: `{ endpoint, args, sink, cancelled, uplink }`. */
  const streams = []
  let connection = { connected: false, detail: 'not started' }

  const set = (next) => {
    connection = next
    for (const listener of listeners) listener(next)
  }

  const agent = {
    baseUrl: 'http://127.0.0.1:9',
    start: () => { set({ connected: true }) },
    stop: () => { set({ connected: false, detail: 'stopped' }) },
    get connection() { return connection },
    onConnection: (listener) => {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    call: async () => ({ ok: true, value: {} }),
    open: (endpoint, args, sink) => {
      const stream = { endpoint, args, sink, cancelled: false, uplink: [], ended: false }
      streams.push(stream)
      return {
        item: (value) => { stream.uplink.push(value) },
        end: () => { stream.ended = true },
        cancel: () => { stream.cancelled = true },
      }
    },
    export: async () => new Response('archive'),
    ...overrides,
  }

  return {
    agent,
    streams,
    /** The `$events` streams opened so far, newest last. */
    eventStreams: () => streams.filter(stream => stream.endpoint === '$events'),
    /** Push one item to the newest live `$events` stream. */
    emit: (value) => {
      const live = streams.filter(stream => stream.endpoint === '$events' && !stream.cancelled)
      const newest = live.at(-1)
      if (newest === undefined) throw new Error('nobody has $events open')
      newest.sink.item(value)
    },
    /** The connection dropping, as when dsh restarts: every stream fails. */
    drop: () => {
      for (const stream of streams) if (!stream.cancelled) stream.sink.error({ code: 'upstream-lost', message: 'gone', details: {} })
      set({ connected: false, detail: 'gone' })
    },
    /** The connection coming back. */
    restore: () => { set({ connected: true }) },
  }
}

/** A waterfall item as dsh's `$events` sends it. */
export function ask(eventId, event = 'approval/request') {
  return { type: 'waterfall', event, eventId, agentId: 'session-1', request: { toolName: 'bash' } }
}

/** A state file's worth of identity, for a core that never touches disk keys. */
export function machineState(overrides = {}) {
  return {
    version: 1,
    deviceId: 'd',
    privateKey: Buffer.alloc(32).toString('base64url'),
    signingKey: Buffer.alloc(64).toString('base64url'),
    machineName: 'a-mac',
    relayUrl: '',
    dshUrl: 'http://127.0.0.1:9',
    peers: [],
    ...overrides,
  }
}
