// networking/main.bicep — Hub VNET, subnets, NSGs, and diagnostics

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('VNET address space')
param vnetAddressPrefix string

@description('Gateway subnet prefix')
param gatewaySubnetPrefix string

@description('Default subnet prefix')
param defaultSubnetPrefix string

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object

// =====================================================================
// Variables
// =====================================================================

var vnetName = 'vnet-${projectName}-hub-${location}'
var nsgGatewayName = 'nsg-${projectName}-gateway-${location}'
var nsgDefaultName = 'nsg-${projectName}-default-${location}'
var natGatewayName = 'natgw-${projectName}-hub-${location}'
var natGatewayPipName = 'pip-${projectName}-natgw-${location}'

// =====================================================================
// Network Security Groups
// =====================================================================

resource nsgGateway 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgGatewayName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSSHFromHome'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '99.7.231.75/32'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowTailscaleWireGuard'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '41641'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowTailscaleSTUN'
        properties: {
          priority: 1020
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '3478'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgDefault 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgDefaultName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

// =====================================================================
// NAT Gateway
// =====================================================================

resource natGatewayPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: natGatewayPipName
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

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natGatewayPip.id
      }
    ]
  }
}

// =====================================================================
// Virtual Network
// =====================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-gateway'
        properties: {
          addressPrefix: gatewaySubnetPrefix
          networkSecurityGroup: {
            id: nsgGateway.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'snet-default'
        properties: {
          addressPrefix: defaultSubnetPrefix
          networkSecurityGroup: {
            id: nsgDefault.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ]
  }
}

// =====================================================================
// Diagnostics
// =====================================================================

resource vnetDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${vnetName}-diag'
  scope: vnet
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

resource nsgGatewayDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${nsgGatewayName}-diag'
  scope: nsgGateway
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource natGatewayPipDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${natGatewayPipName}-diag'
  scope: natGatewayPip
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

output vnetId string = vnet.id
output vnetName string = vnet.name
output gatewaySubnetId string = vnet.properties.subnets[0].id
output defaultSubnetId string = vnet.properties.subnets[1].id
output natGatewayId string = natGateway.id
