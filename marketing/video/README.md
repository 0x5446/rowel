# The launch video

One thing happens in it: an agent is stopped, waiting on a person, and the
person says yes from a phone. That is the product, and it is the only part
that a screenshot cannot carry — a still shows the card, but not that the Mac
was blocked before the tap and working after it.

## Why it is recorded rather than generated

The 2026 house style for this category is real product UI, and the reason is
not taste: a generated approximation of a screen cannot be evidence, and
evidence is the entire job here. What generative video is good for — a
cinematic establishing shot — is the part this video does not need.

What is worth borrowing from that world is the *assembly*: the edit is code
(Remotion), so when the interface moves the video is re-rendered rather than
re-shot. That is the same bargain `ios/screenshots.sh` already makes for the
stills, and the reason neither is kept as a hand-made artifact.

## Producing it

```sh
ios/screenshots.sh --seed          # a harness with a sample repository, once
ios/demo.sh                        # arm a real approval, record the tap
cd marketing/video && npm install  # once
node render.mjs                    # trim, then render all three shapes
```

Out come `out/rowel-{vertical,square,wide}.mp4` — 9:16, 1:1 and 16:9 of the
same cut. Three rather than one because a launch video that exists only in
16:9 gives up the feed everywhere that is not YouTube.

The captions are placed against `raw/beats.json`, which the recording writes:
`Demo.swift` marks when it saw the card and when it answered, `demo.sh` knows
when the camera started, `beats.py` subtracts. Re-record and the words move
with the footage instead of describing a frame that has shifted. Each caption
runs until the next one starts, so there is no per-line duration to keep in
step — the first attempt had those, and put two captions on screen at once.

In the landscape cut the phone is deliberately taller than the frame. Fitted
whole into 1080 lines it is about 430 pixels wide, and the command the video is
asking you to read is then unreadable; overscaled and anchored low, what is on
screen is the card and the answer.

`demo.sh` provokes a genuine permission request — the session runs under a
`read-only` sandbox, so the agent's first write is refused and escalating
needs consent — then drives the tap and records:

The phone is the simulator, recorded with `xcrun simctl io recordVideo` — no
camera and no physical device, so a take is repeatable.

## The App Review walkthrough

A second cut from the same machinery, for App Review rather than a feed: the
app from its first launch — the first-run screen, the setup it asks for on the
Mac, pairing, notifications — through reading a conversation and answering a
permission request.

```sh
ios/demo.sh --review               # raw/review.mov, driven by ReviewTour.swift
node review.mjs                    # out/rowel-review.mp4
```

The simulator has no camera, so it pairs through the `rowel://pair` link
Bridle prints, opened by `demo.sh` when the test drops a marker. It is a real
first launch: the app is uninstalled and the simulator rebooted before the
take, because an alert left from the last one otherwise sits over the first
screen of the next.

## The Mac half: safe now, still not useful

`ios/demo.sh --mac` records the harness's window too, through
`ios/Tools/RecordWindow.swift`.

It is a *window* capture rather than a screen capture, and that distinction is
the reason the tool exists. The first attempt cropped a rectangle of the
display, and a rectangle holds whatever is in front of it: two takes came back
containing windows belonging to the person running the script — the second a
private conversation — and the only reason neither reached a video is that both
were looked at first. Targeting by title does not fix a region capture, because
AppleScript will tell you a window exists and where it was moved to, not that
it is the thing visible at those coordinates. ScreenCaptureKit captures the
window's own contents, so nothing drawn over it can get in.

Three things it learned, all of them now guards rather than comments. A browser
permission bubble carries the page's address in its title, so matching a URL
found the dialog and recorded 170×94 of it — there is a minimum size now.
Several windows matching is refused rather than resolved by picking one, and
`demo.sh` closes stale harness windows first so the second run of the day does
not trip over the first. And a window recording is finalised when its writer
closes the file, so the process is waited on; killed instead, what is left is a
megabyte with no index, which reads as a corrupt file rather than an
interrupted one.

**It is off by default because the footage is not worth much yet.** The
harness's web UI has no per-session URL, so the window cannot be pointed at the
conversation being approved without driving the browser, and a Mac half showing
the new-session screen adds nothing the phone does not already say. The tool is
here for when that is solved.

Two smaller things that cost a take each, in case they come up again. The Xcode
project is generated and not committed, so a driver added since the last
`xcodegen` is not in the scheme, and `-only-testing` against a test that does
not exist still leaves a recording on disk — of a home screen. And while
`simctl` is recording it holds the capture system, so anything asking "can I
record the screen?" after that point is told no on a machine where the answer
is yes.

## Raw footage

`raw/` is not committed. It is large, it is regenerable, and it is a recording
of a real machine — the same reason `marketing/shots` is generated from a
throwaway harness rather than from anybody's own.
