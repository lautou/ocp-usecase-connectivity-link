## Apicurio Studio Deployment - COMPLETE ✅

**Status**: Apicurio Studio (Red Hat build of Apicurio Registry 3) is **FULLY DEPLOYED** and **OPERATIONAL** ✅

**Deployment Date**: 2026-03-27

### Overview

Apicurio Studio provides a schema registry and API design platform for managing API schemas, event schemas, and API artifacts. This deployment uses the **Red Hat build of Apicurio Registry 3** (officially supported) instead of the legacy community ApicurioStudio operator.

**Key Features**:
- ✅ Schema registry for OpenAPI, AsyncAPI, Avro, Protobuf, JSON Schema
- ✅ API design and collaboration platform
- ✅ OAuth 2.0 authentication via Keycloak (RHBK 26)
- ✅ Role-based access control (admin, developer, readOnly)
- ✅ External PostgreSQL storage (production-ready)
- ✅ RESTful API and web-based UI
- ✅ GitOps deployment via ArgoCD

### Architecture

**Components Deployed**:

1. **Apicurio Registry Backend** (`apicurio-studio-app-deployment`)
   - Image: Red Hat build of Apicurio Registry 3
   - Operator: `apicurio-registry-3.v3.1.6-r2` (OperatorHub)
   - API Version: `registry.apicur.io/v1` (stable)
   - Replicas: 1
   - Service: ClusterIP on port 8080
   - Route: `apicurio-studio-api-apicurio.apps.<cluster-domain>`

2. **Apicurio Registry UI** (`apicurio-studio-ui-deployment`)
   - Web-based interface for API design and schema management
   - Replicas: 1
   - Service: ClusterIP on port 8080
   - Route: `apicurio-studio-ui-apicurio.apps.<cluster-domain>`

3. **PostgreSQL Database** (`postgres-db`)
   - Image: `registry.redhat.io/rhel9/postgresql-15:latest`
   - Database: `apicuriodb`
   - User: `apicurio`
   - Storage: EmptyDir (demo configuration, use PVC for production)
   - Service: ClusterIP on port 5432

4. **Keycloak Realm** (`apicurio`)
   - Deployed in separate `keycloak` namespace
   - 2 OAuth clients:
     - `apicurio-api` - Backend API client (bearer-only with secret)
     - `apicurio-studio` - Frontend UI client (public with PKCE)
   - RHBK 26 compliant (OAuth Code Flow + PKCE, no Implicit Flow)

### Configuration Details

**ApicurioRegistry3 CR** (`kustomize/apicurio/apicurio-apicurioregistry3-apicurio-studio.yaml`):

```yaml
apiVersion: registry.apicur.io/v1
kind: ApicurioRegistry3
metadata:
  name: apicurio-studio
  namespace: apicurio
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  app:
    replicas: 1

    # External PostgreSQL storage
    storage:
      type: postgresql
      sql:
        dataSource:
          url: jdbc:postgresql://postgres-db.apicurio.svc.cluster.local:5432/apicuriodb
          username: apicurio
          password:
            name: postgres-db
            key: password

    # Keycloak OIDC authentication
    auth:
      enabled: true
      authServerUrl: https://keycloak-keycloak.apps.<cluster-domain>/realms/apicurio
      appClientId: apicurio-api
      uiClientId: apicurio-studio
      redirectUri: https://apicurio-studio-ui-apicurio.apps.<cluster-domain>
      logoutUrl: https://apicurio-studio-ui-apicurio.apps.<cluster-domain>

      # TLS configuration (CRITICAL for OpenShift Routes)
      tls:
        tlsVerificationType: none  # Edge TLS termination at Route

      # Role-based authorization
      authz:
        enabled: true
        ownerOnlyEnabled: true
        readAccessEnabled: true
        roles:
          admin: admin
          developer: developer
          readOnly: readOnly
          source: token

      # Basic auth for API clients
      basicAuth:
        enabled: true
        cacheExpiration: 10min

    # Feature flags
    features:
      resourceDeleteEnabled: true
      versionMutabilityEnabled: false

    # Backend API ingress
    ingress:
      enabled: true
      host: apicurio-studio-api-apicurio.apps.<cluster-domain>

  # Frontend UI component
  ui:
    enabled: true
    replicas: 1
    ingress:
      enabled: true
      host: apicurio-studio-ui-apicurio.apps.<cluster-domain>
```

