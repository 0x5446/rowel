#!/usr/bin/env node
/**
 * Record what a real dsh 0.2 answers to everything the app asks of it.
 *
 * The app parses dsh's own shapes (tunnel version 2 passes them through), and
 * its parsers are only as right as the examples they were written against.
 * This runs a throwaway dsh (see e2e/src/dsh.ts — no model, an empty home),
 * drives it through a real Bridle and tunnel exactly as the app would, and
 * writes each call's arguments and answer, and the first items of each stream,
 * to ios/RowelTests/Fixtures/dsh-0.2/. The iOS tests decode those files.
 *
 * Re-run it whenever the dsh that CI pins moves forward:
 *
 *   npm run build
 *   ROWEL_E2E_DSH_BIN=<path to dsh> node e2e/scripts/capture-fixtures.mjs
 *
 * Paths that would name this machine — the account's home, the throwaway
 * home — are replaced with placeholders, so the files are the same on any
 * machine and say nothing about the one they were made on.
 */

import { mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'
import { RowelPhone, startDsh, startStack, waitFor } from '../lib/index.js'

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'ios', 'RowelTests', 'Fixtures', 'dsh-0.2')
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

const dsh = await startDsh()
const stack = await startStack({ dshUrl: dsh.url, dshToken: dsh.token, machineName: 'Fixture Mac' })
const phone = new RowelPhone({ bundle: stack.invite().bundle, prefer: 'direct' })
const ready = await phone.connect()
mkdirSync(OUT, { recursive: true })

