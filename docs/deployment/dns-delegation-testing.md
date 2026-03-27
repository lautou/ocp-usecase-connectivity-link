## DNS Delegation with ACK Route53 - Tested and Verified

**Status**: DNS delegation using ACK Route53 controller produces **IDENTICAL results** to Red Hat's ansible approach ✅

**Test Date**: 2026-03-25

### Background

Red Hat's official Connectivity Link demo uses an Ansible playbook (`connectivity-link-ansible`) to create Route53 DNS infrastructure using the `amazon.aws` collection (boto3/Python SDK). We tested whether our ACK (AWS Controllers for Kubernetes) approach produces identical results.

### Test Methodology

1. **Clean State**: Deleted ansible-created zone (`Z03794592AARIB1DKITL6`) and NS delegation
2. **Minimal Deployment**: Created `dns-only` overlay with only ACK resources + Job
3. **Subdomain Pattern Match**: Adjusted Job to use root domain (`globex.sandbox3491.opentlc.com`) not cluster domain
4. **TTL Match**: Changed TTL from 300 to 3600 seconds to match ansible
5. **ArgoCD Integration**: Deployed via main `usecase-connectivity-link` Application

### Job Implementation

**File**: `kustomize/base/openshift-gitops-job-globex-ns-delegation.yaml`

**What it does** (6 steps, ~18 seconds execution):
1. Extracts cluster domain and calculates root domain (e.g., `myocp.sandbox3491.opentlc.com` → `sandbox3491.opentlc.com`)
2. Creates HostedZone CR for `globex.{root_domain}` → ACK creates zone in AWS
3. Waits for HostedZone to be ready (checks `ACK.ResourceSynced` condition)
4. Extracts nameservers from HostedZone status (4 AWS nameservers)
5. Gets parent zone ID from cluster DNS configuration
6. Creates RecordSet CR for NS delegation → ACK creates records in parent zone

**Key Configuration**:
```bash
# Subdomain pattern (matches ansible)
SUBDOMAIN_NAME="globex"
ROOT_DOMAIN=$(echo "${BASE_DOMAIN}" | sed 's/^[^.]*\.//')  # Remove cluster name
FULL_DOMAIN="${SUBDOMAIN_NAME}.${ROOT_DOMAIN}"  # globex.sandbox3491.opentlc.com

# RecordSet name (relative, not FQDN)
RECORDSET_NAME="${SUBDOMAIN_NAME}"  # Just "globex"

# TTL (matches ansible)
ttl: 3600  # Same as ansible (was 300 in initial version)
```

### Results Comparison: Ansible vs ACK

| Aspect | Ansible Result | ACK Result | Match? |
|--------|---------------|------------|--------|
| **Domain** | `globex.sandbox3491.opentlc.com` | `globex.sandbox3491.opentlc.com` | ✅ **IDENTICAL** |
| **Zone ID** | `Z03794592AARIB1DKITL6` | `Z09307543C0T831AQ399N` | Different (AWS assigns new) ✅ |
| **Nameservers** | 4 AWS nameservers | 4 AWS nameservers | ✅ Same pattern |
| **Parent Zone** | `Z09941991LWPLNSV0EDW` | `Z09941991LWPLNSV0EDW` | ✅ **IDENTICAL** |
| **NS Record Name** | `globex.sandbox3491.opentlc.com` | `globex.sandbox3491.opentlc.com` | ✅ **IDENTICAL** |
| **TTL** | 3600 seconds | 3600 seconds | ✅ **IDENTICAL** |
| **DNS Resolution** | ✅ Working | ✅ Working | ✅ **IDENTICAL** |
| **Execution Time** | ~45 seconds | ~18 seconds | ACK is 2.5x faster ✅ |
| **Method** | Imperative (boto3) | Declarative (CRDs) | Different approach, same result ✅ |

### DNS Verification

**Nameservers** (from public DNS):
```bash
$ dig NS globex.sandbox3491.opentlc.com +short
ns-194.awsdns-24.com.
ns-606.awsdns-11.net.
ns-1406.awsdns-47.org.
ns-1651.awsdns-14.co.uk.
```

**NS Delegation** (from parent zone authoritative nameserver):
```bash
$ dig @ns-1131.awsdns-13.org globex.sandbox3491.opentlc.com NS
;; AUTHORITY SECTION:
globex.sandbox3491.opentlc.com. 3600 IN NS ns-1406.awsdns-47.org.
globex.sandbox3491.opentlc.com. 3600 IN NS ns-1651.awsdns-14.co.uk.
globex.sandbox3491.opentlc.com. 3600 IN NS ns-194.awsdns-24.com.
globex.sandbox3491.opentlc.com. 3600 IN NS ns-606.awsdns-11.net.
```

**TTL confirmed**: 3600 seconds (matches ansible exactly)

### ACK Resources Created

