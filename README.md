# SST Preview Action

Deploy and remove isolated SST preview environments for pull requests.

<img width="2050" height="754" alt="SST preview deployment comment" src="https://github.com/user-attachments/assets/160e8769-14ba-45be-8bd3-6e6b3aee26c1" />

## Features

- Deploys only to a `pr-{number}` stage
- Removes a partially created stage when deployment fails
- Retries failed removals and verifies the SST state
- Automatically clears stale SST state locks after lock-specific remove failures
- Streams SST deployment logs in real time
- Reads a named SST output with a CloudFront URL fallback
- Posts a sticky PR comment with the preview URL
- Resolves manual deploy targets from the selected branch
- Resolves manual cleanup targets from a trusted branch input
- Supports PR-number disambiguation and deleted-branch cleanup
- Reconciles orphaned preview stages on a schedule
- Supports explicit `deploy`, `remove`, `unlock`, and `reconcile` operations, plus event-based auto detection

## Recommended usage

Use one workflow for deployment, close-event cleanup, and manual cleanup.

```yaml
name: SST Preview

on:
  pull_request:
    types: [opened, reopened, synchronize]
  pull_request_target:
    types: [closed]
  schedule:
    - cron: "23 */6 * * *"
  workflow_dispatch:
    inputs:
      operation:
        description: Operation to run
        required: true
        type: choice
        options:
          - deploy
          - remove
          - unlock
          - reconcile
      pr_number:
        description: PR number for disambiguation, deleted branches, or unlock
        required: false
        type: string
      target_branch:
        description: PR branch to remove
        required: false
        type: string

concurrency:
  group: sst-preview
  queue: max
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  preview:
    if: >-
      ${{
        github.event_name != 'pull_request' ||
        (
          github.actor != 'dependabot[bot]' &&
          github.event.pull_request.head.repo.full_name == github.repository
        )
      }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          ref: >-
            ${{
              github.event_name == 'pull_request' &&
              github.event.pull_request.head.sha ||
              (
                github.event_name == 'workflow_dispatch' &&
                inputs.operation == 'deploy' &&
                github.sha
              ) ||
              github.event.repository.default_branch
            }}
          persist-credentials: false
      - uses: actions/setup-node@v6
        with:
          node-version: 24
      - run: npm ci
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1
      - uses: lemtoc/sst-preview-action@v1
        with:
          operation: ${{ github.event_name == 'workflow_dispatch' && inputs.operation || 'auto' }}
          pr-number: ${{ inputs.pr_number || github.event.pull_request.number }}
          target-branch: ${{ inputs.target_branch }}
          working-directory: path/to/sst/project
```

For production workflows, pin third-party actions to a full commit SHA.
Replace `npm ci` with the repository's package-manager install command.

The workflow deploys pull-request head code only for same-repository
`pull_request` events. A manual deploy checks out the branch selected in
GitHub's standard **Run workflow** branch selector. For manual remove, unlock,
or reconcile, select the default branch in that selector. The action rejects
cleanup or unlock dispatched from another ref. `pull_request_target` close
events, manual remove/unlock, and reconciliation therefore run the trusted
default branch, including when the pull request has merge conflicts. Do not
change the checkout expression to execute pull-request code for cleanup,
unlock, or reconciliation.

Scheduled runs reconcile SST state from the trusted default branch. The shared
concurrency group prevents deployment, close cleanup, and reconciliation from
overlapping. `queue: max` keeps up to 100 lifecycle runs waiting instead of
replacing an older pending run.

For a manual deploy without `pr-number`, the action looks for one open pull
request whose head is the selected branch. No match is a successful no-op; more
than one match is rejected. For a manual remove, `target-branch` identifies the
pull request while the workflow remains on the default branch. Without
`pr-number`, exactly one open or closed pull request must match that target
branch. An open pull request's preview is removed with a warning and can be
recreated by its next update. No match or multiple matches are rejected without
removing anything.

An explicit `pr-number` disambiguates multiple pull requests for the selected
deploy branch or the cleanup `target-branch`. For immediate cleanup after a
branch is deleted, select the default branch, leave `target-branch` empty, and
provide its pull request number. The action verifies the pull request and always
derives a `pr-{number}` stage, so it cannot be used to remove `dev`, `stg`, or
`prod`. Manual reconciliation ignores both targeting inputs; select the default
branch and choose `reconcile`. To clear a stale SST lock, select the default
branch, choose `unlock`, and provide `pr-number`. Unlock is intentionally
manual-only and does not remove resources; after confirming that no deployment
is running, run `remove` or `reconcile` to clean up the stage.

Remove operations detect SST's lock-specific error message. With
`unlock-on-lock: true`, the action verifies the stage, unlocks it once, and
retries the removal within the configured attempt limit. Unrelated removal
failures never trigger an unlock. Keep the workflow concurrency group in place
and do not run an independent SST operation against the same stage at the same
time; SST cannot distinguish an active lock from a stale one.

## Reconciliation

Reconciliation is a safety net for a close-event workflow that failed or was
canceled. It:

