# changelog-promote-pipeline

PoC: Reusable GitHub Actions workflow for changelog promotion.

Translates the AzDO `claude-changelog-promote` pipeline (definition 1207) to a reusable GitHub Actions workflow that any repo can call with a thin caller.

## What it does

1. On push to main that modifies CHANGELOG.md, promotes `[Unreleased]` entries to a versioned section
2. Auto-resolves CHANGELOG.md merge conflicts on open PRs

## Usage

Add this thin caller to your repo at `.github/workflows/changelog-promote.yml`:

```yaml
name: Changelog Promote
on:
  push:
    branches: [main]
    paths: ['CHANGELOG.md']
jobs:
  promote:
    if: "!contains(github.event.head_commit.message, '[skip ci]')"
    uses: jeigenjjk/changelog-promote-pipeline/.github/workflows/changelog-promote.yml@main
    with:
      trigger_sha: ${{ github.sha }}
    permissions:
      contents: write
      pull-requests: read
```

## Test Results (2026-05-12/13)

**16/16 PASS**

| Test | Description | Target | Result |
|------|-------------|--------|--------|
| T1 | PR merge with CHANGELOG entry | target-a | PASS |
| T2 | PR merge without CHANGELOG change | target-a | PASS |
| T3 | Promotion commit no re-trigger | target-a | PASS |
| T4 | Auto-resolve PR conflict | target-a | PASS |
| T5 | Multi-file conflict skipped | target-a | PASS |
| T6 | Version format YYYYMMDD.N | target-a | PASS |
| T7 | Branch protection bypass | target-b | PASS |
| T8 | Concurrent merge queuing | target-b | PASS |
| T9 | Script tests on ubuntu | pipeline | PASS |
| T10 | Custom version input | target-a | PASS |
| T11 | Cross-repo workflow_call | target-b | PASS |
| T12 | GITHUB_TOKEN fallback | target-a | PASS |
| T13 | Empty unreleased skip | target-a | PASS |
| T14 | Multiple categories | target-a | PASS |
| T15 | Version monotonicity | target-b | PASS |
| T16 | [skip ci] scope | target-b | PASS |
