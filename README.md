A utility repository to build a quarto book website for the BMM Developer Notes for the bmm package: https://github.com/popov-lab/bmm

The contents of the `_book` directory contain the rendered website, and they are automatically pushed via Github Action to the gh-pages branch of `bmm`, at both `dev/dev-notes` and `dev-notes`.

## How to make changes

1. Make the changes to the .qmd files
2. Run `Rscript tools/check-drift.R` to check the code excerpts against bmm
3. Run `quarto render` from the terminal to render the book
4. Commit and push the changes to the `master` branch

## Keeping the notes in sync with bmm

The chapters teach by quoting bmm's own source, so they go stale when bmm changes. `tools/check-drift.R` catches that. It needs base R only — no packages, and **not** an installed bmm, because the bmm in your library may be a personal fork ahead of any release.

```bash
Rscript tools/check-drift.R                  # bmm at ../bmm, at the version index.qmd claims
Rscript tools/check-drift.R --bmm ../bmm     # explicit checkout
Rscript tools/check-drift.R --ref develop    # check against an unreleased ref
Rscript tools/check-drift.R --ref WORKTREE   # check the checkout as it stands
```

By default it reads the version the book claims out of `index.qmd` and checks against that tag, so this repository is not permanently red on unreleased work in bmm.

Every fenced R block that quotes bmm carries its source:

```` markdown
```{.r filename="R/model_sdm.R" bmm-src="configure_model.sdm"}
````

`filename=` is a Quarto feature and shows the reader which file the block came from. `bmm-src=` (comma-separated for a block with several definitions) is what the checker resolves. Extra attributes reach the HTML as `data-*` and are dropped by the LaTeX writer, so the PDF is unaffected.

A block that elides on purpose is marked `bmm-excerpt="abridged"`. It must still resolve — the name has to exist in bmm — but its body is not compared. There are four of these, each also carrying a visible `...` in the code.

Two things the checker will not do: it will not skip an anchor it cannot resolve (that is always an error, because silent skipping on rename is how these checkers stop working), and it will not verify prose claims other than package paths and identifiers matching bmm's own naming conventions.

### Where the check runs

- **In this repository** (`.github/workflows/check-drift.yml`): blocking, on push and pull request, against the released ref.
- **In bmm**: the same script should run on pull requests touching `R/**`, non-blocking, reporting to the step summary. That is the load-bearing trigger, because it fires in the pull request that breaks the notes while the author still remembers why. It is not set up yet — see the open follow-up.

There is deliberately no scheduled cron. GitHub disables scheduled workflows after 60 days of repository inactivity, and this repository went 2026-07-08 to 2026-09-16 without a commit, so a cron would have switched itself off.
