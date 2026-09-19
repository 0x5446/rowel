#!/usr/bin/env node
/**
 * Catch the documentation drifting away from the code.
 *
 * The docs declare themselves authoritative enough to reimplement a client
 * from, and they sit at the bottom of the conflict order (`docs/README.md`).
 * Both of those are only safe if something notices when they stop being true.
 * Nothing did: the test vectors cover the wire bytes, the unit tests cover the
 * fold, and neither has an opinion about whether a prose table still lists the
 * right constants.
 *
 * So this checks the handful of facts that are cheap to verify mechanically and
 * expensive to get wrong — the constants a reimplementer would copy, and the
 * method and frame lists a reader would trust. It is deliberately not a
 * spellchecker for prose; it only knows things that have one right answer.
 *
 *   node scripts/check-docs.mjs
 *
 * Exit 0 when the docs match the source, 1 with a list of mismatches otherwise.
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (path) => readFileSync(join(root, path), 'utf8')

const problems = []

/**
 * @param {boolean} ok - whether the check passed.
 * @param {string} message - what is wrong, phrased so it can be acted on.
 */
function expect(ok, message) {
  if (!ok) problems.push(message)
}

/**
 * Pull a numeric constant out of a source file.
 * @param {string} source - file contents.
 * @param {string} name - the identifier.
 * @returns {string | undefined} the literal, with underscores stripped.
 */
function constant(source, name) {
  // Accepts `64 * 1024 * 1024` as well as `5_000`. Constants in this codebase
  // are written the way they are meant to be read, and a checker that only
  // understood bare literals would silently skip the ones spelled as products —
  // which is how the first version of this file reported `64` for a 64 MiB cap.
  const match = new RegExp(`${name}\\s*(?::\\s*[\\w<>\\[\\]]+)?\\s*=\\s*([0-9_ *]+)`).exec(source)
  const expression = match?.[1]?.replaceAll('_', '').trim()
  if (expression === undefined) return undefined
  if (!/^[0-9 *]+$/.test(expression)) return undefined
  const product = expression.split('*').reduce((total, part) => total * Number(part.trim()), 1)
  return Number.isFinite(product) ? String(product) : undefined
}

/**
 * Pull the fallback out of `positiveInt(process.env['NAME'], 1_000)`.
 * @param {string} source - file contents.
 * @param {string} name - the environment variable.
 * @returns {string | undefined} the default, underscores stripped.
 */
function envDefault(source, name) {
  const match = new RegExp(`process\\.env\\['${name}'\\]\\s*,\\s*([0-9_]+)`).exec(source)
  return match?.[1]?.replaceAll('_', '')
}

// --- Constants a reimplementer would copy ------------------------------------

const protocolDoc = read('docs/protocol.md')
const deployDoc = read('docs/deployment.md')
const session = read('bridle/src/tunnel/session.ts')
const eventLog = read('bridle/src/tunnel/event-log.ts')
const registry = read('relay/src/registry.ts')
const offers = read('relay/src/offers.ts')
const relayServer = read('relay/src/server.ts')
const frameConstants = read('protocol/src/frames.ts')

/**
 * Render a number the way the docs might write it, so a match is not defeated
 * by a thousands separator.
 * @param {string} value - the raw digits.
 * @returns {string[]} every spelling worth looking for.
 */
function spellings(value) {
  const grouped = Number(value).toLocaleString('en-US')
  return grouped === value ? [value] : [value, grouped]
}

