# open-build-service-frontend

Self-contained Docker image for the [Open Build Service](https://openbuildservice.org/)
Rails frontend/API, built via GitHub Actions -- see
[`.github/workflows/open-build-service-frontend-rebuild.yml`](../.github/workflows/open-build-service-frontend-rebuild.yml).

The image **bakes the pinned open-build-service release's `src/api` into
`/obs/src/api`** and runs under `RAILS_ENV=production`, so it needs **no
host-side git checkout** to run (unlike the previous runtime-only design -- see
[`open-build-service/README.md`](../open-build-service/README.md)).

## How it's built

openSUSE's base image `frontend-base:210` is *runtime-only*: the
Ruby/Rails + Node toolchain, a `frontend` user (uid 1000, group `users`) and an
**empty** `/obs/src/api` stub, but not the application source. (Not
`frontend-features:210`: that is the same image plus chromedriver/chromium for
upstream's feature tests, a ~400 MB compressed layer production never uses.)
The build:

1. Reads the version openSUSE pinned into the `:210` runtime (from
   `OBS:Server:2.10`'s `obs-server` `_service` -- the same source of truth as
   the backend image, so both always bake the same release) plus the digest of
   the Dockerfile's `FROM` image, and tracks both as `<version>@<digest>`: an
   openSUSE rebuild of the base (security fixes under the same `:210` tag)
   rebuilds this image too.
2. Clones that exact release tag.
3. Adds this repo's `open-build-service/config/` files to the source --
   without replacing any upstream file: `database.yml`, `thinking_sphinx.yml`
   + `no_ssl.cnf`, the `zz_container.rb` initializer (static files,
   `OBS_PROXY_AUTH_*` env overrides, `SECRET_KEY_BASE` check), and
   `options.yml` = upstream's `options.yml.example` + our
   `options.production.yml` block. Drops upstream's `spec/` and `test/`
   suites from the build context (never used at runtime).
4. Builds `open-build-service-frontend/docker/Dockerfile` with the clone as
   context: `gem install foreman`, then -- as `frontend` -- `bundle install`
   from just `Gemfile`/`Gemfile.lock`/`vendor/cache` (same flags as upstream's
   own Dockerfile, without the `test` group), `COPY --chown` of `src/api/`,
   and `rails assets:precompile` under `RAILS_ENV=production` (with a
   build-time dummy `SECRET_KEY_BASE`). Gems come before the source, so a
   config-only rebuild reuses the gem layer from the build cache.
5. Trivy-scans, pushes `:<version>`, `:<version>-<YYYYMMDD>` (kept for
   rollback -- a base rebuild re-publishes `:<version>`) and `:latest`,
   records `<version>@<digest>`.

Nightly runs only build when the version or base digest changed; a push that
touches `open-build-service-frontend/docker/` or `.trivyignore`,
`open-build-service/config/` or the workflow (and a manual run) always
rebuilds.

`CMD` is `foreman start -f Procfile -p 3000` (web + delayed_job + clock +
search). The compose file runs the idempotent `db:migrate:with_data` on start
(OBS's data_migrate gem needs the combined task -- see the compose file
comment), then the same foreman command.

There is no custom `ENTRYPOINT`. OBS loads `options.yml` with a plain
`YAML.load_file` (no ERB) into the `CONFIG` hash *before* the initializers run,
so `zz_container.rb` applies the `OBS_PROXY_AUTH_*` env overrides to `CONFIG`
directly. Upstream's `secret_token.rb` requires a `config/secret.key` file; the
image ships a placeholder, Rails 5.2 prefers `ENV["SECRET_KEY_BASE"]`, and
`zz_container.rb` refuses to boot in production without it.

## First deploy -- verify the asset precompile

`rails assets:precompile` is the one build step that can't be exercised without
a docker daemon. If it fails on a missing key/env, add the specific
requirement to the Dockerfile (e.g. a `RAILS_MASTER_KEY`, a `NODE_OPTIONS`
tweak, or run precompile as the `frontend` user). The image tag in the registry
is what gets tested -- the CI build either succeeds or the workflow fails, so a
published image has already precompiled cleanly.


## Files

| File | Used by CI? | Purpose |
| --- | --- | --- |
| `docker/Dockerfile` | yes | Bakes the pinned `src/api` + config overrides into the runtime base; precompiles assets; runs as `frontend`. |
| `.open-build-service-frontend-version` | yes | Last `<release>@<base image digest>` (e.g. `2.10.34@sha256:...`) CI built. Updated automatically by CI. |
