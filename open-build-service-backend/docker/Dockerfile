# Self-contained OBS backend image (source/repo servers, dispatcher, publisher,
# signer, schedulers, workers -- all the non-Rails pieces).
#
# openSUSE's own backend:210 base ships the Perl *runtime* (bs_srcserver & co
# under /usr/lib/obs/server, signd, the source-service Perl libs) but NOT the
# OBS source tree that the start scripts run from. So, like the frontend image,
# we bake the pinned open-build-service release's backend source in at build
# time (CI supplies it already merged with this repo's config overrides). The
# result runs WITHOUT any host-side git checkout.
#
# The "2.10" project/tag (not "unstable") matters: OBS:Server:2.10 pins its
# obs-server build to the release this repo tracks (2.10.34 as of writing), and
# openSUSE says to use it "for production environments". Using this path keeps
# the runtime (this base) naturally aligned with the source we bake in -- the
# CI workflow pins the source to the version openSUSE derives, so they move
# together.
FROM registry.opensuse.org/obs/server/2.10/containers/containers/openbuildservice/backend:210

# Source-service + packaging support the backend needs at runtime (the base
# image doesn't ship these by default), plus the pending security patches of
# the base's own repos (same OBS:Server:2.10 / Leap repos the base was built
# from, so the runtime stays aligned) -- keeps a fixable CVE from failing the
# Trivy gate between openSUSE's own base rebuilds. One layer, repo metadata and
# package cache removed at the end so they don't ship. `zypper patch` exits
# 103 after updating the package manager itself (run it again for the rest)
# and 102 when a patch would want a reboot (meaningless in a container).
RUN zypper -n --gpg-auto-import-keys ref \
 && rc=0 && { zypper -n patch --category security || rc=$?; } \
 && if [ "$rc" -eq 103 ]; then rc=0; zypper -n patch --category security || rc=$?; fi \
 && { [ "$rc" -eq 0 ] || [ "$rc" -eq 102 ]; } \
 && zypper -n install obs-service-set_version obs-service-recompress dpkg dpkg-devel \
 && zypper clean -a

# The openSUSE base image ships a dummy cloud-upload private key at
# /etc/obs/cloudupload/secret.pem (a placeholder for the AWS/EC2 "cloud
# upload" feature). We never configure cloud upload, so the key is unused --
# but Trivy's secret scanner flags any embedded RSA private key, and
# --exit-code 1 fails the build on it. Remove it. (The sibling _pubkey is
# harmless and stays.)
RUN rm -f /etc/obs/cloudupload/secret.pem

# Signing: the obsrun services call /usr/bin/sign, which talks to signd on
# 127.0.0.1 and authenticates via a privileged source port -- so it must be
# setuid root, as upstream's appliance setup does (chmod 4755). Key, sign.conf
# and BSConfig settings are set up at start by start_prod_backend (OBS_SIGN*).
RUN chmod 4755 /usr/bin/sign \
 && test -x /usr/sbin/signd \
 && command -v gpg

# Bake the pinned backend source (build context = the release clone, repo root).
# The base image's /obs is an empty stub; this populates it with the Perl
# backend scripts and the contrib start scripts. The backend scripts resolve
# their modules from the SOURCE tree (each does `unshift @INC, "$wd"` in a
# BEGIN block), so this must be the real source tree.
COPY src/backend/ /obs/src/backend/
COPY contrib/ /obs/contrib/

# obs-build: use the base image's packaged `build` (/usr/lib/build, pulled in
# by obs-server's `Requires: build`), exactly like upstream's obs-server rpm
# does (`ln -sf /usr/lib/build build` in dist/obs-server.spec). The source
# tree's src/backend/build submodule pin is only for upstream's own tests and
# is years stale (2.10.34 pins a 2017 obs-build: bs_sched crashes on
# preinstallexpand, and Deb.pm can't read control.tar.zst/.xz, so every
# modern Debian/Ubuntu build fails with "bad binary"). Workers fetch this
# build code from the backend, so this also fixes the workers.
RUN rm -rf /obs/src/backend/build \
 && ln -s /usr/lib/build /obs/src/backend/build
# Our production startup script (kept in open-build-service/config/, staged
# into the build context by the CI workflow): a wrapper that runs upstream's
# start_development_backend unchanged plus signing setup, the scheduler manager
# and the worker sweep.
COPY open-build-service/config/start_prod_backend /obs/contrib/start_prod_backend

# Runtime entrypoint: seeds /obs/src/backend/BSConfig.pm from its .template on
# every start (the baked source ships only the .template) with the same
# substitutions our previous deploy used (service user obsrun, hostname from
# $OBS_BACKEND_HOST so the worker can point at the backend container), then
# execs the requested command. Without a checkout, /obs is writable at runtime,
# so this in-image seeding works.
COPY docker/files/obs-entry.sh /usr/local/bin/obs-entry
RUN chmod +x /usr/local/bin/obs-entry \
 && test -f /obs/src/backend/BSConfig.pm.template \
 && test -f /obs/src/backend/build/Build.pm \
 && test -f /obs/src/backend/build/Build/Deb.pm \
 && test -x /obs/contrib/start_development_worker \
 && echo "backend source baked OK"

# Releases build jobs whose worker is gone (run by start_prod_backend's worker
# sweep). Fail the build if the upstream routes it relies on changed.
COPY docker/files/obs-reap-jobs /usr/local/bin/obs-reap-jobs
# Starts/stops schedulers according to the UI's Architecture Availability
# (configuration.xml <schedulers>), run by start_prod_backend.
COPY docker/files/obs-sched-manager /usr/local/bin/obs-sched-manager
RUN chmod +x /usr/local/bin/obs-reap-jobs /usr/local/bin/obs-sched-manager \
 && grep -qF "\$ARGV[0] eq '--stop'" /obs/src/backend/bs_sched \
 && grep -qF 'bs_sched.$_myarch.lock' /obs/src/backend/bs_sched \
 && grep -qF "'schedulers' =>" /obs/src/backend/BSXML.pm \
 && grep -qF "'/worker \$jobid:?'" /obs/src/backend/bs_worker \
 && grep -qF "cmd=idleworker workerid jobid?" /obs/src/backend/bs_repserver \
 && grep -qF "'jobstatus' =>" /obs/src/backend/BSXML.pm \
 || { echo "upstream drift: review open-build-service-backend/docker/files/obs-reap-jobs and obs-sched-manager" >&2; exit 1; }

ENV OBS_BACKEND_HOST=backend
ENTRYPOINT ["/usr/local/bin/obs-entry"]
CMD ["/obs/contrib/start_prod_backend", "-d", "/obs", "-h", "backend", "-l", "/logs"]

# Source server listens here (BSConfig.pm source_port).
EXPOSE 5352
