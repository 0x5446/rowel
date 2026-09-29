/**
 * The App Review walkthrough: the real app from first launch through its
 * typical use, recorded in the iOS Simulator against a real Mac companion
 * (`ios/demo.sh --review`, driven by `ReviewTour.swift`).
 *
 * The captions name each step for a reviewer who has never seen the product;
 * the endplate is left off, because this is evidence, not an advertisement.
 */

import React from 'react'
import { Cut } from './Cut.jsx'

const LINES = [
  { beat: 'welcome', offset: 0.3, text: 'First launch. Rowel works with a coding agent on your own Mac.' },
  { beat: 'setup', offset: 0.3, text: 'On the Mac: one install command, then “bridle pair” prints a pairing code.' },
  { beat: 'permission', offset: 0.1, text: 'Allow notifications: it is how an agent waiting on you reaches the phone.' },
  { beat: 'paired', offset: 0.1, text: 'Paired. The Mac’s conversations arrive over an end-to-end encrypted tunnel.' },
  { beat: 'reading', offset: 0.3, text: 'Read what the agent did: its plan, its replies, the tools it ran.' },
  { beat: 'asked', offset: 0.3, text: 'The agent stopped to ask permission. The full command is shown.' },
  { beat: 'allowed', offset: 0.1, text: 'One tap on the phone, and the agent on the Mac carries on.' },
]

export function Review({ timeline }) {
  return <Cut timeline={timeline} lines={LINES} video="review.mp4" endplate={false} />
}
