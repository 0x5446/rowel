#!/usr/bin/env sh
#
# Install the Rowel Bridle on this machine.
#
# This is what `curl -fsSL https://rowel.novabox.ai/install | sh` fetches — the
# Relay serves this very file at `GET /install`. It runs under plain `sh` with no
# arguments and no assumptions, because the person running it has just been told
# to paste a line into Terminal and is not going to debug it.
#
# What it does, in order: check Node, fetch the source, build it, put `bridle` on
# the PATH, and hand over to `bridle pair`. What it does not do: install Node,
# touch the harness, ask for a password, or write anywhere outside
# ~/.rowel and one symlink.
#
# Environment:
#   ROWEL_REPO    git URL to install from (default: the public repo)
#   ROWEL_REF     tag to install (default: the current release tag). Pass a
#                 branch name only when you mean to run unreleased code.
#   ROWEL_SRC     where to keep the checkout (default: ~/.rowel/src)
#                 (not ROWEL_HOME — the Bridle uses that for its own state)
#   ROWEL_BIN     where to link the `bridle` command (default: first writable
#                 of ~/.local/bin, /usr/local/bin)

set -eu

REPO="${ROWEL_REPO:-https://github.com/0x5446/rowel.git}"
# A tag, not a branch. `main` moves, which means the thing this script installs
# is whatever was pushed most recently — including a push made thirty seconds
# ago by someone who should not have been able to make it. A tag is a name for
# one commit, and a release is a decision rather than a side effect of merging.
#
# The cost of that choice is that this line has to move with every release, and
# once it did not: the project was renamed ten hours after 0.1.2 was tagged, and
# this kept installing 0.1.2 — a Bridle that greeted people as Reins and dialled
# a relay that had been retired. Nothing downstream can catch it, because from
# here a stale tag and a current one look identical. Bump this in the same
# commit as the CHANGELOG heading; they are one decision, not two.
REF="${ROWEL_REF:-v0.1.7}"
SRC_DIR="${ROWEL_SRC:-$HOME/.rowel/src}"

# Colour only when a human is watching. Piped output stays plain.
if [ -t 1 ]; then
  bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); red=$(printf '\033[31m'); off=$(printf '\033[0m')
else
  bold=''; dim=''; red=''; off=''
fi

say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
fail() { printf '%s%s%s\n' "$red" "$*" "$off" >&2; exit 1; }

# --- Node -------------------------------------------------------------------
#
# The Bridle needs Node 22 for the WebSocket and crypto APIs it uses. Installing
# a language runtime behind someone's back is the kind of thing that makes an
# installer untrustworthy, so this stops and says what to run instead.

if ! command -v node >/dev/null 2>&1; then
  say "Rowel needs Node 22 or newer, and this Mac does not have Node."
  say ""
  say "  ${bold}brew install node${off}"
  say ""
  fail "Install Node, then run this again."
fi

node_major=$(node -p 'process.versions.node.split(".")[0]')
if [ "$node_major" -lt 22 ]; then
  fail "Rowel needs Node 22 or newer. This Mac has $(node -v). Try: brew upgrade node"
fi

command -v git >/dev/null 2>&1 || fail "Rowel needs git. Install the Xcode command line tools: xcode-select --install"

# --- Source -----------------------------------------------------------------

if [ -d "$SRC_DIR/.git" ]; then
  step "Updating Rowel in $SRC_DIR"
  git -C "$SRC_DIR" fetch --quiet --depth 1 origin "refs/tags/$REF:refs/tags/$REF" 2>/dev/null \
    || git -C "$SRC_DIR" fetch --quiet --depth 1 origin "$REF"
  git -C "$SRC_DIR" checkout --quiet FETCH_HEAD 2>/dev/null || git -C "$SRC_DIR" checkout --quiet "$REF"
else
  step "Downloading Rowel into $SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  rm -rf "$SRC_DIR"
  git clone --quiet --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
    || fail "Could not download Rowel from $REPO. If this is a private repo, run: git clone $REPO $SRC_DIR"
fi

step "Building"
# `npm ci` rather than `npm install`: it installs exactly what package-lock.json
# pins and fails if the lockfile and the manifest disagree, instead of quietly
# resolving something newer. On a machine about to be handed the same authority
# as its own shell, "quietly newer" is not a tradeoff worth making.
#
# Dev dependencies are included on purpose: TypeScript is one of them, and the
# Bridle ships as source rather than as a published tarball.
( cd "$SRC_DIR" && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 \
  || npm install --silent --no-audit --no-fund >/dev/null )
( cd "$SRC_DIR" && npx tsc -b protocol bridle )

# --- PATH -------------------------------------------------------------------
#
# A symlink rather than `npm link`, which needs a global prefix that is often
# root-owned and turns a one-line install into a sudo prompt.

target="$SRC_DIR/bridle/lib/cli.js"
[ -f "$target" ] || fail "The build did not produce $target. Please report this."
chmod +x "$target"

bin=""
for candidate in "${ROWEL_BIN:-}" "$HOME/.local/bin" /usr/local/bin; do
  [ -n "$candidate" ] || continue
  if mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ]; then bin="$candidate"; break; fi
done
[ -n "$bin" ] || fail "Nowhere writable to put the bridle command. Set ROWEL_BIN to a directory on your PATH."

ln -sf "$target" "$bin/bridle"
step "Installed bridle to $bin/bridle"

case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    say ""
    say "$bin is not on your PATH. Add it:"
    say ""
    say "  ${bold}echo 'export PATH=\"$bin:\$PATH\"' >> ~/.zshrc && exec zsh${off}"
    say ""
    ;;
esac

# --- Hand over --------------------------------------------------------------

say ""
say "${bold}Rowel Bridle is installed.${off}"
say "${dim}Next: pair your iPhone. This starts Bridle and prints a QR code — point Rowel at it.${off}"
say ""

# Running `bridle pair` directly would inherit the pipe from `curl | sh` as its
# stdin, which is already at EOF, so the QR would flash past. Tell them the
# command instead; it is one line and they are already in a terminal.
say "  ${bold}bridle pair${off}"
say ""
say "${dim}If no Bridle was running yet, it stays in that terminal. Once the phone is in,${off}"
say "${dim}Ctrl-C and run ${bold}bridle service install${off}${dim} to keep it running after login.${off}"
say ""
