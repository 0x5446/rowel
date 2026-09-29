/**
 * When things happen in a cut.
 *
 * Each cut has a timeline written by its render script (`render.mjs` for the
 * launch video, `review.mjs` for the App Review walkthrough) into `public/`:
 * the beats the recording wrote down, moved onto the trimmed footage. It is
 * read when the composition's metadata is calculated rather than imported,
 * so one cut can be rendered without the other's files existing.
 */

import { staticFile } from 'remotion'

/**
 * Convert a beat into a frame of the edit.
 * @param {Record<string, number>} timeline - the cut's beats, in seconds.
 * @param {string} name - which beat.
 * @param {number} fps - frames per second of the composition.
 * @param {number} [offset] - seconds to shift by.
 * @returns {number} the frame.
 */
export function at(timeline, name, fps, offset = 0) {
  return Math.round(((timeline[name] ?? 0) + offset) * fps)
}

/** Whether a beat is in this cut at all. */
export function has(timeline, name) {
  return typeof timeline[name] === 'number'
}

/**
 * Metadata for a composition cut against `file`: its length, and the
 * timeline handed to the component as a prop.
 * @param {string} file - the timeline JSON under `public/`.
 * @param {number} fps - frames per second.
 */
export function fromTimeline(file, fps) {
  return async ({ props }) => {
    const timeline = await (await fetch(staticFile(file))).json()
    return { durationInFrames: Math.round(timeline.duration * fps), props: { ...props, timeline } }
  }
}
