# Submission Runbook — zero to "Waiting for Review"

Ordered. Steps marked **[Account Holder]** can only be done by the account
holder (this is a personal developer account, so that is you — but they
cannot be delegated to an API key or a future team member). Everything else
needs Admin or App Manager.

Facts assumed (verified in repo): bundle id `ai.novabox.rowel`, team
`AVKUVD4FPN`, version 1.0 (`ios/project.yml: MARKETING_VERSION`), iPhone-only,
iOS 17+, upload path `ios/release.sh` (archive → export → altool with ASC API
key), `ios/ExportOptions.plist` method `app-store-connect`.

---

## Phase 0 — prerequisites (one-time, ~15 min)

1. **[Account Holder]** appleid/developer.apple.com: membership active
   (activated 2026-08-19), latest **Apple Developer Program License
   Agreement accepted** — ASC banners block submissions until agreed. Free
   app → no Paid Applications agreement, no banking/tax forms needed.
2. Local toolchain: Xcode 26+ with iOS 26 SDK (26.4 verified on this
   machine — meets the "built with Xcode 26" upload requirement),
   `brew install xcodegen`.
3. Site URLs live — verified 2026-09-01: `https://rowel.novabox.ai/` ,
   `/help`, `/privacy` all HTTP 200. (**Use extensionless paths everywhere;
   `.html` variants 404.**)
4. Repo public at `github.com/0x5446/rowel` (the description and review
   notes point reviewers at it).

## Phase 1 — App Store Connect API key (one-time, ~10 min)

1. **[Account Holder]** ASC → Users and Access → **Integrations** →
   App Store Connect API → **Request Access** (first time only) → agree →
   Submit. Usually instant.
