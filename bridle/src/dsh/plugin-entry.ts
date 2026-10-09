/**
 * Putting the Bridle plugin into a dsh profile, and taking it out again.
 *
 * The plugin is not on npm; it ships in the checkout `install.sh` makes, and
 * dsh loads a plugin by absolute path from the profile's own patch layer
 * (`$DSH_HOME/profiles/web/cordis.patch.yml`). Verified on 0.2.0-rc.2 and
 * 0.2.1-alpha.1. Being inside dsh is what lets the Bridle sign in: dsh hands a
 * plugin its port and launch token, and hands them to nothing else.
 *
 * The file is the person's, so the edit is narrow: one entry in one exact
 * shape, added to the two shapes a fresh or hand-kept file has — the `[]` dsh
 * writes, or a block list — and removed only in the shape it was added. Any
 * other shape is left alone, with the lines to add by hand.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/** The entry id; also what dsh lists the plugin as. */
export const PLUGIN_ID = 'rowel-bridle'

/** What happened to the patch file. */
export type PluginEdit =
  | { result: 'added' | 'updated' | 'removed' | 'unchanged'; file: string }
  /** The file is in a shape this will not edit; `lines` is what to do by hand. */
  | { result: 'manual'; file: string; lines: string }

/**
 * The dsh home a command means: the one named, else `DSH_HOME`, else `~/.dsh`.
 * @param named - a `--dsh-home` the person gave.
 * @returns the directory.
 */
export function dshHome(named?: string): string {
  if (named !== undefined && named.length > 0) return named
  const fromEnvironment = process.env['DSH_HOME']
  return fromEnvironment !== undefined && fromEnvironment.length > 0 ? fromEnvironment : join(homedir(), '.dsh')
}

/**
 * The patch file of a home's web profile.
 * @param home - the dsh home.
 * @returns its path.
 */
export function patchFile(home: string): string {
  return join(home, 'profiles', 'web', 'cordis.patch.yml')
}

/**
 * The entry, exactly as written and as matched for removal.
 * @param modulePath - absolute path of the plugin's entry file.
 * @returns the YAML lines, newline-terminated.
 */
function entry(modulePath: string): string {
  return `- insert:\n    - id: ${PLUGIN_ID}\n      name: ${JSON.stringify(modulePath)}\n`
}

/** Our entry in its written shape, whatever path it points at. */
const OURS = new RegExp(`^- insert:\\n {4}- id: ${PLUGIN_ID}\\n {6}name: .*\\n?`, 'mu')

/**
 * Add the plugin to a home's web profile, or point an existing entry at a new
 * path.
 * @param home - the dsh home.
 * @param modulePath - absolute path of the plugin's entry file.
 * @returns what was done.
 * @throws {@link Error} when the profile has no patch file (dsh never ran with it).
 */
export function installPlugin(home: string, modulePath: string): PluginEdit {
  const file = patchFile(home)
  const text = readFileSync(file, 'utf8')
  const wanted = entry(modulePath)
  const existing = OURS.exec(text)
  if (existing !== null) {
    if (existing[0].trimEnd() === wanted.trimEnd()) return { result: 'unchanged', file }
    writeFileSync(file, text.replace(OURS, wanted))
    return { result: 'updated', file }
  }
  if (text.includes(`id: ${PLUGIN_ID}`)) {
    return { result: 'manual', file, lines: `an entry for ${PLUGIN_ID} is already there in another form; point its name at ${modulePath}` }
  }
  const body = withoutComments(text)
  if (body === '[]') {
    // dsh's own starting content: an empty flow list. Replaced, not appended
    // to — a block entry after `[]` is not YAML.
    writeFileSync(file, text.replace(/^\[\]\s*$/mu, wanted.trimEnd()))
    return { result: 'added', file }
  }
  if (body === '' || body.startsWith('- ')) {
    writeFileSync(file, `${text}${text === '' || text.endsWith('\n') ? '' : '\n'}${wanted}`)
    return { result: 'added', file }
  }
  return { result: 'manual', file, lines: wanted }
}

/**
 * Take the plugin out of a home's web profile.
 * @param home - the dsh home.
 * @returns what was done.
 */
export function uninstallPlugin(home: string): PluginEdit {
  const file = patchFile(home)
  let text: string
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return { result: 'unchanged', file }
  }
  if (OURS.test(text)) {
    let next = text.replace(OURS, '')
    // Back to what dsh wrote if nothing else is left, so the file stays YAML.
    if (withoutComments(next) === '') next = `${next}${next === '' || next.endsWith('\n') ? '' : '\n'}[]\n`
    writeFileSync(file, next)
    return { result: 'removed', file }
  }
  if (text.includes(`id: ${PLUGIN_ID}`)) {
    return { result: 'manual', file, lines: `remove the entry for ${PLUGIN_ID} by hand; it is not in the form bridle writes` }
  }
  return { result: 'unchanged', file }
}

/** The file with comment lines and surrounding blank space removed. */
function withoutComments(text: string): string {
  return text.split('\n').filter(line => !line.trimStart().startsWith('#')).join('\n').trim()
}
