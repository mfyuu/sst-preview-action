# SST Preview Action

Deploy SST preview environments automatically on pull requests.

<img width="2050" height="754" alt="CleanShot 2026-01-15 at 20 59 29@2x" src="https://github.com/user-attachments/assets/160e8769-14ba-45be-8bd3-6e6b3aee26c1" />

## Features

- 🚀 Auto deploy on PR open/sync, auto remove on PR close
- 💬 Automatic PR comments with preview URL
- 🔧 Handles Pulumi conflicts automatically

## Usage

```yaml
name: Preview

on:
  pull_request:
    types: [opened, synchronize, closed]

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-node@v6
        with:
          node-version: 24
      - uses: aws-actions/configure-aws-credentials@v5
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}

      - uses: mfyuu/sst-preview-action@v1
```

That's it! The action automatically:

- **Deploys** on `opened` and `synchronize` events
- **Removes** on `closed` event
- **Comments** the preview URL on the PR

## Inputs

| Name                | Required | Default | Description                     |
| ------------------- | -------- | ------- | ------------------------------- |
| `working-directory` | false    | `.`     | Directory containing sst.config |
| `comment-enabled`   | false    | `true`  | Whether to post PR comment      |

## Outputs

| Name  | Description             |
| ----- | ----------------------- |
| `url` | Deployed CloudFront URL |

## Prerequisites

1. **AWS credentials configured** - Use `aws-actions/configure-aws-credentials` before this action
2. **Node.js installed** - Use `actions/setup-node`
3. **SST project** - A valid `sst.config.ts` in your repository

## License

MIT
