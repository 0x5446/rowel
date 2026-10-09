/**
 * Model routes taken from a dsh 0.1 `settings.yaml` (`modelRows`), which the
 * real-model tests and ios/screenshots.sh both depend on. A route lost here
 * fails late and quietly — a turn that errors for want of a provider — so the
 * shapes a hand-edited file takes are pinned.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { modelRows } from '../lib/index.js'

const settings = [
  'ui-theme:',
  '  preference: system',
  'llm-pi-ai:',
  '  providers:',
  '# the gateway this machine pays for',
  '    commandcode:',
  '      apiKeyEnv: COMMANDCODE_API_KEY   ',
  '      api: openai-completions',
  '',
  'agent-default-model:',
  '  provider: commandcode',
  '  model: deepseek/deepseek-v4.1-flash',
  'locale:',
  '  preference: en',
].join('\n')

const expected = [
  '- insert:',
  '    - id: llm-pi-ai',
  "      name: '@deepseek-ai/dsh-llm-pi-ai'",
  '      config:',
  '        providers:',
  '          commandcode:',
  '            apiKeyEnv: COMMANDCODE_API_KEY',
  '            api: openai-completions',
  '',
  '- id: agent-default-model',
  '  config:',
  '    provider: commandcode',
  '    model: deepseek/deepseek-v4.1-flash',
].join('\n')

test('the pi-ai routes and the default model move under profile rows, and nothing else does', () => {
  assert.equal(modelRows(settings), expected)
})

test('a file saved with Windows line endings reads the same', () => {
  assert.equal(modelRows(settings.replaceAll('\n', '\r\n')), expected)
})

test('a file with neither section gives nothing', () => {
  assert.equal(modelRows('ui-theme:\n  preference: system\n'), '')
})
