targetScope = 'resourceGroup'

@description('Azure region for the AKS workload.')
param location string

@description('Common tags for AKS resources.')
param tags object

@description('Name prefix for AKS resources.')
param namePrefix string

@description('Existing Log Analytics workspace resource ID for Container Insights and the alert query scope.')
param workspaceId string

@description('Existing Action Group resource ID to notify when AKS pods restart or crashloop.')
param actionGroupId string

@description('AKS node count. Keep at 1 for the low-cost demo cluster.')
@minValue(1)
@maxValue(3)
param nodeCount int = 1

@description('AKS node VM size. Defaults to the repo-standard AU-friendly burstable SKU.')
param nodeVmSize string = 'Standard_B2as_v2'

@description('Kubernetes namespace for the sample workload.')
param workloadNamespace string = 'arc-demo-aks'

@description('Kubernetes deployment name for the sample workload.')
param workloadName string = 'crashloop-demo'

@description('Sample workload image. Must include /bin/sh because the demo fault is env-var driven.')
param workloadImage string = 'mcr.microsoft.com/azurelinux/base/core:3.0'

var safePrefix = toLower(replace(namePrefix, '_', '-'))
var clusterName = take('${safePrefix}-aks', 63)
var dnsPrefix = take('${replace(safePrefix, '-', '')}aks', 54)
var scriptIdentityName = take('id-${safePrefix}-aks-workload', 128)
var deploymentScriptName = take('ds-${safePrefix}-aks-workload', 63)
var restartAlertName = take('alert-${safePrefix}-aks-pod-restarts', 260)
var contributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

var workloadManifest = format('''
apiVersion: v1
kind: Namespace
metadata:
  name: {0}
  labels:
    app.kubernetes.io/part-of: arc-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {1}
  namespace: {0}
  labels:
    app.kubernetes.io/name: {1}
    app.kubernetes.io/part-of: arc-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {1}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {1}
        app.kubernetes.io/part-of: arc-demo
    spec:
      containers:
      - name: app
        image: {2}
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - -c
        args:
        - |
          if [ "$CRASH_LOOP" = "true" ]; then
            echo "Crash-loop mode enabled for the arc-demo AKS break scenario."
            exit 1
          fi

          while true; do
            echo "arc-demo AKS workload healthy"
            sleep 30
          done
        env:
        - name: CRASH_LOOP
          value: "false"
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 50m
            memory: 64Mi
''', workloadNamespace, workloadName, workloadImage)

var workloadScriptContent = format('''
set -euo pipefail

cat > workload.yaml <<'YAML'
{0}
YAML

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if az aks command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --command "kubectl apply -f workload.yaml && kubectl rollout status deployment/{1} -n {2} --timeout=180s" \
    --file workload.yaml \
    --only-show-errors; then
    exit 0
  fi

  echo "AKS command invoke not ready yet; retrying in 30 seconds (attempt $attempt/10)."
  sleep 30
done

echo "Failed to apply AKS demo workload after retries." >&2
exit 1
''', workloadManifest, workloadName, workloadNamespace)

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: clusterName
  location: location
  tags: union(tags, {
    workload: 'aks'
  })
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: dnsPrefix
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osDiskSizeGB: 64
        maxPods: 30
        enableAutoScaling: false
        enableNodePublicIP: false
      }
    ]
    networkProfile: {
      networkPlugin: 'kubenet'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: workspaceId
        }
      }
    }
  }
}

resource workloadScriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: scriptIdentityName
  location: location
  tags: tags
}

resource workloadScriptContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, workloadScriptIdentity.id, 'aks-workload-command')
  scope: aks
  properties: {
    principalId: workloadScriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleDefinitionId
  }
}

resource workloadScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: deploymentScriptName
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${workloadScriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.64.0'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    forceUpdateTag: deployment().name
    environmentVariables: [
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        name: 'CLUSTER_NAME'
        value: aks.name
      }
    ]
    scriptContent: workloadScriptContent
  }
  dependsOn: [
    workloadScriptContributor
  ]
}

var restartAlertQuery = format('''
KubePodInventory
| where TimeGenerated > ago(15m)
| where ClusterName =~ '{0}'
| where Namespace == '{1}'
| summarize Restarts=max(ContainerRestartCount), Reasons=make_set(ContainerStatusReason), Statuses=make_set(PodStatus) by ClusterName, Namespace, Name
| where Restarts >= 2 or set_has_element(Reasons, 'CrashLoopBackOff') or set_has_element(Reasons, 'Error') or set_has_element(Statuses, 'Failed')
''', clusterName, workloadNamespace)

resource restartAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: restartAlertName
  location: location
  tags: union(tags, {
    workload: 'aks'
  })
  properties: {
    displayName: 'Arc Demo — AKS pod restarting or crashlooping'
    description: 'Fires when the AKS sample workload restarts repeatedly or reports CrashLoopBackOff.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: restartAlertQuery
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
      actionGroups: [
        actionGroupId
      ]
    }
  }
  dependsOn: [
    workloadScript
  ]
}

output clusterId string = aks.id
output clusterName string = aks.name
output clusterIds array = [
  aks.id
]
output workloadNamespace string = workloadNamespace
output workloadName string = workloadName
output alertRuleId string = restartAlert.id
output resourceIds array = [
  aks.id
  workloadScriptIdentity.id
  workloadScript.id
  restartAlert.id
]
