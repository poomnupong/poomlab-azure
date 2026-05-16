using '../landing-zone.bicep'

param location                   = 'southcentralus'
param projectName                = 'plaz'
param vnetAddressPrefix          = '192.168.85.0/24'
param gatewaySubnetPrefix        = '192.168.85.0/28'
param defaultSubnetPrefix        = '192.168.85.16/28'
param logRetentionDays           = 30
param sshSourceAddressPrefix     = '99.7.231.75/32'

// Note: the project-wide Compute Gallery and Key Vault live in
// infra/global.bicep + infra/environments/plaz-global.bicepparam, deployed
// once by .github/workflows/global.yml. Region-uniquified names that used
// to need `regionCode` (kv-plaz-scus) are now project-wide and managed there.
