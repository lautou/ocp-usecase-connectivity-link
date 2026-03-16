# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains GitOps manifests for deploying Red Hat Connectivity Link DNS infrastructure on OpenShift using AWS Route53 and ACK (AWS Controllers for Kubernetes).

**Purpose**: Automate the creation of DNS infrastructure (Route53 hosted zone with delegation) and Istio Gateway for the Connectivity Link use case on OpenShift clusters running on AWS.

## Architecture

### Components

1. **GatewayClass** (`kustomize/base/cluster-gatewayclass-istio.yaml`)
   - Cluster-scoped resource defining Istio as the Gateway controller
   - Controller: `openshift.io/gateway-controller/v1`

2. **Namespace** (`kustomize/base/cluster-ns-ingress-gateway.yaml`)
   - Dedicated namespace for Gateway resources

3. **TLSPolicy** (`kustomize/base/ingress-gateway-tlspolicy-prod-web-tls-policy.yaml`)
   - Kuadrant TLSPolicy for automatic certificate management
   - References `ClusterIssuer` named `cluster` (cert-manager)
   - Targets the Gateway `prod-web`

4. **DNS Setup Job** (`kustomize/base/openshift-gitops-job-globex-ns-delegation.yaml`)
   - **Dynamically creates** HostedZone CR for `globex.<cluster-domain>`
   - Waits for ACK Route53 controller to provision zone in AWS
   - Extracts nameservers from HostedZone status
   - Gets parent zone ID from cluster DNS configuration
   - Creates RecordSet CR for NS delegation in parent zone
   - 6-step process, ~45 seconds execution

5. **Gateway Setup Job** (`kustomize/base/openshift-gitops-job-gateway-prod-web.yaml`)
   - **Dynamically creates** Gateway CR with hostname `*.globex.<cluster-domain>`
   - Configures Istio Gateway with HTTPS listener on port 443
   - References TLS certificate Secret `api-tls` (managed by TLSPolicy)
   - 2-step process, ~5 seconds execution

6. **Kustomize Structure**
   - `kustomize/base/` - Base manifests (static resources + Jobs)
   - `kustomize/overlays/default/` - Default overlay (only one)
   - `argocd/application.yaml` - ArgoCD Application definition

### GitOps Flow

```
ArgoCD Application
    ↓
Kustomize Overlay (default)
    ↓
Kustomize Base
    ├── GatewayClass (istio) - cluster-scoped
    ├── Namespace (ingress-gateway)
    ├── TLSPolicy - manages certificates via cert-manager
    ├── Job #1 (DNS) - creates HostedZone + RecordSet dynamically
    └── Job #2 (Gateway) - creates Gateway dynamically

Jobs create resources:
    Job #1 → HostedZone CR (ack-system)
         └→ RecordSet CR (ack-system)
    Job #2 → Gateway CR (ingress-gateway)
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
  - ClusterIssuer named `cluster` must exist
- **Kuadrant Operator** installed (provides TLSPolicy CRD)
- AWS credentials in `kube-system/aws-creds` (created during cluster installation)
- Parent Route53 zone must exist and be accessible

## Key Design Decisions

### Why Dynamic Resource Creation via Jobs?

**Problem**: HostedZone and Gateway need cluster-specific values (domain names) that can't be hardcoded in static manifests.

**Options Considered**:
1. ❌ Hardcode values → Doesn't work across different clusters
2. ❌ Kustomize patches per cluster → Requires cluster-specific overlays (maintenance burden)
3. ❌ External controller → Adds complexity, new component to maintain
4. ✅ **Dynamic Jobs (chosen)** → Simple, GitOps-native, works everywhere

**Why Two Separate Jobs?**:
- **Job #1 (DNS)**: Creates HostedZone, waits for AWS provisioning, creates RecordSet
  - Long-running (~45s) due to AWS API delays
  - Dependent on ACK controller and AWS Route53
- **Job #2 (Gateway)**: Creates Gateway with dynamic hostname
  - Fast (~5s), no external dependencies
  - Independent of DNS setup (can run in parallel)

**Implementation Pattern** (inspired by `ocp-open-env-install-tool`):
- Use Kubernetes Job with standard `ose-cli` image
- Run with ArgoCD application controller ServiceAccount (has cluster-admin permissions)
- Extract cluster domain from `dns.config.openshift.io/cluster`
- Create resources with `oc apply -f -` (idempotent)
- Comprehensive logging and error handling

**Simplicity over Complexity**:
- ✅ Single hardcoded value: `"globex"` subdomain name
- ✅ No tool installation (uses standard ose-cli image)
- ✅ No AWS API calls for zone discovery
- ✅ No external dependencies beyond cluster APIs
- ✅ Fast execution: DNS job ~45s, Gateway job ~5s

### ArgoCD Job Management

Both Jobs use minimal ArgoCD configuration:
```yaml
annotations:
  argocd.argoproj.io/sync-options: Force=true
