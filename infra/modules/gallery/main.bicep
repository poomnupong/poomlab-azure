// gallery/main.bicep — Azure Compute Gallery and NixOS image definition
//
// Creates a Shared Image Gallery (Azure Compute Gallery) and a NixOS image
// definition.  Image *versions* are staged imperatively by the image-bake
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
var sanitizedProjectName = replace(projectName, '-', '_')
var galleryName = 'gal_${sanitizedProjectName}'
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
      publisher: 'plaz'
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
    // SecurityType is intentionally omitted (Standard security only).
    // NixOS uses systemd-boot which is not signed with Microsoft's UEFI CA;
    // Trusted Launch / Secure Boot would prevent the VM from booting.
    // See: https://github.com/poomnupong/nixos-azimage-builder#security-type
    features: [
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
