# Region code convention — design note

> Persisted answer to the earlier question: *"Should we add a separate
> `code ↔ azure-region` shorthand map (e.g. `scus`/`sea`/`jpe`) to shorten
> resource names?"*

## TL;DR

**No.** Don't introduce a second source of truth. `infra/regions.json`
already encodes `regionCode ↔ location`. Just document the naming
convention in the existing `_comment` block, and only build a real
`code → location` helper when a second resource actually needs it.

## Findings (verified in the current branch)

1. **`infra/regions.json` is the single source of truth.** Every region
   entry already carries both `location` (full Azure name) and
   `regionCode` (3-letter abbreviation). All matrix workflows
   (landing-zone, deploy-workload, comin-status, image-bake) discover
   regions from this file via `jq`.
   - Citations: `infra/regions.json:29-52`,
     `.github/workflows/landing-zone.yml` (discover job),
     `.github/workflows/deploy-workload.yml` (discover job + matrix),
     `.github/workflows/comin-status.yml` (discover job),
     `.github/workflows/image-bake.yml` (target-regions step).

2. **Only one resource actually uses the short code today.** Key Vault,
   because its global name must fit in 24 characters:
   `kv-${projectName}-${regionCode}` in
   `infra/modules/keyvault/main.bicep`. Every other resource uses the
   full Azure `location` string and is well under any length limit.

3. **`REGION_CODE` env var is legacy.** `deploy-workload.yml` exports it,
   but nothing downstream reads it. `regions.json`'s `_comment` already
   flags `regionCode` as "legacy; exported as env var only".

## Recommendation

- **Skip the separate shorthand map.** A second `code → location`
  dictionary (in Bicep, a workflow, or a script) would duplicate
  `regions.json` with no real consumer to justify the divergence risk.

- **Document the abbreviation convention** in the `_comment` block of
  `infra/regions.json` so future regions stay consistent: 3-letter code
  that tracks Azure's word order — for example:
  - `southcentralus` → `scus`
  - `southeastasia`  → `sea`
  - `japaneast`      → `jpe`

- **Defer** any real `code → location` helper until a second resource
  needs a shortened name (e.g. VM names approaching the 64-char Linux
  limit, or a new globally-unique resource type).

## Decision needed

Pick one and let me know — I'll do the change in a follow-up commit:

- **(a)** Update `regions.json`'s `_comment` now to document the
  abbreviation convention described above.
- **(b)** Leave as-is and revisit when a second consumer of the short
  code appears.
