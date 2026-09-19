# Changelog

What changed between releases, from the point of view of someone using it. The
commit log has the rest.

Versions are the tags `install.sh` can install. `ROWEL_REF` in that script names
the one it installs by default, so a release here and a change to that line are
the same decision.

## Unreleased

- **A running conversation's access mode can now be changed from the phone.**
  Session ▸ Access was a badge that said the mode is fixed when a conversation
  starts, and that was wrong — it was measured through the only write the app
  had, `settings.update {ns: permission, patch: {defaultPreset}}`, which sets the
  mode *new* conversations begin in and by design leaves a running one alone. The
  mode of a conversation is changed by the Mac's `/permission` command, which
  writes to that one session's log, so the three presets are now a picker: read
  only, workspace write, and full access, that last one behind a confirmation
  because it drops the sandbox *and* the approval prompts. Only this conversation
  moves — every other one keeps what it was running under — and the checkmark
  follows the Mac's own `permissions` projection rather than a local guess, so it
  cannot claim a mode the agent is not actually running under.

- **Opening a conversation no longer says it is empty first.** The view was
  handed a conversation with no messages and no reason given, because the flag
  that says "still loading" was set one Task later — so every conversation
  opened by flashing "Nothing here yet" before its contents arrived.

- **A conversation started from the phone is now in the Mac's sidebar under its
  folder, not under Ungrouped.** The phone seats conversations by working
  directory — dsh's own rule, and the reason the two screens read the same — but
  the Mac's sidebar reads dsh's workspace ledger, which is written only when a
  conversation is created *into* a workspace and is never backfilled. A
  conversation started in a folder that had no workspace yet was therefore
  missing from the Mac for good. Starting a conversation now claims its folder
  first, so the ledger write has something to name. What it costs is a section
  on the Mac nobody made there by hand — a row in a list, removable, with
  nothing on disk behind it. Conversations already stranded that way stay
  stranded: nothing on the wire backfills them. `WorkspaceWriteTests` pins the
  claim-then-join sequence and both refusals.

## 0.1.4 — 2026-09-01

- **A machine that was plainly running could report itself offline to the
  phone, forever.** The machine id is a hash of the signing key, domain-separated
  by the project's name — so the rename changed it, while the copy cached in
  `bridle.json` stayed on the old value. The Relay never reads that copy (it
  derives the id from the signature), so registering kept working; the pairing
  bundle does read it, so the phone was sent looking for a machine that could
  not exist. The id is derived on load now and the stale copy corrected once.

## 0.1.3 — 2026-09-01

- **Reins is now Rowel, and 0.1.2 cannot reach anything any more.** The project
  was renamed after 0.1.2 was tagged, and the installer went on handing out
  0.1.2 for the rest of the day — so a fresh install printed "scan this in the
  Reins app", built its identity in `~/.reins`, and dialled
  `wss://reins-relay.novabox.ai`, which no longer exists. Nothing about the
  failure said "you installed the wrong version": the QR simply never worked.
  **Upgrade by re-running the installer.** Then note what moved:
  - the home is `~/.rowel`, not `~/.reins`, and the environment variables are
    `ROWEL_*`
  - the relay is `wss://rowel-relay.novabox.ai`; an install that still names
    an old address is moved to it on load, so a config you did not write
    yourself needs no attention
  - the identity does **not** move with the rename, so the machine is new to
    your phone and each device pairs once more. `~/.reins` can be deleted
    after that.
- **Photos in a conversation are drawn instead of standing as grey squares.**
  A history page names its images rather than carrying them, and the app had
  the parser for the reference and the call for the bytes but nothing joining
  them, so every image read back from the log showed the placeholder forever.
  The bytes are now fetched when a thumb is about to draw, once per image, and
  downsampled while decoding — a phone that kept full-size photos to fill
  56-point squares would run out of memory on a conversation with a few.
- **A failure talking to the harness says which call failed and why.** Node
  reports every connection-level failure as the three words "fetch failed" and
  puts the reason one level down; the phone was shown only the three words. It
  now gets the method and the root cause.

## 0.1.2 — 2026-09-01

- **Two Bridles claiming one identity now lose quickly instead of fighting all
  night.** A leftover copy of a `ROWEL_HOME` used to displace the real machine
  in a tight loop — thousands of relay requests in two hours, and a machine
  that never stayed online. A second daemon now refuses to start against a home
  that already has a live one, a tunnel earns its backoff reset by staying up
  rather than by merely connecting, and the relay rate-limits a machine that
  redials too hot.
- **A full disk no longer silently kills the daemon.** The heartbeat tolerates
  a state file it cannot write instead of throwing out of a timer.
- **`bridle instances` lists every identity on this Mac — which dsh each one
  fronts, which is running — and `bridle reset` retires one deliberately.**
