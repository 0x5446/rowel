# App Store Metadata — Rowel v1.0

Everything on this page is calibrated against the repo (README, CHANGELOG,
`site/public/*.html`, `ios/` source) and against the policy research in
`APPSTORE.md`. Character counts are verified; limits per Apple's field
reference (Name 30, Subtitle 30, Promotional Text 170, Description 4000,
Keywords 100).

**2026-09-30:** the Description's Approvals and Notifications paragraphs were
corrected here (the push does not wake the app; an approval carries the tool
call and a reason, the command or diff is in the card it belongs to). App Store
Connect still holds the old text for 1.0, which was in review — put this in
with the next version.

---

## App Name (limit 30)

**Registered:** `Rowel: DeepSeek Harness Remote` (30/30) — App ID 6807263060,
SKU `rowel-ios`, bundle `ai.novabox.rowel`, created 2026-09-01.

The product was called Reins until the day this record was made. An app named
`Reins: for Ollama & LM Studio` has been live in Developer Tools since January
2025, is still shipping, has 272 ratings, and opens its description with "Take
the Reins of your AI" — the same name, the same category, an adjacent product,
and the same metaphor, twenty months ahead of us. App Store name uniqueness is
exact-string, so a differentiated `Reins: …` would have been accepted; what
would not have survived is discovery. Every search for our own name would have
returned theirs first, permanently, and every mention of "Reins" in a review or
a thread would have split between two apps in one category. Renaming cost a day
at zero users. See the commit `rename: Reins becomes Rowel`.

A rowel is the wheel on a spur. It also fits the architecture better than reins
did: the bridle is on the animal, the rowel is on the rider, and the relay
belongs to neither — which is exactly why it can read nothing.

The name leads with the positioning rather than the brand, because the brand is
new and "DeepSeek Harness remote" is what the first users are actually looking
for. It carries a known risk: guideline 2.3.7 / 5.2.1 discourage third-party
product names in app names. The precedent above — a shipping app named for two
third-party runtimes in this same category — is the reason to try it. If App
Review objects, the name is editable before release; fall back in this order:

| Fallback | Chars | Notes |
|---|---|---|
| `Rowel — Coding Agent Remote` | 27 | No third-party mark. Keeps three indexed search words. |
| `Rowel: Mobile dsh Client` | 24 | Keeps dsh, drops the DeepSeek mark. |
| `Rowel` | 5 | Brand only; positioning moves entirely to the subtitle. |

Availability at registration: no live US app is named `Rowel`, and
`rowel.app` / `rowel.dev` were both unregistered.

## Subtitle (limit 30)

**With Name = `Rowel`:**

```
Drive your Mac's coding agent
```
(29 characters)

