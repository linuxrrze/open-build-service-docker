# open-build-service — outstanding issues

Three items below. **Fix 1** and **Fix 2** were the original "TODO" items (still
open); **Fix 3** (project delete 500s with a thinking-sphinx SSL error) is
**DONE**.

---

## Fix 1: `bs_sched` crashes on "cold start, scanning all projects"

**Status: fixed differently, awaiting CI rebuild + host verification.** The
root problem is broader than `expandpreinstalls`: the whole obs-build
submodule pin (2017) is stale -- its `Build/Deb.pm` also only accepts
`control.tar.gz`, so every modern Debian/Ubuntu build fails in
init_buildsystem with "control.tar.gz is not second ar entry / bad binary"
(Ubuntu uses `control.tar.zst`). Upstream never runs that pin in production:
the obs-server rpm symlinks `build` -> `/usr/lib/build` (dist/obs-server.spec,
`Requires: build >= 20200110`), and the base image ships `build-20260901`. The
backend Dockerfile now does the same symlink; the submodule init and the
earlier `d81d3353` backport patch are gone. The analysis below is kept for
reference. The missing `/srv/obs/log` is created by `obs-entry.sh`.

**Symptom** (backend container, `bs_sched_x86_64.log`):
```
cold start, scanning all projects
getting data for all projects from http://backend:5352
...
2026-09-27 21:14:14: [31]    CRITICAL Not a HASH reference at /obs/src/backend/build/Build.pm line 500.
/srv/obs/log/scheduler_x86_64.crit.log: No such file or directory
dumping emergency state...
```

**Root cause** (verified against the pinned sources):
- OBS's scheduler (`src/backend/bs_sched:1046`) *locally* rebinds the obs-build
  expander to a BSSolv expander, and that rebind **overwrites the first argument
  in place**:
  ```perl
  local *Build::expand = sub { $_[0] = $xp; goto &BSSolv::expander::expand; };
  ```
  So the value passed as arg 0 to `Build::expand` is *discarded and replaced*
  with the expander object `$xp`.
