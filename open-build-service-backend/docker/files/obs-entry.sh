#!/usr/bin/env bash
# Backend/worker runtime entrypoint. The image bakes the OBS source into /obs
# (no host checkout), so on every start we regenerate /obs/src/backend/BSConfig.pm
# from its .template with the same substitutions our previous deploy used:
#   - service user "obsrun" (the base image's obs service account)
#   - hostname "$OBS_BACKEND_HOST" (default "backend") so $srcserver/$reposerver
#     point at the backend container; the worker uses the same value to reach it
#   - ipaccess neutralized (the old start script did this too)
# Then exec the requested command (start_prod_backend for the backend service,
# start_development_worker for the worker service).
set -euo pipefail

GIT_HOME="/obs"
BS_CFG="$GIT_HOME/src/backend/BSConfig.pm"
DEVHOST="${OBS_BACKEND_HOST:-backend}"

cp "$GIT_HOME/src/backend/BSConfig.pm.template" "$BS_CFG"
perl -pi -e 's/our \$bsserviceuser.*/our \$bsserviceuser="obsrun";/' "$BS_CFG"
perl -pi -e "s/my \\\$hostname.*/my \\\$hostname=\"$DEVHOST\";/" "$BS_CFG"
perl -pi -e 's/\$ipaccess/\$removed_by_obs_entry /' "$BS_CFG"

# The services' crit loggers write to $logdir ("$bsdir/log" = /srv/obs/log,
# owned by $bsuser/$bsgroup = obsrun, per BSConfig.pm.template), but nothing
# creates it on a fresh data dir -- the first crit write would then die with
# "scheduler_<arch>.crit.log: No such file or directory". The worker has no
# /srv/obs mount, so only do this where the data dir exists.
[ -d /srv/obs ] && install -d -o obsrun -g obsrun /srv/obs/log

# Everything under the data dir belongs to the obs service account
# ($bsuser/$bsgroup = obsrun). A bind mount / docker volume can bring in
# root- or foreign-uid-owned files (fresh volume, restored backup, files
# created by `docker compose exec` as root), which the services -- running as
# obsrun -- then can't write. Only touch entries that are wrong (a full
# `chown -R` would rewrite every inode of a potentially huge tree on each
# start); -h changes symlinks themselves, never their targets.
# One exception: /srv/obs/gnupg (the signing key) stays root-only, as in
# upstream's appliance -- only signd (root) may read the private key; see
# start_prod_backend.
if [ -d /srv/obs ]; then
  find /srv/obs -path /srv/obs/gnupg -prune -o \
    \( ! -user obsrun -o ! -group obsrun \) -exec chown -h obsrun:obsrun {} + \
    || echo "obs-entry: WARNING: could not fix ownership of everything under /srv/obs" >&2
fi

exec "$@"
