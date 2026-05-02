// keyvault/main.bicep — Key Vault for CI deployment secrets

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Object ID of the CI service principal that needs Key Vault Secrets Officer access')
param ciServicePrincipalObjectId string

@description('Resource tags')
param tags object

// =====================================================================
// Variables
// =====================================================================

// Key Vault names must be 3-24 chars and globally unique.
// uniqueString produces a stable 13-char hash; take(…, 8) keeps us under 24.
var kvName = 'kv-${projectName}-ci-${take(uniqueString(resourceGroup().id, 'kvci'), 8)}'

// Key Vault Secrets Officer built-in role ID
var kvSecretsOfficerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

// =====================================================================
// Key Vault
// =====================================================================

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true    // Use Azure RBAC, not legacy access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7     // Minimum retention
  }
}

// Grant the CI service principal read/write access to Key Vault secrets.
// The Key Vault Secrets Officer role allows creating, reading, and updating
// secrets without granting access to keys or certificates.
resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, ciServicePrincipalObjectId, kvSecretsOfficerRoleId)
  scope: kv
  properties: {
    roleDefinitionId: kvSecretsOfficerRoleId
    principalId: ciServicePrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

// =====================================================================
// Outputs
// =====================================================================

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
