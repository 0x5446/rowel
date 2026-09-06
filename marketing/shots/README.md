# Screenshots

Every image here came out of the running app talking to a real Bridle and a
real harness — no mockups, no staged text. They are regenerated, not edited:

```sh
ios/screenshots.sh          # the whole set
```

That script starts a throwaway dsh (its own `DSH_HOME`, its own port, its own
pairing identity) so the shots never contain a real project path, a real
conversation, or a name belonging to whoever is running it. The sample repo it
works in is `/Users/Shared/code/checkout-api`, seeded by the script — a
neutral path on purpose, because the app prints the working directory in
the list, the header and the transcript, so a fixture under `$HOME` puts
the operator's username on the store listing.

The driver is `ios/RowelUITests/Screenshots.swift`. Each shot asserts it is
looking at the right screen before it saves, because a screenshot taken on
faith reaches the store listing showing the wrong page and nothing fails to say
so.

## What each one is for

| File | Shows | Used by |
|---|---|---|
| `sessions.png` | The list: anything waiting on a person on top, then conversations grouped by folder | App Store 1, site |
| `conversation.png` | A finished answer with code, a test run, and the model that wrote it | App Store 2, site |
| `approval.png` | The agent stopping to ask, with the options it wrote itself | App Store 3, site |
| `tools.png` | A long job mid-flight: reads, shell commands, a todo update, a file write | App Store 4 |
| `artifact.png` | The same job finished — 5/5 steps, and what the data said | App Store 5 |
| `photo.png` | A sketch from the camera roll on its way to the agent | App Store 6, site |
| `push.png` | The notification that arrives when the agent needs an answer | site |
| `models.png` | The model picker | site |
| `machine.png` | Fingerprint, device id, harness port — the pairing is to a key | reserve |
| `trace.png` | Every step with what it cost | reserve |
| `plan.png` | The plan the agent wrote for itself | reserve |
| `welcome.png` | First launch | reserve |
| `pairing-sheet.png` | The install-and-pair sheet | help page |
| `dashboard.png` | The artifact itself, rendered — a dark-mode page with inline SVG charts the agent built from `metrics.json` | site, video |

`site/public/_/shots/` holds copies scaled to 660px wide (1200px for the
dashboard) so the marketing page stays under a megabyte. The originals here are
1320×2868, which is the App Store's 6.9" size.

## The recording

`streaming.mp4` is a real turn arriving over the tunnel — thinking, tool cards,
then the answer a word at a time. It is deliberately **not** committed (see
`.gitignore`): regenerate it with `ios/RowelUITests/Recording.swift`, which sits
in the conversation while a prompt is sent from the machine side.
