# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains GitOps manifests for deploying Red Hat Connectivity Link infrastructure on OpenShift using AWS Route53, ACK (AWS Controllers for Kubernetes), and Istio Gateway API.

**Purpose**: Automate the creation of DNS infrastructure (Route53 hosted zone with delegation), Istio Gateway with TLS, and a demo application (echo-api) for the Connectivity Link use case on OpenShift clusters running on AWS.

## Architecture

### Components

1. **Namespaces** (cluster-scoped)
   - `echo-api` - Application namespace
   - `ingress-gateway` - Gateway and routing namespace

2. **GatewayClass** (`cluster-gatewayclass-istio.yaml`)
   - Cluster-scoped resource defining Istio as the Gateway controller
   - Controller: `openshift.io/gateway-controller/v1`

3. **RBAC** (`cluster-clusterrole-gateway-manager.yaml`, `cluster-crb-gateway-manager-openshift-gitops-argocd-application-controller.yaml`)
   - ClusterRole with Gateway API permissions (create, get, list, watch, update, patch, delete)
   - ClusterRoleBinding for `openshift-gitops-argocd-application-controller` ServiceAccount
   - Required for Jobs to manage Gateway resources

4. **Gateway** (`ingress-gateway-gateway-prod-web.yaml`)
   - Static YAML with placeholder hostname: `*.globex.placeholder`
   - Istio Gateway with HTTPS listener on port 443
   - References TLS certificate Secret `api-tls` (managed by TLSPolicy)
   - **Patched by Job** to use actual cluster domain

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
     - Patches Gateway hostname from placeholder to `*.globex.<cluster-domain>`
     - 2 steps, ~5 seconds execution

   - **Job #4: HTTPRoute Patch** (`openshift-gitops-job-echo-api-httproute.yaml`)
     - Patches HTTPRoute hostname from placeholder to `echo.globex.<cluster-domain>`
     - 2 steps, ~5 seconds execution

11. **Keycloak Realm Import** (keycloak namespace)
   - **KeycloakRealmImport** (`keycloak-keycloakrealmimport-globex-user1.yaml`)
     - Creates `globex-user1` realm in existing Keycloak instance
     - Includes 3 OAuth clients: `client-manager`, `globex-web-gateway`, `globex-mobile`
     - Includes 8 users: 1 realm admin (`user1`), 5 demo users, 2 service accounts
     - Realm roles: `admin`, `confidential`, `mobile-user`, `web-user`, `user`
     - Composite role: `default-roles-globex` (includes realm and client roles)
     - **⚠️ CONTAINS DEMO SECRETS**: OAuth client secrets from Red Hat Globex workshop materials
     - **NOT FOR PRODUCTION**: See SECURITY.md for proper secret management
     - References Keycloak CR named `keycloak` in `keycloak` namespace
     - ArgoCD annotation: `SkipDryRunOnMissingResource=true`

12. **Globex Web Application** (globex namespace)
   - **Deployment** (`globex-deployment-globex-web.yaml`) - Angular SSR application with OAuth integration
   - **Service** (`globex-service-globex-web.yaml`) - ClusterIP exposing port 8080
   - **Route** (`globex-route-globex-web.yaml`) - OpenShift Route for external access
   - **ServiceAccount** (`globex-serviceaccount-globex-web.yaml`)
   - **Image**: `quay.io/cloud-architecture-workshop/globex-web:latest`
   - **Architecture**: Angular 15 with Server-Side Rendering (SSR), Node.js Express server
   - **OAuth Configuration**:
     - Uses OpenID Connect implicit flow with Keycloak
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

### GitOps Flow

