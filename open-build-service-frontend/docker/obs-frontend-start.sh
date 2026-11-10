#!/usr/bin/env bash
# Frontend start command (the image's CMD): migrate the database, sync the
# instance configuration to the backend, then run foreman (Procfile: web +
# delayed_job + clock + search). Runs after obs-frontend-entry (stale pid-file
# cleanup). Kept in the image rather than in the compose file's `command:` so
# a deployment's own docker-compose.yml never runs an outdated copy of it --
# a `docker compose pull` is enough to get changes. Services that use this
# image for something else (frontend-token) set their own `command:` and skip
# all of this.
set -euo pipefail

cd /obs/src/api

# OBS uses the data_migrate gem: schema and data migrations are separate
# tracks, and schema migration 20170306084558 refuses to run until its paired
# data migration 20170306084550 is recorded. Running plain `db:migrate` then
# `data:migrate` separately hits that guard, so use the combined task, which
# runs both in version order. Idempotent; on a fresh database it creates the
# schema.
bin/rails db:migrate:with_data

# obs_sync_configuration.rb writes configuration.xml to the backend's source
# server. Compose only orders container *starts*, so the source server may not
# be listening yet; without this wait the sync would fail, the warning below
# would scroll by, and .env changes wouldn't reach the backend until the next
# restart. Host/port match options.production.yml's source_host and upstream's
# default source_port. Give up after OBS_BACKEND_WAIT seconds and start anyway:
# the web UI doesn't need the backend to come up.
backend_host=${OBS_BACKEND_HOST:-backend}
backend_port=${OBS_BACKEND_PORT:-5352}
wait_max=${OBS_BACKEND_WAIT:-300}
waited=0
until (exec 3<>"/dev/tcp/$backend_host/$backend_port") 2>/dev/null; do
  if [ "$waited" -ge "$wait_max" ]; then
    echo "obs-frontend-start: backend $backend_host:$backend_port not reachable after ${wait_max}s -- continuing" >&2
    break
  fi
  [ "$waited" -eq 0 ] && echo "obs-frontend-start: waiting for backend $backend_host:$backend_port ..."
  sleep 2
  waited=$((waited + 2))
done

# Write the instance configuration (name, scheduler architectures from the
# UI's Architecture Availability, ...) to the backend's configuration.xml --
# OBS itself only does that when an admin saves the configuration page.
bin/rails runner script/obs_sync_configuration.rb \
  || echo "WARNING: could not write configuration.xml to the backend" >&2

exec foreman start -f Procfile -p 3000
