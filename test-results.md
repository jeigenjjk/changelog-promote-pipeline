# Changelog Promotion PoC — Test Results

**Run date:** 2026-05-12 / 2026-05-13
**Repos:** jeigenjjk/changelog-promote-pipeline, changelog-promote-target-a, changelog-promote-target-b, changelog-promote-target-unrestricted, changelog-promote-target-restricted

## Phase 1: Public Repos (GITHUB_TOKEN + PAT)

| Test | Description | Target | Result | Notes |
|------|-------------|--------|--------|-------|
| T9 | Script tests on ubuntu | pipeline | PASS | All 11 Pester tests passed. Run 25760473509 |
| T1 | PR merge with CHANGELOG entry | target-a | PASS | Promotion commit on main, [Unreleased] emptied, PR title in version header. Run 25760582798 |
| T3 | Promotion commit no re-trigger | target-a | PASS | 2 total runs (seed + T1), no 3rd run from promotion commit. [skip ci] worked. |
| T6 | Version format YYYYMMDD.N | target-a | PASS | Version 20260512.2 matches expected format |
| T12 | GITHUB_TOKEN fallback | target-a | PASS | No push_token configured; GITHUB_TOKEN pushed to unprotected main + checked out public pipeline repo |
| T2 | PR merge without CHANGELOG | target-a | PASS | No workflow triggered (paths filter). Still 2 total runs after T2 merge. |
| T4 | Auto-resolve PR conflict | target-a | PASS | PR-1 promoted to 20260512.3, PR-2 auto-resolved (commit 0970c60), PR-2 merged cleanly, promoted to 20260512.4 |
| T5 | Multi-file conflict skipped | target-a | PASS | Logs: "2 file(s) conflicted - not safe to auto-resolve; Conflicted: CHANGELOG.md, README.md". PR#5 left CONFLICTING. |
| T13 | Empty unreleased skip | target-a | PASS | Logs: "No entries under [Unreleased] - skipping". No promotion commit created. Run 25761106389 |
| T14 | Multiple categories | target-a | PASS | All 3 categories (Added, Fixed, Security) in promoted section, correct KaC order. Version 20260512.7. |
| T10 | Custom version input | target-a | PASS | Promotion commit: "docs: promote changelog [Unreleased] to [99.0.0-custom-test] [skip ci]". Reverted caller after. |
| T11 | Cross-repo workflow_call | target-b | PASS | Reusable workflow from pipeline repo executed successfully. Promotion to 20260512.2. Run 25761362754 |
| T8 | Concurrent merges | target-b | PASS | PR#2 promoted to 20260512.3, auto-resolved PR#3, PR#3 promoted to 20260512.4. Both runs succeeded. |
| T15 | Version monotonicity | target-b | PASS | 3 sequential merges: 20260512.5, 20260512.6, 20260512.7. Monotonically increasing. Auto-resolve worked for each subsequent PR. |
| T7 | Branch protection bypass (PAT) | target-b | PASS | PAT (gho_ OAuth token) stored as PUSH_TOKEN secret. Promotion pushed to protected main (1 required review, enforce_admins=false). Version 20260513.8. Run 25779443090 |
| T16 | [skip ci] scope | target-b | PASS | Dummy Build workflow did NOT run on any promotion commits ([skip ci] skips ALL workflows). Confirmed expected trade-off. |

**Phase 1: 16/16 PASS**

## Phase 2: GitHub App Token (Private Repos)

| Test | Description | Target | Result | Notes |
|------|-------------|--------|--------|-------|
| P2-1 | App token auth on unrestricted repo | target-unrestricted | PASS | App token detected ("Auth mode: GitHub App"), promotion committed by changelog-promote-bot[bot]. Version 20260513.25. Run 25820603550 |
| P2-2 | App token bypass of branch protection ruleset | target-restricted | PASS | Ruleset: require PRs + App as bypass actor (Integration type). App pushed promotion commit to protected main. Author: changelog-promote-bot[bot]. Version 20260513.2. Run 25820841149 |
| P2-3 | Cross-repo script checkout with App token | target-unrestricted | PASS | App token checked out scripts from public pipeline repo. Verified in P2-1 run logs. |
| P2-4 | Git identity matches auth mode | target-unrestricted | PASS | App mode: "changelog-promote-bot[bot]" identity. Default mode: "github-actions[bot]" identity. |

**Phase 2: 4/4 PASS**

## Bugs Found and Fixed During Phase 2

