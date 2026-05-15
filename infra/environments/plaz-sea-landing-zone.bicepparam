using '../landing-zone.bicep'

param location                   = 'southeastasia'
param projectName                = 'plaz'
param vnetAddressPrefix          = '192.168.86.0/24'
param gatewaySubnetPrefix        = '192.168.86.0/28'
param defaultSubnetPrefix        = '192.168.86.16/28'
param logRetentionDays           = 30
param sshSourceAddressPrefix     = ''

// Object ID of the CI service principal (backing AZURE_CLIENT_ID).
// Grants Key Vault Secrets Officer so deploy-workload.yml can write
// the generated ssh_host_ed25519_key. Leave empty to skip role assignment.
param ciServicePrincipalObjectId = readEnvironmentVariable('CI_SP_OBJECT_ID', '')
