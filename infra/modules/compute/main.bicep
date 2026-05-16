// compute/main.bicep — NixOS gateway VM with public IP

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Gateway short name used in resource naming (e.g. gw1, gw2). Each gateway VM in a project must have a distinct name across regions, since the compute resource group is region-scoped but agenix/Comin tooling distinguishes hosts by this name.')
param gatewayName string = 'gw1'

@description('VM size')
param vmSize string

@description('Admin username')
param adminUsername string

@description('SSH public key for admin access')
@secure()
param adminSshPublicKey string

@description('Subnet resource ID to attach the VM NIC to')
param subnetId string

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('NixOS gallery image version resource ID (from Azure Compute Gallery)')
param nixosImageId string

@description('Base64-encoded cloud-init customData for first-boot configuration. Contains the SSH host private key — must be treated as a secret. Empty string means no customData is set.')
@secure()
param customData string = ''

@description('Resource tags')
param tags object

// =====================================================================
// Variables
// =====================================================================

var vmName = 'vm-${projectName}-${gatewayName}-${location}'
var nicName = 'nic-${projectName}-${gatewayName}-${location}'
var pipName = 'pip-${projectName}-${gatewayName}-${location}'
var osDiskName = 'osdisk-${projectName}-${gatewayName}-${location}'

// Deploy the VM only when a NixOS image version has been staged
var hasImageVersion = !empty(trim(nixosImageId))

// =====================================================================
// Public IP
// =====================================================================

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// =====================================================================
// Network Interface
// =====================================================================

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    enableIPForwarding: true // Required for NVA / network appliance role
  }
}

// =====================================================================
// Virtual Machine
// =====================================================================

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = if (hasImageVersion) {
  name: vmName
  location: location
  tags: union(tags, {
    role: 'gateway'
    os: 'nixos'
  })
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: gatewayName
      adminUsername: adminUsername
      customData: empty(trim(customData)) ? null : customData
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 64
      }
      imageReference: {
        id: nixosImageId
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// =====================================================================
// NIC Diagnostics
// =====================================================================

resource nicDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${nicName}-diag'
  scope: nic
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource pipDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${pipName}-diag'
  scope: publicIp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// =====================================================================
// Outputs
// =====================================================================

output vmName string = hasImageVersion ? vm.name : ''
output vmId string = hasImageVersion ? vm.id : ''
output publicIpAddress string = publicIp.properties.ipAddress
output nicId string = nic.id
