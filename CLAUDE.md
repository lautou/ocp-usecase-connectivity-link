# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains GitOps manifests for deploying Red Hat Connectivity Link infrastructure on OpenShift using AWS Route53, ACK (AWS Controllers for Kubernetes), and Istio Gateway API.

**Purpose**: Automate the creation of DNS infrastructure (Route53 hosted zone with delegation), Istio Gateway with TLS, and a demo application (echo-api) for the Connectivity Link use case on OpenShift clusters running on AWS.

## ⚠️ CRITICAL: RHBK 26 Compatibility Issue (UNRESOLVED)

**Status**: The globex-web application is **NOT COMPATIBLE** with Red Hat build of Keycloak (RHBK) 26.x

**Root Cause**:
- The official globex-web application (`quay.io/cloud-architecture-workshop/globex-web:latest`) is hardcoded to use **OAuth 2.0 Implicit Flow**
- **RHBK 26 completely removed Implicit Flow support** (per OAuth 2.0 Security Best Current Practice)
- Implicit Flow is removed from OAuth 2.1 specification and considered insecure

**Symptom**:
- User can authenticate with Keycloak successfully
- Keycloak redirects back to application with tokens
- Application fails with `user_session_not_found` error on `/userinfo` endpoint (HTTP 401)
- Keycloak logs show: `type="USER_INFO_REQUEST_ERROR", error="user_session_not_found", auth_method="validate_access_token"`

**Why This Fails**:
- Implicit Flow (by design) does not create server-side sessions in Keycloak
- The `/userinfo` endpoint requires a valid server-side session
- This is an architectural incompatibility - not a configuration issue

**RHBK 26 Requirements for SPAs** (per official documentation):
1. **Must use Authorization Code Flow** (not Implicit Flow)
2. **Must use PKCE** (Proof Key for Code Exchange)
3. **Public clients** must set `pkceMethod` in keycloak-js `initOptions`
4. **Client configuration**:
   - `publicClient: true`
   - `standardFlowEnabled: true`
   - `implicitFlowEnabled: false` (must be disabled)
   - `attributes["pkce.code.challenge.method"] = "S256"`

**Attempted Solutions**:
1. ✅ Custom image with JavaScript patches to use Authorization Code Flow (`quay.io/laurenttourreau/globex-web:fixed-pkce`)
   - Patches response_type from "token" to "code"
   - Attempts to enable PKCE in minified code
   - **Result**: Patches may not be applied correctly in minified/obfuscated code
2. ❌ Configuring Keycloak client as confidential with client secret
   - **Result**: Modern Angular OIDC libraries don't support confidential clients in browser
3. ❌ Using original image with Implicit Flow configuration
   - **Result**: Implicit Flow removed in RHBK 26 - returns 401 on /userinfo

**Required Fix**:
The globex-web application needs to be **rebuilt from source** with proper RHBK 26 support:
1. Update Angular OIDC library configuration to use Authorization Code Flow
2. Enable PKCE in keycloak-js initialization: `pkceMethod: 'S256'`
3. Remove all Implicit Flow references from application code
4. Test with RHBK 26.x

**Workarounds**:
- **Option 1**: Downgrade to RHBK 24.x or 25.x (still has Implicit Flow support)
- **Option 2**: Use a different demo application compatible with RHBK 26
- **Option 3**: Rebuild globex-web from source with proper OAuth configuration (source code location unknown)