**If the fallback name is used** (it already contains remote/coding/agent —
don't repeat indexed words across name and subtitle):

```
End-to-end encrypted control
```
(28 characters)

## Promotional Text (limit 170 — editable any time without a new build; not indexed for search)

```
The agent keeps working while you're away. Approve a command from your phone with the full diff in front of you, and start the next thing from the train.
```
(153 characters)

## Description (limit 4000 — not indexed by App Store search; keep it honest, it feeds web search and App Store Tags)

```
Rowel is the iPhone side of the coding agent already running on your Mac.

The agent runs where your code and your API keys already are. Rowel gives you
the part that does not need to be at the desk: reading what it did, approving
what it wants to do next, and starting the next thing from wherever you are.

WHAT YOU CAN DO

• Approvals — when the agent wants to run something, the request arrives with
the tool call it is for — the command or the diff — and the reason given.
Approve or refuse. Anything raised while you
were away is waiting when you come back, pinned above everything else.

• Notifications that respect the content — when the agent stops to ask and the
app is closed, your phone gets a notification. It carries no question — just
"Your agent is waiting on you" and your Mac's name. Open it, and the app
fetches the real request over its own encrypted tunnel.

• Sessions — everything running on your Mac, grouped by workspace. Start new
ones, fork a conversation from where it got interesting, archive what is done.

• Reading — streaming replies and the model's reasoning as they arrive, plus
diffs, terminal output, file reads, and to-do lists rendered for a phone
screen rather than shrunk to fit one.

• Search — full-text search across your conversations, answered by your own
Mac.

• Photos — attach a photo to a message: a whiteboard sketch, an error on
another screen. It travels the same encrypted channel as everything else.

• Control — pick the model and how hard it thinks. Change what the agent is
allowed to touch. Run the skills installed on your Mac by typing /.

• Trace — the whole run as one line per step, searchable, with what each step
took. For the two questions a transcript cannot answer at a glance: what has
it been doing, and where did it go wrong.

• Cost and context — how full the context window is and what is filling it,
turns and steps, time to first token, and the token classes broken out.

• Subagents — when work is handed to a child agent, see what it is doing
instead of watching a tool call sit there.

• Several Macs — pair as many as you like and switch between them.

• App lock — Face ID, Touch ID, or a passcode before your conversations show,
because a paired phone can approve commands on your Mac.

HOW IT CONNECTS

Rowel talks to Bridle, a small companion program you install on your Mac with
one command. Pairing is a QR code: run one command on the Mac, point the phone
at the screen, done. There is no account to create, no server address to type,
and no password. Bridle dials out, so there is no port forwarding and nothing
to change on your router.

When the phone and the Mac are on the same Wi-Fi, they talk directly and
nothing leaves your network. When they are not, a relay forwards the traffic.

WHAT THE RELAY CAN SEE

Nothing you type or read. The app and Bridle establish an end-to-end encrypted
channel with each other — Noise IK, X25519, ChaCha20-Poly1305 — and the relay
switches sealed frames between two sockets without holding any key material.
It cannot decrypt them. That is a property of the design, not a promise about
our conduct, and the source is public so you can check it.

There are no accounts. No name, no email, no phone number. No analytics SDK,
no crash reporter, and no advertising or tracking code in the app. Your
conversations are not stored on the phone: they are fetched from your Mac
when you open the app and held only in memory.

REQUIREMENTS

A Mac running the companion program, and a coding agent installed on it. Rowel
currently works with DeepSeek Harness (dsh). Setup takes about a minute and is
documented at rowel.novabox.ai. The app is free and the source is public.
```

(3636 characters — verified under 4000.)

Notes on the wording:
- `Rowel currently works with DeepSeek Harness (dsh)` is the only third-party
  mention: referential, factual, under REQUIREMENTS, not a headline
  (2.3.7/5.2.1-safe). Do not claim multi-agent support — only dsh is
  implemented.
- Every feature listed is verified in source: approvals/questions
  (`Interrupts.swift`), content-free push (`Push.swift`,
  `relay-worker` APNs constant), fork (`Harness.swift: session.fork`),
  full-text search (`SessionListView.swift` + Mac-side index), photo attach
  (`Composer.swift` PhotosPicker, up to 4 images), model + reasoning pickers
  (`ModelPicker.swift`), trace (`TraceView.swift`), cost/context
  (`SessionInfoView.swift`), subagents (`SubagentsView.swift`), app lock
  (`AppLock.swift`, `LockScreen.swift`).

## What's New (first submission)

```
First release.
```

## Keywords (limit 100, comma-separated, no spaces, English only)

**With Name = `Rowel` + Subtitle = `Drive your Mac's coding agent`:**

```
ssh,terminal,remote,ai,llm,developer,devtools,code,shell,encrypted,e2ee,tunnel,git,diff,cli,harness
```
(99 characters)

**If the fallback name is used** (remote/coding/agent now indexed via the
name — remove `remote`, gain room):

```
ssh,terminal,ai,llm,developer,devtools,code,shell,encrypted,e2ee,tunnel,git,diff,cli,harness,vibe
```
(97 characters)

Selection logic (search intent, then rules):

- **Real intents this app can honestly claim:** people looking for phone
  control of a coding agent search category-adjacent terms — `ssh` and
  `terminal` (the closest established category: Termius/Blink/Prompt users),
  `remote` + name/subtitle words combine into "remote coding agent",
  `ai`/`llm` + `code`, `encrypted`/`e2ee`/`tunnel` (the differentiator),
  `git`/`diff`/`cli`/`shell` (what the screens actually show), `harness`
  (generic word; catches the tail of "…harness" queries without touching the
  DeepSeek mark).
- **Excluded — trademarks / competing app names (2.3.7 hard ban):**
  `deepseek`, `claude`, `codex`, `copilot`, `cursor`. "Claude Code" analogies
  belong in press/social copy, never in keywords.
- **Excluded — already indexed via name/subtitle** (Apple: don't duplicate):
  `rowel`, `drive`, `mac`, `coding`, `agent` (and `remote` in the fallback
  variant).
- **No plurals, no spaces after commas** (spaces count against the limit;
  Apple stems words).
- **Gray option, off by default:** `dsh` (3 chars, highest-intent query in
  this niche). It is another company's product name, so it carries 2.3.7
  metadata-rejection risk. If the first review passes and search traction is
  poor, consider swapping `harness` → `dsh,` in an update and see if it
  survives review. Do not include it in the first submission.

## Category

- **Primary: Developer Tools**
- **Secondary: Utilities** (Productivity also fine; **never Entertainment** —
  it is the only trigger for Korea GRAC regional rating.)

## URLs

| Field | Value | Verified |
|---|---|---|
| Support URL (required) | `https://rowel.novabox.ai/help` | HTTP 200 (2026-09-01) |
| Marketing URL (optional) | `https://rowel.novabox.ai` | HTTP 200 |
| Privacy Policy URL (required) | `https://rowel.novabox.ai/privacy` | HTTP 200 |

**Important:** use the extensionless URLs. The `.html` variants
(`/help.html`, `/privacy.html`) return **404 in production** — the site's
Cloudflare Worker (`site/wrangler.jsonc`) routes only `/`, `/get`, `/help`,
`/privacy`, `/_/*`, and the app's own links (`Links.swift`) point at `/help`
and `/privacy`. A dead privacy URL is an instant metadata rejection (2.1
"fully functional URLs").

## Price and availability

- **Price: Free.** No in-app purchases, no subscriptions.
- Regions: all territories **except Mainland China, Russia, Belarus**; tick
  "automatically make available in future territories". (Rationale in
  `APPSTORE.md` §5.)
- Turn **off** "iPhone and iPad Apps on Apple Silicon Macs" and **off**
  Apple Vision Pro availability (Pricing and Availability page).

## Copyright

```
2026 <legal name of the account holder>
```
(ASC prepends the © symbol.)

## Age rating questionnaire — recommended answers

Expected outcome: **4+ worldwide** (new-scale 13+/16+/18+ tiers not
triggered). Full reasoning in `APPSTORE.md` §5.5.

| Question | Answer | Why |
|---|---|---|
| All content descriptors (violence, sexuality, profanity, medical, mature themes, chance-based) | NONE | Developer tool. For "Profanity" Apple asks you to weigh AI output frequency; profanity is not the intended experience of a coding tool → NONE. |
| Unrestricted Web Access | **NO** | No `WKWebView`/`SFSafariViewController`/browser in the binary (verified). Links open in Safari. This is the one answer that jumps the rating to 16+ if wrong — keep links opening externally. |
| User-Generated Content | NO | Requires "broad distribution"; output goes only to the person who asked, no accounts, nothing shared. |
| Messaging and Chat | NO | Defined as user-to-user communication. Human-to-agent is not. (Say so in Review Notes; the UI looks like chat.) |
| Social media / U13 facilities | NO / N/A | None. |
| Advertising | NO | None. |
| Parental controls / age assurance | NO / NO | None. |
| Age category override | Not applicable | — |

## Export compliance (asked at first submission)

Keep `ITSAppUsesNonExemptEncryption = true` (as shipped in Info.plist) and
answer the ASC questionnaire per `APPSTORE.md` §2.7:

| Question | Answer |
|---|---|
| Uses encryption? | **Yes** |
| Qualifies for Cat 5 Part 2 exemptions? | **No** (conservative track) |
| Proprietary / non-standard algorithms? | **No** — X25519 (RFC 7748), ChaCha20-Poly1305 (RFC 8439), HKDF (RFC 5869), SHA-256 (FIPS 180-4); Noise is published; every primitive is CryptoKit |
| Standard algorithms beyond the OS? | **Yes** (conservative track → triggers the one-time France declaration) |
| Available in France? | **Yes** |

This is the conservative reading; the `false`/OS-only reading is defensible
too — the tradeoffs and the `appstore.ec@apple.com` escalation path are in
`APPSTORE.md` §2.3. Do not flip it casually; it is an export declaration.
