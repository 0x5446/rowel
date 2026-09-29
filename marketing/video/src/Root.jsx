/**
 * The compositions: the launch video in three shapes, and the App Review
 * walkthrough.
 *
 * A launch video that exists only in 16:9 gives up the feed on every platform
 * that is not YouTube, which for this audience is most of them. Same footage,
 * same beats, same words — the only thing that differs is whether the words sit
 * beside the phone or under it. The review walkthrough is portrait only: it is
 * watched once, by one person, at the size of a phone.
 *
 * Lengths come from each cut's timeline at render time (`fromTimeline`), so
 * rendering one cut does not need the other's footage to exist.
 */

import React from 'react'
import { Composition } from 'remotion'
import { Launch } from './Launch.jsx'
import { Review } from './Review.jsx'
import { fromTimeline } from './timeline.js'

const FPS = 30
const launch = fromTimeline('beats.json', FPS)

export function RemotionRoot() {
  return (
    <>
      <Composition id="Vertical" component={Launch} fps={FPS} width={1080} height={1920}
        durationInFrames={1} defaultProps={{ wide: false, timeline: {} }} calculateMetadata={launch} />
      <Composition id="Square" component={Launch} fps={FPS} width={1080} height={1080}
        durationInFrames={1} defaultProps={{ wide: false, timeline: {} }} calculateMetadata={launch} />
      <Composition id="Wide" component={Launch} fps={FPS} width={1920} height={1080}
        durationInFrames={1} defaultProps={{ wide: true, timeline: {} }} calculateMetadata={launch} />
      <Composition id="Review" component={Review} fps={FPS} width={1080} height={1920}
        durationInFrames={1} defaultProps={{ timeline: {} }} calculateMetadata={fromTimeline('review-beats.json', FPS)} />
    </>
  )
}
