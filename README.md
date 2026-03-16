# OpenShift Use Case - Red Hat Connectivity Link

GitOps repository for automating Red Hat Connectivity Link DNS infrastructure on OpenShift using AWS Route53 and ACK.

## Overview

This project automates the creation and delegation of a Route53 hosted zone for the Red Hat Connectivity Link use case. It uses:

- **AWS Controllers for Kubernetes (ACK)** for Route53 management
- **Kustomize** for manifest templating
- **ArgoCD** for GitOps deployment
- **100% dynamic configuration** - no hardcoded values

## What It Does

1. **Creates a Route53 HostedZone** for `globex.<your-cluster-domain>` using ACK
2. **Automatically extracts** nameservers from the created zone
3. **Dynamically fetches** parent zone information from cluster configuration
4. **Creates NS delegation records** in the parent zone automatically
5. **Manages everything via GitOps** - changes in Git trigger updates

## Prerequisites

- OpenShift cluster running on AWS
- OpenShift GitOps (ArgoCD) installed
- ACK Route53 controller installed and configured
- AWS credentials available in cluster (`kube-system/aws-creds`)

## Quick Start

### Deploy

```bash
oc apply -f argocd/application.yaml
```

### Verify

```bash
# Check Application status
oc get application usecase-connectivity-link -n openshift-gitops

# Check HostedZone
oc get hostedzone globex -n ack-system

# Check NS delegation RecordSet
oc get recordset globex-ns-delegation -n ack-system

# Test DNS resolution (may take 5-10 minutes for propagation)
dig NS globex.myocp.sandbox4993.opentlc.com +short
```

### Check Job Logs

```bash
# Find the Job pod
oc get pods -n openshift-gitops -l job-name=globex-ns-delegation

# View logs
oc logs -n openshift-gitops <pod-name>
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ ArgoCD Application (openshift-gitops)                       │
│  └─ Syncs from: github.com/lautou/ocp-usecase-connectivity-link │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│ Kustomize (overlays/default)                                │
│  ├─ HostedZone CR → Creates globex.<domain> zone            │
│  └─ Job → Dynamic NS delegation                             │
└───────┬───────────────────────────┬─────────────────────────┘
        │                           │
        ▼                           ▼
┌───────────────────┐   ┌───────────────────────────────────┐
│ ACK Route53       │   │ Kubernetes Job                    │
│ Controller        │   │ (openshift-gitops namespace)      │
│                   │   │                                   │
│ Creates zone in   │   │ 1. Waits for HostedZone ready    │
│ AWS Route53       │   │ 2. Extracts nameservers          │
│                   │   │ 3. Gets parent zone ID           │
│ Returns:          │   │ 4. Creates RecordSet for NS      │
│ - Zone ID         │   │                                   │
│ - Nameservers     │   │ Creates:                         │
│                   │   │ - RecordSet CR in ack-system     │
└───────────────────┘   └───────────────────────────────────┘
        │                           │
        │                           │
        └───────────┬───────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ AWS Route53                                                 │
│                                                             │
│ Parent Zone: myocp.sandbox4993.opentlc.com                 │
│  └─ NS Record: globex.myocp.sandbox4993.opentlc.com       │
│      └─ Points to: ns-451.awsdns-56.com, ...              │
│                                                             │
│ Subdomain Zone: globex.myocp.sandbox4993.opentlc.com      │
│  └─ Managed by ACK                                         │
└─────────────────────────────────────────────────────────────┘
```

## How It Works

### 1. HostedZone Creation

The ACK Route53 controller watches for `HostedZone` custom resources and creates corresponding zones in AWS Route53.

### 2. Dynamic NS Delegation

A Kubernetes Job runs automatically when ArgoCD syncs the application:

- Waits for the HostedZone to be ready
- Extracts nameservers from the HostedZone status
- Fetches the parent zone ID from the cluster DNS configuration
- Creates a `RecordSet` CR for NS delegation in the parent zone

### 3. GitOps Management

All changes are declarative and managed via Git:
- Modify manifests in this repository
- ArgoCD automatically syncs changes to the cluster
- The Job re-runs to update delegation if needed

## Configuration

The system is **fully dynamic** and extracts all necessary information from the cluster:

| Value | Source | Example |
|-------|--------|---------|
| Cluster base domain | `dns.config.openshift.io/cluster` | myocp.sandbox4993.opentlc.com |
| Parent zone ID | `dns.config.openshift.io/cluster` | Z044356419CQ6A6BXXDV3 |
| Nameservers | HostedZone status (after creation) | ns-451.awsdns-56.com, ... |

**No hardcoded values** → Works on any OpenShift cluster on AWS!

**Note**: The parent zone ID must point to the root public zone (e.g., sandbox4993.opentlc.com), following the same pattern as connectivity-link-ansible.

## Repository Structure

```
.
├── kustomize/
│   ├── base/
│   │   ├── hostedzone.yaml          # HostedZone CR
│   │   ├── ns-delegation-job.yaml   # Dynamic NS delegation Job
│   │   └── kustomization.yaml       # Base Kustomize config
│   └── overlays/
│       └── default/
│           └── kustomization.yaml   # Default overlay
├── argocd/
│   └── application.yaml             # ArgoCD Application
├── CLAUDE.md                        # Developer documentation
├── README.md                        # This file
└── .gitignore
```

## Troubleshooting

### Job Fails with "Timeout waiting for HostedZone"

The HostedZone creation may be slow or failed.

```bash
# Check HostedZone status
oc get hostedzone globex -n ack-system -o yaml

# Check ACK controller logs
oc logs -n ack-system deployment/ack-route53-controller
```

### RecordSet Not Created

Check the Job logs for errors:

```bash
oc logs -n openshift-gitops -l job-name=globex-ns-delegation
```

### DNS Not Resolving

DNS propagation can take 5-10 minutes. Test with authoritative nameserver directly:

```bash
# Get nameservers
NAMESERVERS=$(oc get hostedzone globex -n ack-system -o jsonpath='{.status.delegationSet.nameServers[*]}')

# Test directly
dig @<nameserver> globex.myocp.sandbox4993.opentlc.com SOA
```

### Force Resync

```bash
# Delete and recreate the Job to force re-run
oc delete job globex-ns-delegation -n openshift-gitops

# Trigger ArgoCD sync
oc annotate application usecase-connectivity-link -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Development

For detailed developer documentation, see [CLAUDE.md](./CLAUDE.md).

## Related Projects

- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible-based approach
- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Pattern inspiration for dynamic configuration

## License

This project is part of the Red Hat Connectivity Link solution pattern.
