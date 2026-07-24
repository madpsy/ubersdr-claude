#!/usr/bin/env bash
# docker.sh — build / push the ubersdr-claude Docker image.
#
# Usage:
#   ./docker.sh [build|arm64|push|run]
#
#   build    — build the image for linux/amd64 and load into local Docker (default)
#   arm64    — build the image for linux/arm64 and load into local Docker
#   push     — build linux/amd64 + linux/arm64 with buildx, push multi-arch
#              manifest to the registry, then git commit + push (if a git repo)
#   run      — run the image locally (for a quick smoke test)
#
# Environment variables (build):
#   IMAGE      Docker image name/tag   (default: madpsy/ubersdr-claude:latest)
#   PLATFORM   Docker --platform flag  (default: linux/amd64)
#
# Requirements for 'push':
#   docker buildx with a builder that supports linux/amd64 and linux/arm64.
#   Created automatically as the 'multiarch' builder if missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-madpsy/ubersdr-claude:latest}"
PLATFORM="${PLATFORM:-linux/amd64}"
BUILDER="${BUILDER:-multiarch}"

die() { echo "error: $*" >&2; exit 1; }

check_deps() {
    command -v docker >/dev/null || die "docker not found in PATH"
}

# Ensure a buildx builder that supports multi-arch exists and is active.
ensure_builder() {
    if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
        echo "Creating buildx builder '$BUILDER' (docker-container driver)..."
        docker buildx create --name "$BUILDER" --driver docker-container --bootstrap
    fi
    docker buildx use "$BUILDER"
}

# Stage source into a temp dir (excludes .git) and return the path in $TMPCTX.
stage_context() {
    TMPCTX="$(mktemp -d)"
    trap 'rm -rf "$TMPCTX"' EXIT
    echo "Staging build context in $TMPCTX..."
    rsync -a --exclude='.git' "$SCRIPT_DIR/" "$TMPCTX/"
}

# build [platform] — single-arch build loaded into the local Docker daemon.
build() {
    check_deps
    stage_context
    echo "Building image $IMAGE (platform=$PLATFORM) via buildx --load..."
    docker buildx build \
        --platform "$PLATFORM" \
        --tag "$IMAGE" \
        --load \
        "$TMPCTX"
    echo "Built and loaded: $IMAGE"
}

# push — multi-arch build (amd64 + arm64) pushed directly to the registry.
push() {
    check_deps
    ensure_builder
    stage_context
    local platforms="linux/amd64,linux/arm64"
    echo "Building multi-arch image $IMAGE (platforms=$platforms) and pushing..."
    docker buildx build \
        --platform "$platforms" \
        --tag "$IMAGE" \
        --push \
        "$TMPCTX"
    echo "Pushed multi-arch manifest: $IMAGE"

    if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Committing and pushing git repository..."
        git -C "$SCRIPT_DIR" add -A
        git -C "$SCRIPT_DIR" diff --cached --quiet || git -C "$SCRIPT_DIR" commit -m "Release $IMAGE"
        git -C "$SCRIPT_DIR" push || echo "warning: git push failed (no remote configured?)"
    else
        echo "(not a git repo — skipping git commit/push)"
    fi
}

run_image() {
    docker run --rm -it --platform "$PLATFORM" "$IMAGE" "$@"
}

case "${1:-build}" in
    build) build ;;
    arm64) PLATFORM=linux/arm64 build ;;
    push)  push  ;;
    run)   shift; run_image "$@" ;;
    *)
        echo "Usage: $0 [build|arm64|push|run [args...]]" >&2
        exit 1
        ;;
esac
