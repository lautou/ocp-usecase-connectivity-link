# OpenShift Use Case - Red Hat Connectivity Link

GitOps repository for automating Red Hat Connectivity Link infrastructure on OpenShift using AWS Route53, ACK, Istio Gateway API, and Kuadrant.

> **⚠️ IMPORTANT**: This is a **demo/testing repository** containing hardcoded secrets from Red Hat Globex workshop materials. These secrets are publicly known and **should NEVER be used in production**. See [SECURITY.md](SECURITY.md) for details on proper secret management.

## Overview

This project automates the deployment of:
- **DNS infrastructure** (Route53 hosted zone with delegation)
- **Istio Gateway** with automated TLS certificates
- **Demo application** (echo-api) to validate the setup

Everything is managed via GitOps using ArgoCD with **100% dynamic configuration** - works across different OpenShift clusters without modification.

## What It Deploys

1. **Route53 HostedZone** - Creates `globex.<cluster-domain>` DNS zone
2. **NS Delegation** - Automatically configures delegation in parent zone
3. **DNS Records** - Kuadrant DNSPolicy creates CNAME records pointing to Gateway Load Balancer
4. **Istio Gateway** - HTTPS ingress gateway at `*.globex.<cluster-domain>`
5. **TLS Certificates** - Automatic Let's Encrypt certificates via cert-manager
6. **Authentication** - Kuadrant AuthPolicy with deny-by-default at Gateway level
7. **Rate Limiting** - Kuadrant RateLimitPolicy at Gateway level (5 req/10s)
8. **Echo API Application** - Demo service with allow-all AuthPolicy and HTTPRoute-level RateLimitPolicy (10 req/12s)
9. **Keycloak Realm Import** - Optional Globex demo realm with users and OAuth clients (for testing/demo only)

## Prerequisites

### OpenShift Platform
- **OpenShift Container Platform 4.19+** running on AWS
  - Gateway API CRDs are automatically installed
- **OpenShift GitOps** (ArgoCD) - for GitOps deployment
- **OpenShift Ingress Operator** (pre-installed) - manages Gateway API integration

### Service Mesh
- **OpenShift Service Mesh 3 Operator** (Sail Operator)
  - Installed via OperatorHub
  - **Note**: Istio control plane will be created automatically by Ingress Operator when GatewayClass is created
  - **Note**: If RHOAI is installed, the control plane may already exist and will be shared

### AWS Integration
- **ACK Route53 controller** (in `ack-system` namespace)
- AWS credentials in `kube-system/aws-creds` (created during cluster installation)
- Parent Route53 zone must exist and be writable