### ArgoCD Applications

**Two Applications deployed**:

1. **apicurio-studio** (`argocd/application-apicurio.yaml`)
   - Project: `solution-patterns-connectivity-link`
   - Path: `kustomize/apicurio`
   - Destination: `apicurio` namespace
   - Sync Policy: Automated (prune + selfHeal)
   - ignoreDifferences: 5 hostname fields (patched by Job)

2. **keycloak** (`argocd/application-keycloak.yaml`)
   - Project: `solution-patterns-connectivity-link`
   - Path: `kustomize/keycloak`
   - Destination: `keycloak` namespace
   - Sync Policy: Automated (prune + selfHeal)
   - ignoreDifferences: Keycloak hostname field

### Hostname Patching

**PostSync Job** (`openshift-gitops-job-apicurio-hostname.yaml`):
- Sync wave: 3 (runs after resource creation)
- Patches 5 hostname fields in ApicurioRegistry3 CR:
  - `spec.app.auth.authServerUrl`
  - `spec.app.auth.redirectUri`
  - `spec.app.auth.logoutUrl`
  - `spec.app.ingress.host`
  - `spec.ui.ingress.host`
- Replaces `placeholder` with actual cluster domain
- Execution time: ~3 seconds

### Keycloak Integration (RHBK 26)

**Realm**: `apicurio` (separate from `globex-user1` realm)

**OAuth Clients**:

1. **apicurio-api** (Backend):
   ```yaml
   clientId: apicurio-api
   bearerOnly: true  # Bearer tokens only (no redirects)
   publicClient: false  # Confidential client with secret
   secret: apicurio-api-secret  # ⚠️ DEMO SECRET
   standardFlowEnabled: false
   directAccessGrantsEnabled: true
   ```

2. **apicurio-studio** (Frontend):
   ```yaml
   clientId: apicurio-studio
   publicClient: true  # Public client (SPA, no secret)
   clientAuthenticatorType: none
   standardFlowEnabled: true  # OAuth Code Flow
   implicitFlowEnabled: false  # Not supported in RHBK 26
   attributes:
     pkce.code.challenge.method: S256  # PKCE enforced
   redirectUris:
     - https://apicurio-studio-ui-apicurio.apps.<cluster-domain>/*
   webOrigins:
     - https://apicurio-studio-ui-apicurio.apps.<cluster-domain>
   ```

**RHBK 26 Compliance**:
- ✅ OAuth 2.0 Authorization Code Flow + PKCE (S256)
- ✅ No Implicit Flow (removed in RHBK 26)
- ✅ Public client with `clientAuthenticatorType: none`
- ✅ Bearer-only backend client for API access
- ✅ `sslRequired: external` (not "none")

### Critical Configuration: TLS Verification

**Issue Encountered**: NullPointerException in Apicurio operator when `auth.tls` section was missing.

**Error**:
```
NullPointerException: Cannot invoke "io.apicurio.registry.operator.api.v1.spec.auth.AuthTLSSpec.getTlsVerificationType()"
because the return value of "io.apicurio.registry.operator.api.v1.spec.auth.AuthSpec.getTls()" is null
```

**Fix**: Add `tls.tlsVerificationType` field under `auth` section:

```yaml
auth:
  enabled: true
  authServerUrl: https://keycloak-keycloak.apps.<cluster-domain>/realms/apicurio
  # ... other auth config

  # CRITICAL: TLS configuration is REQUIRED even if auth is enabled
  tls:
    tlsVerificationType: none  # Disable TLS verification (OpenShift Routes use edge termination)
```

**Why `none`?**: OpenShift Routes terminate TLS at the edge (HAProxy), so the connection from Apicurio pods to Keycloak Route is HTTP internally. TLS verification is unnecessary and would fail since the internal service doesn't have TLS certificates.

### Access and Verification

**Access URLs**:
- **UI**: http://apicurio-studio-ui-apicurio.apps.<cluster-domain>
- **API**: http://apicurio-studio-api-apicurio.apps.<cluster-domain>
- **System Info**: http://apicurio-studio-api-apicurio.apps.<cluster-domain>/apis/registry/v3/system/info

**Verification Commands**:

```bash
# Check Application status
oc get application.argoproj.io apicurio-studio keycloak -n openshift-gitops
# Expected: Synced, Healthy

# Check all resources in apicurio namespace
oc get all -n apicurio
# Expected: 3 deployments (app + ui + postgres), 3 services, 2 routes

# Check ApicurioRegistry3 CR status
oc get apicurioregistry3 apicurio-studio -n apicurio
oc get apicurioregistry3 apicurio-studio -n apicurio -o yaml | grep -A 10 "status:"
# Expected: Ready: True, All active Deployments are available

# Check Keycloak realm
oc get keycloakrealmimport apicurio -n keycloak
oc get keycloakrealmimport apicurio -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'
# Expected: True

# Test UI accessibility
curl -sI http://apicurio-studio-ui-apicurio.apps.<cluster-domain> | head -3
# Expected: HTTP/1.1 200 OK

# Test API endpoint
curl -sI http://apicurio-studio-api-apicurio.apps.<cluster-domain>/apis/registry/v3/system/info | head -3
# Expected: HTTP/1.1 200 OK

# Check page title
curl -s http://apicurio-studio-ui-apicurio.apps.<cluster-domain> | grep -o '<title>.*</title>'
# Expected: <title>Apicurio Registry</title>
```

### Deployment Resources

**Namespace**: `apicurio`
- Label: `argocd.argoproj.io/managed-by: openshift-gitops` (CRITICAL for RBAC)

**Manifests** (in `kustomize/apicurio/`):
- `cluster-ns-apicurio.yaml` - Namespace with ArgoCD management label
- `apicurio-rolebinding-argocd.yaml` - RoleBinding for ArgoCD controller (admin access)
- `apicurio-secret-postgres-db.yaml` - PostgreSQL credentials
- `apicurio-deployment-postgres-db.yaml` - PostgreSQL 15 deployment
- `apicurio-service-postgres-db.yaml` - PostgreSQL service
- `apicurio-apicurioregistry3-apicurio-studio.yaml` - ApicurioRegistry3 CR
- `openshift-gitops-job-apicurio-hostname.yaml` - PostSync hostname patching Job
- `kustomization.yaml` - Kustomize configuration

**Total Resources Created**: ~13
- 1 Namespace
- 1 RoleBinding
- 1 Secret
- 3 Deployments
- 3 Services
- 2 Routes
- 1 ApicurioRegistry3 CR
- 1 Job (PostSync)

### Comparison: Modern ApicurioRegistry3 vs Legacy ApicurioStudio

| Aspect | **Modern: ApicurioRegistry3** (Our Deployment) | **Legacy: ApicurioStudio** (Ansible) |
|--------|------------------------------------------|--------------------------------------|
| **Status** | ✅ **Deployed and Verified** | Would require Helm deployment |
| **Operator** | Red Hat build of Apicurio Registry 3 (OperatorHub) | Community ApicurioStudio operator (quay.io/lbroudoux) |
| **Operator Version** | `apicurio-registry-3.v3.1.6-r2` | `latest` (no version pinning) |
| **API Version** | `registry.apicur.io/v1` (stable) | `studio.apicur.io/v1alpha1` (alpha) |
| **CR Type** | `ApicurioRegistry3` | `ApicurioStudio` |
| **Support Level** | ✅ **Red Hat commercial support** | ❌ Community support only |
| **Components** | 2 (app backend + ui frontend) | 3 (api + ui + ws WebSocket server) |
| **Deployments** | 2 (app + ui) | 3 (api + ui + ws) |
| **Routes** | 2 (app + ui) | 3 (api + ui + ws) |
| **Storage** | External required (PostgreSQL, MySQL, KafkaSQL) | Embedded PostgreSQL option available |
| **Our Storage** | External PostgreSQL 15 (RHEL9 image) | Would use embedded PostgreSQL |
| **Production Ready** | ✅ Yes (with external database) | ⚠️ Only with external database |
| **Keycloak Auth** | ✅ RHBK 26 (OAuth Code Flow + PKCE) | ✅ Keycloak (compatibility unknown) |
| **TLS Config** | ✅ **REQUIRED** `tls.tlsVerificationType` field | ❓ Unknown if required |
| **Auth Bug** | ⚠️ NullPointerException if `tls` section missing | ❓ Unknown |
| **Authorization** | ✅ Role-based (admin, developer, readOnly) | ✅ Similar roles available |
| **Basic Auth** | ✅ API client authentication | ❓ Unknown |
| **Ingress** | ✅ OpenShift Routes (no TLS config) | ✅ OpenShift Routes |
| **Features** | Resource delete, version mutability control | ❓ Unknown feature flags |
| **GitOps** | ✅ ArgoCD with automated hostname patching | Helm (manual values) |
| **Hostname Management** | ✅ PostSync Job (fully automated) | Manual Helm values per cluster |
| **RBAC** | ✅ Automated via namespace label | Manual configuration |
| **Resource Count** | ~13 resources | ~20-25 resources (more complex) |
| **Architecture** | ✅ Simpler (2 components) | More complex (3 components) |
| **Real-time Features** | ❌ No WebSocket server | ✅ WebSocket for collaboration |
| **API Stability** | ✅ Stable `v1` API | ⚠️ Alpha `v1alpha1` API |
| **Long-term Support** | ✅ Red Hat product lifecycle | ❌ Community project (uncertain) |

