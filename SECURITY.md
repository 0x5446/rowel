# Security

Rowel hands a phone the same authority over a Mac that its own terminal has.
That is the product, and it is why this file is longer than the template.

## Reporting a vulnerability

**Do not open a public issue.**

1. **GitHub private advisory** — [report it here](https://github.com/0x5446/rowel/security/advisories/new).
   Preferred, because the discussion, the fix, and the CVE all stay in one place.
2. **Email** — `hi@novabox.ai`, subject starting with `SECURITY`. Use this if you
   would rather not have a GitHub account attached to the report. There is no
   PGP key; if you need one, say so in a first message with no details in it.

Useful in a report: what an attacker has to start with (a paired device? the
relay? a machine on the same Wi-Fi? a recorded transcript of traffic?), what they
get, and whether you have a proof of concept. `e2e/tests/security.test.js` is the
existing set of attacker-shaped tests and is a reasonable place to express one.

### What happens next

One person maintains this. The commitments are sized to that rather than to what
looks good in a policy:

| | |
|---|---|
| Acknowledgement | within 3 working days |
| First assessment — is it real, how bad, what is affected | within 10 working days |
| Fix or a dated plan | within 90 days of the assessment |
| Credit | yes, under whatever name you give, unless you ask otherwise |

If a report is going to slip one of these, you will be told that it is slipping,
rather than left waiting. You are free to disclose on your own schedule; being
told the date in advance is appreciated and is not a condition of anything.

There is no bounty. There is no budget for one.

### Supported versions

The tip of `main` and the most recent tag. There are no maintenance branches, and
`install.sh` pins `ROWEL_REF` to a release tag, so a fix ships as a new tag.

## Scope

**In scope:** the Noise implementation on either side, the tunnel framing, the
pairing protocol, the relay (both the Node and Cloudflare implementations), the
Bridle's handling of the harness, key storage on either end, `install.sh`, and
anything that lets an unpaired party reach a harness or read tunnel contents.

**Out of scope**, because they are stated properties of the design rather than
defects. Each one is expanded below.

- A paired device can do anything the harness can do. That is not a privilege
  escalation, it is the feature.
- Anyone who can run code on the Mac already has the harness. Local privilege
  escalation against the Bridle is not a boundary crossing.
- The relay learns metadata. Which metadata, and why it cannot not, is listed
  below.
- An unlocked phone in someone else's hands is a working session.
- The DeepSeek Harness itself. Report those to
  [its own project](https://github.com/deepseek-ai/deepseek-harness); the Bridle
  neither adds nor removes anything from its behaviour.

## Threat model

### What the design actually protects

**A tunnel the relay cannot open.** The app and the Bridle complete a
`Noise_IK_25519_ChaChaPoly_SHA256` handshake with each other. The relay switches
sealed frames between two sockets by circuit number and holds no key material.
This is checked, not asserted: the e2e test `the relay only ever sees ciphertext`
taps the socket and fails if a canary string, a method name, the machine name, or
a session id appears on the wire.

Both ends use only their platform's own primitives — Node's `node:crypto`, Swift's
`CryptoKit`, WebCrypto in the Worker. There is no third-party cryptography
dependency anywhere in the tree, on either side.

**Mutual authentication, pinned on first use.** The pairing code carries the
machine's static X25519 public key, so the app encrypts the first handshake
message *to that key* before it has spoken to anything. A wrong key cannot be
opened at all. The app keeps the key and reuses it on every reconnect: a machine
whose key changed is indistinguishable from an impostor and is refused.

**Forward secrecy for the session, precisely stated.** Fresh ephemerals on both
sides every connection; the transport keys absorb `ee` and `se`, so recorded
traffic stays sealed if either static key is later compromised. **Handshake
message one is the exception** — IK seals it under `es` and `ss`, both of which
derive from the responder's *static* key. Someone who records a pairing handshake
and later obtains `~/.rowel/bridle.json` can decrypt that one message and recover
the app's static public key, the device name, and the one-time pairing token.
This is inherent to IK rather than a bug, and it is the reason the pairing token
is single-use.

**Replay, reordering, and tampering are fatal rather than survivable.** Nonces are
a per-direction counter that never resets. A frame that fails authentication
throws with no detail about which byte was wrong, and the tunnel is torn down
rather than resynchronised. A stream that can silently recover from a bad frame
is a stream an attacker can steer.

**Pairing tokens are single-use.** Photographing the QR code over someone's
shoulder buys one connection attempt, and only if you win the race. Once the
owner's phone has used it, the token is gone and the thief is an unpaired
stranger. Test: `a stolen pairing token works exactly once`.

**The local-network listener is not a web server.** The Bridle's LAN listener
answers `426` to anything that is not a WebSocket upgrade on exactly one path. It
never exposes a byte of the harness API to the network, even to a host on the
same Wi-Fi. Test: `the direct listener is not a web server`. This matters more
than it sounds: the harness has no authentication of its own, so a plain
`socat` from `0.0.0.0` to its loopback port would hand unauthenticated remote
code execution to the whole subnet.

**Push carries no content.** The message the relay is able to send to Apple is a
constant in `relay-worker/src/apns.ts`, plus the machine's display name. The
structure the Bridle uses to ask for a wake has two fields, `token` and
`machine` — there is no field an over-helpful Bridle could put the agent's
question into, so nothing rests on the relay choosing not to read one. The push
does not run the app; the real words appear when you open it and it reconnects
over its own Noise channel.

### What it does not protect, and cannot

**A paired device has the harness's full authority.** The harness ships with no
authentication of its own; its fence is a loopback bind plus a Host header, and
the Bridle is on the far side of that fence. So a paired phone can run commands,
read and write files, and approve the agent's own requests to do the same.

Note the shape of this carefully: **the tunnel is generic, and the app's
restraint is not the protocol's.** `docs/architecture.md` §17 says the app
deliberately does not expose `settings.*` or `credentials.*` — writing an API key
from a phone would widen what a paired device is. That is a decision in the app.
`TunnelSession.handleRequest` passes the method name straight through, so
*anything speaking the protocol* can call all of the harness's methods, including
the loopback-privileged ones. Treat a pairing as equivalent to shell access, not
as the subset of it the app draws buttons for.

`bridle revoke` is the only way to take that back. It is also, today, not
immediate: it removes the peer and refuses the next handshake, but it does not
tear down a tunnel that is already open. The CLI says so and tells you to restart
`bridle` to drop a live one.

**A compromised Mac is a total loss.** The Bridle's static private key is in
`~/.rowel/bridle.json` at `0600`. It is not in the Keychain and not in the Secure
Enclave. Anything that can read that file can impersonate the machine to every
phone paired with it, and anything that can run as your user already has the
harness anyway.

**An unlocked, paired phone is a shell with no further challenge.** The app locks
itself with Face ID, Touch ID, or a passcode on launch and after an idle timeout,
and covers its own screen when it stops being frontmost. Read what that is for:
it bounds the window, it does not close it. Approvals are deliberately not behind
a second authentication — a lock people have to defeat forty times a day is a
lock people turn off. The lock does not protect data at rest, and it does not
hold on a jailbroken device. If you lose the phone, the thing that revokes it is
`bridle revoke` on the Mac, and there is no way to do that from another phone.

**Unpairing in the app is one-sided, on purpose.** The phone forgets the machine;
the machine still lists the phone. A phone asking to be forgotten is exactly the
phone whose word should not be taken for it.

**The relay learns metadata.** It cannot read your traffic and it stores nothing
between sessions, but it necessarily observes: the machine's device id, its
display name in clear text (it defaults to your computer's name — edit
`machineName` in `~/.rowel/bridle.json`), the Bridle version, that some phone has
a circuit open to some machine and when it opened, message sizes and timing, and
your IP address. If you push, it also learns the association between an Apple
device token and a machine, and it holds an APNs signing key — a relay that can
wake your phone is no longer only a dumb pipe, and that is an unavoidable
consequence of push rather than a design choice that could have gone the other
way.

An **active** relay is also a denial of service in several ways it cannot be
prevented from being. It can drop, delay, duplicate, or reorder frames;
duplicates and reordering tear the tunnel down by design, so a hostile relay can
keep a tunnel permanently broken. It can also truncate — close a socket after
withholding the last few frames — and the gap is only detected on the next
`resume`. Run your own relay if that matters to you; `bridle --relay <url>` is
all it takes, and the Node implementation in `relay/` is a single process with no
database.

**Same-network hosts can see that the Bridle is there.** The LAN listener binds
`0.0.0.0`, so it is reachable from every attached network — including Docker
bridges, VPN legs, and a tailnet. Its `426` body names it, which makes it
identifiable to any scanner and therefore points at a machine running an
unauthenticated harness. Nothing on that path is authenticated below Noise: the
transport is plain `ws://`, and the listener has no connection cap or rate limit
of its own, so a host on your network can make it allocate handshake state
indefinitely.

**The installer is `curl | sh` with no signature.** It clones a pinned tag over
HTTPS and builds from source. There is no checksum and no signed commit. If you
do not want that, read `install.sh` first — it is 150 lines, mostly comments —
and run the steps yourself.

**No one has audited this.** No external review, no formal analysis, no
penetration test. The Noise state machine is a from-scratch implementation, twice
over — once in TypeScript and once in Swift — rather than a binding to an audited
library. The two are pinned to each other byte for byte by deterministic test
vectors, which catches a divergence between them and would catch neither of them
misreading the specification the same way.

## Known weaknesses

Things that are wrong, or weaker than they look, that are worth knowing before
you spend time on them.

**The short-code path depends on you comparing a fingerprint — and now cannot
skip it.** Pairing by QR code needs nothing from the relay: the code carries
the machine's public key and a token that leaves the Mac only inside that code,
so a hostile relay can neither stand in for the machine nor pair itself.

The short-code path is different. The relay holds the bundle a typed code
fetches, so it could read the token in it, swap in a key of its own, or present
the token itself. Until September 2026 that token was the *same* one the QR
carried, and presenting it paired the presenter outright — so a hostile relay
could pair itself with any machine whose owner had run `bridle pair`, whichever
path the owner then used. The two are now separate tokens, and the short-code
token only earns a *request*: the Bridle records the requesting phone, refuses
it, and `bridle pair --code` shows that phone's key fingerprint and asks
`Accept? [y/N]`. The app shows its own fingerprint while it waits. Accept only
if the two match. One comparison covers both attacks: a relay pairing itself
shows its own key, and a relay sitting in the middle presents its own key to
the Mac as well.

The comparison is still a person's job — nothing can do it for you — but the
flow no longer finishes without one. `bridle start` and plain `bridle pair`
only show the QR; the short code exists only behind `--code`.

The six-digit confirmation number derived from the handshake hash
(`confirmationNumber` in `protocol/src/pairing.ts`) remains unimplemented on
the Mac and is not part of either flow.

**The short code is 8 characters from a 28-character alphabet** — about 38.5 bits
— with a small modulo bias toward the first four letters. It is single-use and
short-lived, and the relay rate-limits claims, so this is a bound worth knowing
rather than a way in.

**`GET /v1/machine/:deviceId` is unauthenticated and unmetered** on both relay
implementations. Anyone who has ever seen a pairing bundle can poll a machine's
online status and display name indefinitely.

**Every paired phone is rung for every waiting request.** The Bridle wakes all
distinct device tokens it knows, not just the one that will act. If you have
paired an old phone and forgotten it, it still buzzes — and its token is still
associated with your machine at the relay.

**`scripts/lan-webui.mjs` deliberately defeats the loopback fence.** It is a
development script, it says what it is doing in its own header, and it must never
be run on a machine reachable by anyone you do not trust.

## Where the details are

The design documents are in Chinese; this file is the English summary of the
parts a security reader needs. If you are reading source instead:

| | |
|---|---|
| The Noise implementation | `protocol/src/noise.ts`, `ios/Rowel/Protocol/Noise.swift` |
| Pairing, short codes, the confirmation number | `protocol/src/pairing.ts` |
| Handshake acceptance order and the tunnel | `bridle/src/tunnel/session.ts` |
| The relay's content-blindness | `protocol/src/mux.ts`, `relay-worker/src/switchboard.ts` |
| What the relay may and may not do with a wake | `relay-worker/src/apns.ts` |
| Key storage | `bridle/src/identity.ts`, `ios/Rowel/Net/Keychain.swift` |
| The properties as executable tests | `e2e/tests/security.test.js`, `e2e/tests/direct.test.js` |
| Byte-level wire specification | `docs/protocol.md` (Chinese) |
| Design rationale for all of the above | `docs/architecture.md` §5, §7, §14 (Chinese) |
| The invariant list, each with its guarding test | `docs/architecture.md` §16 (Chinese) |

`docs/README.md` records which sections are specification-grade — implemented,
tested, safe to reimplement from — and which are design-grade. Do not read a
design-grade section as a description of running code.