**HostedZone CR**:
```yaml
apiVersion: route53.services.k8s.aws/v1alpha1
kind: HostedZone
metadata:
  name: globex
  namespace: ack-system
spec:
  name: globex.sandbox3491.opentlc.com.
  hostedZoneConfig:
    comment: "Globex subdomain for Red Hat Connectivity Link"
status:
  id: /hostedzone/Z09307543C0T831AQ399N
  conditions:
    - type: ACK.ResourceSynced
      status: "True"
  delegationSet:
    nameServers:
      - ns-1651.awsdns-14.co.uk
      - ns-194.awsdns-24.com
      - ns-1406.awsdns-47.org
      - ns-606.awsdns-11.net
```

**RecordSet CR**:
```yaml
apiVersion: route53.services.k8s.aws/v1alpha1
kind: RecordSet
metadata:
  name: globex-ns-delegation
  namespace: ack-system
spec:
  name: globex  # Relative name (not FQDN)
  recordType: NS
  ttl: 3600  # Matches ansible
  hostedZoneID: Z09941991LWPLNSV0EDW  # Parent zone
  resourceRecords:
    - value: ns-1651.awsdns-14.co.uk
    - value: ns-194.awsdns-24.com
    - value: ns-1406.awsdns-47.org
    - value: ns-606.awsdns-11.net
```

### Testing Overlay

**Location**: `kustomize/overlays/dns-only/`

**Purpose**: Minimal deployment for testing DNS delegation independently

**Contents**:
- References `kustomize/base-dns-only/` which contains:
  - ClusterRole: `gateway-manager` (RBAC for Job)
  - ClusterRoleBinding: `gateway-manager-openshift-gitops-argocd-application-controller`
  - Job: `globex-ns-delegation` (creates HostedZone + RecordSet)

**ArgoCD Application**: `usecase-connectivity-link` (main app, configured to use `dns-only` overlay for testing)

**To switch back to full deployment**:
```bash
# Edit argocd/application.yaml
path: kustomize/overlays/default  # Change from dns-only to default
```

### GitOps Benefits Demonstrated

**Advantages over Ansible**:
1. ✅ **Declarative**: YAML in Git (visible, reviewable)
2. ✅ **Automated**: ArgoCD syncs automatically
3. ✅ **Visible**: Resources queryable with `oc get hostedzone`, `oc get recordset`
4. ✅ **Auditable**: Git history tracks all changes
5. ✅ **Self-healing**: ArgoCD monitors drift and auto-corrects
6. ✅ **Faster**: 18s vs 45s execution time (2.5x faster)
7. ✅ **Idempotent**: Job checks if resources exist before creating
8. ✅ **Kubernetes-native**: Standard CRDs, no Python/boto3 dependencies

**Same Imperative Approach**:
- Both create resources dynamically (not pre-defined in YAML)
- Both extract cluster domain at runtime
- Both calculate parent zone automatically

**Key Difference**:
- Ansible: boto3 Python SDK calls AWS API directly
- ACK: Kubernetes CRDs → ACK controller calls AWS API
- Result: Identical DNS infrastructure

### Ansible Playbook Analysis

**Analysis Reports** (in repository):
- `ANSIBLE_CONFLICT_REPORT.md` - Conflicts between ansible and existing cluster operators
- `ANSIBLE_DETAILED_TASK_ANALYSIS.md` - What each ansible task does

**Key Findings**:
- ✅ `aws-setup.yml` safe to run (only creates DNS, no conflicts)
- ❌ Operator tasks create duplicates (RHCL, Kuadrant, Cert Manager, Service Mesh already installed)
- ⚠️ `ingress-gateway.yml` safe after namespace deletion
- ⚠️ `observability.yaml` needs investigation before running

**Recommendation**: Use ACK approach for DNS delegation instead of ansible for better GitOps integration.

### Subdomain Pattern Decision

**Root Domain vs Cluster Domain**:

| Pattern | Example | Used By | Benefits |
|---------|---------|---------|----------|
| **Root domain** | `globex.sandbox3491.opentlc.com` | Ansible | Shorter, cluster-agnostic |
| **Cluster domain** | `globex.myocp.sandbox3491.opentlc.com` | Our initial approach | More specific, cluster-scoped |

**Current Implementation**: Root domain pattern (matches ansible exactly)

**Rationale**: Alignment with Red Hat's official demo for consistency and easier comparison.

### Conclusion

✅ **ACK Route53 approach is production-ready and provides identical DNS delegation results to ansible**

**Proof**:
- Same subdomain pattern: `globex.sandbox3491.opentlc.com`
- Same TTL: 3600 seconds
- Same NS delegation in parent zone
- Same DNS resolution behavior
- Faster execution: 18s vs 45s
- Better GitOps integration

The ACK approach is **recommended** over ansible for DNS delegation in GitOps environments.