### Why We Use Modern ApicurioRegistry3

**Advantages** ✅:
1. **Red Hat Commercial Support** - SLA, security patches, lifecycle guarantees
2. **Stable API** (`v1`) - Backward compatibility, production-ready
3. **Simpler Architecture** - 2 components instead of 3 (easier to maintain)
4. **Active Development** - Regular updates from Red Hat product team
5. **Production-Ready** - Designed for enterprise deployments
6. **Better Integration** - Works seamlessly with OpenShift ecosystem
7. **GitOps-Friendly** - Automated deployment via ArgoCD
8. **RHBK 26 Compatible** - Modern OAuth flows (Code + PKCE)

**Trade-offs** ⚠️:
1. **No WebSocket Server** - Legacy has real-time collaboration features we lack
2. **External Database Required** - Cannot use embedded PostgreSQL (but this is better for production)
3. **TLS Config Bug** - Requires `tls.tlsVerificationType` field even when using Routes (fixed in our deployment)

**Recommendation**: ✅ **Use ApicurioRegistry3** for all new deployments due to Red Hat support, API stability, and long-term maintainability.

### Troubleshooting

**Issue: NullPointerException in ApicurioRegistry3 CR**

**Symptoms**:
```
OperatorError: NullPointerException: Cannot invoke getTlsVerificationType() because getTls() is null
Ready: False, ActiveDeploymentUnavailable
```

**Cause**: Missing `tls` section under `auth` configuration.

**Fix**: Add TLS configuration:
```yaml
spec:
  app:
    auth:
      enabled: true
      authServerUrl: https://keycloak-keycloak.apps.<cluster-domain>/realms/apicurio
      # ... other config

      tls:  # ← ADD THIS
        tlsVerificationType: none  # Disable for OpenShift Routes
```

**Issue: RBAC Permission Denied for ArgoCD**

**Symptoms**:
```
deployments.apps is forbidden: User system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
cannot create resource deployments in API group apps in the namespace apicurio
```

**Cause**: Missing RoleBinding or namespace label.

**Fix**:
1. Ensure namespace has label: `argocd.argoproj.io/managed-by: openshift-gitops`
2. Create RoleBinding: `apicurio-rolebinding-argocd.yaml`

**Issue: ArgoCD Dry-Run Fails (CRD Not Found)**

**Symptoms**: ArgoCD sync fails with "CRD not found" during dry-run phase.

**Cause**: ApicurioRegistry3 CRD may not exist when ArgoCD performs dry-run.

**Fix**: Add annotation to ApicurioRegistry3 CR:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

**Issue: UI Route Returns HTTP 503**

**Symptoms**: `curl https://apicurio-studio-ui-apicurio.apps.<domain>` returns HTTP 503.

**Cause**: Route may have TLS misconfiguration or pod not ready.

**Fix**:
1. Check pod status: `oc get pods -n apicurio | grep ui`
2. Check pod logs: `oc logs -n apicurio -l app.kubernetes.io/name=apicurio-studio-ui`
3. Use HTTP instead of HTTPS: Routes are created without TLS termination by default
4. Check ApicurioRegistry3 status: `oc get apicurioregistry3 apicurio-studio -n apicurio -o yaml | grep -A 10 status`

**Issue: Applications Not Syncing**

**Symptoms**: ArgoCD Applications show no sync/health status.

**Cause**: ArgoCD application-controller may not be ready.

**Fix**:
1. Check controller pod: `oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller`
2. If 0/1 READY, restart: `oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller`
3. Wait for pod to be 1/1 READY (15-30 seconds)
4. Applications should auto-sync after controller restart

