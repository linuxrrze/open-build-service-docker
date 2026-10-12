#!/usr/bin/env bash
#
# Add a startup banner to a freshly built image: the image name in line 1,
# its version in line 2, figlet style, printed on every container start.
#
# Usage (right after the workflow's `docker build`, with the same tags):
#   bash .github/scripts/add-banner.sh "$IMAGE:<version tag>" "$IMAGE:latest" ...
#
# The first tag decides the text: line 1 = repository basename (e.g.
# "samba-dc"), line 2 = its tag (the version). The banner is rendered HERE, on
# the CI runner (figlet installed on the runner only, plain-text fallback), and
# added as a thin layer on top of the built image -- no figlet, and no change
# to the image's own Dockerfile:
#   FROM <built image>
#   /usr/local/share/image-banner.txt   the rendered text
#   /usr/local/bin/image-banner         cat the text, then exec "$@"
#   ENTRYPOINT ["/usr/local/bin/image-banner", <original ENTRYPOINT...>]
#   CMD <original CMD>        (a child ENTRYPOINT resets the inherited CMD)
# The original ENTRYPOINT/CMD are read from the built image, so every image
# keeps its exact start command (exec keeps e.g. s6's /init as PID 1). All
# given tags are re-pointed to the result. Images without /bin/sh (FROM
# scratch) can't run the wrapper: they are left unchanged, with a notice.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <image:tag> [<image:tag>...]" >&2; exit 2; }
BASE=$1
NAME=${BASE%:*}; NAME=${NAME##*/}
VERSION=${BASE##*:}

if ! docker run --rm --entrypoint /bin/sh "$BASE" -c true >/dev/null 2>&1; then
  echo "add-banner: $BASE has no /bin/sh (FROM scratch?) -- no startup banner"
  exit 0
fi

CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT

if ! command -v figlet >/dev/null 2>&1; then
  { apt-get update -qq && apt-get install -y -qq figlet; } >/dev/null 2>&1 \
    || { sudo apt-get update -qq && sudo apt-get install -y -qq figlet; } >/dev/null 2>&1 \
    || echo "add-banner: figlet not installable -- plain-text banner"
fi
if command -v figlet >/dev/null 2>&1; then
  # -w: wide enough that long image names stay on one line
  { figlet -w 240 "$NAME"; figlet -w 240 "$VERSION"; } > "$CTX/image-banner.txt"
else
  printf '%s\n%s\n' "$NAME" "$VERSION" > "$CTX/image-banner.txt"
fi
cat "$CTX/image-banner.txt"

cat > "$CTX/image-banner" <<'EOF'
#!/bin/sh
# Startup banner (added by CI, .github/scripts/add-banner.sh), then the
# image's original entrypoint/command.
cat /usr/local/share/image-banner.txt 2>/dev/null
# No command at all (neither ENTRYPOINT nor CMD): just the banner, exit 0
# (`[ $# -gt 0 ] && exec "$@"` as the last line would exit 1 here).
[ $# -eq 0 ] && exit 0
exec "$@"
EOF

ENTRYPOINT=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$BASE")
CMD=$(docker image inspect --format '{{json .Config.Cmd}}' "$BASE")
case "$ENTRYPOINT" in
  *'"/usr/local/bin/image-banner"'*)
    echo "add-banner: $BASE already has the banner entrypoint -- nothing to do"
    exit 0 ;;
  null|'[]') NEW_ENTRYPOINT='["/usr/local/bin/image-banner"]' ;;
  '['*) NEW_ENTRYPOINT="[\"/usr/local/bin/image-banner\",${ENTRYPOINT#[}" ;;
  *) echo "add-banner: unexpected ENTRYPOINT $ENTRYPOINT" >&2; exit 1 ;;
esac

{
  echo "FROM $BASE"
  echo "COPY --chmod=0644 image-banner.txt /usr/local/share/image-banner.txt"
  echo "COPY --chmod=0755 image-banner /usr/local/bin/image-banner"
  echo "ENTRYPOINT $NEW_ENTRYPOINT"
  case "$CMD" in null|'[]') ;; *) echo "CMD $CMD" ;; esac
} > "$CTX/Dockerfile"

TAGS=()
for t in "$@"; do TAGS+=(-t "$t"); done
docker build -q "${TAGS[@]}" "$CTX" >/dev/null
echo "add-banner: $* now start with the banner (ENTRYPOINT $NEW_ENTRYPOINT${CMD:+, CMD $CMD})"