- **A Bridle can bind a dsh by its home, not just by a port.** `bridle start
  --dsh-home <dir>` reads the address the home itself declares, so the binding
  follows the world rather than whatever answered first. When the harness moves,
  the daemon says so out loud.
- **`bridle pair` says which dsh the invitation is for.** A `harness:` line
  under the QR code names the URL and, when bound by home, the `DSH_HOME` — so
  a Mac running two of them hands its phone the right one.
- **The phone can tell same-named Macs apart, and you can rename one.** Paired
  machines with identical names grow a fingerprint suffix; the machine's detail
  page shows the fingerprint and harness port, takes a new name that survives
  re-pairing, and moves Forget to the bottom where it stops being the only
  button left to press.
- **When a machine is unreachable, the app says which layer died and what to
  type.** The empty state distinguishes "Bridle isn't connected to the relay"
  from "Bridle is up but dsh isn't", and the rescue card prints commands with
  the right `ROWEL_HOME` already filled in.
- **Rescue commands are spelled in a way that exists.** They said
  `npx @rowel/bridle`, but no such npm package is published — that path ends in
  a 404 at the worst possible moment. Bare `bridle` is what the installer puts
  on the PATH, and the pairing sheet now says the install line is what provides
  it.

## 0.1.1 — 2026-08-20

- **Conversations resume where they left off.** Reopening a session starts at the
  last thing said rather than at the top.
- **A model that declines to answer says so.** The transcript used to show the
  space where a reply would have been.
- **Push notifications work on a phone that is not running.** The membership that
  gates the entitlement is live, so the wake path is enabled rather than
  commented out. The push itself carries no content — the phone opens its own
  tunnel and asks the machine what happened, and posts a local notification with
  the real words.
- **`bridle` says when the running process is older than the code on disk.** An
  update that never restarted used to look like a bug in the new code.
- Repository scaffolding for being public: `SECURITY.md` with the threat model
  and a disclosure process, `CONTRIBUTING.md`, a code of conduct, issue and pull
  request templates, and CI.
- **The app stops promising a check the Mac never offered.** Pairing told you to
  compare six digits against something `bridle pair` has never printed. It points
  at the key fingerprint instead, which both ends do show and which catches the
  same substitution.
- **Four purpose strings were missing from every build.** `INFOPLIST_KEY_*` build
  settings are ignored when a target ships its own `Info.plist`, so scanning a
  pairing code terminated the app rather than asking for the camera, and direct
  connections on the local network failed with no prompt and no error.
- **Continuing a conversation no longer starts with a folder picker.** The button
  opens where the last one was; hold it to choose somewhere else.
- An app icon.

## 0.1.0 — 2026-08-19

The first tag anyone can install from.

`install.sh` had always pointed at this name and it had never existed, so the one
line the app tells people to paste would have failed at the clone the moment this
repository went public. A tag rather than a branch, because `main` moves and an
installer that follows it installs whatever was pushed most recently — onto a
machine that is about to be handed the same authority as its own shell.

**Pairing.** A QR code in the terminal, or an 8-character short code for when the
camera is not an option. One-time tokens. No accounts, no server address to type,
no password.

**One tunnel, everything through it.** A single
`Noise_IK_25519_ChaChaPoly_SHA256` channel carries every interaction with the
harness. The relay switches sealed frames by circuit number and holds no key
material. The protocol is implemented twice, in TypeScript and in Swift, and
pinned to itself by deterministic test vectors.

**Reachability without configuration.** Bridle dials out, so there is nothing to
open on the router. On a shared network the app talks to the Mac directly; the
two paths are raced with the relay given a head start delay, and the local one
wins. Tailscale addresses are found automatically, and `--advertise` covers a
tunnel hostname the machine cannot discover for itself.

**Reading and driving.** The event log folds into a transcript on the phone —
diffs, terminal output, file reads, to-do lists, and reasoning as it arrives.
Sessions grouped by workspace with anything waiting on you above everything else.
Approvals and questions, including the ones raised while nobody was attached.
Model and reasoning-effort pickers, slash commands, subagents, a trace view, and
what the session cost.

**Resume without gaps.** Reconnecting replays what was missed from a ring buffer.
When the buffer cannot cover the gap the machine says so and the phone refetches,
rather than silently rendering a transcript that is missing a piece.

**Waking a phone that is not running,** without telling anyone what it is about.

**The app locks itself,** because a paired phone that is unlocked in someone
else's hands is a shell with no further challenge. Face ID, Touch ID, or a
passcode, on launch and after an idle timeout, and the screen is covered the
moment the app stops being frontmost.

**Two relays, one wire format.** A Node process and a Cloudflare Worker on
Durable Objects. The public relay runs the Worker; the same acceptance suite runs
against both.

**Identity backup.** `bridle backup` and `bridle restore`, encrypted under a
passphrase, because a machine that loses its static key is indistinguishable from
an impostor to every phone paired with it.
