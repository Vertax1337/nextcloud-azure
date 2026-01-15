targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(10)
@description('Short prefix used for resource names. Lowercase letters+digits recommended.')
param prefix string = 'nc50m'

@description('Public hostname you will bind to the Nextcloud Container App (custom domain).')
param cloudFqdn string = 'cloud.50er-jahre-museum.de'

@description('Public hostname you will bind to the ONLYOFFICE Container App (custom domain).')
param officeFqdn string = 'office.50er-jahre-museum.de'

@description('Admin username that Nextcloud will create on first install.')
param nextcloudAdminUser string = 'admin'

@secure()
@description('Admin password that Nextcloud will create on first install.')
param nextcloudAdminPassword string

@description('PostgreSQL admin login (also used by Nextcloud as DB user in this small setup).')
param postgresAdminUser string = 'ncadmin'

@secure()
@description('PostgreSQL admin password.')
param postgresAdminPassword string

@description('PostgreSQL database name for Nextcloud.')
param postgresDbName string = 'nextcloud'

@secure()
@description('Shared JWT secret for ONLYOFFICE <-> Nextcloud integration. Use a long random value.')
param onlyofficeJwtSecret string

@description('Nextcloud image tag for your custom image build. Keep this aligned with your Docker build.')
param nextcloudImageTag string = 'production-apache'

@description('Sizing: Nextcloud main container CPU cores (e.g., 0.5, 1.0).')
param ncCpu string = '0.5'

@description('Sizing: Nextcloud main container memory (e.g., 1Gi, 2Gi).')
param ncMemory string = '1Gi'

@description('Sizing: ONLYOFFICE container CPU cores (e.g., 1.0, 2.0).')
param ooCpu string = '1.0'

@description('Sizing: ONLYOFFICE container memory (e.g., 2Gi, 4Gi).')
param ooMemory string = '2Gi'

@description('If true, deploy ACR + build/push your custom Nextcloud image there. If false, set nextcloudImageOverride to a public image and skip ACR.')
param useAcr bool = true

@description('If useAcr=false, provide a full image reference here (e.g., ghcr.io/org/nextcloud-custom:tag).')
param nextcloudImageOverride string = 'nextcloud:production-apache'

var uniq = toLower(substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 10))
var namePrefix = toLower(replace(prefix, '-', ''))

// Global-unique resource names
var acrName = toLower('${namePrefix}${uniq}acr')
var storageName = toLower('${namePrefix}${uniq}st')
var vnetName = '${namePrefix}-${uniq}-vnet'
var caEnvName = '${namePrefix}-${uniq}-cae'
var pgServerName = toLower('${namePrefix}${uniq}pg')
var laName = '${namePrefix}-${uniq}-law'

// Container App names
var ncAppName = '${namePrefix}-${uniq}-nc'
var ooAppName = '${namePrefix}-${uniq}-office'

// File share names (must be lowercase)
var ncShareName = 'nextcloud'

// Images
var nextcloudImage = useAcr ? '${acr.properties.loginServer}/nextcloud-custom:${nextcloudImageTag}' : nextcloudImageOverride
var redisImage = 'redis:7-alpine'
var onlyofficeImage = 'onlyoffice/documentserver:latest'

// Role definition IDs (built-in)
var acrPullRoleDefId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull

// ----------------------
// Observability
// ----------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: laName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ----------------------
// Networking (VNet + subnets)
// - One subnet for Container Apps Environment infrastructure
// - One subnet delegated to PostgreSQL Flexible Server (private access)
// ----------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'aca-infra'
        properties: {
          addressPrefix: '10.42.0.0/23'
          delegations: [
            {
              name: 'acaDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'pg-delegated'
        properties: {
          addressPrefix: '10.42.2.0/24'
          delegations: [
            {
              name: 'pgDelegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: 'aca-infra'
  parent: vnet
}

resource pgSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: 'pg-delegated'
  parent: vnet
}

// Private DNS zone for PostgreSQL flexible server private access
resource pgPrivateDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'private.postgres.database.azure.com'
  location: 'global'
}

resource pgDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${pgPrivateDns.name}/${vnet.name}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// ----------------------
// Storage (Azure Files for /var/www/html)
// ----------------------
resource st 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  name: '${st.name}/default'
}

resource ncShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${st.name}/default/${ncShareName}'
  properties: {
    shareQuota: 5120 // 5 TB
  }
  dependsOn: [
    fileService
  ]
}

// ----------------------
// ACR (optional) + User Assigned Identity for image pull
// ----------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = if (useAcr) {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (useAcr) {
  name: '${namePrefix}-${uniq}-uai-acr'
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useAcr) {
  name: guid(acr.id, acrPullIdentity.name, acrPullRoleDefId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefId
    principalId: acrPullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ----------------------
// Container Apps Environment
// ----------------------
resource caEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: caEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: listKeys(logAnalytics.id, logAnalytics.apiVersion).primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnet.id
    }
    zoneRedundant: false
  }
}

