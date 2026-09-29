/**
 * The launch video: an agent stopped on a permission request, and a person
 * unblocking it from a phone. One shot, three shapes (see Root.jsx).
 */

import React from 'react'
import { Cut } from './Cut.jsx'

const LINES = [
  { beat: 'notified', offset: 0.7, text: 'It found you.' },
  { beat: 'opened', offset: 0.2, text: 'Your agent stopped to ask.' },
  { beat: 'asked', offset: 1.2, text: 'The whole command. Not a summary.' },
  { beat: 'allowed', offset: 0.1, text: 'One tap, from wherever you are.' },
  { beat: 'allowed', offset: 3.4, text: 'The Mac carries on.' },
]

export function Launch({ timeline, wide = false }) {
  return <Cut timeline={timeline} lines={LINES} video="phone.mp4" wide={wide} />
}
