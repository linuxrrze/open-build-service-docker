# open-build-service-docker

Self-contained Docker images for [Open Build Service](https://openbuildservice.org/)
(OBS) 2.10, built and published by GitHub Actions to the GitHub Container
Registry, plus the compose stack that deploys them.

| Directory | What |
| --- | --- |
| [`open-build-service-backend/`](open-build-service-backend/) | Backend image (source/repo servers, scheduler, dispatcher, signer, workers) |
| [`open-build-service-frontend/`](open-build-service-frontend/) | Frontend image (Rails UI/API, `RAILS_ENV=production`) |
| [`open-build-service/`](open-build-service/) | The deployment: `docker-compose.yml.sample`, `.env.sample`, the config overrides CI bakes into both images, and a project-import script |
| [`.github/workflows/`](.github/workflows/) | One rebuild workflow per image -- see its [README](.github/workflows/README.md) |
| [`.github/scripts/`](.github/scripts/) | Shared CI helpers: startup banner, pinned Trivy scan |

Images:

- `ghcr.io/<owner>/open-build-service-backend:{latest,<version>,<version>-<YYYYMMDD>}`
- `ghcr.io/<owner>/open-build-service-frontend:{latest,<version>,<version>-<YYYYMMDD>}`

`<owner>` is this repository's owner, lowercased. Deployment instructions
are in [`open-build-service/README.md`](open-build-service/README.md).

## Origin

Converted from the `open-build-service*` images of a Gitea-hosted
`docker-images` repo (Gitea Actions, Gitea container registry) to a
standalone GitHub repo. The image contents, the build logic and the
change-detection are unchanged; what differs is listed in
[`.github/workflows/README.md`](.github/workflows/README.md#differences-from-the-gitea-version).

## GitHub setup (once)

No secrets are needed: the workflows push with the built-in `GITHUB_TOKEN`.

1. **Settings → Actions → General → Workflow permissions**: the workflows
   request `contents: write` (version-bump commits) and `packages: write`
   (ghcr.io push) themselves. If the organization/repo restricts the token to
   read-only and blocks workflows from raising it, allow read and write.
2. **Branch protection on `main`**: CI commits the tracked version back to
   `main`. If `main` requires PRs/reviews, allow GitHub Actions to bypass,
   or the "Record built version" step fails (the images are still pushed).
3. **Package visibility**: the first push creates the two packages under
   the owner's *Packages*, private by default (for a user account; orgs
   follow their default). Make them public, or `docker login ghcr.io` on
   the deployment host with a PAT that has `read:packages`.
4. Push to `main` (or run a workflow via **Actions → … → Run workflow**). The
   version files start empty, so the first run of each workflow always builds.

**Scheduled runs and inactivity:** GitHub disables `schedule:` triggers in a
public repo after 60 days without repository activity. The bot's bump
commits count as activity, but only when upstream moves -- if the nightly
checks stop, re-enable the workflows under **Actions**.
