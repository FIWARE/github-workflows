# FIWARE GitHub workflows

Reusable GitHub Actions workflows shared by FIWARE repositories, so that a fix is made in one place.

## Chart version (`chart-pr.yml`)

For repositories that release Helm charts from a `charts/` directory, with the version of each chart driven by the semver label of the pull request that changes it. On every pull request it:

1. requires exactly one of the labels `major`, `minor` or `patch`, and comments on the pull request when it is missing;
2. bumps the `version` of every chart the pull request changes: its version on the base branch, bumped by the label. A chart that is not on the base branch yet keeps its version;
3. commits the new versions ("Update helm chart versions") to the pull request branch. A pull request from a fork, which the workflow token cannot push to, fails instead, listing the versions its author has to set.

The version is computed from the base branch, so running the workflow again, or several times concurrently, gives the same result. A version already set by hand to the expected value is kept.

### Usage

In the workflow that checks pull requests, replace the label check and the version bump with:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

# one run per pull request: opening one with a label fires two events at once
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  # ... the repository's own checks

  chart-version:
    needs: [lint]                # whatever has to pass first
    uses: FIWARE/github-workflows/.github/workflows/chart-pr.yml@v1
    permissions:
      contents: write            # push the new versions to the pull request branch
      pull-requests: write       # comment when the label is missing
```

Inputs, both optional:

| Input | Default | Description |
|---|---|---|
| `charts-dir` | `charts` | Directory that holds one directory per chart |
| `exclude` | `<charts-dir>/README.md` | Space-separated paths that never count as a chart change |

Pushes made with the workflow token do not trigger workflows, so the checks of the pull request keep running on the commit before the version bump.

### Versions

Callers use the `v1` tag, which moves with every compatible release (`v1.0.1`, `v1.1.0`, ...). A change that needs callers to change their call gets a new major tag. Callers that want to update by hand pin an exact release (`@v1.0.1`) or its commit instead.

## Releases

Every pull request to this repository needs one of the labels `major`, `minor` or `patch`. When it is merged, `release.yml`:

1. takes the highest `vX.Y.Z` tag and bumps it by the label;
2. tags the merge commit with the new `vX.Y.Z` and moves the major tag (`vX`) to it. A `major` release creates the next major tag and leaves the previous one where it was, so its callers keep working;
3. publishes a GitHub release with notes generated from the merged pull requests.

A pull request merged without a label is not released, and the workflow fails saying so. The first release, or any release no pull request carries, is made by running the Release workflow by hand on `main` with the version (`X.Y.Z`).

Recommended repository settings:

- a tag ruleset on `v*.*.*` that blocks updates and deletions, so a release, once tagged, cannot change. The major tags (`v1`) do not match it and stay movable by the release workflow;
- optionally, immutable releases.

## Development

```shell
shellcheck scripts/*.sh
bats tests
actionlint
```

The workflow checks out `scripts/` from its own commit (`job.workflow_sha`), so a caller pointing to a branch of this repository runs that branch's script too.
