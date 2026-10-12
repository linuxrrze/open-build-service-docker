# open-build-service-backend

Self-contained Docker image for the [Open Build Service](https://openbuildservice.org/)
backend -- the source server, repo server, scheduler, dispatcher, signer and
workers (all the non-Rails pieces) -- built via GitHub Actions, see
[`.github/workflows/open-build-service-backend-rebuild.yml`](../.github/workflows/open-build-service-backend-rebuild.yml).

Also used, unmodified, as the `worker` image in
[`open-build-service/docker-compose.yml.sample`](../open-build-service/docker-compose.yml.sample)
(same image, different `command:`).

The image **bakes the pinned open-build-service release's `src/backend` +
`contrib` into `/obs`** so it needs **no host-side git checkout** to run.

## How it's built

openSUSE's base image `backend:210` ships the Perl *runtime* (`bs_srcserver` &
co under `/usr/lib/obs/server`, `signd`, the source-service Perl libs) but **not**
the OBS source tree the start scripts run from -- the backend scripts resolve
their modules from the source tree (each does `unshift @INC, "$wd"` in a
`BEGIN` block), so the real source must be present. The build:

1. Reads the version openSUSE pinned into the `:210` runtime (from
   `OBS:Server:2.10`'s `obs-server` `_service`) and rebuilds whenever the
   `:210` image digest changes (polled anonymously via the registry v2 API)
   -- nightly only then; a push touching `open-build-service-backend/docker/`,
   `open-build-service/config/` or the workflow (and a manual run) always
   rebuilds.
   Pinning the baked source to that same version keeps runtime and source
   aligned -- the same release line by openSUSE's own design, and it matches
   whatever the frontend image bakes in.
2. Clones that release tag (without the `src/backend/build` obs-build
   submodule: the Dockerfile symlinks `build/` to the base image's packaged,
   current obs-build in `/usr/lib/build`, as upstream's obs-server rpm does --
   the submodule pin is years stale and can't read modern `.deb`s).
3. Stages this repo's `open-build-service/config/start_prod_backend` into the
   clone (and drops upstream's `src/backend/t` + `testdata` test suite), then
   builds `open-build-service-backend/docker/Dockerfile` (context = the clone):
   applies the base repos' pending security patches and `zypper install`s the
   source-service packages (one layer, zypper cache cleaned), `COPY
   src/backend/`, `COPY contrib/`, the start script, and the runtime entrypoint.
4. Trivy-scans, pushes `:<version>`, `:<version>-<YYYYMMDD>` (kept for
   rollback -- a base rebuild re-publishes `:<version>`) and `:latest`,
   records the digest.

## Runtime entrypoint (`obs-entry`)

`/usr/local/bin/obs-entry` runs before the requested command. The baked source
ships only `BSConfig.pm.template`, so on every start it regenerates
`/obs/src/backend/BSConfig.pm` with the substitutions our previous deploy used
(service user `obsrun`, hostname from `$OBS_BACKEND_HOST` defaulting to
`backend`, ipaccess neutralized). This is what lets the `worker` service (a
separate container with its own baked `/obs`) seed its own config and point at
the `backend` container. `CMD` is
`/obs/contrib/start_prod_backend -d /obs -h backend -l /logs`.

`start_prod_backend` is a small wrapper that runs upstream's
`start_development_backend` unchanged, plus signing setup, the scheduler
manager and the worker sweep.

**Schedulers follow the web UI's "Architecture Availability"** (Admin >
Architectures); there is no `.env` setting.
- **How changes arrive:** the UI stores availability in the database and
  immediately rewrites `<schedulers>` in `/srv/obs/configuration.xml`.
- **What the manager does:** every 30 seconds `obs-sched-manager` compares
  that list with the running schedulers (so several quick UI changes are all
  applied). It starts `bs_sched <arch>` for every
  listed architecture that isn't running, and stops (same exit event as `bs_sched --stop`, which
  saves the state) every running scheduler that isn't listed. That includes
  the i586/x86_64 ones upstream always starts. Changes apply within about 30
  seconds. A scheduler still in its initial startup ignores exit events, so the
  manager re-sends the event until it exits, and sends `SIGTERM` only after 15
  minutes.
- **Crashed schedulers** of listed architectures are restarted, with backoff
  while one keeps dying shortly after start (30 s, doubling up to 30 min).
- **Only one direction:** the database (UI) is the only source; nothing
  writes availability back. Upstream's frontend normally re-enables every
  architecture whose scheduler the backend reports, stopped ones included (its
  30-second worker-status job, `WorkerStatus#parse_daemon_infos`, marked
  "FIXME2.5 … gross hack" upstream). `zz_container.rb` in the frontend
  disables that. The manager also removes the leftover
  `bs_sched.<arch>.lock` of disabled, stopped schedulers, so they don't show
  up as "dead" on the monitor.
- **If the file is missing:** the manager changes nothing (the frontend writes
  it on start).
- **Logs:** `obs-sched-manager: …` in the backend log, and
  `/logs/bs_sched_<arch>.log` per scheduler.

Busy workers that are gone are released by `/usr/local/bin/obs-reap-jobs`,
which runs in the same 5-minute sweep. This covers a worker container
recreated while building, e.g. when OBS was shut down mid-build: it comes back
under a new id, so its job would stay "building" and its old id would stay
busy on the monitor forever.
- **Liveness check:** for every job in state `building` it asks the recorded
  worker `GET <uri>/worker?jobid=<jobid>`, which only succeeds while that worker
  is alive and still building that job.
- **Release:** after two failed checks in a row (about 5 minutes apart) it
  hands the job back with upstream's own
  `POST /jobs/<arch>/<job>?cmd=idleworker` on the repserver (the call a
  restarting worker makes; it only resets the job if worker id and job id
  match) and removes the worker's `building/` entry. The dispatcher then
  schedules the build again.
- **Log:** released jobs show up as `obs-reap-jobs: released …` in the backend
  log.
- **Upgrade guard:** the image build fails if the upstream routes it relies on
  change.
On every start it also makes everything under `/srv/obs` owned by
`obsrun:obsrun` (the services' account), so a fresh docker volume, a restored
backup or files created as root don't break the services. Only entries with
the wrong owner are changed (`find ... -exec chown -h`), not the whole tree.

**Signing** (`OBS_SIGN*` in `.env`, default on). `start_prod_backend` sets it up
the way upstream's appliance does (`dist/setup-appliance.sh`,
`prepare_obssigner`):
- **Key:** kept in `/srv/obs/gnupg` (root-only; the one exception to the
  ownership fix), generated without a passphrase on first start if missing.
- **Public key:** exported to `/srv/obs/obs-default-gpg.asc` and set as
  `$keyfile`.
- **Config:** writes `/etc/sign.conf` for `signd`, and enables
  `$forceprojectkeys` (`OBS_SIGN_FORCE_PROJECT_KEYS`).
- **Upstream's part:** upstream's start script enables `$sign` and starts
  `signd`. `/usr/bin/sign` is setuid root (Dockerfile).
- **Digest:** `hash: sha256` (`OBS_SIGN_HASH`) in `sign.conf`. The `sign` tool
  defaults to SHA1, which current apt/rpm reject ("untrusted digest algorithm:
  SHA1"). Repositories published before a change keep their old signature
  until republished:
  `docker compose exec -u obsrun backend /obs/src/backend/bs_admin --republish-repository <project> <repository>`
- **Off:** `OBS_SIGN=0` removes `$sign`, so jobs skip the signer.


## Files

| File | Used by CI? | Purpose |
| --- | --- | --- |
| `docker/Dockerfile` | yes | Bakes the pinned `src/backend` + `contrib` + `start_prod_backend` into the runtime base; installs source-service packages; sets the `obs-entry` entrypoint. |
| `docker/files/obs-entry.sh` | yes | Runtime entrypoint that seeds `BSConfig.pm` from its template on each start, then execs the command. |
| `docker/files/obs-reap-jobs` | yes | Releases build jobs whose worker is gone (see above); run every 5 minutes by `start_prod_backend`. |
| `docker/files/obs-sched-manager` | yes | Starts/stops `bs_sched <arch>` to match `<schedulers>` in `configuration.xml` (the UI's Architecture Availability); run by `start_prod_backend`. |
| `.open-build-service-backend-version` | yes | Last upstream `Docker-Content-Digest` CI built against (not the human-readable version -- that's derived fresh each run and used for the tag, the commit message, and the source clone). Updated automatically by CI. |