```

- `Force=true` - Allows Job recreation if deleted
- No hooks - Jobs are regular managed resources
- Completed Jobs are preserved for audit (no TTL cleanup)
- Jobs can run in parallel (no interdependencies)

### Why SkipDryRunOnMissingResource?

```yaml
annotations:
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

ACK CRDs (HostedZone, RecordSet) are installed by an operator and may not exist when ArgoCD first tries to sync. This annotation prevents ArgoCD from failing the sync on CRD discovery.

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

# Check HostedZone
oc get hostedzone globex -n ack-system

# Check Gateway
oc get gateway prod-web -n ingress-gateway

# Check RecordSet (NS delegation)
oc get recordset globex-ns-delegation -n ack-system

# Check TLSPolicy
oc get tlspolicy prod-web-tls-policy -n ingress-gateway

# Check Job logs
oc logs -n openshift-gitops job/globex-ns-delegation
oc logs -n openshift-gitops job/gateway-prod-web-setup
```

### Verification

After deployment, verify DNS delegation:

```bash
# Get the created subdomain
DOMAIN=$(oc get hostedzone globex -n ack-system -o jsonpath='{.spec.name}')

# Check NS records (should show AWS nameservers)
dig NS $DOMAIN +short

# Verify DNS resolution works
dig $DOMAIN SOA +short
```

## Repository Structure

```
.
├── kustomize/
│   ├── base/
│   │   ├── cluster-gatewayclass-istio.yaml                      # GatewayClass (cluster-scoped)
│   │   ├── cluster-ns-ingress-gateway.yaml                      # Namespace for Gateway
│   │   ├── ingress-gateway-tlspolicy-prod-web-tls-policy.yaml   # TLSPolicy for cert-manager
│   │   ├── openshift-gitops-job-globex-ns-delegation.yaml       # Job: DNS setup (HostedZone + RecordSet)
│   │   ├── openshift-gitops-job-gateway-prod-web.yaml           # Job: Gateway setup
│   │   └── kustomization.yaml                                   # Base Kustomize config
│   └── overlays/
│       └── default/
│           └── kustomization.yaml  # Default overlay
├── argocd/
│   └── application.yaml            # ArgoCD Application
├── .gitignore                      # Excludes .claude/
├── CLAUDE.md                       # This file
└── README.md                       # User-facing documentation
```

**File Naming Convention**: `<namespace>-<kind>-<name>.yaml`
- `cluster-*` for cluster-scoped resources (no namespace)
- `<namespace>-*` for namespaced resources
- Examples:
  - `cluster-gatewayclass-istio.yaml` (GatewayClass, cluster-scoped)
  - `cluster-ns-ingress-gateway.yaml` (Namespace, cluster-scoped)
  - `ingress-gateway-gateway-prod-web.yaml` (Gateway in ingress-gateway namespace)
  - `openshift-gitops-job-globex-ns-delegation.yaml` (Job in openshift-gitops namespace)

## Configuration

All configuration is **cluster-aware** and extracted from cluster resources:

- **Cluster Base Domain**: From `dns.config.openshift.io/cluster` spec.baseDomain (e.g., myocp.sandbox4993.opentlc.com)
- **Parent Zone ID**: From `dns.config.openshift.io/cluster` spec.publicZone.id (e.g., Z044356419CQ6A6BXXDV3)
- **Root Domain**: Calculated by removing cluster name from baseDomain (e.g., sandbox4993.opentlc.com)
- **Nameservers**: Extracted from HostedZone status.delegationSet.nameServers after creation
- **Gateway Hostname**: Computed as `*.globex.<cluster-domain>` (e.g., *.globex.myocp.sandbox4993.opentlc.com)

**Only hardcoded value**: `"globex"` (subdomain name)
Everything else is 100% dynamic → Works across different clusters/environments

**Important**: The `spec.publicZone.id` MUST point to the **root public zone** (e.g., sandbox4993.opentlc.com), NOT the cluster's private zone. This follows the same pattern as connectivity-link-ansible.

**Resources Created Dynamically** (by Jobs, not static files):
- HostedZone CR (`globex` in `ack-system` namespace)
- RecordSet CR (`globex-ns-delegation` in `ack-system` namespace)
- Gateway CR (`prod-web` in `ingress-gateway` namespace)

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

### Gateway Not Created

**Cause**: Gateway setup Job failed

**Fix**:
```bash
# Check Job status
oc get job gateway-prod-web-setup -n openshift-gitops

