# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains GitOps manifests for deploying Red Hat Connectivity Link DNS infrastructure on OpenShift using AWS Route53 and ACK (AWS Controllers for Kubernetes).

**Purpose**: Automate the creation and delegation of a Route53 hosted zone for the Connectivity Link use case on OpenShift clusters running on AWS.

## Architecture

### Components

1. **HostedZone CR** (`kustomize/base/ack-system-hostedzone-globex.yaml`)
   - Creates a Route53 hosted zone for `globex.<cluster-domain>`
   - Managed by ACK Route53 controller
   - Zone is public (not private)
   - Tagged for tracking and cost allocation

2. **NS Delegation Job** (`kustomize/base/openshift-gitops-job-globex-ns-delegation.yaml`)
   - **100% Dynamic** approach inspired by `ocp-open-env-install-tool`
   - Runs as ArgoCD Sync Hook with the `openshift-gitops-argocd-application-controller` ServiceAccount
   - **Automatically** extracts nameservers from HostedZone status
   - **Automatically** fetches parent zone ID from cluster DNS configuration
   - Creates RecordSet CR for NS delegation in parent zone
   - Implements retry logic and proper error handling

3. **Kustomize Structure**
   - `kustomize/base/` - Base manifests
   - `kustomize/overlays/default/` - Default overlay (only one)
   - `argocd/application.yaml` - ArgoCD Application definition

### GitOps Flow

```
ArgoCD Application
    ↓
Kustomize Overlay (default)
    ↓
Kustomize Base
    ├── HostedZone CR → Creates globex.<domain> zone in Route53
    └── Job → Waits for HostedZone → Extracts NS → Creates RecordSet for delegation
```

## Prerequisites

- OpenShift cluster running on AWS
- **ACK Route53 controller** installed and configured in `ack-system` namespace
  - Requires `ack-route53-user-secrets` Secret (AWS credentials)
  - Requires `ack-route53-user-config` ConfigMap (AWS region, etc.)
- **OpenShift GitOps** (ArgoCD) installed
- AWS credentials in `kube-system/aws-creds` (created during cluster installation)
- Parent Route53 zone must exist and be accessible

## Key Design Decisions

### Why Dynamic NS Delegation?

**Problem**: When ACK creates a HostedZone, AWS assigns random nameservers. We need to create an NS record in the parent zone pointing to these nameservers for proper DNS delegation.

**Options Considered**:
1. ❌ Hardcode nameservers → Breaks if zone is recreated
2. ❌ Manual intervention → Not GitOps-friendly
3. ✅ **Dynamic Job (chosen)** → Fully automated, resilient, GitOps-native

**Implementation Pattern** (inspired by `connectivity-link-ansible`):
- Use Kubernetes Job with standard `ose-cli` image
- Run with ArgoCD application controller ServiceAccount (has cluster-admin permissions)
- Wait for HostedZone to be ready
- Extract nameservers from HostedZone status
- Get parent zone ID from cluster DNS config (`dns.config.openshift.io/cluster`)
- Create RecordSet in parent zone

**Simplicity over Complexity**:
- ✅ Uses cluster DNS config as single source of truth
- ✅ No tool installation (uses standard ose-cli image)
- ✅ No AWS API calls for zone discovery
- ✅ Simple 5-step process (~30 seconds)

### ArgoCD Job Management

The NS delegation Job uses minimal ArgoCD configuration:
```yaml
annotations:
  argocd.argoproj.io/sync-options: Force=true
```

- `Force=true` - Allows Job recreation if deleted
- No hooks - Job is a regular managed resource
- Completed Jobs are preserved for audit (no TTL cleanup)

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

# Check RecordSet (NS delegation)
oc get recordset globex-ns-delegation -n ack-system

# Check Job logs
oc logs -n openshift-gitops job/globex-ns-delegation
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
│   │   ├── ack-system-hostedzone-globex.yaml                # HostedZone CR for globex subdomain
│   │   ├── openshift-gitops-job-globex-ns-delegation.yaml   # Dynamic NS delegation Job
│   │   └── kustomization.yaml                               # Base Kustomize config
│   └── overlays/
│       └── default/
│           └── kustomization.yaml  # Default overlay
├── argocd/
│   └── application.yaml            # ArgoCD Application
├── .gitignore                      # Excludes .claude/
├── CLAUDE.md                       # This file
└── README.md                       # User-facing documentation (to be created)
```

## Configuration

All configuration is **cluster-aware** and extracted from cluster resources:

- **Cluster Base Domain**: From `dns.config.openshift.io/cluster` spec.baseDomain (e.g., myocp.sandbox4993.opentlc.com)
- **Parent Zone ID**: From `dns.config.openshift.io/cluster` spec.publicZone.id (e.g., Z044356419CQ6A6BXXDV3)
- **Root Domain**: Calculated by removing cluster name from baseDomain (e.g., sandbox4993.opentlc.com)
- **Nameservers**: Extracted from HostedZone status.delegationSet.nameServers after creation

**No hardcoded values** → Works across different clusters/environments

**Important**: The `spec.publicZone.id` MUST point to the **root public zone** (e.g., sandbox4993.opentlc.com), NOT the cluster's private zone. This follows the same pattern as connectivity-link-ansible.

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

### ArgoCD Sync Stuck

**Cause**: Job running or failed

**Fix**:
```bash
# Delete stuck Job
oc delete job globex-ns-delegation -n openshift-gitops

# Force ArgoCD resync
argocd app sync usecase-connectivity-link --force
```

## Important Notes

- **Completed Jobs are preserved**: No TTL cleanup - Jobs remain for audit/debugging
- **Job recreates on deletion**: With `Force=true`, deleting the Job triggers recreation on next sync
- **Idempotent operations**: `oc apply` makes RecordSet creation safe to re-run
- **Parent zone must be writable**: ACK needs permission to modify the public zone
- **ServiceAccount**: Job uses `openshift-gitops-argocd-application-controller` (has cluster-admin)
- **Fast execution**: ~30-45 seconds (no tool installation overhead)

## Related Projects

This project is inspired by:
- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Dynamic configuration injection pattern
- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible-based approach

## Future Enhancements

Potential improvements:
- [ ] Add health checks for DNS propagation validation
- [ ] Create a cleanup Job for decommissioning (delete RecordSet, then HostedZone)
- [ ] Add Prometheus metrics for DNS delegation status
- [ ] Support multiple subdomains with templating
- [ ] Add tests with pre-commit hooks
