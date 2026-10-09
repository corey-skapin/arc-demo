targetScope = 'resourceGroup'

@description('Azure region for the Container Apps workload.')
param location string

@description('Common tags for Container Apps resources.')
param tags object

@description('Name prefix for Container Apps resources.')
param namePrefix string

@description('Existing Action Group resource ID to notify when the Container App restarts repeatedly.')
param actionGroupId string

@description('Customer-facing demo title used in alert descriptions.')
param demoTitle string = 'Arc Demo'

@description('Container image for the tiny HTTP app. The default Microsoft sample includes /bin/sh and dotnet.')
param containerImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

@description('HTTP port exposed by the sample app.')
@minValue(1)
@maxValue(65535)
param targetPort int = 8080

@description('Deploy-time value for SIMULATE_CRASH. Keep false for normal deploys; use az containerapp update to flip it during demos.')
param simulateCrash bool = false

@description('RestartCount threshold over the alert window. The alert fires when Total RestartCount is greater than this value.')
@minValue(0)
param restartCountThreshold int = 3

var safePrefix = toLower(replace(namePrefix, '_', '-'))
var containerAppName = take('ca-${safePrefix}-fault', 32)
var environmentName = take('cae-${safePrefix}', 60)
var restartAlertName = take('alert-${safePrefix}-containerapp-restarts', 260)
var simulateCrashValue = simulateCrash ? 'true' : 'false'
var startupScript = '''
if [ "$SIMULATE_CRASH" = "true" ]; then
  echo "[FATAL] Simulated bad deploy: crashing on startup because SIMULATE_CRASH=true" >&2
  exit 1
fi

exec dotnet /app/aspnetapp.dll
'''

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  tags: union(tags, {
    workload: 'container-app'
  })
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: containerAppName
  location: location
  tags: union(tags, {
    workload: 'container-app'
    faultMechanism: 'SIMULATE_CRASH'
  })
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          command: [
            '/bin/sh'
          ]
          args: [
            '-c'
            startupScript
          ]
          env: [
            {
              name: 'ASPNETCORE_HTTP_PORTS'
              value: '${targetPort}'
            }
            {
              name: 'SIMULATE_CRASH'
              value: simulateCrashValue
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource restartAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: restartAlertName
  location: 'global'
  tags: union(tags, {
    workload: 'container-app'
  })
  properties: {
    description: 'Fires when the ${demoTitle} Container App crash-loop scenario drives replica restarts.'
    severity: 2
    enabled: true
    scopes: [
      containerApp.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.App/containerApps'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'RestartCountHigh'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'RestartCount'
          operator: 'GreaterThan'
          threshold: restartCountThreshold
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroupId
        webHookProperties: {
          workload: 'container-app'
          containerAppName: containerApp.name
          faultEnvVar: 'SIMULATE_CRASH'
        }
      }
    ]
  }
}

output environmentId string = environment.id
output environmentName string = environment.name
output containerAppIds array = [
  containerApp.id
]
output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output alertRuleId string = restartAlert.id
output resourceIds array = [
  environment.id
  containerApp.id
  restartAlert.id
]
