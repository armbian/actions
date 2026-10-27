# depends-on

Holds a pull request until what it depends on is merged, and tells a pull
request when what it watches has landed.

- `Depends-on:` lines hold an open pull request. The action sets a commit
  status (`depends-on`) on its head commit; make it a required check in a
  ruleset and GitHub keeps the merge button disabled until the status turns
  green.
- `Notify-when:` lines hold nothing: the pull request can be merged at once.
  When a line is met, also long after the merge, the action comments on the
  pull request, so its participants learn that, say, a patch it carries
  has landed upstream and the copy can go.

## Lines

One condition per line in the pull request description, after `Depends-on:`
or `Notify-when:`. Lines inside fenced code blocks or quotes do not count.

| Condition | Met when |
|---|---|
| `#123` | pull request 123 of this repository is merged |
| `owner/repo#123` | that pull request on GitHub is merged |
| `https://github.com/owner/repo/pull/123` | the same |
| `owner/repo#123 released` | it is merged and its merge commit is in the latest release |
| `owner/repo#123 in <branch or tag>` | it is merged and its merge commit is in that branch or tag |
| `git <https url> <branch or tag>` | the ref exists in that git repository |
| `git <https url> <ref or commit> in <ref>` | that commit is reachable from `<ref>` |
| `git <https url> contains "<text>" in <ref> after <tag>` | a commit message in `<ref>` after `<tag>` contains `<text>` |

The `contains` form is for patches sent by mail: their commit is not known
until a maintainer applies them. Search for something the applied commit is
sure to carry, such as the Message-ID that `b4` puts on its `Link:` line, or
the subject. For example, to learn when a patch reaches mainline:

```
Notify-when: git https://github.com/torvalds/linux.git contains "20261005-kexec-v2-1-0123456789ab@example.org" in master after v7.3
```

Only `https://` URLs and plain ref names are accepted.

## Status and comments

For `Depends-on:` the status is `success` when every line is met, `pending`
while one is not met yet, and `failure` when one cannot be met (closed
without merge), cannot be read, or is not understood. When all lines are
met, the action comments once for that set of lines.

For `Notify-when:` the action comments once per line when it is met, with a
link to the commit when a `git` condition found one. While some line is not announced, the pull
request carries the `notify-pending` label; scheduled runs look only at open
pull requests and at those with the label, not at every merged one. A pull
request closed without merge stops being watched, and a merged one gives up
after `notify-ttl-days` with a last comment.

Commit links are known for github.com, gitlab.com, git.u-boot-project.org
(and source.denx.de), gitlab.freedesktop.org, salsa.debian.org, codeberg.org,
git.sr.ht, git.kernel.org and git.openwrt.org. Add others with
`commit-links`, one `<host> <URL>` per line, where the URL uses `{repo}`
(the path without `.git`), `{path}` and `{sha}`. Without a template the
comment gives the full commit and the repository.

## Fetching from other git servers

Conditions on GitHub are answered by its API. Other servers are fetched:
commits only, without files, where the server supports it, and only the
commits after `<tag>` where the server can cut there. On an event (an edited
description, a push, a label) a pull request is checked in full at once;
scheduled runs fetch from other servers every `git-every-hours`. Each fetch
has `git-fetch-timeout` seconds and a run at most `git-max-fetches` fetches;
a condition cut by these limits stays pending.

Some servers make this slow. git.kernel.org does not support partial fetch,
and a stable branch from there did not fit in five minutes; use the GitHub
mirrors of the kernel trees instead.

## Releasing the hold

- Edit the description: anyone with write access can remove or change a
  `Depends-on:` line, and the status follows at once.
- Bypass the ruleset: actors on its bypass list can merge regardless.
- Add the `depends-on: override` label: it counts when the person who added
  it has at least the `override-role` (default `maintain`); the status then
  names who released it. Removing the label restores the hold.

## Workflow

```yaml
name: "Pull request dependencies"

on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled, closed]
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch:

permissions: {}

concurrency:
  group: depends-on-${{ github.event.pull_request.number || 'all' }}
  cancel-in-progress: false

jobs:
  evaluate:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
      issues: read
    outputs:
      result: ${{ steps.evaluate.outputs.result }}
    steps:
      - id: evaluate
        uses: armbian/actions/depends-on@<commit sha>
        with:
          mode: evaluate

  apply:
    needs: evaluate
    runs-on: ubuntu-latest
    permissions:
      statuses: write
      pull-requests: write
    steps:
      - uses: armbian/actions/depends-on@<commit sha>
        with:
          mode: apply
          result: ${{ needs.evaluate.outputs.result }}
```

`pull_request_target` lets the check run for pull requests from forks; the
action never checks out their code, it reads only the description and labels
through the API. A closed pull request re-checks every open one, since others
may wait for it. The schedule catches changes in other repositories, which
send no event here. Pin the action to a commit: the workflow runs with write
access.

## Inputs

| Input | Default | |
|---|---|---|
| `mode` | `all` | `evaluate` (read-only, outputs `result`), `apply` (writes from `result`), or `all` in one step |
| `result` | | decisions of an `evaluate` step, for `apply` |
| `pull-requests` | | numbers or `all`; empty: the event's pull request, or all |
| `token` | `github.token` | must read every repository named in a line |
| `context` | `depends-on` | name of the commit status |
| `override-label` | `depends-on: override` | label that releases the hold |
| `override-role` | `maintain` | lowest role whose override label counts |
| `commit-links` | | extra commit page templates |
| `notify-label` | `notify-pending` | label of pull requests with lines not announced |
| `notify-ttl-days` | `365` | days after the merge to keep watching |
| `git-every-hours` | `6` | how often scheduled runs fetch from other servers |
| `git-max-fetches` | `10` | fetches per run |
| `git-fetch-timeout` | `300` | seconds per fetch |
| `max-lines` | `20` | most lines per pull request |

## Trust

The `evaluate` job reads the descriptions and contacts the dependencies with a
read-only token; git speaks https only and takes words from a description
only as an `https://` URL or a plain ref name. The `apply` job writes statuses,
comments and the notify label and reads no description, but it trusts the
decisions of `evaluate`: it only checks that a status goes to the head commit
of an open pull request and that a comment has one of the fixed shapes. Never
feed it a `result` from an untrusted run.

The default token reads only its own repository and public ones.
