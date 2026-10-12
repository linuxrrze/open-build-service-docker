# CLAUDE.md

Guidance for Claude Code (or any AI assistant) working in this repository.

## What this repo is

Two self-contained Open Build Service 2.10 images (`open-build-service-backend`,
`open-build-service-frontend`) built by GitHub Actions and pushed to
`ghcr.io/<owner>/`, plus their compose deployment in `open-build-service/`.
The images bake the pinned upstream OBS release source (cloned in CI) onto
openSUSE's runtime-only `:210` base images. Read
[`.github/workflows/README.md`](.github/workflows/README.md) before changing a
workflow, and [`open-build-service/README.md`](open-build-service/README.md)
for the deployment.

## Rules

- The build context is the upstream clone, not this repo: anything a
  Dockerfile `COPY`s from this repo must be staged into the clone by the
  workflow first (see the "Stage"/"Merge" steps).
- Only *add* files to the upstream source; don't replace upstream files. If
  an override depends on upstream internals, add a check to the frontend
  workflow's drift guard.
- The real `docker-compose.yml`, `.env` and `fs/` are gitignored -- never
  commit them; edit the `.sample` files instead.
- Workflow scripts: no early-closing pipes under `pipefail` (`head`, awk
  `exit`), secrets only via step `env:`, every commit-back step ends with the
  retry-with-rebase loop, every workflow keeps its `run-name:`.
- `paths:` filters list image inputs only, never version files or docs.
- The version files are written by CI only. Empty one to force the next
  scheduled run to rebuild.
- There is no docker daemon in the dev sandbox: container-side checks
  must run on a docker host or in CI.
- For multi-line commit messages use a temp file and `git commit -F`.
