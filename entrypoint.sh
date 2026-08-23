#!/bin/bash
#
# entrypoint.sh — prepare the sandbox and hand over to Claude Code.
#
# Runs as the unprivileged `node` user inside the ubersdr-claude container.
# $HOME (/home/node) is the only writable path (a named volume that persists the
# Claude login between runs); everything else is a read-only root filesystem.
set -euo pipefail

CLAUDE_HOME="${HOME:-/home/node}"
SKILL_SRC="/opt/ubersdr-claude/skills"
WORK="$CLAUDE_HOME/work"

# Admin API base — the main UberSDR service on the shared docker network.
export BASE="${BASE:-http://ubersdr:8080}"

# Permission mode: the container IS the sandbox, so bypassing per-command prompts
# is safe here (the piped curl/jq recipes can't be allowlisted cleanly anyway).
PERM_MODE="${WIDGET_AI_PERMISSION_MODE:-bypassPermissions}"

# Seed prompt when the session starts with no explicit prompt/args.
INIT_PROMPT="${WIDGET_AI_PROMPT:-Ensure the UberSDR panels skill is loaded, then: (1) list the panels and widgets I have already created on this instance, saying which are enabled and which are still classic widgets; (2) list some of the available community panels (name + short description) I could enable or clone; and (3) give me three example prompts I could use to build a new panel. Finally, as the last thing, tell me that I can remotely control this Claude session itself (not the UberSDR instance) any time by running the /remote-control command.}"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Refresh the baked-in skill(s) into the (persisted) Claude skills dir, so
#    image updates always take precedence over the home volume's older copy.
# ---------------------------------------------------------------------------
mkdir -p "$CLAUDE_HOME/.claude/skills"
if [ -d "$SKILL_SRC" ]; then
  cp -a "$SKILL_SRC"/. "$CLAUDE_HOME/.claude/skills/"
  say "Skills loaded: $(ls "$CLAUDE_HOME/.claude/skills" 2>/dev/null | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2. Fresh scratch working dir each launch. The real panels live on the instance
#    behind the admin API — nothing here needs to persist.
# ---------------------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/panels" "$WORK/reference"

# Best-effort: pull the authoring documents from the instance itself rather than
# from a repository. They are served by the receiver being published to, so they
# describe exactly the version in front of the user — a copy baked into this
# image would go stale the first time the panel format moved.
for doc in PANEL_AUTHORING.md example-panel.html BRIDGE_API.md dist/panel-meta.json; do
  curl -fsSL --max-time 15 "$BASE/v2/$doc" -o "$WORK/reference/$(basename "$doc")" 2>/dev/null || true
done
if [ -s "$WORK/reference/PANEL_AUTHORING.md" ]; then
  say "Reference loaded from the instance ($(ls "$WORK/reference" | tr '\n' ' '))."
else
  echo "  (instance reference unavailable — the skill is self-contained, so building still works)"
fi

# The interface's own panel source, so the assistant can read how a real panel
# words its states, formats a frequency or lays out a row rather than inventing
# conventions. Sixty files it can grep; the difference between a panel that
# looks like it belongs and one that looks like a debug readout.
#
# A sparse partial clone rather than the repository or a source tarball: blobs
# are fetched only for the paths asked for, which is about 28 MB and three
# seconds instead of the whole history of a repo carrying client binaries.
REF_REPO_URL="${PANEL_REF_REPO:-https://github.com/madpsy/ka9q_ubersdr.git}"
REF_SRC="$WORK/reference/ubersdr"
if timeout 120 git clone --depth 1 --filter=blob:none --sparse -q \
     "$REF_REPO_URL" "$REF_SRC" 2>/dev/null \
   && timeout 120 git -C "$REF_SRC" sparse-checkout set static/v2 >/dev/null 2>&1 \
   && [ -d "$REF_SRC/static/v2/src/panels" ]; then
  # Short paths for the common case, without hiding where they came from. The
  # clone is left whole — .git and all — so the assistant can `git pull` it or
  # widen it with `git sparse-checkout add <path>` if it needs something outside
  # static/v2. Moving the files out and deleting the repo would have saved
  # nothing and cost both.
  ln -sfn ubersdr/static/v2/src "$WORK/reference/src"
  say "Panel source loaded ($(ls "$REF_SRC/static/v2/src/panels" | wc -l) built-in panels in reference/src/panels)."
else
  rm -rf "$REF_SRC"
  echo "  (panel source unavailable — the skill's own conventions still apply)"
fi

cd "$WORK"

# ---------------------------------------------------------------------------
# 3. Banner + hand over to Claude. The admin password arrives as
#    $UBERSDR_ADMIN_PASSWORD (set by the compose service); it is used only for
#    the X-Admin-Password header and is never printed.
# ---------------------------------------------------------------------------
cat <<'EOF'

  ┌───────────────────────────────────────────────────────────┐
  │  UberSDR Panel Assistant (sandboxed)                       │
  ├───────────────────────────────────────────────────────────┤
  │  Just tell Claude what you want, e.g.                      │
  │    • "Create a panel that shows the current UTC sunrise"   │
  │    • "List my panels" / "Edit my band memories panel"      │
  │                                                            │
  │  Your panels live on your instance (admin API), not here.  │
  │  This scratch folder is wiped clean on each launch.        │
  └───────────────────────────────────────────────────────────┘

EOF

if [ "$#" -gt 0 ]; then
  exec claude --permission-mode "$PERM_MODE" "$@"
else
  exec claude --permission-mode "$PERM_MODE" "$INIT_PROMPT"
fi
