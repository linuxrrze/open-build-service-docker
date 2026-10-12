# open-build-service

Multi-service deployment of [Open Build Service](https://openbuildservice.org/)
(OBS), built from the two images in this repository:
[`open-build-service-frontend`](../open-build-service-frontend/) and
[`open-build-service-backend`](../open-build-service-backend/), published to
`ghcr.io/<owner>/` by this repo's GitHub Actions workflows.

## Architecture: self-contained images, production environment

The `frontend`/`backend` images ([`../open-build-service-frontend/`](../open-build-service-frontend/)
and [`../open-build-service-backend/`](../open-build-service-backend/)) bake the
**pinned open-build-service release's source** into the image at build time
and run the frontend under `RAILS_ENV=production` (assets precompiled in the
image, secrets/hostnames from `.env`). openSUSE's own `frontend-base:210`
/ `backend:210` base images are *runtime-only* (toolchain + Perl/Ruby libs, an
empty `/obs` stub) -- the source normally comes from a bind mount, so this repo
instead clones the release in CI and `COPY`s it in.

**Consequences for deployment:**
- **No host-side git checkout.** The only host paths in
  `docker-compose.yml.sample` are the *data* mounts: `./fs/backend/srv/obs`
  (the build service data), `./fs/mariadb/var/lib/mysql` (the database), and
  `./fs/logs`. Update OBS by **rebuilding the images** (this repo's CI does
  that automatically), not by `git pull`ing a checkout.
- **Production frontend, upstream files untouched.** CI only *adds* files
  from this repo's `config/` to the source (`database.yml`, `thinking_sphinx.yml`,
  `no_ssl.cnf`, the `zz_container.rb` initializer) and builds `options.yml` as
  upstream's `.example` + our short `options.production.yml` block, so the app
  runs as `production` with `secret_key_base` from `SECRET_KEY_BASE` and new
  upstream releases need no re-merging of overridden files.
- **Backend & worker** share the backend image (different `command:`). The
  image's `obs-entry` entrypoint regenerates `/obs/src/backend/BSConfig.pm`
  from its `.template` on every start (service user `obsrun`, hostname
  `backend`), since each container has its own baked `/obs`.
