/**
 * The version this Bridle is, read from its own package.json.
 *
 * One place, because a version spelled out in code is a number nothing keeps
 * true: the dsh plugin said 0.1.2 through two releases past it, and `bridle
 * status` and the Relay both repeat whatever this says. `check:docs` holds
 * every package.json to the released CHANGELOG version, so the plugin and the
 * CLI can share this one.
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

function readVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url))
    const manifest = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8')) as { version?: string }
    return manifest.version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

/** This build's version, e.g. `0.1.5`. */
export const VERSION: string = readVersion()
