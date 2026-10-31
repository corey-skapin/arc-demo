@description('Region of the existing Log Analytics workspace.')
param location string

@minLength(2)
@maxLength(15)
param namePrefix string

@description('Exact existing workspace, Arc machine and Action Group resource IDs.')
param workspaceResourceId string
param machineResourceId string
param actionGroupId string
param tags object = {}

var incidentQuery = format('''
Event
| where TimeGenerated > ago(15m)
| where tolower(_ResourceId) == '{0}'
| where Source == 'ArcSqlEngineDemo' and EventID == 6201
| extend Incident = parse_json(RenderedDescription)
| where toint(Incident.schemaVersion) == 1
| where tostring(Incident.scenario) == 'sql-lock-timeout' and tostring(Incident.state) == 'detected'
| where toint(Incident.sqlErrorNumber) == 1222
| project TimeGenerated, Computer, _ResourceId, Incident
''', toLower(machineResourceId))

resource alert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'al-${namePrefix}-sql-lock-timeout'
  location: location
  tags: union(tags, {
    managedBy: 'arc-demo-sql-incident'
    workload: 'sql-lock-timeout'
  })
  properties: {
    displayName: 'Arc SQL lock timeout - ${namePrefix}'
    description: 'A controlled real SQL lock timeout was observed. Investigate recorded blocking evidence; the probe self-recovers and leaves the orders worker running.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT15M'
    scopes: [workspaceResourceId]
    criteria: {
      allOf: [
        {
          query: incidentQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [actionGroupId]
    }
  }
}

output alertRuleId string = alert.id
output alertQuery string = incidentQuery
