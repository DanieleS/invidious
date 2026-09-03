# CLAUDE.md

Fork of [iv-org/invidious](https://github.com/iv-org/invidious). Crystal + Kemal,
server-side ECR templates, PostgreSQL.

## Pull requests target this fork, never upstream

GitHub always defaults the base repository of a fork's pull request to the
parent, and offers no setting to change it. So it has to be pinned explicitly:

- Always open pull requests against `DanieleS/invidious`, base branch `master`.
  Pass the base repository explicitly rather than relying on a default —
  `gh pr create --repo DanieleS/invidious`, or `owner`/`repo` on API calls.
- On the web UI, use
  `https://github.com/DanieleS/invidious/compare/master...BRANCH`, which
  pre-selects this repo as the base, instead of the "Contribute" button.
- Locally, `gh repo set-default DanieleS/invidious` once per clone makes the
  `gh` CLI resolve to this fork.

Only send something upstream when that is the explicit intent, and note that
`AI_POLICY.md` then applies: it requires disclosing the exact model and tooling
used, and demonstrating human verification.

## Roadmap

Planned work is tracked in issues, each carrying its own feasibility analysis,
integration points and upstream prior art:

- #1 — OIDC authentication
- #2 — UI modernization (tiered; the CSS design-token tier goes first)
- #3 — Kids mode

## Build

```sh
make            # build (shards install + crystal build)
make verify     # typecheck without producing a binary
make test       # crystal spec
make format     # crystal tool format
```

Test coverage is thin: 15 spec files, no route or integration tests and no
visual regression testing. Changes to routes or templates need manual
verification, across all three theme states and both mobile and desktop for
anything touching CSS.