// Environment storage for Azure Files
resource caEnvStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: '${caEnv.name}/ncfiles'
  properties: {
    azureFile: {
      accountName: st.name
      accountKey: listKeys(st.id, st.apiVersion).keys[0].value
      shareName: ncShareName
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [
    ncShare
    caEnv
  ]
}

// ----------------------
// PostgreSQL Flexible Server (private access)
// ----------------------
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: pgServerName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    version: '16'
    storage: {
      storageSizeGB: 64
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Disabled'
      delegatedSubnetResourceId: pgSubnet.id
      privateDnsZoneArmResourceId: pgPrivateDns.id
    }
    highAvailability: {
      mode: 'Disabled'
    }
    maintenanceWindow: {
      customWindow: 'Disabled'
      dayOfWeek: 0
      startHour: 0
      startMinute: 0
    }
  }
  dependsOn: [
    pgDnsLink
  ]
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  name: '${pg.name}/${postgresDbName}'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    pg
  ]
}

// ----------------------
// Container App: Nextcloud (multi-container: nextcloud + cron + redis)
// ----------------------
resource ncAppAcr 'Microsoft.App/containerApps@2024-03-01' = if (useAcr) {
  name: ncAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: caEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: acrPullIdentity.id
        }
      ]
      secrets: [
        {
          name: 'pg-password'
          value: postgresAdminPassword
        }
        {
          name: 'nc-admin-password'
          value: nextcloudAdminPassword
        }
        {
          name: 'oo-jwt-secret'
          value: onlyofficeJwtSecret
        }
      ]
    }
    template: {
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        {
          name: 'ncfiles'
          storageType: 'AzureFile'
          storageName: 'ncfiles'
        }
      ]
      containers: [
        {
          name: 'nextcloud'
          image: nextcloudImage
          resources: {
            cpu: json(ncCpu)
            memory: ncMemory
          }
          env: [
            { name: 'NEXTCLOUD_ADMIN_USER', value: nextcloudAdminUser }
            { name: 'NEXTCLOUD_ADMIN_PASSWORD', secretRef: 'nc-admin-password' }

            { name: 'POSTGRES_HOST', value: '${pg.name}.postgres.database.azure.com' }
            { name: 'POSTGRES_DB', value: postgresDbName }
            { name: 'POSTGRES_USER', value: postgresAdminUser }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }

            // Redis (sidecar): talk over localhost
            { name: 'REDIS_HOST', value: '127.0.0.1' }
            { name: 'REDIS_HOST_PORT', value: '6379' }

            // Reverse-proxy / HTTPS hints (custom domain you will bind later)
            { name: 'NEXTCLOUD_TRUSTED_DOMAINS', value: cloudFqdn }
            { name: 'OVERWRITEHOST', value: cloudFqdn }
            { name: 'OVERWRITEPROTOCOL', value: 'https' }
            { name: 'OVERWRITECLIURL', value: 'https://${cloudFqdn}' }
            { name: 'NEXTCLOUD_UPDATE', value: '1' }
            // ONLYOFFICE bootstrap (used by the custom image hook script)
            { name: 'OO_PUBLIC_URL', value: 'https://${officeFqdn}/' }
            { name: 'OO_INTERNAL_URL', value: 'http://${ooAppName}' }
            { name: 'OO_JWT_SECRET', secretRef: 'oo-jwt-secret' }
            { name: 'OO_JWT_HEADER', value: 'Authorization' }

            // PHP tuning (small team defaults)
            { name: 'PHP_MEMORY_LIMIT', value: '512M' }
            { name: 'UPLOAD_MAX_SIZE', value: '10G' }
          ]
          volumeMounts: [
            {
              volumeName: 'ncfiles'
              mountPath: '/var/www/html'
            }
          ]
        }
        {
          name: 'cron'
          image: nextcloudImage
          command: [ '/cron.sh' ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'POSTGRES_HOST', value: '${pg.name}.postgres.database.azure.com' }
            { name: 'POSTGRES_DB', value: postgresDbName }
            { name: 'POSTGRES_USER', value: postgresAdminUser }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }
            { name: 'REDIS_HOST', value: '127.0.0.1' }
            { name: 'REDIS_HOST_PORT', value: '6379' }
          ]
          volumeMounts: [
            {
              volumeName: 'ncfiles'
              mountPath: '/var/www/html'
            }
          ]
        }
        {
          name: 'redis'
          image: redisImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          // Redis listens on 6379 inside the shared network namespace
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: 6379
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
    }
  }
  dependsOn: [
    caEnv
    caEnvStorage
    pgDb
  
    acrPullRole
  ]
}