const checks = [
  // Lives in protocol/ now, not relay/: both ends check against it before
  // writing, so it is a protocol fact rather than one relay's setting.
  ['单帧最大（字节）', constant(frameConstants, 'MAX_FRAME_BYTES'), [protocolDoc, deployDoc], ['32 MiB']],
  ['在途请求上限', constant(session, 'MAX_INFLIGHT'), [protocolDoc], null],
  ['心跳间隔（毫秒）', constant(session, 'PING_INTERVAL_MS'), [protocolDoc, deployDoc], ['25 秒', '25s']],
  ['重放缓冲容量', constant(eventLog, 'DEFAULT_CAPACITY'), [protocolDoc], null],
  ['每机器线路上限', constant(registry, 'MAX_CIRCUITS_PER_MACHINE'), [deployDoc], null],
  ['全局机器上限（默认）', envDefault(registry, 'ROWEL_MAX_MACHINES'), [deployDoc], null],
  ['全局线路上限（默认）', envDefault(registry, 'ROWEL_MAX_CIRCUITS'), [deployDoc], null],
  ['每设备短码上限', constant(offers, 'MAX_OFFERS_PER_DEVICE'), [deployDoc], null],
]

for (const [label, value, docs, phrases] of checks) {
  if (value === undefined) {
    problems.push(`${label}: 源码里找不到这个常量了，check-docs.mjs 需要更新`)
    continue
  }
  const haystack = docs.join('\n')
  // `phrases` is for constants the docs state in a derived form — 64 MiB rather
  // than 67108864, "25 秒" rather than 25000. The derived form still has to be
  // pinned to the source value, or the check passes no matter what the source
  // says, which is what the first version of this file did.
  const wanted = phrases ?? spellings(value)
  const found = wanted.some(phrase => haystack.includes(phrase))
  const derived = phrases !== null
  expect(found, derived
    ? `${label}: 源码是 ${value}，文档里应当以 ${wanted.join(' 或 ')} 出现，但没找到`
    : `${label}: 源码是 ${value}，但文档里找不到这个数`)
  // A derived spelling could drift from the source without the phrase changing,
  // so pin the arithmetic too where it is knowable.
  if (label === '单帧最大（字节）') {
    expect(Number(value) === 32 * 1024 * 1024, `单帧最大: 源码是 ${value}，不再是文档写的 32 MiB`)
  }
  if (label === '心跳间隔（毫秒）') {
    expect(Number(value) === 25_000, `心跳间隔: 源码是 ${value}ms，不再是文档写的 25 秒`)
  }
}

// --- The prologue, which is load-bearing and easy to change by accident ------

const frames = read('protocol/src/frames.ts')
const prologue = /TUNNEL_PROLOGUE.*?Buffer\.from\('([^']+)'/s.exec(frames)?.[1]
expect(prologue === 'rowel-tunnel',
  `prologue 现在是 ${String(prologue)}；文档 §3.1 说它必须是稳定的、不含版本的 rowel-tunnel`)
expect(protocolDoc.includes('`"rowel-tunnel"`'),
  'protocol.md §3.1 没有写出当前的 prologue 值')

const swiftPrologue = /tunnelPrologue = Data\("([^"]+)"/.exec(read('ios/Rowel/Protocol/Frames.swift'))?.[1]
expect(swiftPrologue === prologue,
  `两端 prologue 不一致：TypeScript ${String(prologue)}，Swift ${String(swiftPrologue)}`)

// --- Frame kinds the docs enumerate ------------------------------------------

const FRAME_KINDS = ['hello', 'req', 'res', 'cancel', 'respond', 'resume', 'wake', 'ev', 'resync', 'status', 'ping', 'pong', 'fault', 'ready']
const documentedFrames = new Set(
  [...protocolDoc.matchAll(/\*\*`([a-z]+)`\*\*/g)].map(match => match[1]),
)
for (const kind of FRAME_KINDS) {
  expect(documentedFrames.has(kind), `protocol.md §4 没有描述 \`${kind}\` 帧`)
}