1. Lists deployed SST stages and accepts only bare `pr-{number}` entries.
2. Queries each matching pull request and completes the entire removal plan
   before deleting anything.
3. Keeps open and recently closed pull requests.
4. Removes pull requests that have remained closed for at least one hour.
5. Rechecks every eligible pull request immediately before writing the
   token-free removal plan.

The inventory command uses `pr-1` only as a read-only probe context for
evaluating `sst.config`; it does not deploy or remove that stage. Reconciliation
requires the app name returned by `app(input)` to stay the same across all
pull-request stages.

Any SST state or GitHub API error aborts planning without removing a stage.
Reconciliation also refuses plans larger than 20 stages. It does not scan AWS
resources that are missing from SST state. The action-provided GitHub token is
available only to the planning step; the action does not pass it to SST or
application code. A plan over the limit requires manual cleanup before
scheduled reconciliation can resume.

GitHub state checks and AWS removal cannot be one atomic operation. If a pull
request reopens after the final check, the shared concurrency queue keeps its
deployment behind reconciliation so the preview is recreated afterward.

## SST configuration

Protect persistent environments and purge state only for pull-request stages:

```ts
const persistentStages = new Set(["dev", "stg", "prod"]);

export default $config({
  app(input) {
    const persistent = persistentStages.has(input.stage);
    const preview = /^pr-[1-9][0-9]*$/.test(input.stage);

    if (!persistent && !preview) {
      throw new Error(`Unsupported stage: ${input.stage}`);
    }

    return {
      name: "my-app",
      removal: preview ? "remove" : "retain",
      protect: !preview,
      state: {
        purge: preview,
      },
      home: "aws",
    };
  },
  async run() {
    const frontend = new sst.aws.Nextjs("Frontend");

    return {
      url: frontend.url,
    };
  },
});
```

The action reads `url` from `.sst/outputs.json` by default. Use
`url-output-key` when the project returns a different top-level key. Projects
that do not configure a named output keep the existing CloudFront URL fallback.
`state.purge` requires SST 4.13.0 or newer and the corresponding S3
object-version deletion permissions in the AWS role. Purging state is
irreversible, so keep its condition restricted to canonical `pr-{number}`
stages.

## Inputs

| Name                         | Required | Default | Description                                                |
| ---------------------------- | -------- | ------- | ---------------------------------------------------------- |
| `working-directory`          | false    | `.`     | Directory containing `sst.config`                          |
| `operation`                  | false    | `auto`  | `auto`, `deploy`, `remove`, `unlock`, or `reconcile`        |
| `pr-number`                  | false    |         | Manual PR disambiguation, cleanup, or unlock target         |
| `target-branch`              | false    |         | PR branch to resolve for trusted manual cleanup            |
| `comment-enabled`            | false    | `true`  | Post a preview URL comment after deployment                |
| `cleanup-on-deploy-failure`  | false    | `true`  | Remove the preview stage after a failed deployment         |
| `remove-max-attempts`        | false    | `3`     | Maximum removal attempts                                   |
| `remove-retry-delay-seconds` | false    | `30`    | Delay between removal attempts                             |
| `unlock-on-lock`             | false    | `true`  | Unlock once after a lock-specific remove failure           |
| `verify-removal`             | false    | `auto`  | `auto`, `true`, or `false`                                 |
| `url-output-key`             | false    | `url`   | Top-level SST output key containing the preview URL        |

With `operation: auto`, scheduled events reconcile stages, closed pull-request
events remove their stage, and other events deploy it. A manual workflow may
select `deploy`, `remove`, `unlock`, or `reconcile`. Deploy, remove, and unlock
stages are always
derived from `pr-number`, `github.event.pull_request.number`, or the pull
request resolved from a manually selected deploy branch or cleanup
`target-branch`; arbitrary stage names are not accepted. When both explicit and
event pull request numbers are present, they must match. Explicit
`operation: reconcile` is limited to `schedule` and `workflow_dispatch` events.
Explicit `operation: unlock` is limited to a workflow dispatched from the
repository's default branch and requires `pr-number`.

`unlock-on-lock: true` is used by `remove` and reconciliation. Set it to
`false` if another system may legitimately hold the SST lock and should be
allowed to finish instead of being interrupted.

`verify-removal: auto` verifies state when the installed SST version supports
reliable state deletion and falls back with a warning for older versions.
Use `true` for strict verification with SST 4.13.0 or newer.
`false` skips verification only after a successful `sst remove`; a failed
remove is still state-checked so an already absent stage succeeds without
masking an unverified removal failure.

## Outputs

| Name        | Description                                    |
| ----------- | ---------------------------------------------- |
| `url`       | Deployed preview URL, when one is available    |
| `operation` | Resolved `deploy`, `remove`, `unlock`, or `reconcile` operation |
| `stage`     | The `pr-{number}` stage; empty for reconciliation or a skipped deploy |

## Prerequisites

1. AWS credentials are configured before this action runs.
2. Node.js and the project package manager are available.
3. Project dependencies, including a locally pinned SST version, are installed.
4. The working directory contains a valid SST project.

## License

MIT
