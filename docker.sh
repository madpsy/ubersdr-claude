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

# Trivy vulnerability scan (mirrors the main ubersdr docker.sh). Advisory only —
# reports findings but NEVER fails the build/push. Set SKIP_SCAN=true (or run the
# 'scan' subcommand separately) to control it.
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:latest}"
TRIVY_SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
SKIP_SCAN="${SKIP_SCAN:-false}"

die() { echo "error: $*" >&2; exit 1; }

# Scan an image with Trivy for known vulnerabilities.
#
# Advisory only: reports findings but NEVER fails the build or blocks the
# push/git steps. Every failure mode (no network, Docker Hub rate limit, Trivy
# image unavailable, vuln DB download failure, scan timeout) is caught and
# downgraded to a warning, so an offline build still succeeds.
#
#   scan_image <local|registry> <scan-platform>
#     local    — image lives only in the local daemon (built with --load);
#                Trivy reads it via the Docker socket.
#     registry — image was pushed; Trivy pulls it, pinned to <scan-platform>
#                (a multi-arch tag would otherwise default to amd64).
scan_image() {
    local source="$1" scan_platform="$2"
    local socket_args=() platform_args=()

    if [ "$SKIP_SCAN" = true ]; then
        echo "Skipping Trivy scan (SKIP_SCAN=true)."
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "Trivy vulnerability scan: $IMAGE"
    echo "=========================================="

    # Pull Trivy up front so an unavailable image is a clean skip.
    if ! docker pull --quiet "$TRIVY_IMAGE" >/dev/null 2>&1; then
        echo "WARNING: Could not pull $TRIVY_IMAGE - skipping vulnerability scan"
        echo "         (build is unaffected; scan is advisory only)"
        return 0
    fi

    if [ "$source" = "local" ]; then
        socket_args=(-v /var/run/docker.sock:/var/run/docker.sock)
    else
        platform_args=(--platform "$scan_platform")
    fi

    # A named volume caches the ~100MB vuln DB between runs.
    # --exit-code 0 so findings never fail the build.
    if ! docker run --rm \
        "${socket_args[@]}" \
        -v trivy-cache:/root/.cache/ \
        "$TRIVY_IMAGE" image \
        "${platform_args[@]}" \
        --scanners vuln \
        --severity "$TRIVY_SEVERITY" \
        --exit-code 0 \
        --timeout 10m \
        "$IMAGE"; then
        echo "WARNING: Trivy scan did not complete for $IMAGE"
        echo "         (build is unaffected; scan is advisory only)"
    fi

    return 0
}

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

    # Scan the freshly loaded local image (via the Docker socket).
    scan_image local "$PLATFORM"
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