// Every frame the two implementations define is one the docs know about. The
// list above is hand-written and would otherwise rot the moment someone adds a
// frame without touching it — which is exactly what happened with `wake`.
const tsKinds = [...read('protocol/src/frames.ts').matchAll(/^\s{2}t: '([a-z]+)'$/gm)].map(m => m[1])
const swiftKinds = [...read('ios/Rowel/Protocol/Frames.swift').matchAll(/^\s{4}public let t = "([a-z]+)"$/gm)].map(m => m[1])
for (const kind of new Set([...tsKinds, ...swiftKinds])) {
  expect(FRAME_KINDS.includes(kind), `\`${kind}\` 帧存在于源码，但 check-docs 的清单里没有`)
}
for (const kind of swiftKinds) {
  expect(tsKinds.includes(kind), `Swift 定义了 \`${kind}\` 帧，TypeScript 没有 —— 两份协议已漂移`)
}

// --- The two copies of the Relay wire format ---------------------------------
//
// `protocol/src/mux.ts` is the definition; `relay-worker/src/wire.ts` is a
// second copy, because a Cloudflare Worker cannot import the Node package. A
// value that drifts between them is not a crash — the Relay silently drops the
// frame it no longer recognises — so it is checked mechanically rather than
// left to whoever remembers.

const muxOf = (path) => Object.fromEntries(
  [...read(path).matchAll(/^\s{2}([A-Z][a-zA-Z]*): (0x[0-9a-f]{2}),$/gm)].map(m => [m[1], m[2]]),
)
const muxDefinition = muxOf('protocol/src/mux.ts')
const muxCopy = muxOf('relay-worker/src/wire.ts')
expect(Object.keys(muxDefinition).length > 0, 'protocol/src/mux.ts 里没解析出任何 MuxType')
for (const [name, value] of Object.entries(muxDefinition)) {
  expect(muxCopy[name] === value,
    `MuxType.${name} 漂移了：protocol/src/mux.ts 是 ${value}，relay-worker/src/wire.ts 是 ${String(muxCopy[name])}`)
}
for (const name of Object.keys(muxCopy)) {
  expect(name in muxDefinition, `relay-worker/src/wire.ts 定义了 MuxType.${name}，protocol/src/mux.ts 没有`)
}

// --- Projections the fold doc claims are unfolded ----------------------------

const conversation = read('ios/Rowel/Store/Conversation.swift')
const foldDoc = read('docs/fold.md')

/**
 * Keys named in one of fold.md's two projection sections.
 *
 * §5.2 is a table and §5.3 is a prose line, so `where` says which. Reading
 * every backticked token out of the table would pick up the ones in its
 * description column — `used`, `value.projectedTokens` — and report them as
 * missing cases.
 */
