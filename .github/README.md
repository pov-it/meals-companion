# GitHub Actions workflows

Workflow YAML cannot be pushed with the current OAuth token (missing `workflow` scope).

Canonical copies live in [`ci/github-workflows/`](../ci/github-workflows/).

To enable Actions (once you have a PAT/`gh` auth with the `workflow` scope):

```bash
mkdir -p .github/workflows
cp ci/github-workflows/*.yml .github/workflows/
git add .github/workflows
git commit -m "Enable Meals Companion browser-build workflows"
git push
```

Or: `gh auth refresh -h github.com -s workflow` then move the files as above.
