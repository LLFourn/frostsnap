#!/usr/bin/env bash
# Usage: tools/repro/linux/run.sh [--platform <docker-platform>] <work-dir> -- <repro arguments>
#
# Runs `repro <arguments>` inside the pinned container image, with every apt
# package from the pinned snapshot. This is how to build or verify the Linux
# app on any Docker host; CI and the Lima VMs run it too.
#
# <work-dir> is mounted at the same path inside the container, so firmware,
# --out and --against paths under it work as written. For example:
#
#   tools/repro/linux/run.sh ~/repro -- verify linux --commit v0.5.0 --env prod \
#       --firmware ~/repro/firmware.bin --out ~/repro/out --against ~/repro/frostsnap
#
# --platform (for example linux/amd64) defaults to the host's.
set -euo pipefail

platform=
if [ "${1:-}" = --platform ]; then
    platform=$2
    shift 2
fi
[ $# -ge 2 ] && [ "$2" = -- ] || {
    echo "usage: $0 [--platform <docker-platform>] <work-dir> -- <repro arguments>" >&2
    exit 2
}
mkdir -p "$1"
work=$(realpath "$1")
shift 2

repo=$(git rev-parse --show-toplevel)
git_dir=$(cd "$repo" && realpath "$(git rev-parse --git-common-dir)")
config=$repo/tools/repro/repro.toml

image=$(sed -n 's/^image = "\(.*\)"$/\1/p' "$config")
snapshot=$(sed -n 's/^apt_snapshot = "\(.*\)"$/\1/p' "$config")
packages=$(sed -n '/^\[linux\.packages\]$/,/^\[/s/^\([a-z0-9.+-]*\) = "\(.*\)"$/\1=\2/p' "$config" | tr '\n' ' ')
[ -n "$image" ] && [ -n "$snapshot" ] && [ -n "$packages" ] || {
    echo "could not read linux.image, linux.apt_snapshot or linux.packages from $config" >&2
    exit 1
}

# The repo is mounted read-only so nothing in the container can change the
# checkout; repro builds from `git archive <commit>` anyway. Its git directory
# is mounted at its own path too, which a worktree's `.git` file points to.
docker run --rm ${platform:+--platform "$platform"} \
    -v "$repo:/src:ro" \
    -v "$git_dir:$git_dir:ro" \
    -v "$work:$work" \
    -v /etc/ssl/certs/ca-certificates.crt:/host-ca.crt:ro \
    -e SNAPSHOT="$snapshot" \
    -e PACKAGES="$packages" \
    "$image" bash /src/tools/repro/linux/in-container.sh "$@"
