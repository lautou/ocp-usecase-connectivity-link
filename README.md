# OpenShift Use Case - Red Hat Connectivity Link

GitOps repository for automating Red Hat Connectivity Link infrastructure on OpenShift using AWS Route53, ACK, Istio Gateway API, and Kuadrant.

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
6. **Echo API Application** - Demo service accessible from Internet at `https://echo.globex.<cluster-domain>`

## Prerequisites

### Required Operators
- **OpenShift GitOps** (ArgoCD)
- **ACK Route53 controller** (in `ack-system` namespace)
- **OpenShift Service Mesh** (Istio with Gateway API support)
- **cert-manager**
- **Kuadrant Operator**

### Required Configuration
- OpenShift cluster running on AWS
- AWS credentials in `kube-system/aws-creds`
- cert-manager ClusterIssuer named `cluster` (configured for Let's Encrypt)
- Parent Route53 zone must exist and be writable

## Quick Start

### Deploy

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

# Check DNSPolicy and Internet exposure
oc get dnspolicy prod-web -n ingress-gateway
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
```

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
| **TLSPolicy** | Static | Automatic TLS cert via cert-manager |
| **DNSPolicy** | Static | Creates DNS records for Internet exposure |
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
├── kustomize/
│   ├── base/
│   │   ├── cluster-*                           # Cluster-scoped resources
│   │   ├── echo-api-*                          # echo-api namespace resources
│   │   ├── ingress-gateway-*                   # ingress-gateway namespace
│   │   ├── openshift-gitops-job-*              # Jobs (3)
│   │   └── kustomization.yaml
│   └── overlays/
│       └── default/
│           └── kustomization.yaml
├── CLAUDE.md                                    # Developer documentation
└── README.md                                    # This file
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
