@description('Existing workspace region.')
param location string

@description('Deterministic workbook GUID chosen by the scoped wrapper.')
param workbookName string

param displayName string
param workspaceResourceId string
param serializedData string

@allowed([
  'capacity'
  'optimisation'
])
param purpose string

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  kind: 'shared'
  tags: {
    managedBy: 'arc-demo-operational-workbooks'
    purpose: purpose
  }
  properties: {
    displayName: displayName
    serializedData: serializedData
    version: 'Notebook/1.0'
    sourceId: workspaceResourceId
    category: 'workbook'
  }
}

output workbookResourceId string = workbook.id
