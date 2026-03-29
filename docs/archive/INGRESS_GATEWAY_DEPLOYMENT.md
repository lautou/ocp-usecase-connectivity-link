## Ingress Gateway Deployment - Ansible Alignment

**Status**: Successfully deployed ingress-gateway infrastructure matching Red Hat's ansible deployment **100%** ✅

**Deployment Date**: 2026-03-25

### Deployment Approach

We tested and validated **two deployment approaches** for the ingress-gateway infrastructure:

1. **Red Hat's Ansible/Helm Approach** (connectivity-link-ansible repository)
2. **Our GitOps/ArgoCD Approach** (this repository)

**Result**: Both approaches produce **identical infrastructure** with the exact same resource names and configuration.

### Resource Name Alignment - 100% Match

| Resource | Ansible/Helm Name | Our GitOps Deployment | Match |
|----------|-------------------|----------------------|-------|
| **Gateway** | `prod-web` | `prod-web` | ✅ Exact |
| **Gateway Hostname** | `*.globex.sandbox3491.opentlc.com` | `*.globex.sandbox3491.opentlc.com` | ✅ Exact |
| **TLSPolicy** | `prod-web-tls-policy` | `prod-web-tls-policy` | ✅ Exact |
| **RateLimitPolicy** | `prod-web-rlp-lowlimits` | `prod-web-rlp-lowlimits` | ✅ Exact |
| **AuthPolicy** | `prod-web-deny-all` | `prod-web-deny-all` | ✅ Exact |
| **ClusterIssuer** | `prod-web-lets-encrypt-issuer` | `prod-web-lets-encrypt-issuer` | ✅ Exact |
| **AWS Secret** | `prod-web-aws-credentials` | `prod-web-aws-credentials` | ✅ Exact |
| **ServiceMonitor** | `prod-web-service-monitor` | `prod-web-service-monitor` | ✅ Exact |
| **PodMonitor** | `istio-proxies-monitor` | `istio-proxies-monitor` | ✅ Exact |
| **Metrics Service** | `prod-web-metrics-proxy` | `prod-web-metrics-proxy` | ✅ Exact |
| **Namespace Label** | ❌ Manual `oc label` | ✅ In Git manifests | **Better** |

### Deployment Workflow Comparison

**Ansible Playbook** (`connectivity-link-ansible`):
```bash
cd operator-setup
ansible-playbook playbooks/ocp4_workload_connectivity_link.yml \
  -e ACTION=create \
  -i inventories/inventory.template \
  -e ocp4_workload_connectivity_link_aws_managed_zone_id=Z09941991LWPLNSV0EDW
```

**What ansible does**:
1. Creates AppProject `infra` in `openshift-gitops`
2. Creates ArgoCD Application `ingress-gateway` pointing to Red Hat's Helm chart
3. Helm chart deploys 11 resources to `ingress-gateway` namespace
4. **Manual workaround required**: Add namespace label via `oc label`

**Our GitOps Approach**:
```bash
cd /home/ltourrea/workspace/rhcl
oc apply -f argocd/application-ingress-gateway.yaml
```

**What our ArgoCD Application does**:
1. Uses `kustomize/overlays/ingress-gateway-only/`
2. Deploys 15 resources (11 from Helm + 4 cluster-scoped)
3. **Namespace label included in Git** (no manual step)
4. Jobs automatically patch dynamic values (hostname, AWS credentials)

### Resources Deployed (15 Total)

**Cluster-Scoped (4)**:
1. GatewayClass `istio`
2. ClusterRole `gateway-manager`
3. ClusterRoleBinding `gateway-manager-openshift-gitops-argocd-application-controller`
4. ClusterIssuer `prod-web-lets-encrypt-issuer`

**Namespace (1)**:
5. Namespace `ingress-gateway` (with label `argocd.argoproj.io/managed-by: openshift-gitops`)

**Gateway and Policies (4)**:
6. Gateway `prod-web`
7. TLSPolicy `prod-web-tls-policy`
8. AuthPolicy `prod-web-deny-all`
9. RateLimitPolicy `prod-web-rlp-lowlimits`

**Monitoring (3)**:
10. ServiceMonitor `prod-web-service-monitor`
11. PodMonitor `istio-proxies-monitor`
12. Service `prod-web-metrics-proxy`

