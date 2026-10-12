#!/usr/bin/env bash
#
# Security-scan a freshly built image with Trivy, failing the workflow on a
# fixable CRITICAL/HIGH finding (lower severities and CVEs without a fix are
# reported but don't block).
#
# Usage (the "Security scan (Trivy)" step, between banner and push):
#   bash .github/scripts/trivy-scan.sh "$IMAGE:latest" \
#     [--ignorefile <name>/.trivyignore] [--skip-files '<glob>'] ...
#
# Extra arguments are passed to `trivy image` as-is. Installs a PINNED Trivy
# release into $HOME/.local/bin (once per runner; reused if the same version
# is already there) and verifies the tarball against the sha256 recorded
# below -- instead of piping the unpinned install.sh from Trivy's main branch
# into sh in every workflow. To upgrade: bump TRIVY_VERSION and TRIVY_SHA256
# (from the release's trivy_<v>_checksums.txt, Linux-64bit.tar.gz line).
set -euo pipefail

TRIVY_VERSION=0.75.0
TRIVY_SHA256=c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f

[ $# -ge 1 ] || { echo "usage: $0 <image:tag> [extra trivy image args...]" >&2; exit 2; }
IMAGE=$1
shift

BINDIR="$HOME/.local/bin"
TRIVY="$BINDIR/trivy"

INSTALLED=$("$TRIVY" --version 2>/dev/null || true)
case "$INSTALLED" in
  *"Version: $TRIVY_VERSION"*) ;;
  *)
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    TARBALL="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
    curl -sSfL -o "$TMP/$TARBALL" \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/$TARBALL"
    echo "$TRIVY_SHA256  $TMP/$TARBALL" | sha256sum -c --quiet - \
      || { echo "trivy-scan: checksum mismatch for $TARBALL" >&2; exit 1; }
    tar -xzf "$TMP/$TARBALL" -C "$TMP" trivy
    mkdir -p "$BINDIR"
    install -m 0755 "$TMP/trivy" "$TRIVY"
    ;;
esac
"$TRIVY" --version | sed -n 1p

# Fetch the vulnerability DB up front, retrying and then falling back to
# ghcr.io explicitly. Trivy's own --db-repository default already lists
# ghcr.io after mirror.gcr.io, but that fallback did not kick in on
# 2026-10-08/09: mirror.gcr.io served the DB manifest and then 404'd the
# layer, which failed the scan (and so the build) outright.
DB_OK=
for repo in mirror.gcr.io/aquasec/trivy-db:2 ghcr.io/aquasecurity/trivy-db:2; do
  for attempt in 1 2; do
    if "$TRIVY" image --download-db-only --no-progress --db-repository "$repo"; then
      DB_OK=1
      break 2
    fi
    echo "trivy-scan: DB download from $repo failed (attempt $attempt)" >&2
    sleep 10
  done
done
[ -n "$DB_OK" ] || { echo "trivy-scan: could not download the vulnerability DB" >&2; exit 1; }

"$TRIVY" image \
  --skip-db-update \
  --severity CRITICAL,HIGH \
  --ignore-unfixed \
  --exit-code 1 \
  --no-progress \
  "$@" \
  "$IMAGE"
