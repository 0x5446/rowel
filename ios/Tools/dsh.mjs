#!/usr/bin/env node
/**
 * One call to the screenshot harness's dsh, for ios/screenshots.sh and
 * ios/demo.sh.
 *
 *   node Tools/dsh.mjs <port> <dsh.log> <endpoint> < args.json
 *
 * Prints dsh's answer, `{"type":"server-response","rpcId":…,"result":{…}}`,
 * and exits 1 — with dsh's code and message on stderr — when it is a failure,
 * so a refused step stops the script instead of passing for one that worked.
 * The arguments arrive on stdin rather than as an argument: one of them is a
 * base64 PNG, larger than a command line holds.
 *
 * dsh 0.2 answers nothing without its sign-in cookie, and hands out the
 * cookie only for the launch token it printed (docs/dsh-0.2-protocol.md §1).
 * So this reads the newest token from the harness's log, trades it once, and
 * keeps the cookie beside the log for the next call; a cookie that has
 * stopped working is traded again.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

const [port, log, endpoint] = process.argv.slice(2)
if (port === undefined || log === undefined || endpoint === undefined) {
  process.stderr.write('usage: node Tools/dsh.mjs <port> <dsh.log> <endpoint> < args.json\n')
  process.exit(2)
}
const base = `http://127.0.0.1:${port}`
const jar = join(dirname(log), 'dsh-cookie')
const args = JSON.parse(readFileSync(0, 'utf8') || '{}')

async function signIn() {
  const tokens = [...readFileSync(log, 'utf8').matchAll(/[?&]token=([^\s&]+)/gu)]
  const token = tokens.at(-1)?.[1]
  if (token === undefined) throw new Error(`no launch token in ${log}; is this dsh 0.2, started by the script?`)
  const answer = await fetch(`${base}/?token=${token}`, { redirect: 'manual' })
  const cookie = answer.headers.get('set-cookie')?.split(';')[0]
  if (cookie === undefined) throw new Error(`dsh refused the launch token (HTTP ${answer.status})`)
  writeFileSync(jar, cookie, { mode: 0o600 })
  return cookie
}

async function call(cookie) {
  return fetch(`${base}/api/${endpoint}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: `shots-${Date.now()}`, method: endpoint, payload: { args } }),
  })
}

let cookie
try { cookie = readFileSync(jar, 'utf8') } catch { cookie = await signIn() }
let answer = await call(cookie)
if (answer.status === 401 || answer.status === 403) answer = await call(await signIn())
const text = await answer.text()
process.stdout.write(`${text}\n`)
let result
try { result = JSON.parse(text).result } catch { result = undefined }
if (result?.ok !== true) {
  const error = result?.error ?? { code: `http-${answer.status}`, message: text.slice(0, 200) }
  process.stderr.write(`${endpoint}: ${error.code}: ${error.message}\n`)
  process.exit(1)
}