### Certificate & Policy Management
- **cert-manager** - for automatic TLS certificate management
  - ClusterIssuer named `cluster` must exist (configured for Let's Encrypt)
- **Kuadrant Operator** - provides DNS, TLS, Auth, and RateLimit policies

### Keycloak (Optional - for demo realm)
- **Red Hat Build of Keycloak (RHBK) Operator** - only if using Keycloak realm import
  - Keycloak CR named `keycloak` must exist in `keycloak` namespace
  - Only needed for deploying the demo Globex realm with test users and OAuth clients

## Quick Start

### Option 1: Automated Deployment (Recommended)

Use the deployment script for automated setup with validation:

```bash
# 1. Create configuration file
cp config/cluster.yaml.example config/cluster.yaml

# 2. Edit config/cluster.yaml with your cluster URL and credentials
# (token or password authentication)

# 3. Test configuration (optional)
./scripts/test-deploy.sh

# 4. Deploy
./scripts/deploy.sh
```

The script will:
- ✅ Validate prerequisites and configuration
- ✅ Login to your cluster
- ✅ Check required operators
- ✅ Deploy ArgoCD Application
- ✅ Wait for sync completion
- 📊 Show verification commands

See [scripts/README.md](scripts/README.md) for detailed documentation.

### Option 2: Manual Deployment

Deploy directly using `oc` CLI:

```bash
oc apply -f argocd/application.yaml
```

### Monitor

```bash
# Watch Application status
oc get application usecase-connectivity-link -n openshift-gitops -w

# Check all Jobs
oc get job -n openshift-gitops | grep -E "aws-credentials|globex-ns-delegation|gateway-prod-web|echo-api-httproute"

# View Job logs
oc logs -n openshift-gitops job/aws-credentials-setup
oc logs -n openshift-gitops job/globex-ns-delegation
oc logs -n openshift-gitops job/gateway-prod-web-setup
oc logs -n openshift-gitops job/echo-api-httproute-setup
```

### Verify

```bash
# Check DNS resources
oc get hostedzone globex -n ack-system
oc get recordset globex-ns-delegation -n ack-system

# Check Policies
oc get authpolicy prod-web-deny-all -n ingress-gateway
oc get authpolicy echo-api -n echo-api
oc get dnspolicy prod-web -n ingress-gateway
oc get ratelimitpolicy prod-web -n ingress-gateway
oc get ratelimitpolicy echo-api-rlp -n echo-api
oc get tlspolicy prod-web -n ingress-gateway
oc get secret aws-credentials -n ingress-gateway

# Check Gateway resources
oc get gateway prod-web -n ingress-gateway
oc get httproute echo-api -n echo-api
oc get certificate -n ingress-gateway

# Check echo-api application
oc get deployment echo-api -n echo-api
oc get service echo-api -n echo-api

# Test DNS resolution (wait 2-3 min for DNSPolicy to create records)
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME

# Test echo-api endpoint from Internet
curl https://$HOSTNAME

# Expected response (HTTP 200 with echo-api allow-all AuthPolicy):
# Request served by echo-api-...
# HTTP headers and request information
```

**Note**: The echo-api includes an allow-all AuthPolicy that overrides the Gateway's deny-by-default policy, so it should be accessible via HTTPS.

## Gateway API Approach

This project uses **Kubernetes Gateway API** managed by the OpenShift Ingress Operator:

- **Automatic Control Plane**: The Istio control plane is created automatically when you create the GatewayClass
- **Shared Infrastructure**: The control plane can be shared with other components (e.g., Red Hat OpenShift AI)
- **Platform Integration**: Fully integrated with OpenShift platform features and lifecycle management
- **Zero Manual OSSM Configuration**: No need to create Istio or IstioCNI custom resources manually

The Ingress Operator creates an Istio CR named `openshift-gateway` in the `openshift-ingress` namespace, which is managed automatically and shared across all Gateway API resources.

**Alternative**: OpenShift Service Mesh 3 also supports manual installation with full control over Istio configuration, but this approach is not used in this project as the automatic Gateway API integration is simpler and sufficient for this use case.

## Architecture

### Component Flow

```
ArgoCD Application
    ↓
Kustomize (overlays/default)
    ↓
Static Resources (Git)
    ├─ Namespaces (echo-api, ingress-gateway)
    ├─ RBAC (ClusterRole + ClusterRoleBinding)
    ├─ GatewayClass (istio)
    ├─ Gateway (with placeholder hostname)
    ├─ AuthPolicy (deny-by-default at Gateway level)
    ├─ TLSPolicy (cert-manager integration)
    ├─ DNSPolicy (Kuadrant DNS integration for Internet exposure)
    ├─ HTTPRoute (with placeholder hostname)
    ├─ Deployment + Service (echo-api app)
    └─ Jobs (4)
        ├─ Job #1: Create AWS credentials Secret
        ├─ Job #2: Create HostedZone + RecordSet
        ├─ Job #3: Patch Gateway hostname
        └─ Job #4: Patch HTTPRoute hostname

Runtime Execution:
    Job #1 → Creates Secret with AWS credentials (type: kuadrant.io/aws)
    Job #2 → Creates HostedZone + RecordSet in AWS Route53
    Job #3 → Patches Gateway: *.globex.placeholder → *.globex.<cluster-domain>
    Job #4 → Patches HTTPRoute: echo.globex.placeholder → echo.globex.<cluster-domain>
    TLSPolicy → Triggers cert-manager to create Let's Encrypt certificate
    DNSPolicy → Creates CNAME records in Route53 pointing to Gateway Load Balancer
```

### Key Components

| Component | Type | Purpose |
|-----------|------|---------|
| **GatewayClass** | Static | Defines Istio as Gateway controller |
| **Gateway** | Static + Patch | HTTPS ingress with wildcard hostname |
| **AuthPolicy (Gateway)** | Static | Deny-by-default authentication at Gateway level |
| **AuthPolicy (echo-api)** | Static | Allow-all policy for echo-api HTTPRoute |
| **RateLimitPolicy (echo-api)** | Static | HTTPRoute-level rate limit (10 req/12s), overrides Gateway default |
| **TLSPolicy** | Static | Automatic TLS cert via cert-manager |
| **DNSPolicy** | Static | Creates DNS records for Internet exposure |
| **RateLimitPolicy (Gateway)** | Static | Rate limiting at Gateway level (5 req/10s) |
| **HTTPRoute** | Static + Patch | Routes traffic to echo-api service |
| **Deployment** | Static | echo-api application (1 replica) |
| **Service** | Static | ClusterIP service for echo-api |
| **HostedZone** | Dynamic | Route53 zone for globex subdomain |
| **RecordSet** | Dynamic | NS delegation in parent zone |
| **AWS Secret** | Dynamic | Credentials for DNSPolicy (type: kuadrant.io/aws) |

### Pattern: Static YAML + Job Patches

**Problem**: Resources need cluster-specific values (hostnames) that can't be hardcoded.

**Solution**: Store resources as static YAML in Git with placeholders, patch them at runtime.

**Example**:

Static YAML (reviewable in Git):
```yaml
kind: Gateway
spec:
  listeners:
    - hostname: "*.globex.placeholder"
```

Job patches at runtime:
```bash
BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
oc patch gateway prod-web --type=json -p='[
  {"op": "replace", "path": "/spec/listeners/0/hostname",
   "value": "*.globex.'${BASE_DOMAIN}'"}
]'
```

Result:
```yaml
kind: Gateway
spec:
  listeners:
    - hostname: "*.globex.myocp.sandbox4993.opentlc.com"
```

**Benefits**:
- ✅ YAML visible and reviewable in Git
- ✅ Simple Jobs (3-line patches)
- ✅ Works across all clusters
- ✅ No ArgoCD drift (ignoreDifferences configured)

### Pattern: Deny-by-Default Authentication

**Security Model**: The Gateway has a default AuthPolicy that denies all traffic. Individual HTTPRoutes must define their own AuthPolicy to allow access.

**Gateway-level AuthPolicy** (`prod-web-deny-all`):
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
          rego: "allow = false"
```

**Result**: All requests to the Gateway return HTTP 403 Forbidden with a JSON message explaining that access is denied by default.

**To allow access**: Create a specific AuthPolicy targeting the HTTPRoute in the application namespace (e.g., `echo-api`).

**Why this pattern?**
- ✅ Secure by default - no accidental exposure
- ✅ Explicit allow - each route must define its authentication
- ✅ Defense in depth - even if HTTPRoute is created, no access without AuthPolicy
- ✅ Clear error messages - developers know what to do

**Implementation**: The `echo-api` application includes an allow-all AuthPolicy that overrides the Gateway's deny policy, making it accessible for demonstration purposes.

## Configuration

### Dynamic Values (extracted from cluster)

All configuration is cluster-aware:

| Value | Source | Example |
|-------|--------|---------|
| Cluster domain | `dns.config.openshift.io/cluster` | `myocp.sandbox4993.opentlc.com` |
| Parent zone ID | `dns.config.openshift.io/cluster` | `Z044356419CQ6A6BXXDV3` |
| Gateway hostname | Computed | `*.globex.myocp.sandbox4993.opentlc.com` |
| HTTPRoute hostname | Computed | `echo.globex.myocp.sandbox4993.opentlc.com` |

### Hardcoded Values

Only two values are hardcoded:
- `"globex"` - subdomain name
- `"echo.globex"` - HTTPRoute hostname prefix

Everything else adapts to the cluster automatically.

## Repository Structure

```
.
├── argocd/
│   └── application.yaml                        # ArgoCD Application
├── config/
│   └── cluster.yaml.example                    # Cluster configuration template
├── kustomize/
│   ├── base/
│   │   ├── cluster-*                           # Cluster-scoped resources
│   │   ├── echo-api-*                          # echo-api namespace resources
│   │   ├── ingress-gateway-*                   # ingress-gateway namespace
│   │   ├── keycloak-*                          # Keycloak namespace resources
│   │   ├── openshift-gitops-job-*              # Jobs (4)
│   │   └── kustomization.yaml
│   └── overlays/
│       └── default/
│           └── kustomization.yaml
├── scripts/
│   ├── deploy.sh                               # Automated deployment script
│   ├── test-deploy.sh                          # Configuration validation
│   └── README.md                               # Scripts documentation
├── .gitleaks.toml                              # LeakTK allowlist for demo secrets
├── .gitignore                                  # Git ignore rules
├── CLAUDE.md                                   # Developer documentation
├── README.md                                   # This file
└── SECURITY.md                                 # Security policy and secret management
```

**File naming**: `<namespace>-<kind>-<name>.yaml` (or `cluster-<kind>-<name>.yaml` for cluster-scoped)

## Jobs

### Job #1: AWS Credentials Setup (aws-credentials-setup)

**Duration**: ~5 seconds

**Steps**:
1. Extract AWS credentials from `kube-system/aws-creds`
2. Extract AWS region from cluster infrastructure
3. Create Secret `aws-credentials` in `ingress-gateway` namespace with type `kuadrant.io/aws`

**Creates**:
- Secret `aws-credentials` in `ingress-gateway` namespace (required by DNSPolicy)

**Important**: The Secret type MUST be `kuadrant.io/aws` for Kuadrant to detect the AWS Route53 provider.

### Job #2: DNS Setup (globex-ns-delegation)

**Duration**: ~45 seconds

**Steps**:
1. Get cluster domain
2. Create HostedZone for `globex.<cluster-domain>`
3. Wait for HostedZone to be ready (ACK controller provisions in AWS)
4. Extract nameservers from HostedZone status
5. Get parent zone ID from cluster config
6. Create RecordSet for NS delegation

**Creates**:
- HostedZone `globex` in `ack-system` namespace
- RecordSet `globex-ns-delegation` in `ack-system` namespace

### Job #3: Gateway Patch (gateway-prod-web-setup)

**Duration**: ~5 seconds

**Steps**:
1. Get cluster domain
2. Patch Gateway hostname from placeholder to `*.globex.<cluster-domain>`

**Patches**: Gateway `prod-web` in `ingress-gateway` namespace

### Job #4: HTTPRoute Patch (echo-api-httproute-setup)

**Duration**: ~5 seconds

**Steps**:
1. Get cluster domain
2. Patch HTTPRoute hostname from placeholder to `echo.globex.<cluster-domain>`

**Patches**: HTTPRoute `echo-api` in `echo-api` namespace

## Troubleshooting

### Echo API Returns HTTP 403 Forbidden

**Cause**: The echo-api AuthPolicy may not be deployed or is misconfigured.

```bash
# Verify echo-api AuthPolicy exists
oc get authpolicy echo-api -n echo-api

# Check AuthPolicy status
oc describe authpolicy echo-api -n echo-api

# If missing, it should be deployed automatically by ArgoCD
# Check ArgoCD sync status
oc get application usecase-connectivity-link -n openshift-gitops
```

### DNS Not Resolving

```bash
# Check HostedZone status
oc get hostedzone globex -n ack-system -o yaml

# Check RecordSet status
oc get recordset globex-ns-delegation -n ack-system -o yaml

# Wait 5-10 minutes for DNS propagation
# Test with authoritative nameserver
dig @$(dig NS globex.myocp.sandbox4993.opentlc.com +short | head -1) \
  globex.myocp.sandbox4993.opentlc.com SOA
```

### Gateway Hostname Still Shows Placeholder

```bash
# Check if Job completed
oc get job gateway-prod-web-setup -n openshift-gitops

# View Job logs
oc logs -n openshift-gitops job/gateway-prod-web-setup

# Manually re-trigger Job
oc delete job gateway-prod-web-setup -n openshift-gitops
# ArgoCD will recreate it automatically
```

### TLS Certificate Not Created

```bash
# Check TLSPolicy status
oc get tlspolicy prod-web -n ingress-gateway -o yaml

# Check Certificate
oc get certificate -n ingress-gateway

# Check cert-manager logs
oc logs -n cert-manager deployment/cert-manager

# Verify ClusterIssuer exists
oc get clusterissuer cluster
```

### DNSPolicy Not Creating DNS Records

```bash
# Check DNSPolicy status
oc get dnspolicy prod-web -n ingress-gateway -o yaml

# Check AWS credentials Secret type (MUST be kuadrant.io/aws)
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.type}'

