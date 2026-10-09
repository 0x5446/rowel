#!/usr/bin/env node
/**
 * A stand-in for `dsh web` 0.2, for the test that Bridle can start one and
 * sign in to it. Takes the arguments Bridle passes (`--port <n>`), serves the
 * sign-in door the way dsh does, and prints its token line once on stdout —
 * showing a reverse-proxy address, as dsh 0.2.1 does with a `publicUrl`, so
 * the test also proves only the token is taken from it.
 *
 * Exits on `GET /quit`, or after a minute, so a failed test leaves nothing
 * running.
 */

import { createServer } from 'node:http'

const port = Number(process.argv[process.argv.indexOf('--port') + 1])
const token = 'fake-launch-token'
const cookie = 'dsh-auth-fake=v1.body.sig'

const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://x')
  if (url.pathname === '/quit') {
    response.end()
    process.exit(0)
  }
  if (request.method === 'GET' && url.pathname === '/') {
    if (url.searchParams.get('token') === token) {
      response.writeHead(303, { location: './', 'set-cookie': `${cookie}; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict` })
      response.end()
      return
    }
    response.writeHead(401, { 'content-type': 'text/plain' })
    response.end('dsh web authentication required; reopen the URL printed by dsh web.')
    return
  }
  if (request.headers.cookie !== cookie) {
    response.writeHead(401, { 'content-type': 'text/plain' })
    response.end('unauthorized')
    return
  }
  if (url.pathname === '/api/pluginManager/listBundles') {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ type: 'server-response', rpcId: 'r', result: { ok: true, value: [{ name: '@deepseek-ai/dsh-base', version: '0.2.1-alpha.1' }] } }))
    return
  }
  response.writeHead(404)
  response.end('not found')
})

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`dsh web: https://proxy.example/ui/?token=${token}\n`)
})
setTimeout(() => { process.exit(0) }, 60_000).unref()
