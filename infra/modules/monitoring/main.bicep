// monitoring/main.bicep — Log Analytics workspace and diagnostic infrastructure

@description('Azure region')
param location string

@description('Project name for resource naming')
param projectName string

@description('Log retention in days')
param logRetentionDays int = 30

@description('Resource tags')
param tags object

// =====================================================================
// Log Analytics Workspace
// =====================================================================

var workspaceName = 'log-${projectName}-main-${location}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: 1
    }
  }
}

// =====================================================================
// Outputs
// =====================================================================

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