resource ncAppNoAcr 'Microsoft.App/containerApps@2024-03-01' = if (!useAcr) {
  name: ncAppName
  location: location
  properties: {
    managedEnvironmentId: caEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      registries: []
      secrets: [
        {
          name: 'pg-password'
          value: postgresAdminPassword
        }
        {
          name: 'nc-admin-password'
          value: nextcloudAdminPassword
        }
        {
          name: 'oo-jwt-secret'
          value: onlyofficeJwtSecret
        }
      ]
    }
    template: {
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        {
          name: 'ncfiles'
          storageType: 'AzureFile'
          storageName: 'ncfiles'
        }
      ]
      containers: [
        {
          name: 'nextcloud'
          image: nextcloudImageOverride
          resources: {
            cpu: json(ncCpu)
            memory: ncMemory
          }
          env: [
            { name: 'NEXTCLOUD_ADMIN_USER', value: nextcloudAdminUser }
            { name: 'NEXTCLOUD_ADMIN_PASSWORD', secretRef: 'nc-admin-password' }

            { name: 'POSTGRES_HOST', value: '${pg.name}.postgres.database.azure.com' }
            { name: 'POSTGRES_DB', value: postgresDbName }
            { name: 'POSTGRES_USER', value: postgresAdminUser }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }

            // Redis (sidecar): talk over localhost
            { name: 'REDIS_HOST', value: '127.0.0.1' }
            { name: 'REDIS_HOST_PORT', value: '6379' }

            // Reverse-proxy / HTTPS hints (custom domain you will bind later)
            { name: 'NEXTCLOUD_TRUSTED_DOMAINS', value: cloudFqdn }
            { name: 'OVERWRITEHOST', value: cloudFqdn }
            { name: 'OVERWRITEPROTOCOL', value: 'https' }
            { name: 'OVERWRITECLIURL', value: 'https://${cloudFqdn}' }
            { name: 'NEXTCLOUD_UPDATE', value: '1' }
            // ONLYOFFICE bootstrap (used by the custom image hook script)
            { name: 'OO_PUBLIC_URL', value: 'https://${officeFqdn}/' }
            { name: 'OO_INTERNAL_URL', value: 'http://${ooAppName}' }
            { name: 'OO_JWT_SECRET', secretRef: 'oo-jwt-secret' }
            { name: 'OO_JWT_HEADER', value: 'Authorization' }

            // PHP tuning (small team defaults)
            { name: 'PHP_MEMORY_LIMIT', value: '512M' }
            { name: 'UPLOAD_MAX_SIZE', value: '10G' }
          ]
          volumeMounts: [
            {
              volumeName: 'ncfiles'
              mountPath: '/var/www/html'
            }
          ]
        }
        {
          name: 'cron'
          image: nextcloudImageOverride
          command: [ '/cron.sh' ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'POSTGRES_HOST', value: '${pg.name}.postgres.database.azure.com' }
            { name: 'POSTGRES_DB', value: postgresDbName }
            { name: 'POSTGRES_USER', value: postgresAdminUser }
            { name: 'POSTGRES_PASSWORD', secretRef: 'pg-password' }
            { name: 'REDIS_HOST', value: '127.0.0.1' }
            { name: 'REDIS_HOST_PORT', value: '6379' }
          ]
          volumeMounts: [
            {
              volumeName: 'ncfiles'
              mountPath: '/var/www/html'
            }
          ]
        }
        {
          name: 'redis'
          image: redisImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          // Redis listens on 6379 inside the shared network namespace
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: 6379
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
    }
  }
  dependsOn: [
    caEnv
    caEnvStorage
    pgDb
  ]
}


// ----------------------
// Container App: ONLYOFFICE Document Server
// ----------------------
resource ooApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: ooAppName
  location: location
  properties: {
    managedEnvironmentId: caEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [
        {
          name: 'oo-jwt-secret'
          value: onlyofficeJwtSecret
        }
      ]
    }
    template: {
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      containers: [
        {
          name: 'documentserver'
          image: onlyofficeImage
          resources: {
            cpu: json(ooCpu)
            memory: ooMemory
          }
          env: [
            { name: 'JWT_ENABLED', value: 'true' }
            { name: 'JWT_SECRET', secretRef: 'oo-jwt-secret' }
            { name: 'JWT_HEADER', value: 'Authorization' }
          ]
        }
      ]
    }
  }
  dependsOn: [
    caEnv
  ]
}

// ----------------------
// Useful outputs
// ----------------------
output nextcloudDefaultFqdn string = useAcr ? ncAppAcr.properties.configuration.ingress.fqdn : ncAppNoAcr.properties.configuration.ingress.fqdn
output onlyofficeDefaultFqdn string = ooApp.properties.configuration.ingress.fqdn
output nextcloudExpectedHost string = cloudFqdn
output onlyofficeExpectedHost string = officeFqdn
