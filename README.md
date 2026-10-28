# FIWARE GitHub workflows

Reusable GitHub Actions workflows shared by FIWARE repositories, so that a fix is made in one place.

The repository lives in the SEAMWARE organization until it moves to FIWARE; callers then change the owner in `uses:`.

| Workflow | What it does | Typical trigger |
|---|---|---|
| [`chart-lint.yml`](#chart-lint-chart-lintyml) | Lints the Helm charts and validates what they render | Pull requests |
| [`chart-pr.yml`](#chart-version-chart-pryml) | Requires a semver label and bumps the versions of the changed charts | Pull requests |
| [`chart-release.yml`](#chart-release-chart-releaseyml) | Publishes the charts, failing when a changed chart has no new version | Push to the main branch |
| [`chart-dependencies.yml`](#chart-dependencies-chart-dependenciesyml) | Opens pull requests for newer chart dependencies | Schedule |
| [`semver-version.yml`](#semver-version-semver-versionyml) | Works out the version to release from the semver label of the pull request | Pull requests and push to the main branch |
| [`stale.yml`](#stale-issues-staleyml) | Marks and closes issues and pull requests without activity | Schedule |

Together, the chart workflows cover the life of a chart: a pull request is linted and gets its new version, and merging it publishes that version.

## Chart lint (`chart-lint.yml`)

Lints every chart under `charts/` (the directories with a `Chart.yaml`) with `helm lint`, then builds its dependencies, renders it and validates the result with `kubeconform -strict`, against the Kubernetes schemas and the [CRDs catalog](https://github.com/datreeio/CRDs-catalog). Each `<chart>/ci/*-values.yaml` is rendered and validated as well, to cover what the default values leave off; with those, custom resources that are not in the catalog are skipped. Every chart is checked before the result is reported.

```yaml
jobs:
  chart-lint:
    uses: SEAMWARE/github-workflows/.github/workflows/chart-lint.yml@v1
```

| Input | Default | Description |
|---|---|---|
| `charts-dir` | `charts` | Directory that holds one directory per chart |
| `helm-version` | `v3.17.3` | Helm version |
| `kubeconform-version` | `v0.7.0` | kubeconform version |

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
    uses: SEAMWARE/github-workflows/.github/workflows/chart-pr.yml@v1
    permissions:
      contents: write            # push the new versions to the pull request branch
      pull-requests: write       # comment when the label is missing
```

Inputs, both optional:

| Input | Default | Description |
|---|---|---|
| `charts-dir` | `charts` | Directory that holds one directory per chart |
| `exclude` | `<charts-dir>/README.md` | Space-separated paths that never count as a chart change |
| `helm-docs-version` | (none) | Version of the [`jnorwood/helm-docs`](https://github.com/norwoodj/helm-docs) image, e.g. `v1.14.2`. When set, the `README.md` of every chart the pull request changes is regenerated after the bump and pushed with it. Other charts are left alone: regenerating a stale one would change it without a new version |

Pushes made with the workflow token do not trigger workflows, so the checks of the pull request keep running on the commit before the version bump.

## Chart release (`chart-release.yml`)

Publishes the charts when the main branch changes:

1. **checks the versions first**: a chart that the push changed without changing its version fails the workflow, naming it, before anything is published. Such a change would otherwise never be released, since the version is already published;
2. publishes every chart version that is not released yet as a GitHub release, and updates the Helm repository index on GitHub Pages, with [chart-releaser](https://github.com/helm/chart-releaser-action);
3. optionally, pushes them to an OCI registry, each version once, retrying a push that fails.

The repositories the charts' dependencies come from are added from their `Chart.yaml`.

```yaml
on:
  push:
    branches: [main]

jobs:
  chart-release:
    uses: SEAMWARE/github-workflows/.github/workflows/chart-release.yml@v1
    permissions:
      contents: write
    with:
      oci-registry: quay.io/fiware/helm-charts      # optional
    secrets:
      oci-username: ${{ secrets.QUAY_USERNAME }}
      oci-password: ${{ secrets.QUAY_PASSWORD }}
```

| Input | Default | Description |
|---|---|---|
| `charts-dir` | `charts` | Directory that holds one directory per chart |
| `exclude` | `<charts-dir>/README.md` | Space-separated paths that never count as a chart change |
| `helm-version` | `v3.17.3` | Helm version to package the charts with |
| `oci-registry` | (none) | OCI registry and path to push to as well, without `oci://`; needs the `oci-username` and `oci-password` secrets |
| `oci-charts` | all | Space-separated charts to push to the OCI registry |

## Chart dependencies (`chart-dependencies.yml`)

Looks up the latest stable version of every chart dependency that comes from a Helm repository or an OCI registry. For each one that is outdated it pushes a branch `bump/<chart>-<dependency>-<version>` with the new dependency version and the chart version bumped by the label, and opens a pull request with that label. A dependency that already has an open pull request, for any version, is left alone until it is merged or closed.

```yaml
on:
  schedule:
    - cron: '0 6 * * 3'
  workflow_dispatch:

jobs:
  chart-dependencies:
    uses: SEAMWARE/github-workflows/.github/workflows/chart-dependencies.yml@v1
    permissions:
      contents: write
      pull-requests: write
    with:
      reviewers: someone,someone-else
```

| Input | Default | Description |
|---|---|---|
| `charts-dir` | `charts` | Directory that holds one directory per chart |
| `label` | `patch` | Semver label of the pull requests, and bump of the chart version |
| `reviewers` | (none) | Comma-separated GitHub users to request a review from |

The chart version is bumped in the pull request itself because pull requests opened with the workflow token do not run their checks, `chart-pr.yml` included. To have the checks run, pass a GitHub App or personal token as the `token` secret.

## Semver version (`semver-version.yml`)

For repositories that release an application, not charts, with the version driven by the semver label of the pull request. It works out the version and leaves the build and the release to the caller:

- on a pull request, it requires exactly one of the labels `major`, `minor` or `patch`, commenting on the pull request when it is missing, and returns `X.Y.Z-PRE-<pull request number>`;
- on a push to the main branch, it reads the label of the pull request the pushed commit was merged from, and returns `X.Y.Z`. A commit that no merged pull request contains, or one merged without a label, fails.

`X.Y.Z` is the highest release tag bumped by the label. Release tags are `<tag-prefix>X.Y.Z`; other tags, such as pre-releases (`1.2.3-PRE-4`), are ignored.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

jobs:
  generate-version:
    uses: SEAMWARE/github-workflows/.github/workflows/semver-version.yml@v1
    permissions:
      contents: read
      pull-requests: write       # comment when the label is missing
    with:
      tag-prefix: ""             # tags like 1.2.3

  build-and-push:
    needs: generate-version
    runs-on: ubuntu-latest
    steps:
      - run: echo "Building ${{ needs.generate-version.outputs.version }}"
```

| Input | Default | Description |
|---|---|---|
| `tag-prefix` | `v` | Text the release tags start with; empty for tags like `1.2.3` |

| Output | Description |
|---|---|
| `version` | `X.Y.Z` on a push, `X.Y.Z-PRE-<pull request number>` on a pull request |
| `bump` | `major`, `minor` or `patch`, from the label |

## Stale issues (`stale.yml`)

Marks issues and pull requests without activity as stale, and closes them when they stay so, with [actions/stale](https://github.com/actions/stale).

```yaml
on:
  schedule:
    - cron: '30 1 * * *'
  workflow_dispatch:

jobs:
  stale:
    uses: SEAMWARE/github-workflows/.github/workflows/stale.yml@v1
    permissions:
      issues: write
      pull-requests: write
```

| Input | Default | Description |
|---|---|---|
| `days-before-stale` | `30` | Days without activity before an issue or pull request is marked as stale |
| `days-before-close` | `5` | Days a stale issue or pull request stays open before it is closed |

## Versions

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
bats tests        # the lint and eval tests need helm and kubeconform, and skip themselves without them
actionlint
```

Each workflow checks out `scripts/` from its own commit (`job.workflow_sha`), so a caller pointing to a branch of this repository runs that branch's scripts too.