# Check DNS operator logs
oc logs -n openshift-operators deployment/dns-operator-controller-manager --tail=50

# Verify AWS credentials are valid
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.data.AWS_REGION}' | base64 -d

# Force DNSPolicy recreation
oc delete dnspolicy prod-web -n ingress-gateway
# ArgoCD will recreate it
```

### Echo API Not Responding from Internet

```bash
# Check echo-api works internally
oc run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://echo-api.echo-api.svc.cluster.local:8080

# Check DNS resolution
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME

# Check Gateway Load Balancer address
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.status.addresses}'

# Check DNSPolicy is enforced
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'

# Test HTTPS (check TLS cert and HTTP response)
curl -v https://$HOSTNAME
```

### Force Resync

```bash
# Delete Jobs to force re-run
oc delete job globex-ns-delegation gateway-prod-web-setup echo-api-httproute-setup \
  -n openshift-gitops

# Trigger ArgoCD sync
oc annotate application usecase-connectivity-link -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Advanced

### ArgoCD ignoreDifferences

The Application configures ArgoCD to ignore hostname fields that are managed by Jobs:

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

This prevents ArgoCD from detecting hostname changes as drift.

### RBAC for Jobs

Jobs run with ServiceAccount `openshift-gitops-argocd-application-controller` which has:
- Cluster-admin permissions (from ArgoCD installation)
- Additional Gateway API permissions via ClusterRole `gateway-manager`

### RecordSet Naming

RecordSet uses **relative domain format** to avoid duplication:
- ❌ FQDN: `globex.myocp.sandbox4993.opentlc.com` → AWS creates `globex.myocp.sandbox4993.opentlc.com.sandbox4993.opentlc.com`
- ✅ Relative: `globex.myocp` → AWS creates `globex.myocp.sandbox4993.opentlc.com`

## Related Projects

- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Pattern inspiration
- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible approach
- [cl-install-helm](https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm) - Helm chart for echo-api

## Contributing

See [CLAUDE.md](CLAUDE.md) for developer documentation and architecture details.