**References**:
- [RHBK 26 Securing Applications Guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.0/pdf/securing_applications_and_services_guide/Red_Hat_build_of_Keycloak-26.0-Securing_Applications_and_Services_Guide-en-US.pdf)
- [Keycloak PKCE Configuration](https://skycloak.io/blog/keycloak-how-to-create-a-pkce-authorization-flow-client/)
- [Keycloak JavaScript adapter discussion](https://github.com/keycloak/keycloak/discussions/34705)

**Current Configuration** (as of 2026-03-23):
- RHBK Version: 26.4.10.redhat-00001
- globex-web Image: `quay.io/cloud-architecture-workshop/globex-web:latest` (incompatible with RHBK 26)
- Keycloak Client: `globex-web-gateway` configured with both flows enabled (but Implicit Flow ignored by RHBK 26)

**Next Steps**:
1. Investigate if Red Hat has published an updated globex-web image for RHBK 26
2. Search for globex-web source code repository to rebuild with proper OAuth configuration
3. Consider filing issue with Red Hat about demo incompatibility with RHBK 26
4. Evaluate alternative demo applications that work with RHBK 26

## Architecture

### Components

1. **Namespaces** (cluster-scoped)
   - `echo-api` - Application namespace
   - `ingress-gateway` - Gateway and routing namespace
   - `globex` - Globex demo application namespace

2. **GatewayClass** (`cluster-gatewayclass-istio.yaml`)
   - Cluster-scoped resource defining Istio as the Gateway controller
   - Controller: `openshift.io/gateway-controller/v1`

3. **RBAC** (`cluster-clusterrole-gateway-manager.yaml`, `cluster-crb-gateway-manager-openshift-gitops-argocd-application-controller.yaml`)
   - ClusterRole with Gateway API permissions (create, get, list, watch, update, patch, delete)
   - ClusterRoleBinding for `openshift-gitops-argocd-application-controller` ServiceAccount
   - Required for Jobs to manage Gateway resources

4. **Gateway** (`ingress-gateway-gateway-prod-web.yaml`)
   - Static YAML with placeholder hostname: `echo.globex.placeholder` (specific, NOT wildcard)
   - Istio Gateway with HTTPS listener on port 443
   - References TLS certificate Secret `api-tls` (managed by TLSPolicy)
   - **Patched by Job** to use actual cluster domain: `echo.globex.<cluster-domain>`
   - **CRITICAL**: Uses specific hostname to avoid wildcard CNAME + DNS-01 race condition
   - **Rationale**: See "Gateway Hostname Pattern Decision" section for details

5. **TLSPolicy** (`ingress-gateway-tlspolicy-prod-web.yaml`)
   - Kuadrant TLSPolicy for automatic certificate management
   - References ClusterIssuer named `cluster` (cert-manager)
   - Targets the Gateway `prod-web`
   - Automatically creates Let's Encrypt certificate in Secret `api-tls`

6. **AuthPolicy** (`ingress-gateway-authpolicy-prod-web-deny-all.yaml`)
   - Kuadrant AuthPolicy for authentication/authorization at Gateway level
   - **Deny-by-default pattern**: Blocks all traffic unless explicitly allowed
   - Uses OPA (Open Policy Agent) with rego policy: `allow = false`
   - Returns HTTP 403 with JSON error message
   - Requires HTTPRoute-specific AuthPolicy to allow access

7. **DNSPolicy** (`ingress-gateway-dnspolicy-prod-web.yaml`)
   - Kuadrant DNSPolicy for automatic DNS record management in Route53
   - References Secret `aws-credentials` (type: `kuadrant.io/aws`)
   - Targets the Gateway `prod-web`
   - Automatically creates CNAME records pointing Gateway hostnames to Load Balancer

8. **RateLimitPolicy** (`ingress-gateway-ratelimitpolicy-prod-web.yaml`)
   - Kuadrant RateLimitPolicy for rate limiting at Gateway level
   - Targets the Gateway `prod-web`
   - Default limit: 5 requests per 10 second window
   - Applies to all routes through the Gateway

9. **Echo API Application** (echo-api namespace)
   - **Deployment** (`echo-api-deployment-echo-api.yaml`) - 1 replica, image: `quay.io/3scale/authorino:echo-api`
   - **Service** (`echo-api-service-echo-api.yaml`) - ClusterIP exposing port 8080
   - **HTTPRoute** (`echo-api-httproute-echo-api.yaml`) - Static YAML with placeholder hostname: `echo.globex.placeholder`
   - **AuthPolicy** (`echo-api-authpolicy-echo-api.yaml`) - Allow-all policy for demonstration
   - **RateLimitPolicy** (`echo-api-ratelimitpolicy-echo-api-rlp.yaml`) - HTTPRoute-level rate limit (10 req/12s), overrides Gateway default
   - **Patched by Job** to use actual cluster domain (HTTPRoute only)

10. **Jobs** (openshift-gitops namespace)
   - **Job #1: AWS Credentials Setup** (`openshift-gitops-job-aws-credentials.yaml`)
     - Extracts AWS credentials from `kube-system/aws-creds`
     - Extracts AWS region from cluster infrastructure
     - Creates Secret `aws-credentials` with type `kuadrant.io/aws` (for DNSPolicy)
     - Creates Secret `aws-acme` with type `Opaque` (for cert-manager DNS-01 challenges)
     - Required for DNSPolicy to manage Route53 records and cert-manager to validate certificates
     - 4 steps, ~5 seconds execution

   - **Job #2: DNS Setup** (`openshift-gitops-job-globex-ns-delegation.yaml`)
     - Creates HostedZone CR for `globex.<cluster-domain>`
     - Waits for ACK Route53 controller to provision zone in AWS
     - Extracts nameservers from HostedZone status
     - Creates RecordSet CR for NS delegation in parent zone
     - 6 steps, ~45 seconds execution

   - **Job #3: Gateway Patch** (`openshift-gitops-job-gateway-prod-web.yaml`)
     - Patches Gateway hostname from placeholder to `echo.globex.<cluster-domain>` (specific, NOT wildcard)
     - 2 steps, ~5 seconds execution
     - **Note**: Uses specific hostname to avoid wildcard CNAME blocking cert-manager DNS-01 validation

   - **Job #4: HTTPRoute Patch** (`openshift-gitops-job-echo-api-httproute.yaml`)
     - Patches HTTPRoute hostname from placeholder to `echo.globex.<cluster-domain>`
     - 2 steps, ~5 seconds execution

11. **Keycloak Realm Import** (keycloak namespace)
   - **KeycloakRealmImport** (`keycloak-keycloakrealmimport-globex-user1.yaml`)
     - Creates `globex-user1` realm in existing Keycloak instance
     - Includes 3 OAuth clients: `client-manager`, `globex-web-gateway`, `globex-mobile`
     - **OAuth Flow Configuration**:
       - `globex-web-gateway` client has **both** `standardFlowEnabled: true` and `implicitFlowEnabled: true`
       - `standardFlowEnabled` is **REQUIRED** for proper server-side session creation
       - Without it, Keycloak returns 401 "user_session_not_found" on `/userinfo` endpoint
       - Implicit Flow alone doesn't create persistent sessions in Keycloak
     - Includes 8 users: 1 realm admin (`user1`), 5 demo users, 2 service accounts
     - Realm roles: `admin`, `confidential`, `mobile-user`, `web-user`, `user`
     - Composite role: `default-roles-globex` (includes realm and client roles)
     - **⚠️ CONTAINS DEMO SECRETS**: OAuth client secrets from Red Hat Globex workshop materials
     - **NOT FOR PRODUCTION**: See SECURITY.md for proper secret management
     - References Keycloak CR named `keycloak` in `keycloak` namespace
     - ArgoCD annotation: `SkipDryRunOnMissingResource=true`

12. **Globex Web Application** (globex namespace)
   - **⚠️ INCOMPATIBLE WITH RHBK 26**: See "CRITICAL: RHBK 26 Compatibility Issue" section above
   - **Deployment** (`globex-deployment-globex-web.yaml`) - Angular SSR application with OAuth integration
   - **Service** (`globex-service-globex-web.yaml`) - ClusterIP exposing port 8080
   - **Route** (`globex-route-globex-web.yaml`) - OpenShift Route for external access
   - **ServiceAccount** (`globex-serviceaccount-globex-web.yaml`)
   - **Image**: `quay.io/cloud-architecture-workshop/globex-web:latest`
   - **Architecture**: Angular 15 with Server-Side Rendering (SSR), Node.js Express server
   - **OAuth Configuration**:
     - ⚠️ **BROKEN**: Uses OAuth 2.0 Implicit Flow (hardcoded in JavaScript)
     - ⚠️ **Implicit Flow removed in RHBK 26** - application cannot authenticate
     - Client ID: `globex-web-gateway` (configured via `SSO_CUSTOM_CONFIG` env var)
     - **CRITICAL**: Only 4 SSO environment variables are needed:
       - `SSO_CUSTOM_CONFIG`: "globex-web-gateway" (maps to Keycloak client_id)
       - `SSO_AUTHORITY`: Keycloak realm URL (server-side)
       - `SSO_REDIRECT_LOGOUT_URI`: Logout redirect URL
       - `SSO_LOG_LEVEL`: Log verbosity level
     - **DO NOT add `SSO_CLIENT_ID`**: Conflicts with `SSO_CUSTOM_CONFIG` and breaks session management
   - **Runtime Patching Pattern**:
     - InitContainer patches client-side JavaScript bundle at runtime
     - **Problem**: Placeholder domains are baked into the JavaScript bundle at build time
     - **Solution**: InitContainer copies browser files to shared emptyDir volume and replaces placeholders
     - **Implementation**:
       - InitContainer: `patch-placeholder`
         - Copies `/opt/app-root/src/dist/globex-web/browser/*` to shared volume
         - Extracts cluster domain from `SSO_AUTHORITY` environment variable
         - Runs `sed -i "s/placeholder/${APPS_DOMAIN}/g"` on all `.js` files
       - Main container: Mounts shared volume at `/opt/app-root/src/dist/globex-web/browser`
       - Volume: emptyDir named `app-files`
     - **Why needed**: OAuth redirect_uri must match actual cluster domain for session management
     - **CRITICAL**: Mount only at `/opt/app-root/src/dist/globex-web/browser`, NOT `/opt/app-root/src/dist`
       - Server code in `/opt/app-root/src/dist/globex-web/server` must remain unchanged
       - Mounting at parent directory breaks Node.js server (CrashLoopBackOff)
   - **Job Integration** (`openshift-gitops-job-globex-env.yaml`):
     - Patches both initContainer and main container `SSO_AUTHORITY` values
     - Patches main container `SSO_REDIRECT_LOGOUT_URI` value
     - Uses JSON patch with indices:
       - `/spec/template/spec/initContainers/0/env/0/value` → SSO_AUTHORITY
       - `/spec/template/spec/containers/0/env/10/value` → SSO_AUTHORITY
       - `/spec/template/spec/containers/0/env/11/value` → SSO_REDIRECT_LOGOUT_URI
   - **ArgoCD ignoreDifferences**: Configured to ignore runtime-patched environment variables
     - InitContainer: `/spec/template/spec/initContainers/0/env/0/value`
     - Main container: `/spec/template/spec/containers/0/env/10/value`, `/spec/template/spec/containers/0/env/11/value`

13. **Globex Database** (globex namespace)
   - **Deployment** (`globex-deployment-globex-db.yaml`) - PostgreSQL database for Globex application
   - **Service** (`globex-service-globex-db.yaml`) - ClusterIP exposing port 5432
   - **ServiceAccount** (`globex-serviceaccount-globex-db.yaml`)
   - **Secret** (`globex-secret-globex-db.yaml`) - **⚠️ CONTAINS DEMO SECRETS**: Database credentials for testing only
   - **Image**: `quay.io/cloud-architecture-workshop/globex-store-db:latest`
   - **Configuration**:
     - Database name: `globex`
     - User: `globex`
     - **⚠️ WARNING**: Hardcoded demo passwords in Secret (`database-password`, `database-admin-password`, `database-debezium-password`)
     - **NOT FOR PRODUCTION**: See SECURITY.md for proper secret management
   - **Strategy**: Recreate (not RollingUpdate) to prevent data corruption

14. **Globex Store App** (globex namespace)
   - **Deployment** (`globex-deployment-globex-store-app.yaml`) - Quarkus REST API backend
   - **Service** (`globex-service-globex-store-app.yaml`) - ClusterIP exposing port 8080
   - **ServiceAccount** (`globex-serviceaccount-globex-store-app.yaml`)
   - **Image**: `quay.io/cloud-architecture-workshop/globex-store:latest`
   - **Configuration**:
     - Connects to `globex-db` PostgreSQL database
     - Uses Secret `globex-db` for database credentials
     - JDBC URL: `jdbc:postgresql://globex-db:5432/globex`
   - **Health Probes**:
     - Liveness: `/q/health/live`
     - Readiness: `/q/health/ready`

15. **Globex Mobile Gateway** (globex namespace)
   - **Deployment** (`globex-deployment-globex-mobile-gateway.yaml`) - Quarkus mobile API gateway with OAuth
   - **Service** (`globex-service-globex-mobile-gateway.yaml`) - ClusterIP exposing port 8080
   - **Route** (`globex-route-globex-mobile-gateway.yaml`) - OpenShift Route for external access
   - **ServiceAccount** (`globex-serviceaccount-globex-mobile-gateway.yaml`)
   - **Image**: `quay.io/cloud-architecture-workshop/globex-mobile-gateway:latest`
   - **Configuration**:
     - Connects to `globex-store-app` backend
     - Uses Keycloak for OAuth authentication
     - Environment variable `KEYCLOAK_AUTH_SERVER_URL` with placeholder (patched by Job #5)
   - **Job Integration** (`openshift-gitops-job-globex-env.yaml`):
     - Patches `KEYCLOAK_AUTH_SERVER_URL` environment variable
     - Uses JSON patch: `/spec/template/spec/containers/0/env/1/value`
   - **ArgoCD ignoreDifferences**: Configured to ignore runtime-patched environment variables
     - Main container: `/spec/template/spec/containers/0/env/1/value`
   - **Health Probes**:
     - Liveness: `/q/health/live`
     - Readiness: `/q/health/ready`

### GitOps Flow

```
ArgoCD Application
    ↓
Kustomize Overlay (default)
    ↓
Kustomize Base
    ├── Namespaces (echo-api, ingress-gateway, globex)
    ├── RBAC (ClusterRole, ClusterRoleBinding)
    ├── GatewayClass (istio)
    ├── Gateway (static YAML with placeholder)
    ├── AuthPolicy (deny-by-default at Gateway level)
    ├── TLSPolicy (cert-manager integration)
    ├── DNSPolicy (Kuadrant DNS for Internet exposure)
    ├── RateLimitPolicy (rate limiting at Gateway level)
    ├── HTTPRoute (static YAML with placeholder)
    ├── AuthPolicy (allow-all for echo-api HTTPRoute)
    ├── RateLimitPolicy (HTTPRoute-level for echo-api, overrides Gateway default)
    ├── Deployment + Service (echo-api)
    ├── KeycloakRealmImport (Globex demo realm with users and OAuth clients)
    ├── Globex application stack (db, store-app, mobile-gateway, web)
    └── Jobs (create AWS credentials, patch hostnames, create DNS resources, patch Globex env vars)

Jobs execute:
    Job #1 (AWS) → Creates aws-credentials (DNSPolicy) + aws-acme (cert-manager) Secrets
    Job #2 (DNS) → Creates HostedZone + RecordSet in ack-system
    Job #3 (Gateway) → Patches Gateway hostname
    Job #4 (HTTPRoute) → Patches HTTPRoute hostname
    Job #5 (Globex Env) → Patches globex-web and globex-mobile-gateway environment variables

DNSPolicy creates DNS records in Route53 pointing to Gateway Load Balancer
ArgoCD ignores hostname drifts (ignoreDifferences)
```

## Prerequisites

### OpenShift Platform
- OpenShift cluster running on AWS (version 4.19+)
- **OpenShift GitOps** (ArgoCD) installed in `openshift-gitops` namespace

### Gateway API and Istio
- **OpenShift Gateway API CRDs** (automatically available in OpenShift 4.19+)
- **OpenShift Service Mesh 3 Operator** (Sail Operator) installed
  - Operator will be used by Ingress Operator to create Istio control plane
  - **Note**: You do NOT need to create Istio CR manually - it will be created automatically when you create the GatewayClass
  - **Note**: If Red Hat OpenShift AI (RHOAI) is installed, it may have already created an Istio CR (`openshift-gateway`) which will be reused
- **OpenShift Ingress Operator** (pre-installed in OpenShift)
  - Manages Gateway API integration and Istio lifecycle

### AWS Integration
- **ACK Route53 controller** installed and configured in `ack-system` namespace
  - Requires `ack-route53-user-secrets` Secret (AWS credentials)
  - Requires `ack-route53-user-config` ConfigMap (AWS region, etc.)
- AWS credentials in `kube-system/aws-creds` (created during cluster installation)
- Parent Route53 zone must exist and be writable

### Certificate Management
- **cert-manager** installed cluster-wide
  - ClusterIssuer named `cluster` must exist (configured for Let's Encrypt)
  - ClusterIssuer must use DNS-01 solver with Route53 (for wildcard certificates)
  - Expects AWS credentials in Secret `aws-acme` (created by Job #1)

### Kuadrant
- **Kuadrant Operator** installed (provides TLSPolicy, DNSPolicy, AuthPolicy, RateLimitPolicy CRDs)
  - DNS Operator component must be running (manages DNS records in Route53)
  - Limitador component must be running (manages rate limiting)

### Keycloak (Optional - for demo realm import)
- **Red Hat Build of Keycloak (RHBK) Operator** installed (if using KeycloakRealmImport)
  - Keycloak CR named `keycloak` must exist in `keycloak` namespace
  - Keycloak instance must be running and accessible
  - **Note**: This is optional - only needed if deploying the demo Globex realm

## Key Design Decisions

### Gateway API Architecture Choice

**This project uses the Kubernetes Gateway API** managed by the OpenShift Ingress Operator, not manual OpenShift Service Mesh 3 installation.

**Architecture Approach**:
```
GatewayClass (istio)
  ↓ controllerName: openshift.io/gateway-controller/v1
OpenShift Ingress Operator
  ↓ automatically creates
Istio CR (openshift-gateway)
  ↓ managed by
Sail Operator (OpenShift Service Mesh 3)
  ↓ creates
IstioRevision + istiod Deployment
  ↓ control plane for
Gateway resources (prod-web, etc.)
```

**Why Gateway API over manual OSSM 3?**

This project chooses the **Gateway API integration** for the following reasons:

1. ✅ **Zero Configuration**: Ingress Operator automatically installs and manages Istio control plane
2. ✅ **Platform Integration**: Full integration with OpenShift platform features
3. ✅ **Automatic Lifecycle Management**: Upgrades handled by OpenShift Operators
4. ✅ **Simplified Operations**: No manual Istio CR/IstioCNI management required
5. ✅ **Standard API**: Uses Kubernetes Gateway API (v1) for portability

**Alternative Approach (not used)**:

OpenShift Service Mesh 3 also supports **manual installation** where users:
- Create `Istio` and `IstioCNI` custom resources manually
- Have full control over Istio configuration and multiple control planes
- Manage lifecycle independently (like OSSM 2.x)
- Use traditional gateway injection or optionally Gateway API with `istio.io/gateway-controller`

This manual approach provides more flexibility but requires more operational overhead, which is unnecessary for this use case.

**Control Plane Sharing**:

The Istio control plane created by the Ingress Operator (named `openshift-gateway` in `openshift-ingress` namespace) **can be shared** across multiple GatewayClass resources. This means:

- Other components (e.g., Red Hat OpenShift AI) may create their own GatewayClass
- All GatewayClass resources with `controllerName: openshift.io/gateway-controller/v1` share the same control plane
- Each Gateway resource gets its own data plane (Envoy proxy deployment)
- This sharing is efficient and does not impact isolation or functionality

**Important Notes**:
- The Istio CR name is hardcoded to `openshift-gateway` by the Ingress Operator
- The Istio CR namespace is hardcoded to `openshift-ingress`
- Creating a GatewayClass with `openshift.io/gateway-controller/v1` will either:
  - Reuse existing Istio CR if one exists (created by another component)
  - Create a new Istio CR if none exists
- You **do not** and **should not** create Istio CR manually when using this approach

### Static Resources with Placeholders + Job Patches

**Pattern**: Resources with dynamic values (hostnames) are stored as static YAML in Git with placeholders, then patched by Jobs at runtime.

**Why this pattern?**

**Problem**: Gateway and HTTPRoute need cluster-specific hostnames that can't be hardcoded in Git.

**Options Considered**:
1. ❌ Hardcode values → Doesn't work across different clusters
2. ❌ Kustomize patches per cluster → Requires cluster-specific overlays (maintenance burden)
3. ❌ Jobs with embedded YAML → Not reviewable in Git, hard to maintain
4. ✅ **Static YAML + Patch Jobs (chosen)** → Best of both worlds

**Benefits**:
- ✅ YAML visible and reviewable in Git
- ✅ Jobs are simple (3-line JSON patches)
- ✅ Works across different clusters
- ✅ Easy to debug (`oc get gateway -o yaml`)
- ✅ No drift issues with ArgoCD (using ignoreDifferences)

**Example**:

Static YAML in Git:
```yaml
kind: Gateway
spec:
  listeners:
    - hostname: "*.globex.placeholder"
```

Job patch:
```bash
BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
oc patch gateway prod-web --type=json -p='[
  {"op": "replace", "path": "/spec/listeners/0/hostname", "value": "*.globex.'${BASE_DOMAIN}'"}
]'
```

Result in cluster:
```yaml
kind: Gateway
spec:
  listeners:
    - hostname: "*.globex.myocp.sandbox4993.opentlc.com"
```

### Why HostedZone/RecordSet are Created (not Patched)?

**Exception**: DNS resources (HostedZone, RecordSet) are fully created by Job #1, not stored as static YAML.

**Reason**: AWS ACK Controller requires exact FQDN values to create Route53 resources. A placeholder would break AWS integration. These resources are infrastructure-dependent and can't be pre-defined.

### ArgoCD ignoreDifferences

ArgoCD Application uses `ignoreDifferences` to prevent detecting hostname changes as drift:

```yaml
ignoreDifferences:
  - group: gateway.networking.k8s.io
    kind: Gateway
    jsonPointers:
      - /spec/listeners/0/hostname
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    jsonPointers:
      - /spec/hostnames
```

This tells ArgoCD: "These fields are managed by Jobs, not Git. Don't overwrite them."

### Gateway Hostname Pattern Decision: Specific vs Wildcard

**Critical Decision**: This project uses **specific hostnames** (not wildcards) for the Gateway listener.

**Current Implementation**:
```yaml
# Gateway
hostname: "echo.globex.myocp.sandbox3491.opentlc.com"  # Specific

# NOT using:
# hostname: "*.globex.myocp.sandbox3491.opentlc.com"  # Wildcard ❌
```

#### The Wildcard CNAME + DNS-01 Race Condition Problem

**Background**: cert-manager issue [#5751](https://github.com/cert-manager/cert-manager/issues/5751) (open since 2019) documents a critical conflict between wildcard CNAME records and ACME DNS-01 validation.

**The Problem**:

When using wildcard Gateway hostnames with Kuadrant DNSPolicy and cert-manager TLSPolicy:

1. **DNSPolicy creates wildcard CNAME**:
   ```dns
   *.globex.myocp.sandbox3491.opentlc.com → load-balancer.elb.amazonaws.com
   ```

2. **cert-manager tries DNS-01 validation**:
   ```dns
   Query: _acme-challenge.globex.myocp.sandbox3491.opentlc.com TXT
   Expected: TXT record with ACME challenge token
   Actual: CNAME record (caught by wildcard!)
   ```

3. **Wildcard CNAME blocks TXT record**:
   - DNS returns the CNAME instead of allowing TXT record lookup
   - cert-manager cannot validate domain ownership
   - Certificate issuance **stuck forever** in "pending" state

**Race Condition in Simultaneous Deployment**:

When deploying all resources via ArgoCD simultaneously:

```
Time T0: ArgoCD syncs Gateway + TLSPolicy + DNSPolicy
Time T1: Job patches Gateway to wildcard hostname
Time T2: Controllers react in parallel
  ├─ DNSPolicy: Creates wildcard CNAME (fast, simple operation)
  └─ TLSPolicy: Triggers cert-manager DNS-01 challenge (slow, multi-step)

Race outcome:
  If DNSPolicy wins (common):
    └─ Wildcard CNAME exists BEFORE ACME challenge
    └─ Certificate STUCK ❌

  If TLSPolicy wins (rare):
    └─ Certificate issued BEFORE wildcard CNAME created
    └─ Certificate works ✅
    └─ BUT: Renewal fails after 60-90 days ❌
```

**Why This is Non-Deterministic**:
- Controller reconciliation timing
- Kubernetes scheduling
- Network latency to Route53
- DNS propagation speed
- CPU resource availability

**Real-World Impact**:

This race condition explains:
1. **Why initial deployments sometimes work**: TLSPolicy won the race
2. **Why certificate renewal fails**: Wildcard CNAME now exists, blocks renewal
3. **Why official Red Hat demos don't mention it**: Lucky timing or demos end before 60-day renewal
4. **Why our previous cluster worked**: Incremental deployment avoided the race
5. **Why this cluster failed**: Simultaneous deployment, DNSPolicy won the race

**Historical Evidence**:

Our previous cluster experience validates this theory:
- **Old cluster**: Deployed step-by-step → Certificate issued successfully ✅
- **New cluster**: Deployed simultaneously via ArgoCD → Certificate stuck ❌

**cert-manager Fix Status**:

- **Issue**: [#5751](https://github.com/cert-manager/cert-manager/issues/5751) - Open since 2019
- **Recent PR**: [#8639](https://github.com/cert-manager/cert-manager/pull/8639) - Filed March 20, 2026 (3 days before our deployment!)
- **Fix**: Introduces `isWildcardCNAME()` to distinguish wildcard-derived from explicit CNAMEs
- **Status**: **Not yet merged** - Still under review
- **Our version**: cert-manager v1.18.4 - Does NOT include the fix

**Why We Can't Use Wildcards Now**:

1. ❌ cert-manager fix not available yet
2. ❌ No reliable workaround exists
3. ❌ Race condition makes behavior non-deterministic
4. ❌ Certificate renewal will fail even if initial issuance succeeds
5. ❌ Production systems need deterministic certificate behavior

**Solution: Specific Hostnames**

Using specific hostnames eliminates the race condition:

```yaml
# Gateway
hostname: "echo.globex.myocp.sandbox3491.opentlc.com"

# DNSPolicy creates specific CNAME (not wildcard)
echo.globex.myocp.sandbox3491.opentlc.com → load-balancer.elb.amazonaws.com

# cert-manager DNS-01 validation works
Query: _acme-challenge.echo.globex.myocp.sandbox3491.opentlc.com TXT
Result: TXT record (not blocked by specific CNAME) ✅
```

**Benefits**:
- ✅ Deterministic certificate issuance
- ✅ Successful certificate renewals
- ✅ No race conditions
- ✅ Works with current cert-manager version
- ✅ Can switch to wildcard when cert-manager fix is released

**Comparison with Official Red Hat Pattern**:

Official Red Hat Connectivity Link documentation ([solutionpatterns.io](https://www.solutionpatterns.io/soln-pattern-connectivity-link/)) shows:
- ✅ Uses wildcard Gateway hostnames: `*.globex.mycluster.example.com`
- ✅ Uses DNSPolicy + TLSPolicy
- ❌ Does **not** document the DNS-01 conflict
- ❌ Does **not** mention certificate issuance delays
- ⚠️ Likely encounters the same race condition but doesn't document it

**Why Official Docs Don't Mention It**:
1. Demo/workshop environments may win the race sometimes
2. Demos might not run long enough to hit certificate renewal (60-90 days)
3. Manual intervention might happen behind the scenes
4. Issue is non-deterministic and hard to reproduce consistently

**Future Migration Path**:

When cert-manager PR #8639 is merged and released:
1. Upgrade cert-manager to version with fix
2. Change Gateway hostname back to wildcard pattern
3. Enjoy benefits of wildcard routing without DNS-01 conflicts

**Related Issues**:
- cert-manager #5751: "Wildcard DNS domains and `cnameStrategy: Follow` don't work nicely together"
- cert-manager #8639: "fix(dns01): don't follow wildcard CNAMEs for challenge domain"
- Kuadrant: No documented awareness of this conflict

### Kuadrant DNSPolicy and AWS Provider

**DNSPolicy** automatically creates DNS records in Route53 for Gateway endpoints, enabling Internet access.

**Critical Requirement**: The AWS credentials Secret MUST have type `kuadrant.io/aws` (not `Opaque`).

**Why?** Kuadrant DNS Operator detects the provider type by inspecting the Secret type:
- `kuadrant.io/aws` → AWS Route53 provider
- `kuadrant.io/gcp` → Google Cloud DNS provider
- `kuadrant.io/azure` → Azure DNS provider

**Secret Format**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: ingress-gateway
type: kuadrant.io/aws  # ← CRITICAL: Must be this exact type
stringData:
  AWS_ACCESS_KEY_ID: "AKIAXXXXXXXXXXXX"
  AWS_SECRET_ACCESS_KEY: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  AWS_REGION: "eu-central-1"
```

**What DNSPolicy Does**:
1. Watches Gateway `prod-web` (specified in `targetRef`)
2. Extracts Gateway listener hostnames (e.g., `*.globex.myocp.sandbox4993.opentlc.com`)
3. Gets Load Balancer address from Gateway status
4. Creates CNAME records in Route53 zone `globex.myocp.sandbox4993.opentlc.com`
5. Points hostnames → Load Balancer (e.g., `echo.globex.myocp → addf65e4-656871736.eu-central-1.elb.amazonaws.com`)

**Result**: Internet users can access `https://echo.globex.myocp.sandbox4993.opentlc.com`

### Kuadrant AuthPolicy and Deny-by-Default Pattern

**AuthPolicy** provides authentication and authorization for Gateway and HTTPRoute resources.

**Architecture Pattern**: Deny-by-default at Gateway level
- Gateway-level AuthPolicy blocks all traffic by default
- HTTPRoute-level AuthPolicy must be created to allow specific access
- Defense in depth: prevents accidental exposure of services

**Gateway AuthPolicy** (`prod-web-deny-all`):
```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: prod-web-deny-all
  namespace: ingress-gateway
spec:
  targetRef:
    kind: Gateway
    name: prod-web
  rules:
    authorization:
      deny-all:
        opa:
          rego: "allow = false"  # OPA policy that always denies
    response:
      unauthorized:
        headers:
          "content-type":
            value: application/json
        body:
          value: |
            {
              "error": "Forbidden",
              "message": "Access denied by default..."
            }
```

**What happens**:
1. All requests to Gateway `prod-web` are evaluated by AuthPolicy
2. OPA policy `allow = false` always denies authorization
3. Returns HTTP 403 Forbidden with JSON body
4. HTTPRoute-specific AuthPolicy can override this (more specific wins)

**Why this pattern?**
- ✅ **Secure by default**: No service is accidentally exposed
- ✅ **Explicit allow**: Developers must consciously create AuthPolicy for each route
- ✅ **Defense in depth**: Even if HTTPRoute exists, no access without auth
- ✅ **Clear errors**: JSON message tells developers what to do

**Implementation**: The project includes an allow-all AuthPolicy for echo-api (`echo-api-authpolicy-echo-api.yaml`) that overrides the Gateway deny-by-default, making the demo application accessible.

**Echo API AuthPolicy** (included for demonstration):
```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: echo-api
  namespace: echo-api
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: echo-api
  rules:
    authorization:
      allow-all:
        opa:
          rego: "allow = true"  # Allow all traffic to echo-api
```

### Job Management

All Jobs use minimal ArgoCD configuration:
```yaml
annotations:
  argocd.argoproj.io/sync-options: Force=true
```

- `Force=true` - Allows Job recreation if deleted
- No hooks - Jobs are regular managed resources
- Completed Jobs are preserved for audit (no TTL cleanup)
- Jobs run in parallel where possible (Job #1 is independent of Jobs #3-4)

## Deployment

### Automated Deployment (Recommended)

The project includes deployment automation in `scripts/deploy.sh` that handles the entire deployment workflow:

**Features**:
- Validates prerequisites (`oc` CLI, configuration file)
- Parses YAML configuration from `config/cluster.yaml`
- Authenticates to OpenShift cluster (token or password)
- Validates cluster prerequisites (operators, namespaces)
- Deploys ArgoCD Application
- Waits for sync completion (optional)
- Shows deployment status and verification commands

**Usage**:
```bash
# 1. Create configuration from template
cp config/cluster.yaml.example config/cluster.yaml

# 2. Edit config/cluster.yaml with your values
#    - cluster.url: OpenShift API URL
#    - cluster.auth_method: "token" or "password"
#    - cluster.token: API token (if using token auth)
#    - Or cluster.username/password (if using password auth)

# 3. Test configuration (optional)
./scripts/test-deploy.sh

# 4. Deploy
./scripts/deploy.sh
```

**Configuration file** (`config/cluster.yaml`):
- Located in `config/` directory
- Template: `config/cluster.yaml.example`
- Actual file is in `.gitignore` (never commit credentials!)
- Supports token or password authentication
- Configurable validation options and timeouts

**Script functions**:
- `check_prerequisites()` - Validates `oc` CLI and config file
- `load_config()` - Parses YAML with simple awk-based parser
- `login_cluster()` - Authenticates to OpenShift
- `validate_cluster()` - Checks required operators and namespaces
- `deploy_argocd_app()` - Applies ArgoCD Application YAML
- `wait_for_sync()` - Monitors sync progress with timeout
- `show_status()` - Displays deployment status and next steps

See [scripts/README.md](scripts/README.md) for detailed documentation.

### Manual Deployment

Alternatively, deploy directly using `oc` CLI:

1. **Deploy ArgoCD Application**:
```bash
oc apply -f argocd/application.yaml
```

2. **Monitor Sync**:
```bash
# Watch Application status
oc get application usecase-connectivity-link -n openshift-gitops -w

# Check all Jobs
oc get job -n openshift-gitops | grep -E "aws-credentials|globex-ns-delegation|gateway-prod-web|echo-api-httproute"

# Check resources
oc get hostedzone globex -n ack-system
oc get recordset globex-ns-delegation -n ack-system
oc get dnspolicy prod-web -n ingress-gateway
oc get secret aws-credentials -n ingress-gateway
oc get gateway prod-web -n ingress-gateway
oc get httproute echo-api -n echo-api
oc get tlspolicy prod-web -n ingress-gateway
oc get certificate -n ingress-gateway

# Check Job logs
oc logs -n openshift-gitops job/aws-credentials-setup
oc logs -n openshift-gitops job/globex-ns-delegation
oc logs -n openshift-gitops job/gateway-prod-web-setup
oc logs -n openshift-gitops job/echo-api-httproute-setup
```

### Verification

Verify DNS delegation:
```bash
# Get the created subdomain
DOMAIN=$(oc get hostedzone globex -n ack-system -o jsonpath='{.spec.name}')

# Check NS records (should show AWS nameservers)
dig NS $DOMAIN +short

# Verify DNS resolution works
dig $DOMAIN SOA +short
```

Verify Gateway and hostnames:
```bash
# Check Gateway hostname (should be *.globex.<cluster-domain>)
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[0].hostname}'

# Check HTTPRoute hostname (should be echo.globex.<cluster-domain>)
oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}'

# Check DNSPolicy is enforced
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'

# Check DNS resolution from Internet
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME

# Test echo-api application from Internet
curl https://$HOSTNAME
```

## Security and Secret Management

### Demo Secrets Warning

⚠️ **This repository contains hardcoded demo secrets** from Red Hat Globex workshop materials in:
- `kustomize/base/keycloak-keycloakrealmimport-globex-user1.yaml`

These OAuth client secrets are:
- **FOR DEMO/TESTING ONLY** - Publicly documented and safe for demos
- **NOT FOR PRODUCTION** - Never use these in production environments
- From upstream Red Hat demo materials (https://github.com/rh-soln-pattern-connectivity-link/globex-helm)

### Secret Management Approach

**Demo Secrets (Current)**:
- `.gitleaks.toml` - Allowlist configuration for LeakTK scanner
- Inline comments marking secrets as `# DEMO SECRET`
- SECURITY.md file documenting the approach
- README.md warning banner

**Production Alternatives**:

1. **Sealed Secrets** (Recommended for GitOps):
   ```yaml
   apiVersion: bitnami.com/v1alpha1
   kind: SealedSecret
   metadata:
     name: keycloak-client-secrets
   spec:
     encryptedData:
       client-secret: AgBvVGF...  # Encrypted, safe to commit
   ```

2. **External Secrets Operator**:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: keycloak-secrets
   spec:
     secretStoreRef:
       name: vault-backend
     data:
       - secretKey: client-secret
         remoteRef:
           key: prod/keycloak/client-manager
   ```

3. **Dynamic Generation via Jobs**:
   - Generate secrets at runtime (see existing Jobs pattern)
   - Store in Kubernetes Secrets
   - Never commit to Git

4. **HashiCorp Vault Integration**:
   - Vault Agent Injector
   - External Secrets Operator with Vault backend

### LeakTK Configuration

The repository includes `.gitleaks.toml` to handle false positives from Red Hat's security scanner:

```toml
[allowlist]
regexes = [
    '''\b9JRzL6le4K47JJkcSs6kjd9j2Mmfh1Jc\b''',  # Demo secrets
    '''\bX0zRVwSWDVoUpKFhZwtQmZhDtoJ3MkcI\b''',
    '''\bAob7zLHHStk2RCSn2DVwjmhSwoxOwHW7\b''',
]
```

**Testing the allowlist**:
```bash
# Download LeakTK scanner for your architecture
# From: https://source.redhat.com/departments/it/it_information_security/leaktk

# Test the configuration
./leaktk scan --format=human /path/to/repo

# Should show 0 findings if allowlist is working
```

**Prevention**:
```bash
# Install rh-pre-commit to prevent future leaks
pip install rh-pre-commit
cd /path/to/repo
rh-pre-commit install
```

See [SECURITY.md](SECURITY.md) for complete security documentation.

## Repository Structure

```
.
├── kustomize/
│   ├── base/
│   │   ├── cluster-clusterrole-gateway-manager.yaml
│   │   ├── cluster-crb-gateway-manager-openshift-gitops-argocd-application-controller.yaml
│   │   ├── cluster-gatewayclass-istio.yaml
│   │   ├── cluster-ns-echo-api.yaml
│   │   ├── cluster-ns-globex.yaml
│   │   ├── cluster-ns-ingress-gateway.yaml
│   │   ├── echo-api-authpolicy-echo-api.yaml
│   │   ├── echo-api-deployment-echo-api.yaml
│   │   ├── echo-api-httproute-echo-api.yaml
│   │   ├── echo-api-ratelimitpolicy-echo-api-rlp.yaml
│   │   ├── echo-api-service-echo-api.yaml
│   │   ├── globex-deployment-globex-db.yaml
│   │   ├── globex-deployment-globex-mobile-gateway.yaml
│   │   ├── globex-deployment-globex-store-app.yaml
│   │   ├── globex-deployment-globex-web.yaml
│   │   ├── globex-route-globex-mobile-gateway.yaml
│   │   ├── globex-route-globex-web.yaml
│   │   ├── globex-secret-globex-db.yaml
│   │   ├── globex-service-globex-db.yaml
│   │   ├── globex-service-globex-mobile-gateway.yaml
│   │   ├── globex-service-globex-store-app.yaml
│   │   ├── globex-service-globex-web.yaml
│   │   ├── globex-serviceaccount-globex-db.yaml
│   │   ├── globex-serviceaccount-globex-mobile-gateway.yaml
│   │   ├── globex-serviceaccount-globex-store-app.yaml
│   │   ├── globex-serviceaccount-globex-web.yaml
│   │   ├── ingress-gateway-authpolicy-prod-web-deny-all.yaml
│   │   ├── ingress-gateway-dnspolicy-prod-web.yaml
│   │   ├── ingress-gateway-gateway-prod-web.yaml
│   │   ├── ingress-gateway-ratelimitpolicy-prod-web.yaml
│   │   ├── ingress-gateway-tlspolicy-prod-web.yaml
│   │   ├── keycloak-keycloakrealmimport-globex-user1.yaml
│   │   ├── openshift-gitops-job-aws-credentials.yaml
│   │   ├── openshift-gitops-job-echo-api-httproute.yaml
│   │   ├── openshift-gitops-job-gateway-prod-web.yaml
│   │   ├── openshift-gitops-job-globex-env.yaml
│   │   ├── openshift-gitops-job-globex-ns-delegation.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       └── default/
│           └── kustomization.yaml
├── argocd/
│   └── application.yaml
├── config/
│   └── cluster.yaml.example    # Cluster configuration template for deployment
├── scripts/
│   ├── deploy.sh               # Automated deployment script
│   ├── test-deploy.sh          # Configuration validation script
│   └── README.md               # Scripts documentation
├── .gitleaks.toml              # LeakTK allowlist for demo secrets
├── .gitignore                  # Git ignore rules (includes config/cluster.yaml)
├── CLAUDE.md                   # This file
├── README.md                   # User-facing documentation
└── SECURITY.md                 # Security documentation and secret management
```

**File Naming Convention**: `<namespace>-<kind>-<name>.yaml`
- `cluster-*` for cluster-scoped resources (no namespace)
- `<namespace>-*` for namespaced resources
- Examples:
  - `cluster-gatewayclass-istio.yaml` (GatewayClass, cluster-scoped)
  - `cluster-ns-echo-api.yaml` (Namespace, cluster-scoped)
  - `ingress-gateway-gateway-prod-web.yaml` (Gateway in ingress-gateway namespace)
  - `echo-api-httproute-echo-api.yaml` (HTTPRoute in echo-api namespace)
  - `keycloak-keycloakrealmimport-globex-user1.yaml` (KeycloakRealmImport in keycloak namespace)
  - `openshift-gitops-job-globex-ns-delegation.yaml` (Job in openshift-gitops namespace)

## Configuration

All configuration is **cluster-aware** and extracted from cluster resources:

- **Cluster Base Domain**: From `dns.config.openshift.io/cluster` spec.baseDomain (e.g., `myocp.sandbox4993.opentlc.com`)
- **Parent Zone ID**: From `dns.config.openshift.io/cluster` spec.publicZone.id (e.g., `Z044356419CQ6A6BXXDV3`)
- **AWS Region**: From `infrastructure.config.openshift.io/cluster` status.platformStatus.aws.region (e.g., `eu-central-1`)
- **AWS Credentials**: From `kube-system/aws-creds` (created during cluster installation)
- **Root Domain**: Calculated by removing cluster name from baseDomain (e.g., `sandbox4993.opentlc.com`)
- **Cluster Name**: First segment of baseDomain (e.g., `myocp`)
- **Nameservers**: Extracted from HostedZone status.delegationSet.nameServers after creation
- **Gateway Hostname**: Computed as `*.globex.<cluster-domain>` (e.g., `*.globex.myocp.sandbox4993.opentlc.com`)
- **HTTPRoute Hostname**: Computed as `echo.globex.<cluster-domain>` (e.g., `echo.globex.myocp.sandbox4993.opentlc.com`)

**Only hardcoded values**:
- `"globex"` - subdomain name for Route53 zone and Gateway
- `"echo.globex"` - hostname prefix for HTTPRoute

Everything else is 100% dynamic → Works across different clusters/environments

**Important**: The `spec.publicZone.id` MUST point to the **root public zone** (e.g., `sandbox4993.opentlc.com`), NOT the cluster's private zone.

**RecordSet Name**: Uses relative domain format `globex.<cluster-name>` (e.g., `globex.myocp`) to avoid FQDN duplication in Route53.

## Resources Created

### Static Resources (in Git)
- ClusterRole `gateway-manager`
- ClusterRoleBinding
- GatewayClass `istio`
- Namespaces: `echo-api`, `ingress-gateway`, `globex`
- Gateway `prod-web` (with placeholder hostname)
- AuthPolicy `prod-web-deny-all` (deny-by-default at Gateway level)
- HTTPRoute `echo-api` (with placeholder hostname)
- TLSPolicy `prod-web`
- DNSPolicy `prod-web`
- RateLimitPolicy `prod-web` (Gateway level)
- Deployment `echo-api`
- Service `echo-api`
- AuthPolicy `echo-api` (allow-all for HTTPRoute)
- RateLimitPolicy `echo-api-rlp` (HTTPRoute level)
- Globex application stack:
  - Deployment `globex-db` (PostgreSQL)
  - Deployment `globex-store-app` (Quarkus REST API)
  - Deployment `globex-mobile-gateway` (Quarkus mobile API with OAuth, patched by Job #5)
  - Deployment `globex-web` (Angular SSR web app with OAuth, patched by Job #5)
  - Services, Routes, ServiceAccounts for all components
  - Secret `globex-db` (⚠️ DEMO SECRETS - database credentials)
- KeycloakRealmImport `globex-user1` (⚠️ DEMO SECRETS - OAuth client secrets)
- Jobs (5): AWS credentials, DNS setup, Gateway patch, HTTPRoute patch, Globex env vars patch

### Dynamic Resources (created by Jobs/Controllers)

**In `ingress-gateway` namespace** (created by Job #1):
- Secret `aws-credentials` - AWS credentials for DNSPolicy (type: `kuadrant.io/aws`)
- Secret `aws-acme` - AWS credentials for cert-manager DNS-01 challenges (type: `Opaque`)

**In `ack-system` namespace** (created by Job #2):
- HostedZone `globex` - Route53 zone for `globex.<cluster-domain>`
- RecordSet `globex-ns-delegation` - NS delegation records in parent zone

**In Route53** (created by DNSPolicy):
- CNAME records - Pointing Gateway hostnames to Load Balancer
  - Example: `echo.globex.myocp.sandbox4993.opentlc.com` → `addf65e4-656871736.eu-central-1.elb.amazonaws.com`

**Certificate** (created by TLSPolicy/cert-manager):
- Certificate `prod-web-api` - Let's Encrypt wildcard cert for `*.globex.<cluster-domain>`
- Secret `api-tls` - TLS certificate and key

## Troubleshooting

### Job Fails with "Timeout waiting for HostedZone"

**Cause**: HostedZone creation is slow or failed

**Fix**:
```bash
# Check HostedZone status
oc get hostedzone globex -n ack-system -o yaml

# Check ACK controller logs
oc logs -n ack-system deployment/ack-route53-controller
```

### RecordSet Creation Fails

**Cause**: Insufficient permissions or parent zone not accessible

**Fix**:
```bash
# Verify AWS credentials Secret exists
oc get secret ack-route53-user-secrets -n ack-system

# Check RecordSet status
oc describe recordset globex-ns-delegation -n ack-system

# Verify parent zone ID is correct
oc get dns cluster -o jsonpath='{.spec.publicZone.id}'
```

### DNS Not Resolving

**Cause**: DNS propagation delay or delegation not created

**Fix**:
```bash
# Check if RecordSet exists and is synced
oc get recordset globex-ns-delegation -n ack-system -o yaml

# Wait 5-10 minutes for DNS propagation
# Test with authoritative nameserver directly
dig @ns-451.awsdns-56.com globex.myocp.sandbox4993.opentlc.com SOA
```

### Gateway Hostname Not Updated

**Cause**: Gateway patch Job failed or not run

**Fix**:
```bash
# Check Job status
oc get job gateway-prod-web-setup -n openshift-gitops

# Check Job logs
oc logs -n openshift-gitops job/gateway-prod-web-setup

# Manually trigger by deleting Job (ArgoCD will recreate)
oc delete job gateway-prod-web-setup -n openshift-gitops
```

### HTTPRoute Hostname Not Updated

**Cause**: HTTPRoute patch Job failed or not run

**Fix**:
```bash
# Check Job status
oc get job echo-api-httproute-setup -n openshift-gitops

# Check Job logs
oc logs -n openshift-gitops job/echo-api-httproute-setup

# Manually trigger by deleting Job
oc delete job echo-api-httproute-setup -n openshift-gitops
```

### TLS Certificate Issues

**Cause**: cert-manager or TLSPolicy misconfiguration

**Fix**:
```bash
# Check ClusterIssuer
oc get clusterissuer cluster

# Check Certificate status
oc get certificate -n ingress-gateway

# Check TLSPolicy status
oc get tlspolicy prod-web -n ingress-gateway -o yaml

# Check cert-manager logs
oc logs -n cert-manager deployment/cert-manager
```

### ArgoCD Shows Out-of-Sync

**Cause**: ignoreDifferences not configured correctly

**Fix**:
```bash
# Verify ignoreDifferences in Application
oc get application usecase-connectivity-link -n openshift-gitops -o yaml | grep -A 10 ignoreDifferences

# Re-apply Application with ignoreDifferences
oc apply -f argocd/application.yaml
```

### Gateway Permission Errors

**Cause**: Missing RBAC permissions for Jobs

**Fix**:
```bash
# Check ClusterRole exists
oc get clusterrole gateway-manager

# Check ClusterRoleBinding exists
oc get clusterrolebinding gateway-manager-openshift-gitops-argocd-application-controller

# Verify ServiceAccount has permissions
oc auth can-i create gateways.gateway.networking.k8s.io --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

### DNSPolicy Not Creating DNS Records

**Cause**: Incorrect Secret type or missing AWS credentials

**Fix**:
```bash
# CRITICAL: Check Secret type (MUST be kuadrant.io/aws, NOT Opaque)
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.type}'
# Should output: kuadrant.io/aws

# If type is wrong, delete and recreate via Job
oc delete secret aws-credentials -n ingress-gateway
oc delete job aws-credentials-setup -n openshift-gitops

# Check DNSPolicy status
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.'

# Check DNS Operator logs for provider errors
oc logs -n openshift-operators deployment/dns-operator-controller-manager --tail=50 | grep -i "prod-web\|provider\|error"

# Verify AWS region is set
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.data.AWS_REGION}' | base64 -d
```

### Echo API Returns HTTP 403 Forbidden

**Cause**: The echo-api AuthPolicy may not be deployed or is misconfigured

**Expected Behavior**: echo-api should return HTTP 200 because it has an allow-all AuthPolicy (`echo-api-authpolicy-echo-api.yaml`) that overrides the Gateway deny-by-default.

**Fix**:
```bash
# Verify echo-api AuthPolicy exists
oc get authpolicy echo-api -n echo-api

# Check AuthPolicy status
oc describe authpolicy echo-api -n echo-api

# If missing, check ArgoCD sync status
oc get application usecase-connectivity-link -n openshift-gitops

# Check Gateway-level AuthPolicy (should exist)
oc get authpolicy prod-web-deny-all -n ingress-gateway -o yaml
```

### Echo API Not Accessible from Internet (After Allowing Auth)

**Cause**: DNS records not created or DNS propagation delay

**Fix**:
```bash
# Check DNSPolicy is enforced
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'
# Should show: "status": "True", "message": "DNSPolicy has been successfully enforced"

# Check DNS resolution
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME
# Should return Load Balancer hostname and IPs

# Check Gateway Load Balancer address
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.status.addresses}'

# Test HTTPS connectivity
curl -v https://$HOSTNAME

# Check TLS certificate
echo | openssl s_client -connect $HOSTNAME:443 -servername $HOSTNAME 2>/dev/null | openssl x509 -noout -subject -issuer
```

### Globex Web OAuth Login Completes But Session Not Maintained

**Symptoms**:
- User clicks "Login", redirected to Keycloak, authenticates successfully
- Redirected back to Globex application
- "Login" button remains (should change to "Logout")
- Session is not maintained, user not logged in
- Browser redirects to `globex-web-globex.placeholder` domain (non-existent)

**Root Causes**:

1. **SSO_CLIENT_ID environment variable conflict** (if present):
   - The application uses `SSO_CUSTOM_CONFIG` to specify the client_id
   - Adding `SSO_CLIENT_ID` creates a conflict and breaks session management
   - **Solution**: Remove `SSO_CLIENT_ID` from deployment, only use 4 SSO env vars

2. **Placeholder domain hardcoded in JavaScript bundle**:
   - Environment variables only affect server-side code (Node.js)
   - Client-side JavaScript has placeholder domains baked in at build time
   - OAuth redirect_uri in browser uses `https://globex-web-globex.placeholder/...`
   - After Keycloak auth, redirect fails because domain doesn't exist
   - **Solution**: Use initContainer to patch JavaScript files at runtime

**Fix**:

```bash
# 1. Verify only 4 SSO environment variables are present
oc get deployment globex-web -n globex -o jsonpath='{.spec.template.spec.containers[0].env}' | jq 'map(select(.name | startswith("SSO_")))'
# Should show: SSO_CUSTOM_CONFIG, SSO_AUTHORITY, SSO_REDIRECT_LOGOUT_URI, SSO_LOG_LEVEL

# 2. Check if SSO_CLIENT_ID is present (WRONG - should be removed)
oc get deployment globex-web -n globex -o jsonpath='{.spec.template.spec.containers[0].env}' | jq 'map(select(.name == "SSO_CLIENT_ID"))'
# Should return empty array []

# 3. Verify initContainer is present to patch JavaScript files
oc get deployment globex-web -n globex -o jsonpath='{.spec.template.spec.initContainers[0].name}'
# Should show: patch-placeholder

# 4. Check initContainer logs to verify patching worked
oc logs -n globex -l app.kubernetes.io/name=globex-web -c patch-placeholder --tail=10
# Should show: "Apps domain: apps.<cluster-domain>" and "Placeholder domains replaced"

# 5. Verify placeholder is removed from JavaScript
curl -sk 'https://globex-web-globex.apps.<cluster-domain>/main.js' | grep -o 'placeholder' | wc -l
# Should return: 0

# 6. Verify actual cluster domain is present in JavaScript
curl -sk 'https://globex-web-globex.apps.<cluster-domain>/main.js' | grep -o 'apps\.<cluster-domain>' | head -3
# Should return actual domain multiple times

# 7. If initContainer is missing, check ArgoCD sync status
oc get application.argoproj.io usecase-connectivity-link -n openshift-gitops -o jsonpath='{.status.sync.status}'

# 8. If sync is OK but initContainer missing, force re-sync
oc annotate application.argoproj.io usecase-connectivity-link -n openshift-gitops argocd.argoproj.io/refresh=normal --overwrite

# 9. If everything looks correct, restart deployment to apply changes
oc rollout restart deployment globex-web -n globex
oc rollout status deployment globex-web -n globex --timeout=3m
```

**Important Notes**:
- The globex-web is an Angular 15 SSR (Server-Side Rendering) application
- Environment variables are injected server-side but client-side code is pre-built
- The initContainer pattern is required to patch client-side JavaScript at runtime
- InitContainer must mount at `/opt/app-root/src/dist/globex-web/browser` (NOT parent directory)
- Mounting at `/opt/app-root/src/dist` breaks the Node.js server (CrashLoopBackOff)
- The Job `globex-env-setup` patches both initContainer and main container env vars
- ArgoCD ignoreDifferences must include initContainer env var path to avoid drift

**Debugging OAuth Flow**:

```bash
# Check Keycloak client configuration
oc get keycloakrealmimport globex-user1 -n keycloak -o jsonpath='{.spec.realm.clients[?(@.clientId=="globex-web-gateway")]}' | jq '{clientId, redirectUris, webOrigins, implicitFlowEnabled}'

# Test login with browser developer tools:
# 1. Open browser DevTools → Network tab
# 2. Click "Login" button
# 3. Check the Keycloak redirect URL - should contain:
#    redirect_uri=https://globex-web-globex.apps.<actual-domain>/...
# 4. After auth, check if redirect_uri matches the current domain
# 5. Check Application → Cookies for Keycloak session cookies
```

### Keycloak Userinfo Endpoint Returns 401 Unauthorized

**Symptoms**:
- OAuth login redirects to Keycloak and back successfully
- Browser receives valid access token and ID token in URL fragment
- Multiple requests to `/protocol/openid-connect/userinfo` return **HTTP 401 Unauthorized**
- Keycloak logs show error: `user_session_not_found`
- User session doesn't persist, "Login" button remains instead of showing username

**Root Cause**:

Keycloak client using **OAuth2 Implicit Flow only** (`implicitFlowEnabled: true`) without **Authorization Code Flow** (`standardFlowEnabled: false` or not set).

The Implicit Flow:
- Returns tokens directly in URL fragment (`#`)
- **Does NOT create server-side sessions** in Keycloak
- Fails when calling `/userinfo` because Keycloak can't find the session
- Token introspection returns `"active": false`

**Keycloak Error Log**:
```
type="USER_INFO_REQUEST_ERROR", error="user_session_not_found", auth_method="validate_access_token"
```

**Fix**:

Enable **Authorization Code Flow** alongside Implicit Flow in the Keycloak client:

```yaml
# kustomize/base/keycloak-keycloakrealmimport-globex-user1.yaml
- clientId: globex-web-gateway
  standardFlowEnabled: true  # ← ADD THIS
  implicitFlowEnabled: true
  # ... rest of config
```

**Verification Steps**:

```bash
# 1. Check Keycloak client configuration
oc get keycloakrealmimport globex-user1 -n keycloak -o jsonpath='{.spec.realm.clients[?(@.clientId=="globex-web-gateway")]}' | jq '{clientId, standardFlowEnabled, implicitFlowEnabled}'
# Should show: standardFlowEnabled: true, implicitFlowEnabled: true

# 2. Check Keycloak logs for errors
oc logs -n keycloak -l app=keycloak --tail=20 | grep -i "user_session_not_found\|userinfo"

# 3. After fixing, clear browser cache and storage
# Run in browser console:
localStorage.clear();
sessionStorage.clear();
location.reload(true);

# 4. Test userinfo endpoint after login
# Should return HTTP 200 with user profile data
```

**Important**:
- Modern OAuth2 best practice: Use **Authorization Code Flow with PKCE** for SPAs
- Implicit Flow has known security issues and doesn't maintain sessions
- Both flows enabled ensures compatibility while fixing session issues
- After changing Keycloak config, ArgoCD will sync and Keycloak Operator applies changes automatically

## Important Notes

### Gateway API and Control Plane
- **Gateway API approach**: This project uses Kubernetes Gateway API managed by OpenShift Ingress Operator (not manual OSSM 3 installation)
- **Automatic Istio CR creation**: The Ingress Operator automatically creates the Istio CR (`openshift-gateway` in `openshift-ingress` namespace) when you create the first GatewayClass with `controllerName: openshift.io/gateway-controller/v1`
- **Control plane sharing**: The Istio control plane is shared across all GatewayClass resources using `openshift.io/gateway-controller/v1` controller
- **Coexistence with RHOAI**: If Red Hat OpenShift AI (RHOAI) is installed, it creates its own GatewayClass (`data-science-gateway-class`) which shares the same Istio control plane (`openshift-gateway`)
- **Do NOT create Istio CR manually**: When using Gateway API integration, the Istio CR is managed by the Ingress Operator - creating it manually will cause conflicts
- **One control plane, multiple data planes**: Each Gateway resource gets its own Envoy proxy deployment (data plane), but all share the same istiod control plane

### Job Management
- **Completed Jobs are preserved**: No TTL cleanup - Jobs remain for audit/debugging
- **Job recreates on deletion**: With `Force=true`, deleting the Jobs triggers recreation on next sync
- **Idempotent operations**: All Jobs use `oc apply` or `oc patch` making them safe to re-run
- **Parent zone must be writable**: ACK needs permission to modify the public zone
- **ServiceAccount**: All Jobs use `openshift-gitops-argocd-application-controller` (has cluster-admin + Gateway permissions)
- **Fast execution**: AWS credentials job ~5s, DNS job ~45s, Gateway/HTTPRoute/Globex env patch jobs ~5s each
- **Parallel execution**: Jobs #1 and #2 can run in parallel, Jobs #3-5 are independent
- **Static + Patch pattern**: Gateway and HTTPRoute are static YAML with placeholders, patched by Jobs
- **Dynamic resources**: HostedZone, RecordSet, and AWS Secret are fully created by Jobs (no static YAML)
- **File naming**: Follows convention `<namespace>-<kind>-<name>.yaml` (use `cluster-` prefix for cluster-scoped resources)
- **ArgoCD drift**: ignoreDifferences configured to ignore hostname fields (managed by Jobs)
- **Job recreation after ArgoCD sync**: When ArgoCD syncs (e.g., after Git changes), it may revert Job-patched deployments back to Git state with placeholders. Solution: Delete the relevant Job to trigger recreation and re-patching
  ```bash
  # Example: Re-run globex-env-setup after ArgoCD sync
  oc delete job globex-env-setup -n openshift-gitops
  # ArgoCD will recreate and run it automatically due to Force=true
  ```
- **CRITICAL - Secret type**: AWS credentials Secret MUST have type `kuadrant.io/aws` (not `Opaque`) for DNSPolicy to work
- **cert-manager DNS-01**: Requires `aws-acme` Secret (type `Opaque`) for wildcard certificate validation via Route53 TXT records
- **Two AWS Secrets**: Job #1 creates both `aws-credentials` (DNSPolicy) and `aws-acme` (cert-manager) from same credentials
- **DNSPolicy automation**: Automatically creates/updates DNS records in Route53 when Gateway Load Balancer changes
- **Internet exposure**: DNSPolicy is what makes echo-api accessible from Internet (creates CNAME → Load Balancer)
- **CRITICAL - AuthPolicy deny-by-default**: Gateway has AuthPolicy that blocks all traffic by default (HTTP 403)
- **Access control**: Each HTTPRoute MUST have its own AuthPolicy to allow access
- **Security pattern**: Deny-by-default prevents accidental exposure of services
- **Echo API access**: Includes allow-all AuthPolicy (`echo-api-authpolicy-echo-api.yaml`) for demonstration

### Globex Application Stack
- **Database Secrets**: `globex-db` Secret contains **⚠️ DEMO PASSWORDS** for PostgreSQL (not for production)
- **globex-web Application**:
  - **CRITICAL - SSO Environment Variables**: Only 4 SSO env vars are needed: `SSO_CUSTOM_CONFIG`, `SSO_AUTHORITY`, `SSO_REDIRECT_LOGOUT_URI`, `SSO_LOG_LEVEL`
  - **DO NOT add SSO_CLIENT_ID**: Conflicts with `SSO_CUSTOM_CONFIG` and breaks OAuth session management
  - **CRITICAL - InitContainer Pattern**: Required to patch client-side JavaScript with actual cluster domain
  - **Angular SSR Architecture**: Environment variables only affect server-side code, not pre-built JavaScript bundle
  - **Mount Path**: InitContainer must mount at `/opt/app-root/src/dist/globex-web/browser` (NOT parent directory)
  - **Mounting at wrong path**: Will break Node.js server causing CrashLoopBackOff
  - **Runtime Patching**: InitContainer extracts cluster domain from `SSO_AUTHORITY` and runs `sed` to replace placeholder
  - **Job Integration**: `globex-env-setup` Job patches both initContainer and main container environment variables
  - **Session Management**: OAuth redirect_uri must match actual cluster domain for session cookies to work
- **globex-mobile-gateway Application**:
  - **Job Integration**: `globex-env-setup` Job patches `KEYCLOAK_AUTH_SERVER_URL` environment variable
  - **JSON Patch Path**: `/spec/template/spec/containers/0/env/1/value`
- **ArgoCD ignoreDifferences** (configured for both apps):
  - globex-web: `/spec/template/spec/initContainers/0/env/0/value`, `/spec/template/spec/containers/0/env/10/value`, `/spec/template/spec/containers/0/env/11/value`
  - globex-mobile-gateway: `/spec/template/spec/containers/0/env/1/value`

### Security and Demo Secrets
- **⚠️ DEMO SECRETS IN GIT**: This repository contains hardcoded secrets in multiple files:
  - `keycloak-keycloakrealmimport-globex-user1.yaml` - OAuth client secrets
  - `globex-secret-globex-db.yaml` - Database credentials (passwords for PostgreSQL)
- **NOT FOR PRODUCTION**: These are publicly known demo secrets from Red Hat Globex workshop materials
- **Source**: https://github.com/rh-soln-pattern-connectivity-link/globex-helm
- **LeakTK allowlist**: `.gitleaks.toml` file configures Red Hat's security scanner to ignore these known demo secrets
- **Testing**: Run `./leaktk scan --format=human .` to verify allowlist (should show 0 findings)
- **Prevention**: Install `rh-pre-commit` hooks to prevent accidental secret commits
- **Production alternatives**: Use Sealed Secrets, External Secrets Operator, Vault, or dynamic generation via Jobs
- **Documentation**: See `SECURITY.md` for complete secret management guidance
- **Inline markers**: All demo secrets marked with `# DEMO SECRET` comments
- **File header**: KeycloakRealmImport includes warning header about demo secrets

## Related Projects

This project is inspired by:
- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Dynamic configuration injection pattern
- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible-based approach
- [cl-install-helm](https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm) - Helm chart for echo-api

## Future Enhancements

Potential improvements:
- [ ] Add health checks for DNS propagation validation
- [ ] Add health checks for Gateway readiness and TLS certificate validation
- [ ] Create a cleanup Job for decommissioning (delete HTTPRoute, RecordSet, Gateway, HostedZone)
- [ ] Add Prometheus metrics for DNS delegation and Gateway status
- [ ] Support multiple subdomains/Gateways with templating
- [ ] Add more demo applications with different HTTPRoutes and AuthPolicies
- [ ] Add RateLimitPolicy for API rate limiting
- [ ] Add tests with pre-commit hooks
