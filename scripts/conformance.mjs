#!/usr/bin/env node
/**
 * Run the deployment suite against both relays and refuse to let them drift.
 *
 * There are two implementations of the same protocol now — `relay/` on a box
 * and `relay-worker/` at the edge — and either can be serving the public
 * hostname at any moment. That is only safe while they behave identically,
 * and "we remembered to change both" is not a mechanism.
 *
 * So: one suite, `e2e/tests/deployed.test.js`, pointed at each in turn. It is
 * the right suite for the job because it knows nothing about either
 * implementation — it dials a URL, pairs a phone, drives a real harness, and
 * checks the census. Anything it can tell apart is a difference that would
 * reach a user.
 *
 *   node scripts/conformance.mjs                 # both, local Worker via wrangler dev
 *   node scripts/conformance.mjs --deployed      # both, as actually deployed
 *
 * Exit 0 only when both pass. A relay that cannot be reached is a failure, not
 * a skip: the whole point is that the fallback still works, and a fallback
 * nobody has run is not a fallback.
 */

import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'

const deployed = process.argv.includes('--deployed')

/** Where each implementation answers. */
const targets = deployed
  ? [
      // The address every app and Bridle dials, served by whichever
      // implementation is currently deployed to it.
      { name: 'live · rowel-relay.novabox.ai', url: 'wss://rowel-relay.novabox.ai' },
    ]
  : [
      { name: 'the Node relay', url: null, spawn: nodeRelay },
      { name: 'the Worker under wrangler dev', url: null, spawn: wranglerDev },
    ]

let failed = false

for (const target of targets) {
  process.stdout.write(`\n[1m==> ${target.name}[0m\n`)
  let child
  let url = target.url
  try {
    if (target.spawn !== undefined) ({ child, url } = await target.spawn())
    const code = await runSuite(url)
    if (code !== 0) {
      failed = true
      process.stdout.write(`[31m${target.name} failed[0m\n`)
    }
  } catch (error) {
    failed = true
    process.stdout.write(`[31m${target.name} could not be reached: ${error.message}[0m\n`)
  } finally {
    child?.kill('SIGTERM')
  }
}

process.exit(failed ? 1 : 0)

/**
 * Run the deployment suite against one relay.
 * @param {string} url - the relay's WebSocket base.
 * @returns {Promise<number>} the exit code.
 */
async function runSuite(url) {
  const child = spawn(
    process.execPath,
    ['--test', '--test-concurrency=1', 'e2e/tests/deployed.test.js'],
    { stdio: 'inherit', env: { ...process.env, ROWEL_E2E_RELAY_URL: url } },
  )
  const [code] = await once(child, 'exit')
  return code
}

/** Start the Node relay on an ephemeral port. */
async function nodeRelay() {
  const child = spawn(process.execPath, ['relay/lib/main.js'], {
    env: { ...process.env, PORT: '8791', HOST: '127.0.0.1' },
    stdio: ['ignore', 'ignore', 'inherit'],
  })
  await waitForHealth('http://127.0.0.1:8791/healthz', child)
  return { child, url: 'ws://127.0.0.1:8791' }
}

/** Start the Worker under the local runtime. */
async function wranglerDev() {
  const child = spawn(
    'npx',
    ['--yes', 'wrangler@latest', 'dev', '--config', 'relay-worker/wrangler.jsonc', '--port', '8792', '--local'],
    { stdio: ['ignore', 'ignore', 'inherit'] },
  )
  // Wrangler is slow to boot and prints its readiness on stdout, which is
  // discarded here — polling the health route is the same answer without
  // parsing anyone's console output.
  await waitForHealth('http://127.0.0.1:8792/healthz', child, 60_000)
  return { child, url: 'ws://127.0.0.1:8792' }
}

/**
 * Poll until a relay answers, or give up.
 * @param {string} url - health endpoint.
 * @param {import('node:child_process').ChildProcess} child - so an early exit fails fast.
 * @param {number} timeoutMs - how long to wait.
 */
async function waitForHealth(url, child, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`exited with ${child.exitCode} before answering`)
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(2_000) })
      if (response.ok) return
    } catch {
      // Not up yet.
    }
    await sleep(500)
  }
  throw new Error(`no answer from ${url} within ${timeoutMs}ms`)
}
