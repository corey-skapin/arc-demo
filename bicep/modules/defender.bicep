// Enable Microsoft Defender for Servers Plan 2 at subscription scope.

targetScope = 'subscription'

resource defenderVms 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'P2'
  }
}

output pricingTier string = defenderVms.properties.pricingTier