### Bug 1: `secrets.*` in step `if` conditions causes workflow validation failure
- **Symptom:** Zero jobs created, "workflow file issue", workflowName shows file path instead of `name:`
- **Root cause:** GitHub Actions does not allow `${{ secrets.app_id != '' }}` in step-level `if:` conditions for reusable workflows. This causes a pre-execution validation failure with no useful error message.
- **Fix:** Pass secrets via `env:` block to a detection step that outputs flags, then use `steps.detect-auth.outputs.has_app == 'true'` in subsequent `if:` conditions.
- **Bisect evidence:** 10 iterations to isolate. Bisect 3 (secrets declared, no usage in `if`) = PASS. Bisect 9 (secrets in `if:`) = FAIL.

### Bug 2: Caller must declare `permissions` matching the reusable workflow
- **Symptom:** `startup_failure` when the caller repo's `default_workflow_permissions` is `read` and the reusable workflow declares `permissions: contents: write`.
- **Root cause:** The caller's GITHUB_TOKEN permissions ceiling limits the reusable workflow. If the caller doesn't grant `permissions`, the reusable workflow can't escalate beyond the repo default.
- **Fix:** All thin callers must include `permissions: { contents: write, pull-requests: read }` on the `workflow_call` job.
- **Bisect evidence:** Bisect 5 (no permissions) = PASS. Bisect 6a (permissions in called workflow only) = FAIL. Bisect 6b (permissions in BOTH caller and called) = PASS.

## Platform Limitations (Free Personal Account)

1. **Rulesets require GitHub Pro/Enterprise for private repos** — `POST /repos/.../rulesets` returns 403 on free plan. Branch protection API also blocked. Tested by making target-restricted public temporarily. Org deployment on `jjkeller-ts` (Enterprise) won't have this limitation.
2. **Private-to-private `workflow_call` works** but requires `access_level: user` on the called repo and the pipeline repo must be public OR both repos under the same owner with explicit access configuration.

## Key Findings (Updated)

1. **GitHub App token works end-to-end** — App token is detected, used for checkout, push, and PR conflict resolution. Git identity correctly shows the App's bot name.
2. **App as ruleset bypass actor works** — The App (actor_type: Integration) can push to branches protected by rulesets requiring PRs. This is the production path.
3. **`secrets.*` cannot be used in step `if` conditions** — This is an undocumented GitHub Actions limitation for reusable workflows. Must use env-var-based detection pattern instead.
4. **Caller `permissions` block is mandatory** — When the reusable workflow needs write permissions, the caller must explicitly grant them. Document this in the thin caller template.
5. **[skip ci] skips ALL workflows** — not just changelog-promote. Repos with other push-triggered workflows need awareness (T16). This is a known trade-off, not a bug.
6. **Auto-resolve is robust** — correctly handles single-file CHANGELOG conflicts (T4), refuses multi-file conflicts (T5), and chains across sequential promotions (T15).
7. **Version monotonicity confirmed** — `YYYYMMDD.run_number` is monotonically increasing across sequential merges. Gaps are expected and cosmetic (T15).
8. **PowerShell scripts are cross-platform** — all 11 Pester tests pass on ubuntu-latest with pwsh (T9).

## Production Readiness

The GitHub App approach is validated. For org deployment to `jjkeller-ts`:

1. **Create the App** using `github-app/manifest.json` + `create-app.html` + `Register-GitHubApp.ps1`
2. **Install on "All repositories"** for self-serve opt-in
3. **Store secrets at org level** (`CHANGELOG_APP_ID`, `CHANGELOG_APP_PRIVATE_KEY`) for automatic availability
4. **Each repo opts in** by adding the thin caller workflow (must include `permissions` block)
5. **Each repo with branch protection** needs a ruleset with the App as bypass actor (per-repo admin action)
6. **Pipeline repo** should be internal/private with `access_level: organization` for cross-repo workflow access

### Thin Caller Template (production)

```yaml
name: Changelog Promote
on:
  push:
    branches: [main]
    paths: ['CHANGELOG.md']
jobs:
  promote:
    if: "!contains(github.event.head_commit.message, '[skip ci]')"
    permissions:
      contents: write
      pull-requests: read
    uses: jjkeller-ts/devsecops-shared-infrastructure/.github/workflows/changelog-promote.yml@main
    with:
      trigger_sha: ${{ github.sha }}
    secrets:
      app_id: ${{ secrets.CHANGELOG_APP_ID }}
      app_private_key: ${{ secrets.CHANGELOG_APP_PRIVATE_KEY }}
```
