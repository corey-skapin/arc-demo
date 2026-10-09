targetScope = 'resourceGroup'

@description('Azure region for the future Container Apps workload.')
param location string

@description('Common tags for future Container Apps resources.')
param tags object

@description('Name prefix for future Container Apps resources.')
param namePrefix string

var placeholder = {
  location: location
  tags: tags
  namePrefix: namePrefix
}

output placeholderMetadata object = placeholder
output containerAppIds array = []
output resourceIds array = []
