# Main-branch protection

`main` is the deployment branch for Bicep workflows and Comin's runtime
configuration. Use the existing **repository ruleset**, rather than creating a
second legacy branch-protection configuration.

## Observed configuration and proposed checks

At the September 2026 health review, active ruleset `ruleset01` (ID `15896030`)
targeted the default branch. It required PRs, blocked deletion and
non-fast-forward pushes, and enabled Copilot review. It did **not** require
status checks. Its approval count was zero, and it had configured bypass actors.
The CLI's legacy `/branches/main/protection` endpoint returned 404 even though
the ruleset was active.

Adding required checks is a separate repository-administrator decision. This
document is a proposal, not evidence that repository settings were changed.
Preserve the existing target, enforcement, PR policy, and bypass actors unless
the owner explicitly approves changing them.

| Required check to propose | Workflow | Behavior |
|---|---|---|
| `Validate Bicep` | `ci-pr.yml` | Always produces a result; validates Bicep/what-if when infrastructure paths change |
| `Validate NixOS` | `ci-pr.yml` | Always produces a result; checks the flake when NixOS paths change |
| `Validate CI automation` | `ci-pr.yml` | Always runs helper/event regression tests and workflow lint |

The first two close the gap identified in the review. Add the automation check
once its first PR run has completed successfully. Select the GitHub Actions
integration as the expected check source where GitHub offers that control.

Do **not** make `Build & Tier 1 Smoke` globally required yet: `image-bake.yml`
has workflow-level path filters, so unrelated PRs might wait forever for a
check that never starts. An always-emitted image gate would need a separate
workflow design change. Gallery publication and Tier 2 Azure smoke intentionally
do not run on PRs.

## Updating the existing ruleset

1. Open **Settings → Rules → Rulesets → ruleset01**.
2. Preserve its existing enforcement, branch targets, bypass list, and other
   rules. Do not replace the whole configuration with an example payload.
3. Enable **Require status checks to pass**, then select the exact check names
   listed above that have already run successfully.
4. Enable **Require branches to be up to date before merging** if the owner
   approves strict checking.
5. Save only after administrator approval, and read back the effective rules.

For read-only inspection:

```bash
gh api repos/poomnupong/poomlab-azure/rules/branches/main
gh api repos/poomnupong/poomlab-azure/rulesets/15896030
```

For an approved API update, start with a fresh read of that ruleset, preserve
the documented writable fields and existing rules, and add only the agreed
`required_status_checks` rule. Check for intervening edits before writing and
inspect `/rules/branches/main` afterward. Do not use a legacy protection PUT
that silently imposes a different approval/bypass policy.

For a ruleset with the two initially proposed checks, the additional rule is:

```json
{
  "type": "required_status_checks",
  "parameters": {
    "required_status_checks": [
      {"context": "Validate Bicep", "integration_id": 15368},
      {"context": "Validate NixOS", "integration_id": 15368}
    ],
    "strict_required_status_checks_policy": true,
    "do_not_enforce_on_create": false
  }
}
```

Verify the GitHub Actions integration ID against an actual check run before
using this example. This fragment is not a complete ruleset replacement.
Add `Validate CI automation` to the list only after it exists on the repository.

## Deployment and bypass implications

`image-bake` publishes and runs its real-Azure smoke job on `main` using the
`production` environment. `deploy-workload` manages workload infrastructure.
Review their triggers before merging changes: a PR merge is not merely a
documentation operation when deployment paths change.

Comin on running gateways polls `main` independently of GitHub environment
approval gates. It uses the agenix-managed GitHub credential, not an ephemeral
Actions token, for ongoing operation. A `production` environment reviewer does
not gate those on-host pulls. Keep gateways stopped when that is the approved
operating state.

The deployment workflow also commits encrypted-secret/recipient updates.
Review how its identity interacts with existing bypass rules before tightening
access. Do not remove bypass actors, change required approval counts, enable
linear history, or change merge methods as an incidental part of adding checks.

See [secret rotation and recovery](comin-deployment.md#rotating-the-github-pat)
and the [secrets reference](secrets.md) for the separate credential copies.
