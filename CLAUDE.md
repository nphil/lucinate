# Lucinate — working notes for Claude

## iOS distribution: Feather / AltStore source

- The repo ships an AltStore/Feather source at `apps.json` (repo root).
  Public link: `https://raw.githubusercontent.com/nphil/lucinate/main/apps.json`
- Format mirrors the Stashy repo (`nphil/stashy`): top-level
  name/subtitle/description/iconURL/website/tintColor + `apps[]`, each app
  with a `versions[]` list (version, buildVersion, date, localizedDescription,
  downloadURL, size).

## CI/CD rules (mirror Stashy)

- **Always develop on and release from `main`.** Every push to `main` should
  ship a build — do not gate releases behind manual tagging.
- `.github/workflows/ios-build.yml` — on push to `main`: auto-bumps the
  version to `MAJOR.MINOR.<github.run_number>` (monotonically increasing, so
  Feather always detects an update), builds the unsigned IPA, publishes a
  GitHub release tagged `ios-v<version>`, and then **patches `apps.json`
  in-job** (prepends the new version, commits back with `[skip ci]`).
- **Do NOT rely on a `release: published`-triggered workflow to update
  `apps.json`.** Releases created by the built-in `GITHUB_TOKEN` do not fire
  workflow-triggering events, so such a workflow never runs. The build job
  must own the `apps.json` update itself (this is how Stashy does it too).
- iOS releases use the **`ios-v*`** tag namespace on purpose, to avoid
  triggering the Android `release.yml` (which fires on `v*`).

## After pushing to main — ALWAYS verify the build

- Every push to `main` triggers a real build + public release, so after
  pushing, confirm the pipeline goes green and check for failed builds.
- **Do this with a cheap Haiku subagent** (Agent tool, `model: haiku`,
  run in background) to conserve tokens — keep the expensive main context out
  of the polling loop.
- The Haiku agent should: poll the `ios-build.yml` run to completion, confirm
  the `ios-v<version>` release published with a `lucinate.ipa` asset, confirm
  `apps.json` on `main` gained the new version entry, and — on any failure —
  pull the failing job's logs and report the root cause tersely.
