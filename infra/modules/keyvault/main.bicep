// keyvault/main.bicep — Key Vault for platform secrets
//
// Stores per-VM SSH host private keys injected via cloud-init customData
// (Phase 5 Option A agenix host key delivery).
//
// Uses Azure RBAC (enableRbacAuthorization = true).
// CI service principal gets Key Vault Secrets Officer on this vault.

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Short region code used to keep the (globally unique) Key Vault name distinct across regions (e.g. scus, sea).')
param regionCode string

@description('Object ID of the CI service principal for Key Vault Secrets Officer role assignment. Leave empty to skip.')
param ciServicePrincipalObjectId string = ''

@description('Resource tags')
param tags object

var keyVaultName = 'kv-${projectName}-${regionCode}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Key Vault Secrets Officer — allows CI SP to write/read secrets
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource ciSecretsOfficerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(ciServicePrincipalObjectId)) {
  name: guid(keyVault.id, ciServicePrincipalObjectId, kvSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: ciServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultName string = keyVault.name
output keyVaultId   string = keyVault.id
output keyVaultUri  string = keyVault.properties.vaultUri