# Check Job logs
oc logs -n openshift-gitops job/gateway-prod-web-setup

# Verify GatewayClass exists
oc get gatewayclass istio
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
oc describe tlspolicy prod-web-tls-policy -n ingress-gateway
```

### ArgoCD Sync Stuck

**Cause**: Jobs running or failed

**Fix**:
```bash
# Delete stuck Jobs
oc delete job globex-ns-delegation gateway-prod-web-setup -n openshift-gitops

# Force ArgoCD resync
argocd app sync usecase-connectivity-link --force
```

## Important Notes

- **Completed Jobs are preserved**: No TTL cleanup - Jobs remain for audit/debugging
- **Job recreates on deletion**: With `Force=true`, deleting the Jobs triggers recreation on next sync
- **Idempotent operations**: `oc apply` makes all resource creation safe to re-run
- **Parent zone must be writable**: ACK needs permission to modify the public zone
- **ServiceAccount**: Both Jobs use `openshift-gitops-argocd-application-controller` (has cluster-admin)
- **Fast execution**: DNS job ~45s, Gateway job ~5s (no tool installation overhead)
- **Parallel execution**: Both Jobs can run simultaneously (no interdependencies)
- **Dynamic resources**: HostedZone, RecordSet, and Gateway are created by Jobs, not static files
- **File naming**: Follows convention `<namespace>-<kind>-<name>.yaml` (use `cluster-` prefix for cluster-scoped resources)

## Related Projects

This project is inspired by:
- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Dynamic configuration injection pattern
- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible-based approach

## Future Enhancements

Potential improvements:
- [ ] Add health checks for DNS propagation validation
- [ ] Add health checks for Gateway readiness and TLS certificate validation
- [ ] Create a cleanup Job for decommissioning (delete RecordSet, Gateway, then HostedZone)
- [ ] Add Prometheus metrics for DNS delegation and Gateway status
- [ ] Support multiple subdomains/Gateways with templating
- [ ] Add HTTPRoute examples for application routing
- [ ] Add tests with pre-commit hooks

## Additional Resources Created

Beyond the static manifests, the Jobs create these resources dynamically:

**In `ack-system` namespace**:
- HostedZone `globex` - Route53 zone for globex.<cluster-domain>
- RecordSet `globex-ns-delegation` - NS delegation records in parent zone

**In `ingress-gateway` namespace**:
- Gateway `prod-web` - Istio Gateway with HTTPS listener on port 443
  - Hostname: `*.globex.<cluster-domain>`
  - TLS certificate reference: `api-tls` (managed by TLSPolicy/cert-manager)
