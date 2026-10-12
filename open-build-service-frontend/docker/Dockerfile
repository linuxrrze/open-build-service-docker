# Self-contained OBS frontend (Rails API) image.
#
# The openSUSE base image (frontend-base:210) is a *runtime environment
# only*: the Ruby/Rails + Node toolchain, a `frontend` user (uid 1000, primary
# group `users`) and an EMPTY /obs/src/api stub -- but NOT the application
# source. This image bakes the pinned open-build-service release's src/api in
# at build time (see the open-build-service-frontend/README.md and the workflow
# for how CI supplies it already merged with this repo's config overrides), so
# the resulting image runs WITHOUT any host-side git checkout.
#
# frontend-base, not frontend-features: -features is -base plus chromedriver
# (and the chromium it pulls in, a ~400 MB compressed layer) for upstream's
# capybara feature tests -- never used in production.
#
# The source must match the version openSUSE pinned into the :210 runtime
# (2.10.34 as of writing, per obs-server's _service); the workflow reads that
# same pin to pick the tag it clones.
#
# Gem/user ordering deliberately mirrors upstream's src/api/docker-files/Dockerfile
# (which is the known-good, shipped frontend image): usermod, then USER frontend,
# then bundle install + assets:precompile all run AS the frontend user. If gems
# were installed as root instead, they'd land in root's gem home and the frontend
# runtime user couldn't find them -- the app would build fine but crash at boot.
#
# CI rebuilds on every push touching this directory or open-build-service/config/
# (see the workflow), so a config change needs no version-file trick.
FROM registry.opensuse.org/obs/server/2.10/containers/containers/openbuildservice/frontend-base:210
ARG CONTAINER_USERID

# Process manager, pinned (upstream also installs jshint/brakeman for their own
# lint/scan CI -- not needed here, omitted to keep the image lean).
RUN gem install --no-document --no-format-executable foreman -v 0.90.0

# Set the uid and hand the app dir itself to the app user (upstream's order).
# The files below are COPYed with --chown, so no `chown -R` layer duplicates
# the whole tree. The base image has no `frontend` group; its primary group is
# `users` (useradd -g users in the base), hence frontend:users.
RUN usermod -u ${CONTAINER_USERID} frontend \
 && chown frontend:users /obs/src/api
USER frontend
WORKDIR /obs/src/api

# Gems first, from only the files bundler needs (no path/git gems in the
# Gemfile; vendor/cache holds the .gem files it installs from), so a change to
# the app source or our merged config reuses this layer from the build cache.
# Gem build flags are the same as upstream's src/api/docker-files/Dockerfile,
# then a flaky-network-retrying bundle install -- run as frontend so the gems
# are owned by (and visible to) the runtime user.
# `without test`: the test-only group (capybara, webmock, bunny-mock, ...) is
# never loaded in production. NOT `development` -- in 2.10.34 puma (the Procfile's
# web server) and single_test (required by the Rakefile) are in the
# :development, :test group.
COPY --chown=frontend:users src/api/Gemfile src/api/Gemfile.lock /obs/src/api/
COPY --chown=frontend:users src/api/vendor/cache/ /obs/src/api/vendor/cache/
RUN bundle config build.ffi --enable-system-libffi \
 && bundle config build.nokogiri --use-system-libraries \
 && bundle config build.nio4r --with-cflags='-Wno-return-type' \
 && bundle config build.mysql2 --with-cflags='-Wno-return-type' \
 && bundle config set without 'test' \
 && (bundle install --jobs=3 --retry=3 || bundle install --jobs=3 --retry=3)

# Bake the pinned app source (build context = the release clone; CI has already
# added this repo's config files to src/api/config/ and dropped the spec/ and
# test/ suites before building -- see the workflow's merge step; no upstream
# file is replaced). Overwrites the base image's empty stub.
COPY --chown=frontend:users src/api/ /obs/src/api/

# API-token issuer (see open-build-service/README.md, "API access"). A small
# WEBrick service run by the `frontend-token` compose service: logged-in OIDC
# users issue/show/revoke their OWN HTTP Basic password, and its bcrypt hash is
# appended to the htpasswd file traefik's obs-api basicauth.usersFile reads.
# The build context is the clone root, so the workflow's merge step copies this
# file there so the COPY below can find it.
# Runs under `bundle exec` in the image's Gemfile context (bcrypt is an OBS
# gem; webrick is a Ruby 2.7 default gem), so it's just a plain script.
COPY obs_api_token.rb /usr/local/bin/obs_api_token.rb

# Production runtime.
ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1

# Rails won't boot (or precompile) without a writable tmp/ and log/; create
# them now, owned by frontend (the USER is still frontend), before precompile.
#
# Upstream's config/initializers/secret_token.rb raises in production unless
# config/secret.key exists (the obs-api rpm generates it at install time). A
# placeholder satisfies it: Rails 5.2 prefers ENV['SECRET_KEY_BASE'] anyway, and
# our zz_container.rb initializer refuses to boot without that env var.
#
# Then precompile assets at build time. OBS's application.rb does
# Bundler.require(*Rails.groups(assets: ['development', 'test'])): in production
# that resolves to [:default, :production] -- the :assets gem group
# (codemirror-rails, etc.) is NOT required, so its asset files aren't on
# Sprockets' load path and precompile fails with "couldn't find file
# 'codemirror'". That's intentional at RUNTIME ("we don't need the gems loaded
# then" -- production serves the static compiled assets without the gems), but
# it breaks build-time precompile. Opt back into the group just for this step
# with RAILS_GROUPS=assets (Rails.groups reads it, rails.rb). Staying in the
# production env means production's exact asset settings (compress, digest,
# debug) are used, so the precompiled output matches what runtime serves.
# A build-time dummy SECRET_KEY_BASE satisfies zz_container.rb's check (asset
# digests are content-based, not secret-based); the real one is supplied at
# runtime via .env.
# Sprockets' build cache (tmp/cache) is only needed to speed up a *later*
# precompile; drop it in the same layer so it never ships.
RUN mkdir -p tmp log \
 && echo 'placeholder -- the real secret is SECRET_KEY_BASE from .env' > config/secret.key \
 && RAILS_GROUPS=assets SECRET_KEY_BASE=build-time-dummy bundle exec rails assets:precompile \
 && rm -rf tmp/cache

EXPOSE 3000

# Foreman runs the Procfile: web (rails server) + delayed_job (async) +
# clock (scheduled) + search (ts:rebuild). -p 3000 so traefik/rails agree.
CMD ["foreman", "start", "-f", "Procfile", "-p", "3000"]