```
ArgoCD Application
    ↓
Kustomize Overlay (default)
    ↓
Kustomize Base
    ├── Namespaces (echo-api, ingress-gateway)
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
    └── Jobs (create AWS credentials, patch hostnames, create DNS resources)

Jobs execute:
    Job #1 (AWS) → Creates aws-credentials (DNSPolicy) + aws-acme (cert-manager) Secrets
    Job #2 (DNS) → Creates HostedZone + RecordSet in ack-system
    Job #3 (Gateway) → Patches Gateway hostname
    Job #4 (HTTPRoute) → Patches HTTPRoute hostname

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
│   │   ├── cluster-ns-ingress-gateway.yaml
│   │   ├── echo-api-authpolicy-echo-api.yaml
│   │   ├── echo-api-deployment-echo-api.yaml
│   │   ├── echo-api-httproute-echo-api.yaml
│   │   ├── echo-api-ratelimitpolicy-echo-api-rlp.yaml
│   │   ├── echo-api-service-echo-api.yaml
│   │   ├── ingress-gateway-authpolicy-prod-web-deny-all.yaml
│   │   ├── ingress-gateway-dnspolicy-prod-web.yaml
│   │   ├── ingress-gateway-gateway-prod-web.yaml
│   │   ├── ingress-gateway-ratelimitpolicy-prod-web.yaml
│   │   ├── ingress-gateway-tlspolicy-prod-web.yaml
│   │   ├── keycloak-keycloakrealmimport-globex-user1.yaml
│   │   ├── openshift-gitops-job-aws-credentials.yaml
│   │   ├── openshift-gitops-job-echo-api-httproute.yaml
│   │   ├── openshift-gitops-job-gateway-prod-web.yaml
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
- Namespaces: `echo-api`, `ingress-gateway`
- Gateway `prod-web` (with placeholder hostname)
- AuthPolicy `prod-web-deny-all` (deny-by-default at Gateway level)
- HTTPRoute `echo-api` (with placeholder hostname)
- TLSPolicy `prod-web`
- DNSPolicy `prod-web`
- Deployment `echo-api`
- Service `echo-api`
- Jobs (4): AWS credentials, DNS setup, Gateway patch, HTTPRoute patch

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
- **Fast execution**: AWS credentials job ~5s, DNS job ~45s, Gateway/HTTPRoute patch jobs ~5s each
- **Parallel execution**: Jobs #1 and #2 can run in parallel, Jobs #3-4 are independent
- **Static + Patch pattern**: Gateway and HTTPRoute are static YAML with placeholders, patched by Jobs
- **Dynamic resources**: HostedZone, RecordSet, and AWS Secret are fully created by Jobs (no static YAML)
- **File naming**: Follows convention `<namespace>-<kind>-<name>.yaml` (use `cluster-` prefix for cluster-scoped resources)
- **ArgoCD drift**: ignoreDifferences configured to ignore hostname fields (managed by Jobs)
- **CRITICAL - Secret type**: AWS credentials Secret MUST have type `kuadrant.io/aws` (not `Opaque`) for DNSPolicy to work
- **cert-manager DNS-01**: Requires `aws-acme` Secret (type `Opaque`) for wildcard certificate validation via Route53 TXT records
- **Two AWS Secrets**: Job #1 creates both `aws-credentials` (DNSPolicy) and `aws-acme` (cert-manager) from same credentials
- **DNSPolicy automation**: Automatically creates/updates DNS records in Route53 when Gateway Load Balancer changes
- **Internet exposure**: DNSPolicy is what makes echo-api accessible from Internet (creates CNAME → Load Balancer)
- **CRITICAL - AuthPolicy deny-by-default**: Gateway has AuthPolicy that blocks all traffic by default (HTTP 403)
- **Access control**: Each HTTPRoute MUST have its own AuthPolicy to allow access
- **Security pattern**: Deny-by-default prevents accidental exposure of services
- **Echo API access**: Includes allow-all AuthPolicy (`echo-api-authpolicy-echo-api.yaml`) for demonstration

### Globex Web Application
- **CRITICAL - SSO Environment Variables**: Only 4 SSO env vars are needed: `SSO_CUSTOM_CONFIG`, `SSO_AUTHORITY`, `SSO_REDIRECT_LOGOUT_URI`, `SSO_LOG_LEVEL`
- **DO NOT add SSO_CLIENT_ID**: Conflicts with `SSO_CUSTOM_CONFIG` and breaks OAuth session management
- **CRITICAL - InitContainer Pattern**: Required to patch client-side JavaScript with actual cluster domain
- **Angular SSR Architecture**: Environment variables only affect server-side code, not pre-built JavaScript bundle
- **Mount Path**: InitContainer must mount at `/opt/app-root/src/dist/globex-web/browser` (NOT parent directory)
- **Mounting at wrong path**: Will break Node.js server causing CrashLoopBackOff
- **Runtime Patching**: InitContainer extracts cluster domain from `SSO_AUTHORITY` and runs `sed` to replace placeholder
- **ArgoCD Drift**: Must configure ignoreDifferences for initContainer env var to avoid sync conflicts
- **Job Integration**: `globex-env-setup` Job patches both initContainer and main container environment variables
- **Session Management**: OAuth redirect_uri must match actual cluster domain for session cookies to work

### Security and Demo Secrets
- **⚠️ DEMO SECRETS IN GIT**: This repository contains hardcoded OAuth client secrets in `keycloak-keycloakrealmimport-globex-user1.yaml`
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
