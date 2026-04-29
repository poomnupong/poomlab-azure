// gallery/main.bicep — Azure Compute Gallery and NixOS image definition
//
// Creates a Shared Image Gallery (Azure Compute Gallery) and a NixOS image
// definition.  Image *versions* are staged imperatively by the deploy-infra
// workflow (VHD download → managed-disk upload → gallery image version).

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Resource tags')
param tags object

// =====================================================================
// Variables
// =====================================================================

// Gallery names allow only alphanumerics, underscores, and dots.
var galleryName = 'gal_${projectName}'
var imageDefinitionName = 'nixos-azimage'

// =====================================================================
// Azure Compute Gallery
// =====================================================================

resource gallery 'Microsoft.Compute/galleries@2023-07-03' = {
  name: galleryName
  location: location
  tags: tags
  properties: {
    description: 'Image gallery for ${projectName}'
  }
}

// =====================================================================
// NixOS Image Definition
// =====================================================================

resource imageDefinition 'Microsoft.Compute/galleries/images@2023-07-03' = {
  parent: gallery
  name: imageDefinitionName
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    architecture: 'x64'
    identifier: {
      publisher: 'poomlab'
      offer: 'nixos'
      sku: 'nixos-azimage'
    }
    recommended: {
      vCPUs: {
        min: 2
        max: 32
      }
      memory: {
        min: 4
        max: 128
      }
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunchSupported'
      }
      {
        name: 'DiskControllerTypes'
        value: 'SCSI, NVMe'
      }
    ]
  }
}

// =====================================================================
// Outputs
// =====================================================================

output galleryName string = gallery.name
output galleryId string = gallery.id
output imageDefinitionName string = imageDefinition.name
output imageDefinitionId string = imageDefinition.id