- **Versions stay aligned** by design: the backend workflow pins the source it
  bakes in to the exact release openSUSE built the `backend:210` runtime from
  (read from `OBS:Server:2.10`'s `obs-server` `_service`), and the frontend
  tracks the same release-tag series -- so both images carry 2.10.x together.

## Persistent data -- what to actually back up

All of this is bind-mounted from `docker-compose.yml.sample`, none of it lives
in an image, none of it is tracked by this repo (the `fs/` paths are covered by
this repo's blanket `**/fs/` gitignore rule). If you only back up one of these,
back up `fs/backend/srv/obs` -- it's the actual product of running a build
service.

| Host path | Mounted into | Contains | If you lose it... |
| --- | --- | --- | --- |
| `./fs/backend/srv/obs` | `backend` (at `/srv/obs`), `obs-download` (the `repos` subdir) | **The actual build service data**: every project's sources, build results, published repos. This is what OBS *is*. | Every package ever built, gone. Back this up like you mean it. |
| `./fs/mariadb/var/lib/mysql` | `obs-mariadb` | The application database: projects, packages, users, permissions, request history. | Total loss of all project/user metadata (the build artifacts in `fs/backend/srv/obs` would still exist, but OBS would have no record of them). |
| `./fs/logs` | `backend`, `worker` | Backend service logs (`bs_srcserver.log`, `bs_repserver.log`, `bs_dispatch.log`, ...). | Just lose history for debugging -- not load-bearing. |

The application code itself is **not** a bind mount anymore -- it's baked into
the images, so there's nothing to back up or `git pull` for it.

## One-time deploy (fresh database)

 1. `cp docker-compose.yml.sample docker-compose.yml && cp .env.sample .env`,
    fill in real values: `OBS_IMAGE_PREFIX` (`ghcr.io/<owner>`, lowercase --
    where this repo's CI pushes the images), a real `MARIADB_PASSWORD`, a real `SECRET_KEY_BASE`
    (generate: `docker run --rm ruby:3 ruby -rsecurerandom -e 'puts
    SecureRandom.hex(64)'`), the real OIDC credentials, and (for OIDC
    deployments) point `OBS_PROXY_AUTH_ACCOUNT_PAGE` /
    `OBS_PROXY_AUTH_REGISTER_PAGE` at your IdP's self-service account page so
    the "Edit your account" link goes somewhere useful.
 2. Bring up the stack: `docker compose up -d`. The frontend runs
    `db:migrate:with_data` on every start (idempotent); on a genuinely fresh
    database that creates the schema. (OBS uses the data_migrate gem, so the
    combined `:with_data` task is required -- running plain `db:migrate` hits
    the paired data-migration guard.)
3. **One-time data seeding** (only on a brand-new database, to create the
   initial `Admin` user and bootstrap data):
   ```
   docker compose run --no-deps --rm frontend \
     bin/rails dev:bootstrap RAILS_ENV=production
   ```
   (This uses the app's own `development` environment for the bootstrap task,
   which is what `rake dev:bootstrap` expects -- the app source is in the
   image, so no checkout is needed.)
 4. Verify: `docker compose ps`, then hit the frontend over your reverse proxy
    (or `curl -H 'Host: obs.example.com' http://localhost:3000` for the
    container port).
 5. **Grant admin to your OIDC user.** The initial `Admin` user from
    `dev:bootstrap` is a placeholder (its password is random / unset). When
    you log in via OIDC, a new user record is created without any roles.
    Promote it with the app's own rake task:
    ```
    docker compose run --no-deps --rm frontend \
      bin/rails user:give_admin_rights <your-oidc-login> RAILS_ENV=production
    ```
    Replace `<your-oidc-login>` with the login name OBS assigned (visible in
    the UI top-right, or find it via:
    `docker compose run --no-deps --rm frontend bin/rails runner 'puts User.where("login LIKE ?", "%your-username%").pluck(:login).inspect' RAILS_ENV=production`).
     The task is idempotent — it won't duplicate the role if the user is
     already admin.

## API access without OIDC (per-user basic auth)

OBS has no bearer/API-key token mechanism: its authenticator supports only
the `X-username` proxy header (what OIDC uses), HTTP Basic `user:password`,
and Kerberos. `proxy_auth_mode` is global per frontend, so the web UI host
stays in proxy mode — but a *second* host, `obs-api.example.com`, lets
scripts/cron jobs authenticate with a plain password instead of going through
Keycloak.

It works because traefik's `basicauth` middleware validates the credentials
and then forwards `X-username:<user>`, which OBS (still in proxy mode)
attributes the API call to. The user list lives in a **shared htpasswd file**
(`./fs/api-htpasswd/obs-api-htpasswd`, read via `basicauth.usersFile`), not
in `.env` — because that file can be edited at runtime and traefik picks up
changes on its file watch. A companion sidecar (`frontend-token`, same
frontend image, small WEBrick script) lets each user manage their **own**
token, so there's no hand-editing in the common case.

### One-time host setup (per deployment, before first `up`)

```
mkdir -p fs/api-htpasswd && chown 1000:1000 fs/api-htpasswd \
  && : > fs/api-htpasswd/obs-api-htpasswd
```

The dir must be writable by the frontend user (uid 1000) because the issuer
writes into it; compose would create a missing bind dir root-owned. The empty
file also gives traefik something to read at t=0 (an empty file 401s
everything, which is the correct "no users yet" state).

### Self-service: issue a token (per user, in the browser)

While logged into the web UI on `obs.example.com`, open
`https://obs.example.com/_obs_api_token`. The page shows whether you have a
token and has **Issue new token** / **Revoke token** buttons. traefik routes
`PathPrefix(/_obs_api_token)` on the web host through the OIDC middleware to the
`frontend-token` sidecar, which takes your identity from the injected
`X-username` header, so you can only ever manage your **own** token.

- **Shown once:** a newly issued token is displayed a single time and never
  stored (only its bcrypt hash, in the htpasswd file). Lost it? Issue a new one;
  that replaces the old one.
- **POST only:** issuing and revoking need a POST with the header
  `X-Requested-With: obs-api-token`. The page sends it; another website can't
  (CSRF protection). For scripts, with your OBS session cookies:
  ```
  curl -b <cookies> -X POST -H 'X-Requested-With: obs-api-token' https://obs.example.com/_obs_api_token         # issue
  curl -b <cookies> -X POST -H 'X-Requested-With: obs-api-token' https://obs.example.com/_obs_api_token/revoke  # revoke
  curl -b <cookies> https://obs.example.com/_obs_api_token/status                                               # {"token_exists": ...}
  ```
- **Only via traefik:** the issuer accepts only requests carrying the
  `X-Obs-Issuer-Secret` header that traefik's `obs-token-issuer` middleware adds
  (`OBS_API_TOKEN_ISSUER_SECRET` in `.env`), so other containers on the docker
  network can't call it with a forged `X-username`.
- **Identity headers are stripped:** every traefik router to OBS or the issuer
  first removes client-sent `X-username`/`X-email`/`X-firstname`/`X-lastname`
  (`obs-strip-identity`). traefikoidc skips headers whose claim is empty, so a
  client-supplied value could otherwise reach OBS, which trusts these headers.
- **Keep port 3000 private:** in proxy-auth mode OBS believes `X-username` from
  anyone who reaches the frontend directly. The sample publishes it on
  `127.0.0.1` only; traefik uses the docker network.

The `<user>` is your OIDC `preferred_username`.

### API calls

```
curl -u alice:'<token>' https://obs-api.example.com/public/source/home:alice
```

A newly issued token is valid immediately — traefik's `basicauth.usersFile`
watches the htpasswd file and reloads it on change, so no traefik restart.

### Manual (no browser / scripted)

If you can't or don't want to use the self-service endpoint, append the user
by hand — same file, same result:

```
htpasswd -Bb fs/api-htpasswd/obs-api-htpasswd '<user>' '<password>'
```

(`-b` batch so `htpasswd` doesn't prompt; `-B` for bcrypt to match what the
issuer writes.) The `<user>` must exactly match that user's OBS login (their
OIDC `preferred_username`), and they must have logged in via OIDC once so the
account exists.

## Importing projects from another OBS instance

OBS has no single "import entire project" API command. Two paths:

**Per-package (native):** register the source as an interconnect project
(admin, name + `remoteurl=https://<source>/public`), then use
*Add New Package Branch* with source `<interconnect>:<project>/<package>`.
This is a *linked* copy that follows upstream revisions until broken.

**Bulk (from a broken source):** if the source's database is unusable and
only its on-disk source tree survives, `migrate-from-srv.sh` reads the raw
backend **content-addressed** layout (`projects/<proj>.xml` for meta,
`projects/<proj>.pkg/<pack>.{mrev,rev,xml}` for packages, and
`trees/<pack>/<md5>-<file>` for source file contents, mapped by the
`<srcmd5>-MD5SUMS` trees) and re-creates projects + packages on *this*
instance via `osc` (`meta prj` / `meta pkg` / `up`). Linked packages are
imported as links (resolved because all projects are imported under their
original names). See the script header for the exact layout + usage; it
supports `--dry-run`, `--list`, `--projects` filtering, and `--tree-layout`
(shared|per-project|sources) for non-default sources. Requires the `osc`
client + `perl` and an account with project-creation rights on the target
(use the API host above).

## Files

| File | Used by CI? | Purpose |
| --- | --- | --- |
| `docker-compose.yml.sample` | no | The full stack: cache (unmodified upstream image), backend, worker (same image as backend), frontend, a `frontend-token` sidecar (API-token issuer, same frontend image), an nginx sidecar serving `/download`, mariadb. No `init` container and no app bind mount -- the images are self-contained. |
| `.env.sample` | no | MariaDB/Rails secrets + OIDC credentials + `OBS_PROXY_AUTH_*` page overrides. No API-host variables -- per-user basic auth is self-service (the `frontend-token` sidecar writes the shared htpasswd file; see "API access without OIDC"). No `OBS_ROOT`. |
| `config/database.yml` | yes (merged into the image by CI) | `production:` block (live under `RAILS_ENV=production`); password from `ENV["MARIADB_PASSWORD"]`. |
| `config/options.production.yml` | yes (appended by CI) | Our `production:` block (backend/frontend/memcached hosts, OIDC proxy auth), appended to upstream's `options.yml.example` to form the image's `options.yml` -- the last duplicate YAML key wins, so all other defaults stay upstream's. |
| `config/zz_container.rb` | yes (added as an initializer by CI) | Container settings without replacing any upstream file: serve `public/` from Rails (Puma is the web server here), apply `OBS_PROXY_AUTH_*` env overrides to `CONFIG`, and require `SECRET_KEY_BASE` in production (the image ships only a placeholder `config/secret.key` for upstream's `secret_token.rb`). Also stops upstream's worker-status job from re-enabling architectures in *Architecture Availability* (`WorkerStatus#parse_daemon_infos`), so the UI setting stays authoritative. And makes the *Architecture Availability* checkboxes work: upstream's page disables the checkbox before jquery_ujs serializes it, so the click request never carries `available` and every click saved `false`; a missing value now toggles the stored one. |
| `config/obs_sync_configuration.rb` | yes (added as `script/` by CI) | Run by the frontend on every start (compose command, after the migrations): syncs `.env` settings (`OBS_NAME`, `OBS_URL`, `OBS_ADMIN_EMAIL`, project-key enforcement from `OBS_SIGN*`) into OBS's configuration and writes `/srv/obs/configuration.xml` to the backend. OBS itself only writes that file when an admin saves the configuration page, so a fresh backend data dir would otherwise have none (Origin `obs://build.some.where/...`, no scheduler list). The scheduler architectures come from the UI's Architecture Availability, not from `.env`. |
| `config/thinking_sphinx.yml` | yes (merged into the image by CI) | thinking-sphinx config; upstream ships only the `.example`. Sets `connection_options.default_file` to `no_ssl.cnf` so the `Mysql2` client reaches in-container searchd's no-SSL MySQL-protocol port (9314) -- without it every Sphinx update (e.g. project deletion) 500s with "SSL is required, but the server does not support it". |
| `config/no_ssl.cnf` | yes (merged into the image by CI) | MariaDB client option file (`ssl-verify-server-cert=0`) for the searchd connection only. The base image's libmariadb3 >= 3.4 verifies server certs by default and, while doing so, forces TLS; mysql2 0.5.2's `ssl_mode` is a no-op on libmariadb, and `ssl-enforce=0`/`ssl=0`/`skip-ssl` are overridden. Disabling verification lets the client fall back to plaintext. Scoped via `default_file` rather than the global `MARIADB_TLS_DISABLE_PEER_VERIFICATION` env var, which would also affect Rails' real DB connection. |
| `../open-build-service-frontend/docker/obs_api_token.rb` | yes (baked into the frontend image) | The API-token issuer: a small WEBrick service run by the `frontend-token` compose service (see "API access without OIDC" above). Logged-in users open `/_obs_api_token` to issue (shown once, never stored) or revoke their own token via POST; its bcrypt hash is written to the shared htpasswd file that traefik's `obs-api` basicauth reads. Accepts only requests carrying traefik's `X-Obs-Issuer-Secret`. |
| `config/start_prod_backend` | yes (baked into the backend image) | Wrapper: runs upstream's `contrib/start_development_backend` unchanged, plus signing setup, `obs-sched-manager` (schedulers follow the UI's Architecture Availability) and the worker/job sweep. |
| `migrate-from-srv.sh` | no | Imports projects/packages from a source OBS whose DB is broken, reading its raw `/srv/obs` tree and re-creating them on the target via `osc`. Idempotent; `--dry-run`/`--list`/`--projects`. |
