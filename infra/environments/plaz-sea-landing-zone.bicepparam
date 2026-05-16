using '../landing-zone.bicep'

param location                   = 'southeastasia'
param projectName                = 'plaz'
param vnetAddressPrefix          = '192.168.86.0/24'
param gatewaySubnetPrefix        = '192.168.86.0/28'
param defaultSubnetPrefix        = '192.168.86.16/28'
param logRetentionDays           = 30
param sshSourceAddressPrefix     = ''

// Note: the project-wide Compute Gallery and Key Vault live in
// infra/global.bicep + infra/environments/plaz-global.bicepparam, deployed
// once by .github/workflows/global.yml. Secondary regions consume the
// same gallery / Key Vault as the primary region.
