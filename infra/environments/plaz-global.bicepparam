using '../global.bicep'

// Primary region for project-wide shared services. Pinned to southcentralus:
//   - The Compute Gallery lives here; image versions are replicated to other
//     regions via image-bake.yml.
//   - The Key Vault `kv-plaz-scus` lives here; SSH host keys for every host
//     (gw1-scus in scus, gw1-sea in sea, …) are stored here.
//
// To migrate the primary region, you must also re-create the Key Vault and
// re-publish gallery image versions in the new region; this is rare.
param location                   = 'southcentralus'
param projectName                = 'plaz'
param regionCode                 = 'scus'

// Object ID of the CI service principal (backing AZURE_CLIENT_ID).
// Grants Key Vault Secrets Officer so deploy-workload.yml can write
// the generated ssh_host_ed25519_key. Leave empty to skip role assignment.
param ciServicePrincipalObjectId = readEnvironmentVariable('CI_SP_OBJECT_ID', '')