function projectionKeys(heading, where) {
  const start = foldDoc.indexOf(heading)
  if (start < 0) {
    problems.push(`fold.md 里找不到「${heading}」小节`)
    return []
  }
  // Up to the next heading of any level, so adding a §5.4 cannot silently
  // extend §5.3 to the end of the file.
  const rest = foldDoc.slice(start + heading.length)
  const end = rest.search(/\n#{2,4} /)
  const body = end < 0 ? rest : rest.slice(0, end)
  const pattern = where === 'firstColumn'
    ? /^\|\s*`([a-zA-Z][a-zA-Z0-9]*)`\s*\|/gm
    : /`([a-zA-Z][a-zA-Z0-9]*)`/g
  const keys = [...body.matchAll(pattern)].map(match => match[1])
  // A section that suddenly matches nothing means the shape changed and this
  // check went quiet, which is worse than it failing.
  expect(keys.length > 0, `fold.md「${heading}」里没有解析出任何 projection 键`)
  return keys
}

// Both lists come out of the document rather than being copied into this file.
// A hand-kept copy is the bug this check exists to prevent, one level up: when
// §5.3 listed nine keys and this script named three of them, folding one of the
// other six changed nothing here and the doc quietly became wrong.
for (const key of projectionKeys('### 5.2 已折叠的键', 'firstColumn')) {
  expect(conversation.includes(`case "${key}"`),
    `fold.md §5.2 说折叠了 ${key}，但 Conversation.swift 里没有这个 case`)
}
for (const key of projectionKeys('### 5.3 尚未折叠的键', 'prose')) {
  // The inverse direction: once one of these is implemented, a doc still
  // listing it as "not yet folded" sends the next reader off to reimplement
  // something that already exists.
  expect(!conversation.includes(`case "${key}"`),
    `${key} 现在已经折叠了，但 fold.md §5.3 还把它列在"尚未折叠"里`)
}

// --- The installer installs the release the CHANGELOG is about -----------------
//
// These two lines are one decision recorded in two files, and once they came
// apart: the project was renamed ten hours after 0.1.2 was tagged, and the
// installer kept handing out 0.1.2 for the rest of the day. Every install that
// day was a Bridle that called itself Reins and dialled a relay that had been
// retired — and nothing failed loudly, because from the installer's side a
// stale tag looks exactly like a current one.
{
  const ref = /^REF="\$\{ROWEL_REF:-([^}]+)\}"$/mu.exec(read('install.sh'))?.[1]
  // The newest heading that names a version; `## Unreleased` is not one.
  const released = /^## (v?\d+\.\d+\.\d+)/mu.exec(read('CHANGELOG.md'))?.[1]
  expect(ref !== undefined, 'install.sh 里找不到 REF 那一行')
  expect(released !== undefined, 'CHANGELOG.md 里找不到已发布的版本标题')
  if (ref !== undefined && released !== undefined) {
    const tag = released.startsWith('v') ? released : `v${released}`
    expect(ref === tag,
      `install.sh 装的是 ${ref}，但 CHANGELOG 最新发布版本是 ${tag} —— 发版时两处要一起改`)
  }
}

// --- The software says the version it actually is ------------------------------
//
// `bridle status` prints this, and the Relay records it against the machine, so
// it is the number anybody debugging reads first — "is this the build with the
// fix in it". Two releases shipped without it moving, including the rename, so
// every install answered 0.1.2 about code that was two versions past it. Same
// shape as the installer ref above: one decision, several files, and nothing
// noticing when only some of them moved.
{
  const released = /^## (v?\d+\.\d+\.\d+)/mu.exec(read('CHANGELOG.md'))?.[1]
  const want = released?.replace(/^v/u, '')
  for (const name of ['protocol', 'bridle', 'dsh-plugin', 'relay', 'e2e']) {
    const found = JSON.parse(read(`${name}/package.json`)).version
    expect(found === want,
      `${name}/package.json 是 ${found}，但 CHANGELOG 最新发布版本是 ${want} —— 发版时要一起改`)
  }
}

// --- Internal dependencies carry no version at all ------------------------------
//
// Nothing in this repository is published — `install.sh` builds from a tag — so a
// version written on an internal dependency is a number nothing can keep true and
// nothing notices going stale. 0.1.3 and 0.1.4 both shipped with `"0.1.2"` still
// spelled into four manifests; the first thing to read that pin literally was
// `npm ci`, which went to the registry for it, found nothing, and left every
// workflow that installs red for two weeks. The pin is the bug, so the invariant
// is that there is no pin: `*` resolves to the workspace sitting right there.
{
  for (const name of ['bridle', 'dsh-plugin', 'relay', 'e2e']) {
    const deps = JSON.parse(read(`${name}/package.json`)).dependencies ?? {}
    for (const [dep, spec] of Object.entries(deps)) {
      if (!dep.startsWith('@rowel/')) continue
      expect(spec === '*',
        `${name}/package.json 里 ${dep} 写的是 "${spec}"：仓库里的包不发布，内部依赖一律写 "*"，否则发版时它会留在旧版本上（npm ci 会照它去注册表找一个不存在的版本）`)
    }
  }
}

// --- Report ------------------------------------------------------------------

if (problems.length === 0) {
  process.stdout.write('docs: 与源码一致\n')
  process.exit(0)
}
process.stdout.write(`docs: ${String(problems.length)} 处与源码不符\n\n`)
for (const problem of problems) process.stdout.write(`  - ${problem}\n`)
process.stdout.write('\n改代码时同步改文档，或更新 scripts/check-docs.mjs 里的这项检查。\n')
process.exit(1)
