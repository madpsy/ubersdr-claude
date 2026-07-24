# ubersdr-claude — sandboxed Claude Code for UberSDR widget authoring.
#
# Runs Claude Code with the bundled create-widget skill inside a locked-down
# container: non-root user, read-only root filesystem at runtime (see the
# compose service), no host mounts except a private home volume for auth state.
# Claude reaches only the admin API (via the sdr-network) and the Anthropic API.
FROM node:20-slim

# Runtime tools used by the widget workflow:
#   curl/tar — fetch reference widgets + skill refresh
#   jq       — the admin-API recipes
#   git      — optional deeper repo inspection by the skill
#   tini     — proper PID 1 / signal handling for the interactive session
#   ca-certificates — TLS to api.anthropic.com and the collector proxy
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar jq git tini \
 && rm -rf /var/lib/apt/lists/*

# Claude Code, installed system-wide (/usr/local) so it lives on the read-only
# root filesystem and is never shadowed by the /home volume.
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

# The root filesystem is read-only at runtime and the CLI runs as an
# unprivileged user, so the built-in auto-updater can only fail. Disable it;
# updating the CLI is done by rebuilding this image.
ENV DISABLE_AUTOUPDATER=1

# Baked-in skills. Copied into $HOME/.claude/skills at container start so an
# image update always wins over whatever a persisted home volume already holds.
COPY skills/ /opt/ubersdr-claude/skills/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Unprivileged user shipped by the base image (uid 1000). $HOME is the only
# writable path at runtime (a named volume); everything else is read-only.
USER node
ENV HOME=/home/node
WORKDIR /home/node

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
