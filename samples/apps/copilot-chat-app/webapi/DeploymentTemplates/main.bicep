/*
Copyright (c) Microsoft. All rights reserved.
Licensed under the MIT license. See LICENSE file in the project root for full license information.

Bicep template for deploying Semantic Kernel to Azure as a web app service.

Resources to add:
- vNet + Network security group
*/

@description('Name for the deployment - Must consist of alphanumeric characters or \'-\'')
param name string = 'semkernel'

@description('SKU for the Azure App Service plan')
@allowed(['B1', 'S1', 'S2', 'S3', 'P1V3', 'P2V3', 'I1V2', 'I2V2' ])
param appServiceSku string = 'B1'

@description('Location of package to deploy as the web service')
#disable-next-line no-hardcoded-env-urls // This is an arbitrary package URI
param packageUri string = 'https://skaasdeploy.blob.core.windows.net/api/semantickernelapi.zip'

@description('Underlying AI service')
@allowed([
  'AzureOpenAI'
  'OpenAI'
])
param aiService string = 'AzureOpenAI'

@description('Model to use for chat completions')
param completionModel string = 'gpt-35-turbo'

@description('Model to use for text embeddings')
param embeddingModel string = 'text-embedding-ada-002'

@description('Completion model the task planner should use')
param plannerModel string = 'gpt-35-turbo'

@description('Azure OpenAI endpoint to use (ignored when AI service is not AzureOpenAI)')
param endpoint string = ''

@secure()
@description('Azure OpenAI or OpenAI API key')
param apiKey string = ''

@description('Semantic Kernel server API key - Generated GUID by default\nProvide empty string to disable API key auth')
param semanticKernelApiKey string = newGuid()

@description('Whether to deploy a new Azure OpenAI instance')
param deployNewAzureOpenAI bool = true

@description('Whether to deploy Cosmos DB for chat storage')
param deployCosmosDB bool = true

// TODO: Temporarily disabling qdrant deployment by default while we secure its endpoint.
@description('Whether to deploy Qdrant (in a container) for memory storage')
param deployQdrant bool = false

@description('Whether to deploy Azure Speech Services to be able to input chat text by voice')
param deploySpeechServices bool = true

@description('Region for the resources')
#disable-next-line no-loc-expr-outside-params // We force the location to be the same as the resource group's for a simpler,
var location = resourceGroup().location       // more intelligible deployment experience at the cost of some flexibility

@description('Hash of the resource group ID')
var rgIdHash = uniqueString(resourceGroup().id)

@description('Name for the deployment - Made unique')
var uniqueName = '${name}-${rgIdHash}'

@description('Name of the Azure Storage file share to create')
var storageFileShareName = 'aciqdrantshare'

@description('Name of the ACI container volume')
var containerVolumeMountName = 'azqdrantvolume'

resource openAI 'Microsoft.CognitiveServices/accounts@2022-12-01' = if(deployNewAzureOpenAI) {
  name: 'ai-${uniqueName}'
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: toLower(uniqueName)
  }
}

resource openAI_completionModel 'Microsoft.CognitiveServices/accounts/deployments@2022-12-01' = if(deployNewAzureOpenAI) {
  parent: openAI
  name: completionModel
  properties: {
    model: {
      format: 'OpenAI'
      name: completionModel
    }
    scaleSettings: {
      scaleType: 'Standard'
    }
  }
}

resource openAI_embeddingModel 'Microsoft.CognitiveServices/accounts/deployments@2022-12-01' = if(deployNewAzureOpenAI) {
  parent: openAI
  name: embeddingModel
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModel
    }
    scaleSettings: {
      scaleType: 'Standard'
    }
  }
  dependsOn: [             // This "dependency" is to create models sequentially because the resource
    openAI_completionModel // provider does not support parallel creation of models properly.
  ]
}


resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: 'asp-${uniqueName}'
  location: location
  sku: {
    name: appServiceSku
  }
}

resource appServiceWeb 'Microsoft.Web/sites@2022-09-01' = {
  name: 'app-${uniqueName}-skweb'
  location: location
  tags: {
    skweb: '1'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
  }
  dependsOn: [
    logAnalyticsWorkspace
  ]
}

