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
INIT_PROMPT="${WIDGET_AI_PROMPT:-Ensure the UberSDR widgets skill is loaded, then: (1) list some of the available community widgets (name + short description) I could enable or clone; and (2) give me three example prompts I could use to build a new widget. Finally, as the last thing, tell me I can enable remote access by running the /remote-control command.}"

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
# 2. Fresh scratch working dir each launch (reference widgets + widgets-custom).
#    The real widgets live on the instance behind the admin API — nothing here
#    needs to persist.
# ---------------------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK/widgets" "$WORK/widgets-custom"

# Best-effort: pull the bundled reference widgets so the skill has local
# examples to read. Editing via the API works fine without them.
REF_REPO="${WIDGET_REF_REPO:-madpsy/ka9q_ubersdr}"
REF_BRANCH="${WIDGET_REF_BRANCH:-main}"
if curl -fsSL --max-time 20 "https://github.com/$REF_REPO/archive/refs/heads/$REF_BRANCH.tar.gz" \
     | tar -xz -C "$WORK" --strip-components=1 "ka9q_ubersdr-$REF_BRANCH/widgets" 2>/dev/null; then
  say "Reference widgets loaded ($(ls "$WORK/widgets" 2>/dev/null | wc -l) files)."
else
  echo "  (reference widgets unavailable — creating from scratch still works)"
fi

cd "$WORK"

# ---------------------------------------------------------------------------
# 3. Banner + hand over to Claude. The admin password arrives as
#    $UBERSDR_ADMIN_PASSWORD (set by the compose service); it is used only for
#    the X-Admin-Password header and is never printed.
# ---------------------------------------------------------------------------
cat <<'EOF'

  ┌───────────────────────────────────────────────────────────┐
  │  UberSDR Widget Assistant (sandboxed)                      │
  ├───────────────────────────────────────────────────────────┤
  │  Just tell Claude what you want, e.g.                      │
  │    • "Create a widget that shows the current UTC sunrise"  │
  │    • "List my widgets" / "Edit my callsign lookup widget"  │
  │                                                            │
  │  Your widgets live on your instance (admin API), not here. │
  │  This scratch folder is wiped clean on each launch.        │
  └───────────────────────────────────────────────────────────┘

EOF

if [ "$#" -gt 0 ]; then
  exec claude --permission-mode "$PERM_MODE" "$@"
else
  exec claude --permission-mode "$PERM_MODE" "$INIT_PROMPT"
fi
