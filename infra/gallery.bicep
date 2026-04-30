// gallery.bicep — Subscription-level orchestrator for the image gallery
//
// Deployed by the stage-image workflow job *before* the NixOS VHD is
// uploaded.  Kept separate from main.bicep so the gallery and image
// definition exist before the first image version is staged.

targetScope = 'subscription'

// =====================================================================
// Parameters
// =====================================================================

@description('Azure region for gallery resources')
param location string

@description('Project name used in resource naming')
param projectName string = 'plaz'

@description('Tags applied to all resources')
param tags object = {
  project: projectName
  managedBy: 'bicep'
  repository: 'poomnupong/poomlab-azure'
}

// =====================================================================
// Variables
// =====================================================================

var rgGalleryName = 'rg-${projectName}-gallery-${location}'

// =====================================================================
// Resource Group
// =====================================================================

resource rgGallery 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgGalleryName
  location: location
  tags: tags
}

// =====================================================================
// Module Deployment
// =====================================================================

module gallery 'modules/gallery/main.bicep' = {
  name: 'gallery-deployment'
  scope: rgGallery
  params: {
    location: location
    projectName: projectName
    tags: tags
  }
}

// =====================================================================
// Outputs
// =====================================================================

output galleryResourceGroup string = rgGalleryName
output galleryName string = gallery.outputs.galleryName
output galleryId string = gallery.outputs.galleryId
output imageDefinitionName string = gallery.outputs.imageDefinitionName
output imageDefinitionId string = gallery.outputs.imageDefinitionId
