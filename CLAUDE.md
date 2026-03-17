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

5. **TLSPolicy** (`ingress-gateway-tlspolicy-prod-web-tls-policy.yaml`)
   - Kuadrant TLSPolicy for automatic certificate management
   - References ClusterIssuer named `cluster` (cert-manager)
   - Targets the Gateway `prod-web`
   - Automatically creates Let's Encrypt certificate in Secret `api-tls`

6. **DNSPolicy** (`ingress-gateway-dnspolicy-prod-web-dnspolicy.yaml`)
   - Kuadrant DNSPolicy for automatic DNS record management in Route53
   - References Secret `aws-credentials` (type: `kuadrant.io/aws`)
   - Targets the Gateway `prod-web`
   - Automatically creates CNAME records pointing Gateway hostnames to Load Balancer

7. **Echo API Application** (echo-api namespace)
   - **Deployment** (`echo-api-deployment-echo-api.yaml`) - 1 replica, image: `quay.io/3scale/authorino:echo-api`
   - **Service** (`echo-api-service-echo-api.yaml`) - ClusterIP exposing port 8080
   - **HTTPRoute** (`echo-api-httproute-echo-api.yaml`) - Static YAML with placeholder hostname: `echo.globex.placeholder`
   - **Patched by Job** to use actual cluster domain

8. **Jobs** (openshift-gitops namespace)
   - **Job #1: AWS Credentials Setup** (`openshift-gitops-job-aws-credentials.yaml`)
     - Extracts AWS credentials from `kube-system/aws-creds`
     - Extracts AWS region from cluster infrastructure
     - Creates Secret `aws-credentials` with type `kuadrant.io/aws`
     - Required for DNSPolicy to manage Route53 records
     - 3 steps, ~5 seconds execution

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
    ├── TLSPolicy (cert-manager integration)
    ├── DNSPolicy (Kuadrant DNS for Internet exposure)
    ├── HTTPRoute (static YAML with placeholder)
    ├── Deployment + Service (echo-api)
    └── Jobs (create AWS credentials, patch hostnames, create DNS resources)

Jobs execute:
    Job #1 (AWS) → Creates aws-credentials Secret (type: kuadrant.io/aws)
    Job #2 (DNS) → Creates HostedZone + RecordSet in ack-system
    Job #3 (Gateway) → Patches Gateway hostname
    Job #4 (HTTPRoute) → Patches HTTPRoute hostname

DNSPolicy creates DNS records in Route53 pointing to Gateway Load Balancer
ArgoCD ignores hostname drifts (ignoreDifferences)
```

## Prerequisites

- OpenShift cluster running on AWS
- **OpenShift GitOps** (ArgoCD) installed in `openshift-gitops` namespace
- **ACK Route53 controller** installed and configured in `ack-system` namespace
  - Requires `ack-route53-user-secrets` Secret (AWS credentials)
  - Requires `ack-route53-user-config` ConfigMap (AWS region, etc.)
- **OpenShift Service Mesh** (Istio) installed with Gateway API support
  - GatewayClass `istio` must be available
- **cert-manager** installed cluster-wide
  - ClusterIssuer named `cluster` must exist (configured for Let's Encrypt)
- **Kuadrant Operator** installed (provides TLSPolicy and DNSPolicy CRDs)
  - DNS Operator component must be running (manages DNS records in Route53)
- AWS credentials in `kube-system/aws-creds` (for DNSPolicy provider)
- Parent Route53 zone must exist and be accessible

## Key Design Decisions

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

### Initial Setup

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
oc get dnspolicy prod-web-dnspolicy -n ingress-gateway
oc get secret aws-credentials -n ingress-gateway
oc get gateway prod-web -n ingress-gateway
oc get httproute echo-api -n echo-api
oc get tlspolicy prod-web-tls-policy -n ingress-gateway
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
oc get dnspolicy prod-web-dnspolicy -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'

# Check DNS resolution from Internet
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME

# Test echo-api application from Internet
curl https://$HOSTNAME
```

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
│   │   ├── echo-api-deployment-echo-api.yaml
│   │   ├── echo-api-httproute-echo-api.yaml
│   │   ├── echo-api-service-echo-api.yaml
│   │   ├── ingress-gateway-dnspolicy-prod-web-dnspolicy.yaml
│   │   ├── ingress-gateway-gateway-prod-web.yaml
│   │   ├── ingress-gateway-tlspolicy-prod-web-tls-policy.yaml
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
├── .gitignore
├── CLAUDE.md           # This file
└── README.md           # User-facing documentation
```

**File Naming Convention**: `<namespace>-<kind>-<name>.yaml`
- `cluster-*` for cluster-scoped resources (no namespace)
- `<namespace>-*` for namespaced resources
- Examples:
  - `cluster-gatewayclass-istio.yaml` (GatewayClass, cluster-scoped)
  - `cluster-ns-echo-api.yaml` (Namespace, cluster-scoped)
  - `ingress-gateway-gateway-prod-web.yaml` (Gateway in ingress-gateway namespace)
  - `echo-api-httproute-echo-api.yaml` (HTTPRoute in echo-api namespace)
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
- HTTPRoute `echo-api` (with placeholder hostname)
- TLSPolicy `prod-web-tls-policy`
- DNSPolicy `prod-web-dnspolicy`
- Deployment `echo-api`
- Service `echo-api`
- Jobs (4): AWS credentials, DNS setup, Gateway patch, HTTPRoute patch

### Dynamic Resources (created by Jobs/Controllers)

**In `ingress-gateway` namespace** (created by Job #1):
- Secret `aws-credentials` - AWS credentials for DNSPolicy (type: `kuadrant.io/aws`)

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
oc get tlspolicy prod-web-tls-policy -n ingress-gateway -o yaml

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
oc get dnspolicy prod-web-dnspolicy -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.'

# Check DNS Operator logs for provider errors
oc logs -n openshift-operators deployment/dns-operator-controller-manager --tail=50 | grep -i "prod-web\|provider\|error"

# Verify AWS region is set
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.data.AWS_REGION}' | base64 -d
```

### Echo API Not Accessible from Internet

**Cause**: DNS records not created or DNS propagation delay

**Fix**:
```bash
# Check DNSPolicy is enforced
oc get dnspolicy prod-web-dnspolicy -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'
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

## Important Notes

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
- **DNSPolicy automation**: Automatically creates/updates DNS records in Route53 when Gateway Load Balancer changes
- **Internet exposure**: DNSPolicy is what makes echo-api accessible from Internet (creates CNAME → Load Balancer)

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
- [ ] Add more demo applications with different HTTPRoutes
- [ ] Add AuthPolicy for authentication/authorization
- [ ] Add RateLimitPolicy for API rate limiting
- [ ] Add tests with pre-commit hooks
