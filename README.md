# LaLiga Value Map — self-building site

**Live:** https://sb-marc.github.io/laliga-value-map/

`index.html` is the built **LaLiga Fantasy Value Map**: a scatter of price vs. average
fantasy points per appearance, with a per-position OLS fair-price line and
under/over-valued tables. All data is baked into the single file.

## How it updates itself

A GitHub Actions workflow (`.github/workflows/refresh.yml`) runs **daily at 05:10 UTC**
(and on demand via the *Run workflow* button). On GitHub's servers — no laptop involved — it:

1. runs `scripts/generate_value_map.ps1` (PowerShell Core), which pulls the public
   Biwenger feed, fits the fair-price lines, fills `templates/value_map_template.html`,
   and writes a deduplicated raw-data snapshot under `data/archive/`;
2. copies the result to `index.html` and commits it back to `main`.

GitHub Pages (deploy-from-branch: `main` / root) then serves the new build within ~1 min.

## Files

| Path | Role |
|---|---|
| `index.html` | the built page GitHub Pages serves — **do not hand-edit**, it is overwritten every run |
| `scripts/generate_value_map.ps1` | fetch → regression → fill template → write page + archive |
| `templates/value_map_template.html` | the page with `__TOKENS__` the generator fills |
| `data/archive/` + `index.csv` | every distinct dataset, content-hash deduplicated, with a manifest |
| `.github/workflows/refresh.yml` | the daily job |

## Running it by hand

```
pwsh ./scripts/generate_value_map.ps1 -ProjectRoot .
```

writes `laliga_value_map.html` (copy to `index.html` to publish) plus the `data/` snapshots.
