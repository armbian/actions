<h2 align="center">
  <a href=#><img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo"></a>
  <br><br>
</h2>

# Armbian GitHub Actions

## Purpose of This Repository

This repository hosts a collection of reusable GitHub Actions used across the Armbian project — for building images, provisioning and managing Hetzner Cloud runners, preparing and cleaning self-hosted runners, driving Device-Under-Test (DUT) hardware tests, and generating release metadata and redirector configuration.

## Repository Layout

Each top-level directory is a self-contained composite GitHub Action (`action.yml`).

| Action | Description |
| --- | --- |
| [`build-images/`](build-images/) | Wraps Armbian's Docker-based image build workflow with a small set of inputs (target, runner size, source/packages repository, board filter). |
| [`collect-data/`](collect-data/) | Runs `iperf3`, `7z b`, kernel/U-Boot and `armbianmonitor` collection over SSH on a DUT and exports results as environment variables. |
| [`dut-run/`](dut-run/) | Installs kernel/DTB/headers from the selected Armbian APT repository on a DUT, reboots it, invokes `collect-data`, and emits a JSON result fragment. |
| [`hetzner/`](hetzner/) | Creates or deletes Hetzner Cloud servers preconfigured (via cloud-init) with Docker and self-hosted runners. See [`hetzner/README.md`](hetzner/README.md). |
| [`latest-cache/`](latest-cache/) | Checks out `armbian/cache` and computes the next rootfs cache version number into `ROOTFSCACHE_VERSION`. |
| [`make-json/`](make-json/) | Generates JSON and Markdown release listings from a GitHub release's assets, filtered via `grep`. See [`make-json/README.md`](make-json/README.md). |
| [`make-list/`](make-list/) | Builds board/branch/release/desktop target lists by cross-referencing `armbian/build` board configs against already-released assets in `armbian/community`. |
| [`make-yaml-redirector/`](make-yaml-redirector/) | Renders a `dlrouter-*.yaml` configuration for the [Armbian download router](https://github.com/armbian/armbian-router), pulling server metadata from NetBox. |
| [`power-on/`](power-on/), [`power-off/`](power-off/) | SSH-triggered power control for DUT hardware, using injected SSH keys. |
| [`triggers/`](triggers/) | Generic SSH trigger action — installs a key, connects, and runs a remote command. |
| [`runner-prepare/`](runner-prepare/) | Cleans mounts, workspaces and caches on self-hosted runners before a build. |
| [`runner-clean/`](runner-clean/) | Post-run cleanup: resolves per-runner proxy/cache settings from `github.armbian.com/servers/github-runners.jq`, exports env vars (APT proxy, ccache, ghcr mirror, xz memory cap), tidies caches, and ensures `tree`, `mktorrent` and `gh` are present. |
| [`team-check/`](team-check/) | Cancels the workflow if the actor is not a member of the given `armbian` GitHub team. |

Other files:

- `index.htm` — the static page deployed via GitHub Pages (see below).
- `.github/workflows/static.yml` — deploys `index.htm` together with JSON data pulled from the `data` branch of `armbian/armbian.github.io` to GitHub Pages.
- `LICENSE` — GNU GPL v3.

## Built With

- **YAML** — composite action definitions (`action.yml`) and the GitHub Actions workflow.
- **Bash** — the logic inside each action's `run:` steps (APT/SSH orchestration, JSON assembly, cache management, NetBox queries via `curl` + `jq`).
- **Python 3** — the `hetzner/` action ships `create_servers.py` and `deploy_runners.py`, driven via the [`hcloud`](https://pypi.org/project/hcloud/) Python client.
- **HTML** — `index.htm`, published through GitHub Pages.

External tools invoked by the actions include `gh`, `jq`, `json` (npm), `ssh`, `curl`, `iperf3`, `7z`, `datamash`, `lftp`, `mktorrent`, `tree`, and `git`.

## Usage

Reference an individual action from another workflow by path and ref, for example:

```yaml
- name: Build images
  uses: armbian/actions/build-images@main
  with:
    choice: "stable"
    runner: "ubuntu-latest"
    sourcerepo: "nightly"
    packagesrepo: "yes"
    advanced: "grep -w tinkerboard |"
```

```yaml
- name: Create Hetzner runner
  uses: armbian/actions/hetzner@main
  with:
    action: create
    server-type: cax41
    ssh-key: "UPLOAD"
    hetzner-token: ${{ secrets.HETZNER_ONE }}
    github-token: ${{ secrets.HETZNER_RUNNER }}
```

Per-action inputs and further examples are documented in the individual `action.yml` files and, where present, the action's own `README.md` (`build-images/`, `hetzner/`, `make-json/`).

## Continuous Integration

CI status and history for this repository are tracked centrally:

- [CI overview for `armbian/actions`](https://actions.armbian.com/?repo=actions)

## Related Links

- Armbian project: <https://www.armbian.com>
- Documentation: <https://docs.armbian.com>
- Armbian build framework: <https://github.com/armbian/build>
- Armbian download router: <https://github.com/armbian/armbian-router>

## License

Released under the GNU General Public License v3.0 — see [`LICENSE`](LICENSE).
