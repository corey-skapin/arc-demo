// Assigns MCSB + NIST 800-53 Rev 5 policy initiatives at subscription scope.

targetScope = 'subscription'

@description('Region for the system-assigned managed identity on each assignment')
param location string

@description('Name prefix for assignment names')
param namePrefix string = 'arc-demo'

var mcsbDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
var nistDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/179d1daa-458f-4e47-8086-2a68d0d6c38f'

resource mcsb 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'mcsb-${namePrefix}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Microsoft cloud security benchmark (Arc Demo)'
    policyDefinitionId: mcsbDefinitionId
    enforcementMode: 'Default'
  }
}

resource nist 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'nist-${namePrefix}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'NIST SP 800-53 Rev. 5 (Arc Demo)'
    policyDefinitionId: nistDefinitionId
    enforcementMode: 'Default'
  }
}

output mcsbAssignmentId string = mcsb.id
output nistAssignmentId string = nist.id
