# Reply to the 2.1 information request — 2026-09-06

Apple rejected 1.0 with the standard "Guideline 2.1 — Information Needed —
New App Submission" letter: a developer account with limited review history
is asked six questions before review proceeds. It is not a finding against
the app; the "Prevent Common Issues" section of the letter is boilerplate.
Build 123 stayed VALID, so this is answered with words and one video — no
rebuild.

The same answers were written into the App Review Information Notes field
(3.5k of the 4k limit), as the letter instructs. The reply below goes into
Resolution Center once the demo video is hosted at the URL it names.

---

Hello, and thank you for the review.

All six items follow. They have also been added to the App Review Information
Notes field for future submissions, as requested.

1. Screen recording (physical iPhone 17, iOS 26, captured from app launch
through the typical flow): https://rowel.novabox.ai/review/demo-1.0.mp4
The app has no account registration or login, no user-generated content
visible to other users, and no paid content, so those flows do not exist to
record. What the recording shows: launching the app, the conversation list
arriving from the paired Mac, opening a conversation, sending a request, the
agent stopping on a permission card, tapping Allow, and the work resuming.

2. Purpose and target audience: Rowel is for developers who run the DeepSeek
Harness ("dsh") coding agent on their own Mac. The problem it solves: the
agent stops mid-task to ask permission while the developer is away from the
desk, and the work sits blocked. Rowel delivers that request to the phone
with the full command, and one tap resumes the Mac. It is a companion client
in the same shape as an SSH client or the Home Assistant app.

3. Setup and access: the user installs a small companion program ("Bridle")
on their own Mac with one command — shown on the app's first-run screen and
at https://rowel.novabox.ai/get — then runs `bridle pair` and scans the QR
code it prints. There are no login credentials anywhere in the product.
Pairing tokens are single-use and expire in about ten minutes by design, so
we cannot place one in these notes; if you would like to exercise the app
live against a real Mac, reply with a time window and we will mint a fresh
pairing code at that moment and post it here.

4. External services: (a) a relay we operate on Cloudflare Workers
(rowel-relay.novabox.ai), which forwards end-to-end encrypted frames between
the phone and the user's Mac — it holds no key material and cannot read
content, and the open-source repository contains a test asserting the relay
observes only ciphertext; (b) the Apple Push Notification service, carrying a
content-free wake alert. There are no authentication providers, no payment
processors, no analytics, and no third-party SDKs in the binary. The app
never contacts any AI service: the coding agent runs on the user's own Mac
and talks to whatever model provider the user configured there.

5. Regional differences: none. The app functions identically in all regions.

6. Regulated industries / protected third-party material: none. It is a
developer tool; everything it displays is the user's own code and
conversations. The entire product, including the relay, is open source (MIT):
https://github.com/0x5446/rowel

Thank you again — happy to provide anything further.
