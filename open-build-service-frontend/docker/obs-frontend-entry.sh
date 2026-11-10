#!/usr/bin/env bash
# Frontend runtime entrypoint: drop stale pid files, then exec the requested
# command (the image's foreman CMD, or the compose service's `command:`).
#
# The container's writable layer -- and with it every pid file -- survives a
# stop/start of the same container. searchd's (thinking-sphinx's default
# log/production.sphinx.pid) is fatal: foreman's SIGTERM kills searchd without
# it cleaning up, and the Procfile's `search` process (ts:rebuild
# NODETACH=true) forks a child that execs searchd only if riddle's running?
# check is false. That check reads the pid file and tests the PID with
# kill -0. Because searchd was exec'd from that same forked child last time,
# the stale PID *is* the child's PID, and a container restarts its processes
# in the same order -- so on the next start the child usually gets that PID
# again and finds itself "running". It then skips the exec and falls through
# to Process.wait(nil) ("TypeError: no implicit conversion from nil to
# integer"), `search` exits, and foreman tears down the whole frontend.
#
# Unconditional and cheap: every container using this image (frontend,
# frontend-token, a `compose run`) has its own writable layer, and nothing
# legitimately running exists yet when the entrypoint runs. `docker exec`
# doesn't go through the entrypoint.
set -euo pipefail

rm -f /obs/src/api/tmp/pids/*.pid /obs/src/api/log/*.sphinx.pid

exec "$@"
