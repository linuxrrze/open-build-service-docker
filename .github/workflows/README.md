# GitHub Actions workflows

One workflow per image, each scoped with a `paths:` filter so a push only
rebuilds the image whose inputs changed:

| Workflow | Image | Cron (UTC) | Tracks (`<image>/.<image>-version`) |
| --- | --- | --- | --- |
| `open-build-service-backend-rebuild.yml` | `ghcr.io/<owner>/open-build-service-backend` | 06:00 | `Docker-Content-Digest` of openSUSE's `backend:210` |
| `open-build-service-frontend-rebuild.yml` | `ghcr.io/<owner>/open-build-service-frontend` | 06:20 | `<release>@<digest>` of the pinned release + `frontend-base:210` |

## How a run works

1. **Check:** read the OBS release openSUSE pinned for `OBS:Server:2.10`
   (`obs-server/_service`) and the base image digest from
   `registry.opensuse.org` (anonymous v2 manifest request), compare with the
   version file -> `changed=true|false`.
2. **Gate:** every build-side step has
   `if: github.event_name != 'schedule' || steps.check.outputs.changed == 'true'`
   -- the nightly cron skips when nothing upstream moved; a push touching the
   image inputs (or a manual run) always rebuilds.
3. **Clone** that release tag of `openSUSE/open-build-service` into `/tmp`,
   **stage** this repo's files into it (backend: start script + helper
   scripts; frontend: Rails config overrides + token issuer, then an
   **upstream drift guard** that fails if the upstream code our overrides
   patch has changed), and **build** with our Dockerfile and the clone as
   context.
4. **Banner** (`.github/scripts/add-banner.sh`): thin layer printing image
   name + version on start, wrapping the original entrypoint.
5. **Trivy** (`.github/scripts/trivy-scan.sh`, pinned + sha256-verified):
   fails on a fixable CRITICAL/HIGH before anything is pushed.
6. **Push** `:<version>`, `:<version>-<YYYYMMDD>` (rollback) and `:latest`.
7. **Record** the new tracked value in the version file and push the commit
   with a retry-with-rebase loop (both workflows commit to `main`). No commit
   when nothing changed.

`paths:` lists only image inputs -- never the version file or READMEs, so
CI's own bump commit and doc edits don't rebuild anything.

## Conventions carried over

- Never truncate a pipe early (`head`, `awk` with `exit`) under
  `set -o pipefail` -- SIGPIPE fails the step. Use `tail -1` or let awk read
  to EOF.
- Registry credentials only via step-level `env:`, never `${{ secrets.* }}`
  inside a script.
- Every workflow sets `run-name:` so scheduled/manual runs show "Scheduled
  check" / "Manual run" instead of the latest commit subject.
- Accepted Trivy findings go in a `.trivyignore` with a reason per entry;
  `--skip-files` takes doublestar globs (`'**/x/*.pem'`), not regexes.
- To verify a workflow change end to end, empty the version file (or run the
  workflow manually) and confirm it builds, scans, pushes and records.

## Notes

- Images go to `ghcr.io/<owner>/<image>`; the owner is lowercased in a
  "Set image name" step (ghcr.io names must be lowercase). The build adds an
  `org.opencontainers.image.source` label, which links each package to this
  repository.
- Pushes and version-bump commits use the built-in `GITHUB_TOKEN`
  (`permissions: contents: write, packages: write`); no secrets needed.
  A push made with `GITHUB_TOKEN` does not trigger further workflow runs, so
  bump commits can't loop even without the `paths:` filter.
- `concurrency: <workflow>` queues overlapping runs of the same workflow
  instead of running them in parallel.
