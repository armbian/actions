<p align="left"><img src="https://www.versio.io/img/supported-technology/hetzner-cloud.svg"></p>
<h1>Hetzner GitHub Actions Runner Deployment</h1>

This action creates and manages Hetzner Cloud servers with GitHub Actions runners pre-installed via cloud-init.

## Features

- 🚀 **Automated provisioning** - Creates Hetzner servers with cloud-init
- 🐳 **Docker pre-installed** - Each server comes with Docker ready
- 🏃 **Multiple runners** - Configure multiple runners per server
- 💾 **10GB swap** - Automatic swap file for better memory management
- 🔧 **Armbian-config integration** - Uses armbian-config for runner installation
- 🗑️ **Automatic cleanup** - Delete servers when done

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `action` | Yes | - | Action to perform: `create` or `delete` |
| `server-type` | No | `cax31` | Hetzner server type (e.g., cax21, cax31, cax41) |
| `image` | No | `ubuntu-24.04` | OS image name |
| `ssh-key` | Yes | - | SSH key name in Hetzner Cloud |
| `index` | No | `0` | Server index (for matrix builds) |
| `delete-existing` | No | `false` | Delete existing server before creating |
| `hetzner-token` | Yes | - | Hetzner Cloud API token |
| `github-token` | No* | - | GitHub token for runner registration |
| `runner-count` | No | `2` | Number of runners per server |

*Required for `create` action

## Usage Examples

### Basic server creation

```yaml
- name: Create Hetzner server
  uses: armbian/actions/hetzner@main
  with:
    action: create
    server-type: cax41
    index: 0
    ssh-key: "UPLOAD"
    hetzner-token: ${{ secrets.HETZNER_ONE }}
    github-token: ${{ secrets.HETZNER_RUNNER }}
    runner-count: 4
```

### Matrix strategy for multiple servers

```yaml
name: Enable Hetzner Runners
on:
  workflow_dispatch:

env:
  MACHINE: 'cax41'
  MACHINE_COUNT: '4'
  RUNNER_COUNT: '4'

jobs:
  Prepare:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{steps.matrix.outputs.matrix}}
    steps:
      - name: Generate matrix
        id: matrix
        run: |
          count=${{ env.MACHINE_COUNT }}
          matrix=$(seq 0 $(( count - 1 )) | jq -cnR '[inputs | tonumber]')
          echo "matrix=${matrix}" >> $GITHUB_OUTPUT

  Create:
    needs: Prepare
    runs-on: ubuntu-latest
    strategy:
      matrix:
        index: ${{fromJson(needs.Prepare.outputs.matrix)}}
    steps:
      - name: Create Hetzner server
        uses: arengmbian/actions/hetzner@main
        with:
          action: create
          server-type: "${{ env.MACHINE }}"
          index: "${{ matrix.index }}"
          delete-existing: "true"
          ssh-key: "UPLOAD"
          hetzner-token: ${{ secrets.HETZNER_ONE }}
          github-token: ${{ secrets.HETZNER_RUNNER }}
          runner-count: "${{ env.RUNNER_COUNT }}"
```

### With automatic cleanup

```yaml
jobs:
  Create:
    # ... server creation ...

  Work:
    needs: Create
    runs-on: ubuntu-latest
    steps:
      - name: Hold servers
        run: sleep "110m"

  Cleanup:
    needs: Work
    if: always()  # Runs even if Work fails
    runs-on: ubuntu-latest
    steps:
      - name: Delete Hetzner server
        uses: armbian/actions/hetzner@main
        with:
          action: delete
          server-type: "cax41"
          index: "0"
          ssh-key: "UPLOAD"
          hetzner-token: ${{ secrets.HETZNER_ONE }}
```

## Server Configuration

Each server is automatically configured with:

- **Docker** - Installed via get.docker.com
- **Armbian config repository** - Added for armbian-config installation
- **Armbian-config** - Installed for runner management
- **GitHub Actions runners** - Configured via armbian-config with:
  - Runner labels: `alfa`, `images`
  - Organization: `armbian`
  - Count: Specified by `runner-count` input
- **10GB swap file** - For improved memory management

## Server Naming

Servers are named using the pattern: `hetzner-{index}`

For example, with `index: 0`, the server will be named `hetzner-runner-0`.

## Permissions Required

The workflow needs these permissions:
- `contents: read` - To checkout the action
- `actions: write` - If updating outputs or creating summaries

## Secrets

You'll need to configure these secrets in your repository:

- `HETZNER_ONE` - Hetzner Cloud API token
- `HETZNER_RUNNER` - GitHub personal access token with `repo` scope
- `UPLOAD` - SSH key name in Hetzner Cloud (must exist in your account)

## Troubleshooting

### Server creation fails

1. Verify your Hetzner API token has sufficient permissions
2. Check that the SSH key exists in your Hetzner Cloud account
3. Ensure the server type is available in your region

### Runners not registering

1. Verify the GitHub token has `repo` scope
2. Check that the armbbian-config repository is accessible
3. Review cloud-init logs in the server console

### Cleanup doesn't run

Ensure the Cleanup job has `if: always()` to run even when previous jobs fail.

## License

MIT
