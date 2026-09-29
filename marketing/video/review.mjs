#!/usr/bin/env node
/**
 * Cut and render the App Review walkthrough.
 *
 *   ios/demo.sh --review      # records raw/review.mov and raw/review-beats.json
 *   node review.mjs           # out/rowel-review.mp4
 *
 * One segment: from just before the first-run screen to the end. What comes
 * before it is a test runner installing an app, which is real and nothing a
 * reviewer needs to watch. As in `render.mjs`, the recording is normalised to
 * a constant 30 fps first — the simulator records at a variable rate, and
 * cutting that by time does not give the seconds asked for.
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const beats = JSON.parse(readFileSync(join(here, 'raw/review-beats.json'), 'utf8'))
const run = (file, args) => execFileSync(file, args, { stdio: 'inherit', cwd: here })

/** Seconds of footage kept before the first-run screen appears. */
const LEAD_IN = 1.0

for (const name of ['welcome', 'ended']) {
  if (typeof beats[name] !== 'number') throw new Error(`raw/review-beats.json has no "${name}" beat — re-record`)
}

mkdirSync(join(here, 'public'), { recursive: true })
const source = join(here, 'public/review-source.mp4')
run('ffmpeg', [
  '-y', '-loglevel', 'error', '-i', join(here, 'raw/review.mov'),
  '-vf', 'fps=30', '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-an', source,
])

const from = Math.max(0, beats.welcome - LEAD_IN)
const length = beats.ended - from
run('ffmpeg', [
  '-y', '-loglevel', 'error', '-ss', String(from), '-i', source, '-t', String(length),
  '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-an', join(here, 'public/review.mp4'),
])
rmSync(source, { force: true })

const timeline = { duration: length }
for (const [name, at] of Object.entries(beats)) {
  if (at >= from) timeline[name] = at - from
}
writeFileSync(join(here, 'public/review-beats.json'), `${JSON.stringify(timeline, null, 2)}\n`)

mkdirSync(join(here, 'out'), { recursive: true })
run('npx', ['remotion', 'render', 'Review', 'out/rowel-review.mp4'])