resource appServiceWebConfig 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: appServiceWeb
  name: 'web'
  properties: {
    alwaysOn: true
    cors: {
      allowedOrigins: [
        'http://localhost:3000'
      ]
      supportCredentials: true
    }
    detailedErrorLoggingEnabled: true
    minTlsVersion: '1.2'
    netFrameworkVersion: 'v6.0'
    use32BitWorkerProcess: false
    appSettings: [
      {
        name: 'AIService:Type'
        value: aiService
      }
      {
        name: 'AIService:Endpoint'
        value: deployNewAzureOpenAI ? openAI.properties.endpoint : endpoint
      }
      {
        name: 'AIService:Key'
        value: deployNewAzureOpenAI ? openAI.listKeys().key1 : apiKey
      }
      {
        name: 'AIService:Models:Completion'
        value: completionModel
      }
      {
        name: 'AIService:Models:Embedding'
        value: embeddingModel
      }
      {
        name: 'AIService:Models:Planner'
        value: plannerModel
      }
      {
        name: 'Authorization:Type'
        value: empty(semanticKernelApiKey) ? 'None' : 'ApiKey'
      }
      {
        name: 'Authorization:ApiKey'
        value: semanticKernelApiKey
      }
      {
        name: 'ChatStore:Type'
        value: deployCosmosDB ? 'cosmos' : 'volatile'
      }
      {
        name: 'ChatStore:Cosmos:Database'
        value: 'CopilotChat'
      }
      {
        name: 'ChatStore:Cosmos:ChatSessionsContainer'
        value: 'chatsessions'
      }
      {
        name: 'ChatStore:Cosmos:ChatMessagesContainer'
        value: 'chatmessages'
      }
      {
        name: 'ChatStore:Cosmos:ConnectionString'
        value: deployCosmosDB ? cosmosAccount.listConnectionStrings().connectionStrings[0].connectionString : ''
      }
      {
        name: 'MemoriesStore:Type'
        value: deployQdrant ? 'Qdrant' : 'Volatile'
      }
      {
        name: 'MemoriesStore:Qdrant:Host'
        value: deployQdrant ? 'http://${aci.properties.ipAddress.fqdn}' : ''
      }
      {
        name: 'AzureSpeech:Region'
        value: location
      }
      {
        name: 'AzureSpeech:Key'
        value: deploySpeechServices ? speechAccount.listKeys().key1 : ''
      }
      {
        name: 'AllowedOrigins'
        value: '[*]' // Defer list of allowed origins to the Azure service app's CORS configuration
      }
      {
        name: 'Kestrel:Endpoints:Https:Url'
        value: 'https://localhost:443'
      }
      {
        name: 'Logging:LogLevel:Default'
        value: 'Warning'
      }
      {
        name: 'Logging:LogLevel:SemanticKernel.Service'
        value: 'Warning'
      }
      {
        name: 'Logging:LogLevel:Microsoft.SemanticKernel'
        value: 'Warning'
      }
      {
        name: 'Logging:LogLevel:Microsoft.AspNetCore.Hosting'
        value: 'Warning'
      }
      {
        name: 'Logging:LogLevel:Microsoft.Hosting.Lifetimel'
        value: 'Warning'
      }
      {
        name: 'ApplicationInsights:ConnectionString'
        value: appInsights.properties.ConnectionString
      }
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: appInsights.properties.ConnectionString
      }
      {
        name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
        value: '~2'
      }
    ]
  }
}

resource appServiceWebDeploy 'Microsoft.Web/sites/extensions@2021-03-01' = {
  name: 'MSDeploy'
  kind: 'string'
  parent: appServiceWeb
  properties: {
    packageUri: packageUri
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${uniqueName}'
  location: location
  kind: 'string'
  tags: {
    displayName: 'AppInsight'
  }
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource appInsightExtension 'Microsoft.Web/sites/siteextensions@2020-06-01' = {
  parent: appServiceWeb
  name: 'Microsoft.ApplicationInsights.AzureWebSites'
  dependsOn: [
    appInsights
  ]
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: 'la-${uniqueName}'
  location: location
  tags: {
    displayName: 'Log Analytics'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      searchVersion: 1
      legacy: 0
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' = if (deployQdrant) {
  name: 'st${rgIdHash}' // Not using full unique name to avoid hitting 24 char limit
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
  resource fileservices 'fileServices' = {
    name: 'default'
    resource share 'shares' = {
      name: storageFileShareName
    }
  }
}

resource aci 'Microsoft.ContainerInstance/containerGroups@2022-10-01-preview' = if (deployQdrant) {
  name: 'ci-${uniqueName}'
  location: location
  properties: {
    sku: 'Standard'
    containers: [
      {
        name: uniqueName
        properties: {
          image: 'qdrant/qdrant:latest'
          ports: [
            {
              port: 6333
              protocol: 'TCP'
            }
          ]
          resources: {
            requests: {
              cpu: 4
              memoryInGB: 16
            }
          }
          volumeMounts: [
            {
              name: containerVolumeMountName
              mountPath: '/qdrant/storage'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    ipAddress: {
      ports: [
        {
          port: 6333
          protocol: 'TCP'
        }
      ]
      type: 'Public'
      dnsNameLabel: uniqueName
    }
    volumes: [
      {
        name: containerVolumeMountName
        azureFile: {
          shareName: storageFileShareName
          storageAccountName: deployQdrant ? storage.name : 'notdeployed'
          storageAccountKey: deployQdrant ? storage.listKeys().keys[0].value : ''
        }
      }
    ]
  }
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2022-05-15' = if (deployCosmosDB) {
  name: toLower('cosmos-${uniqueName}')
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [ {
      locationName: location
      failoverPriority: 0
      isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2022-05-15' = if (deployCosmosDB) {
  parent: cosmosAccount
  name: 'CopilotChat'
  properties: {
    resource: {
      id: 'CopilotChat'
    }
  }
}

resource messageContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-03-15' = if (deployCosmosDB) {
  parent: cosmosDatabase
  name: 'chatmessages'
  properties: {
    resource: {
      id: 'chatmessages'
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
        version: 2
      }
    }
  }
}

resource sessionContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-03-15' = if (deployCosmosDB) {
  parent: cosmosDatabase
  name: 'chatsessions'
  properties: {
    resource: {
      id: 'chatsessions'
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
        version: 2
      }
    }
  }
}

resource speechAccount 'Microsoft.CognitiveServices/accounts@2022-12-01' = if (deploySpeechServices) {
  name: 'cog-${uniqueName}'
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'SpeechServices'
  identity: {
    type: 'None'
  }
  properties: {
    customSubDomainName: 'cog-${uniqueName}'
    networkAcls: {
      defaultAction: 'Allow'
    }
    publicNetworkAccess: 'Enabled'
  }
}


output deployedUrl string = appServiceWeb.properties.defaultHostName
