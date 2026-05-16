// global.bicep — Project-wide (region-pinned) platform infrastructure
//
// Owns the resources that are intentionally single-instance for the whole
// project, regardless of how many regional landing zones we deploy:
//   - gallery RG  + Azure Compute Gallery + NixOS image definition
//   - keyvault RG + Key Vault kv-${projectName}-${regionCode}
//
// Both are pinned to a single "primary" region (e.g. southcentralus). The
// gallery replicates image versions to other regions via its publishingProfile
// (driven by image-bake.yml); secondary regions consume images from this one
// gallery. The Key Vault stores per-VM SSH host keys for every host in every
// region — secrets are RBAC-scoped, not region-scoped.
//
// CAF tier: Platform (shared service), one deployment per project.
// Trigger:  Manual or path-filtered push (see .github/workflows/global.yml).
// Cadence:  Very rare — only when gallery definition, project-wide Key Vault
//           config, or CI role assignments change.
//
// Outputs consumed by:
//   - image-bake.yml (galleryName, imageDefinitionName, galleryResourceGroup)
//   - deploy-workload.yml (galleryName, imageDefinitionName, keyVaultName)
//
// See docs/architecture-refactor.md D4.

targetScope = 'subscription'

@description('Primary Azure region for project-wide shared services (gallery, Key Vault).')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('Short region code for the primary region, used in the globally-unique Key Vault name (e.g. scus). Kept in the KV name for backwards-compatibility with existing kv-plaz-scus resource.')
param regionCode string

@description('Object ID of the CI service principal for Key Vault Secrets Officer. Leave empty to skip role assignment.')
param ciServicePrincipalObjectId string = ''

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
  scope: 'global'
}

var rgGalleryName  = 'rg-${projectName}-gallery-${location}'
var rgKeyVaultName = 'rg-${projectName}-keyvault-${location}'

resource rgGallery 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgGalleryName
  location: location
  tags: tags
}

resource rgKeyVault 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgKeyVaultName
  location: location
  tags: tags
}

module gallery 'modules/gallery/main.bicep' = {
  name: 'gallery-deployment'
  scope: rgGallery
  params: {
    location: location
    projectName: projectName
    tags: tags
  }
}

module keyVault 'modules/keyvault/main.bicep' = {
  name: 'keyvault-deployment'
  scope: rgKeyVault
  params: {
    location: location
    projectName: projectName
    regionCode: regionCode
    ciServicePrincipalObjectId: ciServicePrincipalObjectId
    tags: tags
  }
}

output galleryResourceGroup  string = rgGalleryName
output galleryName           string = gallery.outputs.galleryName
output imageDefinitionName   string = gallery.outputs.imageDefinitionName
output keyVaultResourceGroup string = rgKeyVaultName
output keyVaultName          string = keyVault.outputs.keyVaultName
output keyVaultId            string = keyVault.outputs.keyVaultId
