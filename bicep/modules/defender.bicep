// Enable Microsoft Defender for Servers Plan 2 at subscription scope.
// main.bicep deploys this only while the plan is not already Standard: this PUT declares
// no `extensions`, so applying it to an enabled plan would strip settings such as
// AgentlessVmScanning (ARM what-if reports Delete properties.extensions).

targetScope = 'subscription'

resource defenderVms 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
  }
}

output pricingTier string = defenderVms.properties.pricingTier
