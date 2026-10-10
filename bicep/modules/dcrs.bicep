targetScope = 'resourceGroup'

// DCR resources are created by scripts\Deploy-ArcDemo.ps1 after the Log Analytics
// workspace solutions have provisioned their tables. Keep deterministic IDs here
// so Bicep outputs and downstream DCRA association logic stay compatible.

var dcrCoreName = 'dcr-arc-demo'
var dcrVmiName = 'dcr-vminsights'
var dcrCtName = 'dcr-changetracking'

output dcrCoreId string = resourceId('Microsoft.Insights/dataCollectionRules', dcrCoreName)
output dcrVmiId string = resourceId('Microsoft.Insights/dataCollectionRules', dcrVmiName)
output dcrCtId string = resourceId('Microsoft.Insights/dataCollectionRules', dcrCtName)
