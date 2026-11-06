#!/usr/bin/env bash
# Runs inside the pinned image with repro's arguments; see run.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Every package comes from one snapshot of the archive. The source is
# written out rather than using `apt-get --snapshot`, because the arm64 image
# points at ports.ubuntu.com, which the snapshot service doesn't mirror; its
# main archive carries every architecture.
rm -f /etc/apt/sources.list.d/ubuntu.sources
for suite in noble noble-updates noble-security; do
    echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://snapshot.ubuntu.com/ubuntu/$SNAPSHOT $suite main universe"
done > /etc/apt/sources.list.d/snapshot.list

# The image has no CA bundle and the snapshot service is HTTPS-only, so apt
# trusts the host's bundle until the pinned ca-certificates is installed.
# Packages are still verified by the archive's signatures.
apt=(apt-get -qq -o Acquire::https::CAInfo=/host-ca.crt)
"${apt[@]}" update
# shellcheck disable=SC2086
"${apt[@]}" install -y --no-install-recommends $PACKAGES

# System-wide, because repro runs git with its own HOME.
git config --system --add safe.directory /src
# The tool is built with the Rust that repro.toml pins for this host, from
# tarballs checked against their sha256, so nothing unverified builds the
# program that does the checking.
triple=$(uname -m)-unknown-linux-gnu
pins=$(sed -n "/^$triple = \[\$/,/^\]\$/s/.*url = \"\([^\"]*\)\", sha256 = \"\([0-9a-f]*\)\".*/\1 \2/p" /src/tools/repro/repro.toml)
mkdir -p /tmp/rust-dl
for component in rustc rust-std cargo; do
    read -r url sha256 <<<"$(grep "/$component-" <<<"$pins")"
    [ -n "$url" ] || { echo "no $component pin for $triple in repro.toml" >&2; exit 1; }
    file=/tmp/rust-dl/$(basename "$url")
    curl -sSf -o "$file" "$url"
    echo "$sha256  $file" | sha256sum -c --quiet -
    tar -xJf "$file" -C /tmp/rust-dl
    sh "/tmp/rust-dl/$(basename "$file" .tar.xz)/install.sh" --prefix=/tmp/rust --disable-ldconfig >/dev/null
done
PATH=/tmp/rust/bin:$PATH CARGO_TARGET_DIR=/tmp/repro-target CARGO_HOME=/tmp/cargo-home cargo build -q --locked --release \
    --manifest-path /src/tools/repro/Cargo.toml

cd /src
exec /tmp/repro-target/release/repro "$@"
