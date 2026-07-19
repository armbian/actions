# update-readme

AI-driven README generator. Reads a repository's own files (file tree, layout,
manifests, CI workflows, existing README) and asks Claude to (re)write an
accurate `README.md`. It only ever writes `README.md` and is instructed to
describe **only what the files evidence** — no invented features or links.

Driven by the [**Update README (AI)**](../.github/workflows/update-readme.yml)
workflow, which runs it against target repos and opens a pull request in each.
The workflow is `workflow_dispatch` (pass `repos` to target specific ones) and
scheduled weekly. Re-runs are idempotent: no PR is opened when the generated
README matches the current one.

## Run locally

```bash
pip install 'anthropic>=0.40.0'
ANTHROPIC_API_KEY=sk-... \
  python3 generate_readme.py --repo-dir /path/to/repo --repo-name armbian/configng
# writes /path/to/repo/README.md — review, then commit/PR yourself
```

Options: `--repo-dir` (default `.`), `--repo-name` (default from git remote),
`--model` (default `$MODEL` or `claude-opus-4-7`), `--max-context-chars`
(default 180000).

## Required secrets (CI)

| Secret | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API key (same one the reporting workflows use) |
| `ACCESS_TOKEN` | PAT with `repo` scope on the target repos — the builtin `GITHUB_TOKEN` can't push branches or open PRs cross-repo |
