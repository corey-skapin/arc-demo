targetScope = 'resourceGroup'

@description('Azure region for the future Azure-native VM workload.')
param location string

@description('Common tags for future Azure-native VM resources.')
param tags object

@description('Name prefix for future Azure-native VM resources.')
param namePrefix string

var placeholder = {
  location: location
  tags: tags
  namePrefix: namePrefix
}

output placeholderMetadata object = placeholder
output vmNames array = []
output resourceIds array = []
