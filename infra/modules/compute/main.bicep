// compute/main.bicep — NixOS gateway VM with public IP

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

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

@description('Custom NixOS image resource ID. If empty, uses Ubuntu as placeholder.')
param nixosImageId string = ''

@description('Resource tags')
param tags object

// =====================================================================
// Variables
// =====================================================================

var vmName = 'vm-${projectName}-gw1-${location}'
var nicName = 'nic-${projectName}-gw1-${location}'
var pipName = 'pip-${projectName}-gw1-${location}'
var osDiskName = 'osdisk-${projectName}-gw1-${location}'

// Use custom NixOS image if provided, otherwise fall back to Ubuntu
var useCustomImage = !empty(trim(nixosImageId))

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

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
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
      computerName: 'gw1'
      adminUsername: adminUsername
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
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
        diskSizeGB: 64
      }
      imageReference: useCustomImage ? {
        id: nixosImageId
      } : {
        // Fallback to Ubuntu 24.04 LTS until NixOS custom image is available
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-noble'
        sku: '24_04-lts-gen2'
        version: 'latest'
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
// Diagnostics — Azure Monitor Agent (via VM extension)
// =====================================================================

// Note: For NixOS, the Azure Monitor Agent may need to be installed via
// nix configuration instead. This extension works for Ubuntu fallback.
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = if (!useCustomImage) {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Azure Monitor Agent requires a Data Collection Rule (DCR) and an
// association to the VM in order to route guest telemetry to Log Analytics.
resource vmDataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = if (!useCustomImage) {
  name: '${vmName}-dcr'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    destinations: {
      logAnalytics: [
        {
          name: 'logAnalyticsDestination'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(_Total)\\% Free Space'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogDataSource'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            '*'
          ]
          logLevels: [
            '*'
          ]
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
    ]
  }
}

resource vmDataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = if (!useCustomImage) {
  name: '${vmName}-dcr-association'
  scope: vm
  properties: {
    dataCollectionRuleId: vmDataCollectionRule.id
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

output vmName string = vm.name
output vmId string = vm.id
output publicIpAddress string = publicIp.properties.ipAddress
output nicId string = nic.id