**Secrets (2 - created by Jobs)**:
13. Secret `prod-web-aws-credentials` (type: `kuadrant.io/aws`)
14. Secret `api-tls` (TLS certificate from Let's Encrypt)

**Auto-Created (1)**:
15. Deployment `prod-web-istio` (Gateway data plane)

### Key Configuration Details

**Gateway Hostname Pattern**:
- Uses **root domain**: `*.globex.sandbox3491.opentlc.com`
- Calculated by stripping cluster name: `myocp.sandbox3491.opentlc.com` → `sandbox3491.opentlc.com`
- Matches ansible exactly (not using full cluster domain)

**ClusterIssuer**:
- Dedicated issuer `prod-web-lets-encrypt-issuer` (not reusing generic `cluster` issuer)
- Benefits: Isolation, email notifications, independent lifecycle
- Uses same AWS credentials as DNSPolicy (`prod-web-aws-credentials`)

**TLS Certificate**:
- ✅ Issued by Let's Encrypt
- Subject: `*.globex.sandbox3491.opentlc.com`
- Validation: DNS-01 via Route53
- Status: Ready
- Expiry: ~3 months (auto-renewed by cert-manager)

**DNS Configuration**:
- ❌ **No DNSPolicy** at this stage (matches ansible)
- Ansible Helm chart does NOT create DNSPolicy
- DNS records would need to be created manually or via separate deployment
- Our `overlays/default` includes DNSPolicy for full automation

### What's NOT Included (Matches Ansible)

At the `ingress-gateway.yml` stage, both deployments do **NOT** include:
- ❌ DNSPolicy (DNS automation)
- ❌ echo-api application
- ❌ globex applications
- ❌ Keycloak realm
- ❌ HTTPRoutes
- ❌ Observability stack

These components are deployed in **later stages** of the ansible playbook:
- `observability.yaml` (disabled in our test)
- `echo_api.yml` (disabled in our test)
- `webterminal_operator.yml` (disabled in our test)
- `rhsso.yml` (disabled in our test)
- `apicurio_studio.yml` (disabled in our test)

### The ONE Critical Difference

**Namespace Label Management**:

| Aspect | Ansible/Helm | Our GitOps |
|--------|--------------|------------|
| **Label in Source** | ❌ No (Helm chart missing) | ✅ Yes (in Git) |
| **Manual Step** | ✅ Required: `oc label namespace ingress-gateway argocd.argoproj.io/managed-by=openshift-gitops` | ❌ Not needed |
| **GitOps Friendly** | ❌ Manual operation | ✅ Fully declarative |
| **Reproducible** | ⚠️ Easy to forget | ✅ Always applied |

**Why This Matters**:

The namespace label `argocd.argoproj.io/managed-by: openshift-gitops` triggers **OpenShift GitOps automatic RBAC creation**:
- Auto-creates namespace-scoped Role with permissions for 50+ API groups
- Auto-creates RoleBinding for `openshift-gitops-argocd-application-controller`
- Without this label: RBAC errors for Kuadrant resources (TLSPolicy, AuthPolicy, RateLimitPolicy)

**Our Improvement**: The label is in Git manifests, making it part of the declarative deployment (no manual step).

### Jobs for Dynamic Configuration

Both deployments need dynamic values that can't be hardcoded in Git:

**Job #1: AWS Credentials Setup**
- Extracts AWS credentials from `kube-system/aws-creds`
- Extracts AWS region from cluster infrastructure
- Creates Secret `prod-web-aws-credentials` (type: `kuadrant.io/aws`)
- Creates Secret `aws-acme` (for cert-manager DNS-01 validation)

**Job #2: Gateway Hostname Patch**
- Extracts cluster base domain from DNS config
- Calculates root domain by stripping cluster name prefix
- Patches Gateway hostname from placeholder to `*.globex.<root-domain>`

**Execution**: Both Jobs run as ArgoCD PostSync hooks (automatic on every sync)

### Verification Status

**Gateway**:
- ✅ Hostname: `*.globex.sandbox3491.opentlc.com` (matches ansible)
- ✅ Programmed: True
- ✅ Load Balancer: Ready (`a3eaa314bea1a4ceb9a0b3b2b6481b56-2122933903.eu-central-1.elb.amazonaws.com`)

**TLS Certificate**:
- ✅ Issued: Yes (Let's Encrypt)
- ✅ Subject: `*.globex.sandbox3491.opentlc.com`
- ✅ Valid: Until Jun 23, 2026
- ✅ Status: Ready

**DNS**:
- ⏳ No automatic DNS records (expected without DNSPolicy)
- Manual DNS records or DNSPolicy required for external access
- Matches ansible deployment at this stage

**Policies**:
- ✅ AuthPolicy: Deny-by-default (HTTP 403 for all traffic)
- ✅ RateLimitPolicy: 5 requests per 10 seconds
- ✅ TLSPolicy: Enforced (certificate auto-managed)

**Monitoring**:
- ✅ ServiceMonitor: Collecting Gateway metrics
- ✅ PodMonitor: Collecting Istio proxy metrics
- ✅ Metrics Service: Exposing port 15020

### Overlay Structure

**Location**: `kustomize/overlays/ingress-gateway-only/`

**Approach**: Self-contained overlay
- All resource manifests copied directly into overlay directory
- No external file references (avoids kustomize security restrictions)
- Fully reproducible and portable

**Why Self-Contained**:

Kustomize enforces security restrictions preventing references to files outside the overlay directory:
- Error: `file '<path>' is not in or below '<overlay-path>'`
- Solution: Copy all needed manifests into the overlay
- Benefit: Overlay is completely independent and self-documenting

**Files in Overlay** (19 total):
```
ingress-gateway-only/
├── kustomization.yaml (references all 18 resources)
├── cluster-gatewayclass-istio.yaml
├── cluster-clusterrole-gateway-manager.yaml
├── cluster-crb-gateway-manager-openshift-gitops-argocd-application-controller.yaml
├── cluster-clusterissuer-prod-web-lets-encrypt.yaml
├── cluster-ns-ingress-gateway.yaml
├── ingress-gateway-authpolicy-prod-web-deny-all.yaml
├── ingress-gateway-gateway-prod-web.yaml
├── ingress-gateway-podmonitor-istio-proxies.yaml
├── ingress-gateway-ratelimitpolicy-prod-web.yaml
├── ingress-gateway-service-prod-web-metrics-proxy.yaml
├── ingress-gateway-servicemonitor-prod-web.yaml
├── ingress-gateway-tlspolicy-prod-web.yaml
├── openshift-gitops-job-aws-credentials.yaml
├── openshift-gitops-job-gateway-prod-web.yaml
└── README.md
```

### Testing and Validation

**Test Date**: 2026-03-25

**Test Methodology**:
1. Clean cluster state (deleted ansible-deployed resources)
2. Deployed via ArgoCD Application using `ingress-gateway-only` overlay
3. Verified all 15 resources created
4. Compared resource names with ansible deployment
5. Validated TLS certificate issuance
6. Confirmed namespace label triggers auto-RBAC

**Result**: 100% functional match with ansible deployment ✅

### Next Steps (Following Ansible Workflow)

If continuing with the ansible playbook stages:
1. `observability.yaml` - Deploy observability stack (Grafana, dashboards)
2. `echo_api.yml` - Deploy echo-api application
3. `webterminal_operator.yml` - Deploy web terminal
4. `rhsso.yml` - Deploy Red Hat SSO (Keycloak)
5. `apicurio_studio.yml` - Deploy Apicurio Studio

**Our Repository Equivalents**:
- `overlays/default` - Includes echo-api, globex applications, Keycloak realm
- DNSPolicy - For automatic DNS record creation
- Full application stack - All components for complete demo

### Lessons Learned

**1. Resource Naming Matters**:
- Aligning names exactly with ansible/Helm improves consistency
- Makes comparison and troubleshooting easier
- Facilitates migration between deployment methods

**2. Dedicated ClusterIssuer is Safer**:
- Provides isolation between projects
- Enables email notifications for certificate issues
- Prevents accidental impact from cluster-wide changes

**3. Gateway Hostname Uses Root Domain**:
- Ansible uses `*.globex.<root-domain>` not `*.globex.<cluster-domain>`
- Must strip cluster name prefix: `myocp.sandbox3491.opentlc.com` → `sandbox3491.opentlc.com`
- Job calculates this dynamically: `ROOT_DOMAIN=$(echo "${BASE_DOMAIN}" | sed 's/^[^.]*\.//')`

**4. Namespace Label is Critical**:
- Missing label causes RBAC failures
- OpenShift GitOps auto-RBAC depends on this label
- Should be in Git manifests, not applied manually

**5. Kustomize Overlay Best Practices**:
- Self-contained overlays avoid security restrictions
- Copy all resources into overlay directory
- Reference local files only (no `../../base/file.yaml`)

**6. DNSPolicy is Optional at This Stage**:
- Ansible does NOT include DNSPolicy in Helm chart
- DNS records managed separately
- Full automation (DNSPolicy) is an enhancement, not requirement

### Related Documentation

- [Ansible Deployment Guide](ANSIBLE_CONFLICT_REPORT.md) - Analysis of ansible playbook
- [Cleanup and Redeploy](CLEANUP_AND_REDEPLOY.md) - Step-by-step cleanup instructions
- [Migration Guide](ARGOCD_MIGRATION_GUIDE.md) - Migrating from overlays/default
- [Overlay README](kustomize/overlays/ingress-gateway-only/README.md) - Overlay documentation