const realHome = homedir()
/** The package directory of the dsh being recorded: …/node_modules/@deepseek-ai/dsh. */
const dshInstall = dirname(dirname(realpathSync(process.env.ROWEL_E2E_DSH_BIN ?? '')))
/** The private /var/folders spelling and the plain one both appear. */
const throwaway = [dsh.home, dsh.home.replace(/^\/var\//u, '/private/var/')]
function scrub(value) {
  let text = JSON.stringify(value)
  for (const path of throwaway) text = text.split(path).join('/tmp/dsh-home')
  // Every other temporary directory — the Bridle's ROWEL_HOME among them.
  text = text.replace(/\/(?:private\/)?var\/folders\/[^"\\]*/gu, '/tmp/elsewhere')
  // Where dsh itself is installed; the system prompt names it.
  text = text.split(dshInstall).join('/opt/dsh/node_modules/@deepseek-ai/dsh')
  text = text.split(dshInstall.slice(0, dshInstall.indexOf('/node_modules/'))).join('/opt/dsh')
  text = text.split(realHome).join('/Users/someone')
  // This machine's addresses: the direct listener advertises them.
  text = text.replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/gu, (address) => address.startsWith('127.') ? address : '192.0.2.1')
  return JSON.parse(text)
}
function save(name, record) {
  writeFileSync(join(OUT, `${name}.json`), `${JSON.stringify(scrub(record), null, 2)}\n`)
  process.stdout.write(`  ${name}\n`)
}
async function call(name, endpoint, args) {
  const result = await phone.call(endpoint, args)
  save(name, { endpoint, args, result })
  return result
}
async function stream(name, endpoint, args, until, settleMs = 300) {
  const opened = phone.open(endpoint, args)
  // A stream that fails says so and ends; that answer is worth recording too.
  let outcome
  void opened.done.then((done) => { outcome = done })
  await waitFor(() => outcome !== undefined || until(opened.items), 20_000, `${name} to deliver what is needed`)
  await new Promise((resolve) => { setTimeout(resolve, settleMs) })
  if (outcome === undefined) opened.cancel()
  save(name, { endpoint, args, items: opened.items, ...(outcome === undefined ? {} : { outcome }) })
  return opened.items
}

try {
  save('ready', { ready })
  process.stdout.write(`dsh ${ready.dsh} → ${OUT}\n`)

  // Machine-level reads.
  await call('session-list-empty', 'session/list', { _request: {} })
  await call('agent-presets', 'agentPresets/list', {})
  await call('model-catalog', 'session/modelCatalog', {})
  await call('permission-presets', 'permissionPresets/catalog', {})
  await call('plugin-inventory', 'pluginInventory/list', {})
  await call('directory-picker-unavailable', 'directoryPicker/list', { path: dsh.home })
  const settings = await call('settings-describe', 'settings/describe', {})
  const permission = settings.value.namespaces.find(ns => ns.ns === 'permission')
  await call('settings-update-permission', 'settings/update', { ns: 'permission', patch: { defaultPreset: 'read-only' }, expectedRevision: permission.revision })
  await call('permission-presets-after-update', 'permissionPresets/catalog', {})
  await stream('events-ready', '$events', {}, items => items.some(item => item.type === 'ready'))

  // Workspaces.
  const workspace = await call('workspace-create', 'workspace/create', { request: { path: dsh.home } })
  const workspaceId = workspace.value.workspace.workspaceId
  await call('workspace-rename', 'workspace/rename', { request: { workspaceId, title: 'Fixture workspace' } })

  // A conversation, filed into the workspace, with a prompt that carries a
  // photo and ends for want of a model.
  const created = await call('session-create', 'session/create', { request: { workspaceId } })
  const sessionId = created.value.sessionId
  const address = { kind: 'session', sessionId }
  const follow = phone.open('session/follow', { request: { address, assistantStream: true, maxMessages: 25 } })
  await waitFor(() => follow.items.length > 0, 10_000, 'the first snapshot')
  const requestId = randomUUID()
  await call('session-prompt', 'session/prompt', {
    request: { requestId, sessionId, mode: 'queue', content: [{ type: 'text', text: 'Hello from the fixture' }, { type: 'image', mediaType: 'image/png', data: PNG, name: 'dot.png' }], clientTimeZone: 'UTC' },
  })
  await waitFor(() => follow.items.some(item => item.type === 'event' && item.event?.type === 'turn/end'), 30_000, 'the turn to end')
  await new Promise((resolve) => { setTimeout(resolve, 300) })
  follow.cancel()
  save('session-follow-live', { endpoint: 'session/follow', args: { request: { address, assistantStream: true, maxMessages: 25 } }, items: follow.items })

  // The same conversation opened afresh: a snapshot that now has history.
  const snapshot = await stream('session-follow-snapshot', 'session/follow', { request: { address, assistantStream: true, maxMessages: 25 } }, items => items.length > 0)
  await call('session-page', 'session/page', { request: { address, throughSeq: snapshot[0].cursor, maxMessages: 10 } })
  await stream('session-control', 'session/control', {}, items => items.length > 0)
  await call('session-projections', 'session/projections', { request: { sessionId } })

  const image = snapshot[0].records.map(record => record.event).find(event => event.type === 'user/message')
    ?.data?.content?.find(part => part.type === 'image')
  if (image !== undefined) {
    await call('session-attachment', 'session/attachment', { request: { sessionId, attachmentId: image.attachment.attachmentId } })
  }

  // Commands, skills, models, permissions.
  await call('commands-list', 'commands/list', { agentId: sessionId })
  await call('commands-execute-permission', 'commands/execute', { agentId: sessionId, line: '/permission read-only', submittedAttachments: [] })
  await call('skills-list', 'skills/list', { request: { sessionId } })
  const catalog = await phone.call('session/modelCatalog', {})
  const model = catalog.value?.groups?.[0]?.models?.[0]
  if (model !== undefined) {
    await call('session-select-model', 'session/selectModel', { request: { sessionId, provider: catalog.value.groups[0].id, model: model.id } })
  }
  await call('session-select-model-unavailable', 'session/selectModel', { request: { sessionId, provider: 'nobody', model: 'nothing' } })

  // Renaming, searching, forking, cancelling.
  await call('session-rename', 'session/rename', { request: { sessionId, title: 'Fixture conversation' } })
  await call('session-search-disabled', 'session/search', { request: { query: 'fixture' } })
  await call('session-fork', 'session/fork', { request: { sessionId } })
  await call('session-cancel-idle', 'session/cancel', { request: { sessionId } })
  await call('session-update-queue-missing', 'session/updateQueue', { request: { sessionId, itemId: 'nothing', action: 'remove' } })

  // The list now, and how the workspace stream reports an archive.
  await call('session-list', 'session/list', { _request: {} })
  const workspaces = phone.open('workspace/follow', {})
  await waitFor(() => workspaces.items.some(item => item.type === 'baseline'), 10_000, 'the workspace baseline')
  await call('workspace-archive', 'workspace/archiveSession', { request: { sessionId } })
  await call('workspace-unarchive', 'workspace/unarchiveSession', { request: { sessionId } })
  await new Promise((resolve) => { setTimeout(resolve, 500) })
  workspaces.cancel()
  save('workspace-follow', { endpoint: 'workspace/follow', args: {}, items: workspaces.items })
  await call('workspace-delete', 'workspace/delete', { request: { workspaceId } })

  // A bad request, to pin the error shape the app shows.
  await call('arguments-invalid', 'session/list', { wrong: true })
} finally {
  phone.close()
  await stack.stop()
  await dsh.stop()
}
process.exit(0)
