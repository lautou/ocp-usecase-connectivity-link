# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains GitOps manifests for deploying Red Hat Connectivity Link DNS infrastructure on OpenShift using AWS Route53 and ACK (AWS Controllers for Kubernetes).

**Purpose**: Automate the creation and delegation of a Route53 hosted zone for the Connectivity Link use case on OpenShift clusters running on AWS.

## Architecture

### Components

1. **HostedZone CR** (`kustomize/base/hostedzone.yaml`)
   - Creates a Route53 hosted zone for `globex.<cluster-domain>`
   - Managed by ACK Route53 controller
   - Zone is public (not private)
   - Tagged for tracking and cost allocation

2. **NS Delegation Job** (`kustomize/base/ns-delegation-job.yaml`)
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

**Implementation Pattern** (from `ocp-open-env-install-tool`):
- Use Kubernetes Job with `ose-cli` image
- Run with ArgoCD application controller ServiceAccount (has cluster-admin permissions)
- Wait for resources to be ready before proceeding
- Extract dynamic values from cluster state
- Create/update dependent resources

### ArgoCD Sync Hook Strategy

The NS delegation Job uses ArgoCD hooks:
```yaml
annotations:
  argocd.argoproj.io/hook: Sync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
  argocd.argoproj.io/sync-options: Force=true
```

- `hook: Sync` - Runs during ArgoCD sync phase (after HostedZone is created)
- `hook-delete-policy: BeforeHookCreation` - Cleans up previous Job runs
- `Force=true` - Allows recreation on every sync

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
│   │   ├── hostedzone.yaml         # HostedZone CR for globex subdomain
│   │   ├── ns-delegation-job.yaml  # Dynamic NS delegation Job
│   │   └── kustomization.yaml      # Base Kustomize config
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

All configuration is **cluster-aware** and extracted dynamically:

- **Cluster Domain**: Extracted from `dns.config.openshift.io/cluster`
- **AWS Region**: Extracted from `infrastructure.config.openshift.io/cluster`
- **AWS Credentials**: Derived from `kube-system/aws-creds`
- **Parent Zone ID**: Extracted from `dns.config.openshift.io/cluster`
- **Nameservers**: Extracted from HostedZone status after creation

**No hardcoded values** → Works across different clusters/environments

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

- **Job runs every sync**: The Job recreates RecordSet on every ArgoCD sync (idempotent)
- **Nameservers don't change**: AWS rarely changes zone nameservers, but our dynamic approach handles it
- **Parent zone must be writable**: ACK needs permission to modify parent zone
- **Hook ordering**: Job runs during Sync phase, after HostedZone is applied
- **ServiceAccount**: Job uses `openshift-gitops-argocd-application-controller` (has cluster-admin)

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
