targetScope = 'resourceGroup'

@description('Azure region for the future AKS workload.')
param location string

@description('Common tags for future AKS resources.')
param tags object

@description('Name prefix for future AKS resources.')
param namePrefix string

var placeholder = {
  location: location
  tags: tags
  namePrefix: namePrefix
}

output placeholderMetadata object = placeholder
output clusterIds array = []
output resourceIds array = []
