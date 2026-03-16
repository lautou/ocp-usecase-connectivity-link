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
2. **Creates an Istio Gateway** for `*.globex.<your-cluster-domain>` with TLS
3. **Automatically extracts** nameservers from the created zone
4. **Dynamically fetches** parent zone information from cluster configuration
5. **Creates NS delegation records** in the parent zone automatically
6. **Manages everything via GitOps** - changes in Git trigger updates

## Prerequisites

- OpenShift cluster running on AWS
- **OpenShift GitOps** (ArgoCD) installed
- **ACK Route53 controller** installed and configured in `ack-system` namespace
- **OpenShift Service Mesh** (Istio) installed with Gateway API support
- **cert-manager** installed (for TLS certificate management)
- **Kuadrant Operator** installed (for TLSPolicy)
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

# Check Gateway
oc get gateway prod-web -n ingress-gateway

# Check NS delegation RecordSet
oc get recordset globex-ns-delegation -n ack-system

# Check TLSPolicy
oc get tlspolicy prod-web-tls-policy -n ingress-gateway

# Test DNS resolution (may take 5-10 minutes for propagation)
dig NS globex.myocp.sandbox4993.opentlc.com +short
```

### Check Job Logs

```bash
# DNS Job logs
oc logs -n openshift-gitops -l job-name=globex-ns-delegation

# Gateway Job logs
oc logs -n openshift-gitops -l job-name=gateway-prod-web-setup
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
│  ├─ GatewayClass (istio)                                    │
│  ├─ Namespace (ingress-gateway)                             │
│  ├─ TLSPolicy → Manages TLS certs via cert-manager         │
│  ├─ Job #1 → Dynamic DNS setup (HostedZone + RecordSet)    │
│  └─ Job #2 → Dynamic Gateway setup                          │
└───────┬───────────────────────────┬─────────────────────────┘
        │                           │
        ▼                           ▼
┌───────────────────┐   ┌───────────────────────────────────┐
│ Job #1: DNS       │   │ Job #2: Gateway                   │
│ (openshift-gitops)│   │ (openshift-gitops namespace)      │
│                   │   │                                   │
│ 1. Get domain     │   │ 1. Get cluster domain            │
│ 2. Create         │   │ 2. Create Gateway CR             │
│    HostedZone     │   │    (*.globex.<domain>)           │
│ 3. Wait ready     │   │                                   │
│ 4. Extract NS     │   │ Creates:                         │
│ 5. Get parent zone│   │ - Gateway in ingress-gateway     │
│ 6. Create         │   │                                   │
│    RecordSet      │   │                                   │
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

### 1. Dynamic DNS Infrastructure (Job #1)

A Kubernetes Job creates the entire DNS infrastructure dynamically:

1. Gets cluster base domain from `dns.config.openshift.io/cluster`
2. Creates HostedZone CR for `globex.<cluster-domain>`
3. Waits for ACK Route53 controller to provision the zone in AWS
4. Extracts nameservers from HostedZone status
5. Gets parent zone ID from cluster DNS configuration
6. Creates RecordSet CR for NS delegation in parent zone

### 2. Dynamic Gateway Setup (Job #2)

A second Job creates the Istio Gateway:

1. Gets cluster base domain
2. Creates Gateway CR with hostname `*.globex.<cluster-domain>`
3. Configures TLS with certificate reference

The TLSPolicy automatically provisions certificates via cert-manager.

### 3. GitOps Management

All resources are managed via Git:
- Modify manifests in this repository
- ArgoCD automatically syncs changes to the cluster
- Jobs re-run to update configuration if needed

## Configuration

The system is **fully dynamic** and extracts all necessary information from the cluster:

| Value | Source | Example |
|-------|--------|---------|
| Cluster base domain | `dns.config.openshift.io/cluster` | myocp.sandbox4993.opentlc.com |
| Parent zone ID | `dns.config.openshift.io/cluster` | Z044356419CQ6A6BXXDV3 |
| Nameservers | HostedZone status (after creation) | ns-451.awsdns-56.com, ... |
| Gateway hostname | Computed from cluster domain | *.globex.myocp.sandbox4993.opentlc.com |

**Only hardcoded value**: `"globex"` (subdomain name)
Everything else is 100% dynamic → Works on any OpenShift cluster on AWS!

**Note**: The parent zone ID must point to the root public zone (e.g., sandbox4993.opentlc.com), following the same pattern as connectivity-link-ansible.

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

### Gateway Not Created

Check the Gateway setup Job logs:

```bash
oc logs -n openshift-gitops -l job-name=gateway-prod-web-setup
```

### TLS Certificate Issues

Check cert-manager and TLSPolicy:

```bash
# Check ClusterIssuer
oc get clusterissuer cluster

# Check Certificate status
oc get certificate -n ingress-gateway

# Check TLSPolicy status
oc get tlspolicy prod-web-tls-policy -n ingress-gateway -o yaml
```

### Force Resync

```bash
# Delete Jobs to force re-run
oc delete job globex-ns-delegation gateway-prod-web-setup -n openshift-gitops

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
