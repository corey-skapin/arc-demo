// Log Analytics workspace + OMS solutions for VMInsights & ChangeTracking.

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Workspace name')
param workspaceName string = 'law-arc-demo'

@description('Retention in days')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource vmiSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'VMInsights(${workspaceName})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: law.id
  }
  plan: {
    name: 'VMInsights(${workspaceName})'
    publisher: 'Microsoft'
    product: 'OMSGallery/VMInsights'
    promotionCode: ''
  }
}

resource ctSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'ChangeTracking(${workspaceName})'
  location: location
  tags: tags
  properties: {
    workspaceResourceId: law.id
  }
  plan: {
    name: 'ChangeTracking(${workspaceName})'
    publisher: 'Microsoft'
    product: 'OMSGallery/ChangeTracking'
    promotionCode: ''
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
output customerId string = law.properties.customerId
