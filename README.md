# ubersdr-claude

Sandboxed **Claude Code** for authoring UberSDR widgets — the container behind
the Admin panel's *✨ AI Widget Assistant*.

Claude runs inside a locked-down container instead of loose on the host:

- **non-root** user, **read-only root filesystem** at runtime
- only writable path is a private **home volume** (persists the Claude login)
- **no host mounts**, no docker socket, `cap_drop: ALL`, `no-new-privileges`
- network access limited to the **admin API** (over the compose `sdr-network`)
  and the **Anthropic API** for the model
- the admin password arrives as a single env var (`UBERSDR_ADMIN_PASSWORD`),
  never a mounted config volume

Claude's trust boundary is therefore "anything the widget admin API allows, and
nothing else" — it cannot traverse the host, read `config.yaml`, or touch other
containers.

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | Node 20 base + Claude Code + the widget tooling |
| `entrypoint.sh` | Refreshes the baked-in skills, prepares a scratch dir, execs `claude` |
| `skills/` | Bundled Claude skills (`create-widget`), baked into the image |
| `docker.sh` | Build / push helper (`build`, `arm64`, `push`, `run`) |

## Build / push

```bash
./docker.sh build     # local amd64 image
./docker.sh push      # multi-arch (amd64+arm64) → registry, then git commit/push
```

Image: `madpsy/ubersdr-claude:latest`.

## How it runs

Defined as the manually-started `widget-ai` service in the UberSDR
`docker-compose.yml` (under a `manual` profile, so `docker compose up` skips it).
The host-side manager `widget-ai.sh` (in the `ka9q_ubersdr` repo) starts/stops it
and attaches an interactive session via a detached `Widget AI` tmux session, so
closing the terminal only detaches.

```bash
docker compose run --rm --name ubersdr-claude widget-ai
```

## Skills

`skills/create-widget/SKILL.md` is the canonical home of the create-widget skill
(moved out of the `ka9q_ubersdr` repo). Add more skills under `skills/<name>/` and
rebuild; the entrypoint copies them into `~/.claude/skills/` on every launch.