- The obs-build `Build.pm` that `2.10.34` pins (`gitlink 83be5905…`, a **2017-03**
  commit) passes the config hashref *directly* as that first arg:
  ```perl
  # Build.pm:496 (2017 pin)
  @pre = expand($config, @{$config->{'preinstall'} || []});
  ```
  After the first `expand` call the rebind runs `$_[0] = $xp` — destroying
  `$config` itself (Perl passes the hashref by value; the rebind mutates the
  caller's slot). The next `expand($config, …)` at line 504 then dies with
  "Not a HASH reference" — that is the reported `line 500`-region crash (the
  `@{$config->{'vminstall'} || []}` guard at line 500 dereferences the now-
  corrupted `$config`).
- The obs-build fix is the `expandpreinstalls` workaround that copies the
  hashref before the rebind can clobber it:
  ```perl
  my $c = $config;
  @pre  = expand($c, @{$config->{'preinstall'} || []});
  …
  my $c = $config;
  @vm   = expand($c, @pre, @pren, @{$config->{'vminstall'} || []});
  ```
  Upstream added this in `obs-build d81d3353…` ("Add ugly workaround to make
  expandpreinstalls work in OBS", 2020-01).

**The 2.10.34 release pins a *stale* obs-build** (`83be5905…`, 2017-03) that
predates the workaround. The open-build-service **master** branch pins
`obs-build 1fe25db5…` (2023-11), which *has* the workaround.

**Fix (preferred): bump the obs-build submodule pin that CI checks out.**
The backend rebuild workflow does
`git -C /tmp/open-build-service-src submodule update --init src/backend/build`
after `git clone --branch <2.10.34>`, which checks out the *tag's* (stale)
gitlink. To use a newer obs-build, **after** that submodule init, add:
```sh
git -C /tmp/open-build-service-src/src/backend/build fetch --depth 1 origin 1fe25db5f64c31878f8fc9094c009d3f8e085251
git -C /tmp/open-build-service-src/src/backend/build checkout 1fe25db5f64c31878f8fc9094c009d3f8e085251
```
(`1fe25db5…` = the obs-build rev open-build-service *master* pins — the
"known-good" target; verified its `Build.pm` contains the `$c = $config`
workaround.) This keeps the rest of the 2.10.34 app but drops in the fixed
obs-build. The `test -f /obs/src/backend/build/Build.pm` Dockerfile assertion
still passes.

**Fix (alternative): patch `Build.pm` in-repo.** Stage an obs-build
`Build.pm` override (copy the fixed `expandpreinstalls`) into the build
context and `cp` it over the submodule's file in the workflow (same pattern as
the frontend `config/` overrides). Less clean than the submodule bump.

**CI (both alternatives):** a push touching the backend workflow,
`open-build-service-backend/docker/` or `open-build-service/config/` always rebuilds
now -- no version-file trick needed. See cross-cutting CI note below.

**Verify (host, after backend image rebuild + redeploy):**
```sh
docker compose pull && docker compose up -d backend worker
# watch the scheduler get past the point of death
docker compose logs -f bs_sched 2>&1 | grep -E "CRITICAL|Not a HASH|startup complete|event package"
# and confirm the image has the fix
docker run --rm --entrypoint bash ghcr.io/<owner>/open-build-service-backend:latest \
  -c "grep -n 'my \$c = \$config' /obs/src/backend/build/Build.pm"
```

---

## Fix 2: InfluxDB spam ("Failed to contact host localhost … retrying")

**Symptom** (frontend container, every request):
```
W, [2026-09-27T21:15:05.074845 #17]  WARN -- InfluxDB: [17:0.00] Failed to contact host localhost:
  #<Errno::ECONNREFUSED: … "localhost" port 8086 …> - retrying in 0.01s.
… 0.02s / 0.04s / 0.08s …
```

**Root cause** (verified against the baked `src/api` + the vendored
`experimental-influxdb-rails 1.0.0.beta5` gem):
- Our `open-build-service/config/options.yml` leaves **`influxdb_hosts` blank**.
- OBS's `config/initializers/influxdb_rails.rb` does:
  ```ruby
  if CONFIG['influxdb_hosts'].blank?
    InfluxDB::Rails.configure { |c| c.instrumentation_enabled = false }
    return
  end
  …
  ```
  i.e. when `influxdb_hosts` is blank it only sets **`instrumentation_enabled
  = false`** and returns.
- `instrumentation_enabled?` gates *only* the periodic **metric subscribers**
  (`Middleware::Subscriber#enabled?` / `SimpleSubscriber#enabled?`). It does
  **not** gate the **Rack exception middleware**:
  ```ruby
  # gem lib/influxdb/rails/rack.rb
  def _call(env)
    begin
      response = @app.call(env)
    rescue StandardError => e
      InfluxDB::Rails.transmit_unless_ignorable(e, env)   # <- NOT gated
      raise(e)
    end
    response
  end
  ```
  `transmit_unless_ignorable` is skipped only when `ignorable_exception?` is
  true — i.e. when the *current env* is in `configuration.ignored_environments`.
  The gem's **default is `%w[test cucumber selenium]`** — `production` is **not
  in it**, so in production the Rack middleware *always* reports exceptions.
- Every 500 in the Rails app (the thinking-sphinx delete error, and any other
  exception) therefore triggers `transmit` → `InfluxDB::Client#write_point` →
  `Net::HTTP` to `localhost:8086` (the gem's default host) with the gem's
  **default `retry = -1` (infinite)**, producing the escalating
  "retrying in 0.01/0.02/0.04/0.08…" spam.
- `InfluxDB::Rails.client` builds `InfluxDB::Client.new(hosts:
  configuration.influxdb_hosts, retry: configuration.retry, …)`; with
  `influxdb_hosts` nil the gem falls back to `localhost`, and `configuration.retry`
  is never set by OBS (stays at the gem default `-1`).

So: blank `influxdb_hosts` → instrumentation off, but the **exception** path is
still on (production not in `ignored_environments`), and it retries to
`localhost:8086` forever on every exception.

**Fix (preferred): ship an `influxdb_rails.rb` initializer override that
*truly* disables the exception path when `influxdb_hosts` is blank**, mirroring
how we already override `secret_token.rb`. Add
`open-build-service/config/initializers/influxdb_rails.rb`:
```ruby
if CONFIG['influxdb_hosts'].blank?
  InfluxDB::Rails.configure do |config|
    config.instrumentation_enabled  = false
    # Production is not in the gem's default ignored_environments, so the
    # Rack exception middleware would otherwise transmit (retrying forever to
    # localhost:8086) on every 500. Mark the live env ignored so
    # transmit_unless_ignorable is a no-op.
    config.ignored_environments = [Rails.env]
  end
  return
end
# (else: identical to upstream — wire the real InfluxDB host/creds)
InfluxDB::Rails.configure do |config|
  config.influxdb_database   = CONFIG['influxdb_database']
  config.influxdb_username   = CONFIG['influxdb_username']
  config.influxdb_password   = CONFIG['influxdb_password']
  config.influxdb_hosts      = CONFIG['influxdb_hosts']
  config.influxdb_port       = CONFIG['influxdb_port']
  config.retry               = CONFIG['influxdb_retry'] || false
  config.use_ssl             = CONFIG['influxdb_ssl']
  config.time_precision      = CONFIG['influxdb_time_precision']
  config.series_name_for_sql = 'rails.sql'
  config.tags_middleware     = lambda do |tags|
    result = { beta: false, anonymous: true, interface: :none }.merge!(tags)
    result.reject! { |_, value| value.nil? || value == '' }
    return result if result.key?(:method)
    { location: :raw }.merge!(result)
  end
end
```
Then in the **frontend** rebuild workflow's "Merge this repo's config
overrides" step, after the `secret_token.rb` cp, add:
```sh
mkdir -p /tmp/open-build-service-src/src/api/config/initializers
cp open-build-service/config/initializers/influxdb_rails.rb \
   /tmp/open-build-service-src/src/api/config/initializers/influxdb_rails.rb
```
(Overrides the baked `src/api/config/initializers/influxdb_rails.rb` — same
mechanism as `secret_token.rb`.)

This makes "blank `influxdb_hosts`" genuinely disable InfluxDB *including* the
exception path, so no `localhost:8086` retries and no spam. When the user later
*wants* InfluxDB, they set `influxdb_hosts` (+db/creds) in `.env`/`options.yml`
and the else-branch wires it up.

**Fix (simpler alternative, no initializer override):** keep upstream's
initializer but set **`influxdb_hosts` to a non-blank, unreachable-but-silent
value** — *no*, this is worse (still retries). The correct minimal variant is
to add **`config.influxdb_retry = 0`** and **`config.ignored_environments =
[Rails.env]`** to upstream's blank-branch. That still needs the initializer
override (we can't append to upstream's file without replacing it). So the
initializer override above is the cleanest fix.

**Verify (host, after frontend image rebuild + redeploy):**
```sh
docker compose pull && docker compose up -d frontend
# trigger any 500 (e.g. delete a project) and confirm NO influxdb retry spam:
docker compose logs --since 2m frontend 2>&1 | grep -i "influxdb"   # expect empty
```

---

## Fix 3: searchd / thinking-sphinx "TLS/SSL error" (project delete 500s) -- DONE

**Fixed in `bf42426`** (open-build-service: really fix thinking-sphinx TLS error
on project delete), baked into the frontend image by the 2.10.34 rebuild
(`640a17b`). **Verified on the host 2026-09-28: project delete works.**

**Symptom:** `DELETE /project/destroy` 500'd with
`ThinkingSphinx::SphinxError (TLS/SSL error: SSL is required, but the server
does not support it)`.

**Root cause** (verified against MariaDB Connector/C 3.4.9 source + probes in the
container): the frontend base image (Leap 16.0) ships `libmariadb3` 3.4.9, built
with `DEFAULT_SSL_VERIFY_SERVER_CERT`. While server-cert verification is on, the
client *forces* TLS in the handshake (`plugins/auth/my_auth.c`) and errors out
when the server offers none -- and searchd's mysql41 listener has no TLS.
- `ssl_mode: disabled` (the first fix, `9ba0825`) is a no-op: mysql2 0.5.2's
  `ssl_mode=` only works with MySQL client libraries >= 5.7.3.
- Option-file keys `ssl-enforce=0` / `ssl=0` / `skip-ssl` are overridden by the
  verification default (probe: all FAIL).
- `ssl-verify-server-cert=0` (probe: OK, `2.2.11-id64-release`) or the env var
  `MARIADB_TLS_DISABLE_PEER_VERIFICATION` both work -- the client then falls back
  to plaintext.

**Fix:** `config/no_ssl.cnf` (`[client]` / `ssl-verify-server-cert=0`), wired in
via `thinking_sphinx.yml` `connection_options: { default_file: ... }` -- scoped to
the searchd connection only (the env var would also drop verification on Rails'
real MariaDB connection).

**Note:** the host was running a legacy compose (bind-mounted source checkout,
local build, `RAILS_ENV=development`), not the CI images -- the fix only takes
effect with the `docker-compose.yml.sample` layout
(`ghcr.io/<owner>/open-build-service-frontend`), whose `thinking_sphinx.yml`
has only a `production:` key.

---

## Cross-cutting

- **CI triggers (both images):** the `config/` and obs-build overrides are
  baked at build time. Both workflows rebuild on every push that matches their
  `paths:` (and on a manual run); only the nightly cron skips when the tracked
  upstream state (backend: base digest; frontend: `<release>@<base digest>`)
  is unchanged. A no-change rebuild doesn't create a bot commit. (Formerly
  this needed decrementing the version file to force `changed=true`.)
- **All container-side probes/verifies must run on the host** (this sandbox has
  no docker daemon).
