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

var machineName = last(split(machineResourceId, '/'))
var incidentQuery = format('''
Event
| where TimeGenerated > ago(15m)
| where tolower(_ResourceId) == '{0}'
| where Source == 'ArcSqlEngineDemo' and EventID == 6201
| extend Incident = parse_json(RenderedDescription)
| where toint(Incident.schemaVersion) == 2
| where tostring(Incident.state) == 'detected'
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
    description: 'A SQL request on ${machineName} timed out waiting for a lock (error 1222). Investigate the recorded session and lock-wait evidence.'
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