2. Team Keys tab → **Generate API Key**:
   - Name: `rowel-release` (reference only)
   - Access: **Admin**. App Manager is enough to upload and to submit, but not
     to *export*: `xcodebuild -exportArchive` provisions the distribution
     certificate through cloud signing and the App Manager key stops at
     `Cloud signing permission error` + `No signing certificate "iOS
     Distribution" found` (measured 2026-09-21: same team, same machine, same
     archive — only the key's role differed). This account carries both
     `rowel-release` (App Manager) and `rowel-release-admin` (Admin).
3. Record three things:
   - **Issuer ID** (UUID at the top of the Keys page)
   - **Key ID** (10 chars, on the key's row)
   - **AuthKey_<KEYID>.p8** — downloadable **exactly once**; Apple keeps no
     copy. Store at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`,
     never in the repo. Name/role are immutable after creation; revocation is
     permanent.

## Phase 2 — create the app record (~15 min)

1. Confirm the App ID exists: developer.apple.com → Identifiers →
   `ai.novabox.rowel` with **Push Notifications** capability. (It exists if
   the app has ever been signed for a device on this team; `release.sh`'s
   `-allowProvisioningUpdates` maintains it. If missing, register it there
   first — the ASC dropdown only lists registered IDs.)
2. ASC → My Apps → **+** → **New App**:
   | Field | Value |
   |---|---|
   | Platforms | iOS |
   | Name | `Rowel` (fallbacks in `metadata.md` if taken) |
   | Primary Language | English (U.S.) |
   | Bundle ID | `ai.novabox.rowel` (from dropdown — not a wildcard) |
   | SKU | `rowel-ios` (internal, immutable, never shown) |
   | User Access | Full Access |

## Phase 3 — app-level settings (~30 min, all from the prepared files)

1. **App Information**: Subtitle; Category **Developer Tools** (primary) +
   **Utilities** (secondary); Content Rights: does not contain third-party
   content; Age Rating questionnaire → answers table in `metadata.md`
   (expect 4+).
2. **App Privacy**: privacy policy URL `https://rowel.novabox.ai/privacy`;
   questionnaire → **Data Not Collected** per `privacy-questionnaire.md`;
   publish the responses.
3. **Pricing and Availability**:
   - Price: **Free** (USD 0).
   - Availability: choose specific territories → select all → deselect
     **China mainland, Russia, Belarus** → tick automatic availability for
     future territories.
   - **Untick** "iPhone and iPad Apps on Apple Silicon Macs".
   - **Untick** Apple Vision Pro availability.
4. **[Account Holder]** Business/Compliance → **EU Digital Services Act
   trader status**. Apps without a declaration get removed from EU
   storefronts. We declared **trader** — the app is a commercial product,
   and "non-trader" is a claim about intent that would not survive a paid
   tier later. The cost is that the declared address, phone and email are
   published on the product page.

## Phase 4 — build and upload (~20 min machine time)

```sh
export ROWEL_TEAM_ID=AVKUVD4FPN
export ASC_KEY_ID=<Key ID>
export ASC_ISSUER_ID=<Issuer ID>
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_<Key ID>.p8

# Dry run first: archive + export only, catches signing issues locally. It
# needs the key above to be exported: --no-upload does not upload, but the
# *export* is exactly the step that provisions the distribution certificate
# through cloud signing, so without a key the run can only reach the archive
# and then stops at "No Accounts". The first run that carries a key creates
# an Apple Distribution certificate on the account (via
# -allowProvisioningUpdates) — expected, one-time.
./ios/release.sh --no-upload

# Real thing: archive → export → altool validate → altool upload.
./ios/release.sh
```

- Build number defaults to the git commit count (`ROWEL_BUILD` overrides) —
  monotonic, no bookkeeping.
- The script validates before uploading (server-parity checks, ~20 s,
  reported inline instead of by queue email).
- After upload: ASC → TestFlight shows the build "Processing" for a few
  minutes to an hour. There is no export-compliance question to answer:
  `project.yml` ships `ITSAppUsesNonExemptEncryption = false`, because both
  of Apple's criteria turn on *algorithms* and this binary contains none —
  every primitive comes from CryptoKit and `Noise.swift` implements a
  protocol, not a cipher. The rationale is written out in `project.yml`
  next to the key; keep it archived five years.

## Phase 5 — TestFlight internal smoke test (strongly recommended, zero review)

Being the account holder is not enough to see a build, which is the opposite
of what it looks like. Three things have to exist first, and none of them are
created by uploading:

1. **An internal beta group.** A fresh app has none, so TestFlight shows
   nothing at all. `POST /v1/betaGroups` with `isInternalGroup: true`, then
   `POST /v1/betaGroups/<id>/relationships/builds` to put the build in it.
2. **Test Information.** `betaAppLocalizations` starts empty; at minimum a
   description and a feedback email.
3. **An accepted invitation.** Add yourself with `POST /v1/betaTesters` and
   then **open the emailed invite on the phone**. A team member's own Apple ID
   does not surface the app on its own — the tester sits at `INVITED` until
   the link is tapped, and TestFlight looks simply empty in the meantime.

Then verify on a physical phone the things that once crashed in this exact
codebase (fixed in `project.yml`, but TCC only proves itself on-device):
- [ ] Scan-pairing opens the camera **with a permission prompt, no crash**.
- [ ] App lock triggers Face ID without a crash.
- [ ] LAN direct connection shows the Local Network permission prompt and
      connects.
- [ ] A push arrives with the app killed; tapping it opens the session.

## Phase 6 — version page + submit (~30 min)

1. App Store tab → iOS App 1.0 → paste from `metadata.md`: Description,
   Keywords, Promotional Text, Support URL (`https://rowel.novabox.ai/help`),
   Marketing URL (`https://rowel.novabox.ai`), Copyright `2026 <name>`,
   What's New (`First release.`).
2. Upload the six 6.9" screenshots (`screenshots-spec.md`).
3. **App Review Information**: paste notes from `review-notes.md` §2 (with
   the real `<VIDEO URL>`); attach the demo video file; sign-in required:
   **No** (no accounts exist); contact phone + email that get answered.
4. Select the processed build.
5. Version Release: choose **Manually release this version** (you control
   launch timing for the X/PH push; you can flip to automatic later).
6. **Submit for Review.** (App Manager can do this; no Account Holder step.)

## Phase 7 — after submission

- Typical first response inside 24–48 h. If rejected → Resolution Center
  playbook in `review-notes.md` §5 (reply first, escalate rungs B→D only as
  forced).
- On approval with manual release: release when the launch posts are ready
  to go out (`marketing/launch/`).
- Post-release, non-Apple obligations (own deadlines, from `APPSTORE.md`
  §2): one-time BIS/NSA open-source notification email; one-time
  self-classification CSV before 2027-02-01; France declaration if the
  conservative export answers were used; keep the compliance rationale
  archived 5 years.

## Field-to-file map (copy sources)

| ASC field | Source |
|---|---|
| Name / Subtitle / Promo / Description / Keywords / URLs / Copyright | `marketing/appstore/metadata.md` |
| Age rating answers | `metadata.md` (table) |
| App Privacy answers | `marketing/appstore/privacy-questionnaire.md` |
| Export compliance answers | `metadata.md` (table) + `APPSTORE.md` §2.7 |
| Review notes + video | `marketing/appstore/review-notes.md` |
| Screenshots | `marketing/appstore/screenshots-spec.md` |


## Where this actually stands — 2026-09-01

**Submitted. Version 1.0 is `WAITING_FOR_REVIEW`.**

App record **6807263060** (`Rowel: DeepSeek Harness Remote`, SKU `rowel-ios`,
Developer Tools, iOS only), App ID `ai.novabox.rowel` with Push Notifications
and Time Sensitive Notifications — the app sets
`interruptionLevel = .timeSensitive` and the relay sends the matching header,
so both are required. Build 1 uploaded and VALID, attached to 1.0. Six 6.9"
screenshots (1320×2868) from `marketing/shots`; Apple reuses them for 6.5".
Free in all 175 territories. Age ratings answered, content rights declared,
App Privacy published as **Data Not Collected**.

The EU trader declaration is *In Review* for 27 countries: declared as a
trader, with the address, phone number and support address that App Store
Connect holds. Those three become public on the product page once Apple
verifies them, which is Apple's disclosure to make on the account holder's
behalf — this file is in a public repository and is not the place to repeat
them. Read them back with `node ios/asc.mjs get /v1/apps/6807263060` if you
need to check what was submitted. The address was entered in Chinese so it matches the deed
character for character — an English rendering was tried first and abandoned
for exactly that reason.

### Three things that cost time, so they are written down

**App Privacy is not in the public API.** `appDataUsages`,
`appDataUsageCategories`, `appDataUsageDataProtections`, `appPrivacyDetails`
and `appDataUsagesPublishState` all return `404 PATH_ERROR` on
`api.appstoreconnect.apple.com`, and `GET /v1/apps/<id>` exposes no data-usage
relationship. The same resources *do* exist on the dashboard's own
`appstoreconnect.apple.com/iris/v1` API, reachable with a live web session and
an `X-Cross-Site-Security: dash` header. Declaring "Data Not Collected" is two
calls: `POST /iris/v1/appDataUsages` relating the app to the
`DATA_NOT_COLLECTED` protection, then `PATCH
/iris/v1/appDataUsagesPublishState/<app id>` with `published: true`. Nothing
is saved until that second call — an unpublished questionnaire blocks
submission silently.

**`privacyPolicyUrl` lives on the app info localization, not the privacy
section.** Submission fails with a `409` naming
`/v1/appInfoLocalizations/<id>` and `ENTITY_ERROR.ATTRIBUTE.REQUIRED`. Setting
the privacy questionnaire does not set it. Use the extensionless
`https://rowel.novabox.ai/privacy` — the `.html` path 404s.

**A literal in the Info.plist beats the command line.** `project.yml` carried
`CFBundleVersion: "1"`, so every archive was stamped `1` no matter what build
number `release.sh` computed — and App Store Connect only says so on the
*second* upload, twenty minutes in, as a duplicate-version 409 that never
mentions a plist. Both version keys now defer to their build settings
(`$(CURRENT_PROJECT_VERSION)`, `$(MARKETING_VERSION)`) and `release.sh` asserts
the stamp before uploading. Had this not been caught, it would have blocked
every update after 1.0, not just this one.

**Submission is three calls, not one.** `ios/asc.mjs submit` does them:
create a `reviewSubmissions` container, add the version as a
`reviewSubmissionItems`, then `PATCH … submitted: true`. Apple models "Add for
Review" and "Submit to App Review" as separate acts and the API mirrors that.

### Left at Apple's defaults, worth revisiting after 1.0

The app appears on Apple silicon Macs and on Apple Vision Pro. Vision Pro is
inert (1.0 is marked incompatible), but the Mac one puts an iPhone client for
a Mac-side agent on the Mac App Store, which may confuse more than it helps.
