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

Every push to `main` triggers a real build + public release, so after pushing,
confirm the pipeline goes green and check for failed builds. Verify by
checking (a) the `ios-v<version>` release published with a `lucinate.ipa`
asset, and (b) `apps.json` on `main` gained the new version entry.

Token-efficient method (learned the hard way):

- The build takes several minutes. Wait for it, then do the checks — don't
  poll tightly.
- **Use SMALL-output calls:** `mcp__github__list_releases` (perPage 3) and
  `mcp__github__get_file_contents` (apps.json). Do NOT call
  `list_workflow_runs` — it dumps ~180k chars and overflows context.
- A Haiku background subagent **cannot hold a multi-minute wait loop** (it
  ends its turn early) and each dispatch costs ~25k tokens — often *more* than
  a couple of direct small checks. So for the quick green/red verification,
  prefer a single delayed direct check (e.g. schedule a reminder ~6 min out
  via `send_later`, then run the two small calls above).
- Reserve a Haiku subagent for **deeper failure triage** — digging job logs
  (`list_workflow_jobs` + `get_job_logs` with `failed_only`/`tail_lines`)
  when a build is actually broken, so that large log output stays out of the
  main context.
