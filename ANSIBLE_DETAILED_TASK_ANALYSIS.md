# Detailed Ansible Task Analysis

**Generated:** 2026-03-25
**Cluster:** myocp.sandbox3491.opentlc.com

---

## 1. What Each Task Does

### 1.1 aws-setup.yml

**Purpose:** Creates Route53 subdomain and DNS delegation

**What it does:**
1. **Creates Route53 Hosted Zone** for subdomain `globex.sandbox3491.opentlc.com`
   - Uses AWS credentials from your inventory file
   - Creates new hosted zone in AWS Route53
   - Returns zone ID (e.g., `Z044356419CQ6A6BXXDV3`)

2. **Retrieves Nameservers** from the new hosted zone
   - Extracts 4 AWS nameservers (e.g., `ns-451.awsdns-56.com`)

3. **Creates NS Delegation** in parent zone
   - Updates root zone (`sandbox3491.opentlc.com`)
   - Creates NS records pointing subdomain to new hosted zone nameservers
   - Enables DNS resolution for `*.globex.sandbox3491.opentlc.com`

**Result:**
- ✅ Subdomain `globex.sandbox3491.opentlc.com` resolves via AWS Route53
- ✅ Sets variable `ocp4_workload_connectivity_link_aws_managed_zone_id` for use by other tasks

**Safe to run?** ✅ **YES**
- Idempotent (creates zone if doesn't exist, reuses if exists)
- No conflicts with current cluster resources
- Only modifies AWS Route53, not cluster

---

### 1.2 ingress-gateway.yml

**Purpose:** Creates ArgoCD Application to deploy Gateway API resources

**What it does:**

1. **Extracts Red Hat Registry Credentials**
   - Reads Secret `installation-pull-secrets` from `openshift-image-registry`
   - Extracts `registry.redhat.io` username and password
   - Needed for pulling Red Hat images

2. **Creates ArgoCD Application** named `ingress-gateway`
   - **Source:** `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
   - **Path:** `platform/ingress-gateway` (Helm chart)
   - **Namespace:** `ingress-gateway`
   - **Auto-sync:** Enabled (prune + selfHeal)

3. **What the Helm chart deploys** (from GitOps repo):
   - **Gateway** named `prod-web` (Istio Gateway)
     - Hostname: `*.globex.sandbox3491.opentlc.com`
     - HTTPS listener on port 443
     - TLS certificate Secret `api-tls`

   - **TLSPolicy** for cert-manager integration
     - Automatic Let's Encrypt certificates
     - DNS-01 challenge via Route53
     - Uses hosted zone ID from aws-setup.yml

   - **DNSPolicy** for Kuadrant DNS management
     - Creates CNAME records in Route53
     - Points Gateway hostname to Load Balancer
     - Geo-based routing: `{{ gateway_geo_code }}` (EU or US)
     - Load balancing strategy: `loadbalanced`

   - **Secret** `aws-credentials`
     - Type: `kuadrant.io/aws`
     - Contains AWS access key and secret
     - Used by DNSPolicy for Route53 updates

   - **ManagedZone** CR
     - Domain: `globex.sandbox3491.opentlc.com`
     - Zone ID: from aws-setup.yml
     - Links Kuadrant to Route53 hosted zone

   - **ClusterIssuer** (Let's Encrypt production)
     - Name: `le-production`
     - Server: `https://acme-v02.api.letsencrypt.org/directory`
     - DNS-01 solver with Route53
     - Email: `{{ ingress_gateway_tls_issuer_email }}` from inventory

**Helm Values Injected:**
```yaml
nameOverride: prod-web
gateway:
  listeners:
    api:
      hostName: "*.globex.sandbox3491.opentlc.com"
  geoCode: EU  # from inventory
dns:
  routingStrategy: loadbalanced
  loadBalancing:
    geo:
      defaultGeo: US
    weighted:
      defaultWeight: 120
tlsIssuer:
  email: ltourrea@redhat.com  # from inventory
  privateKeySecretRef: le-production
  server: https://acme-v02.api.letsencrypt.org/directory
  solvers:
    route53:
      hostedZoneID: <from aws-setup.yml>
      region: eu-central-1
      accessKeyIDSecretRef:
        name: aws-credentials
      secretAccessKeySecretRef:
        name: aws-credentials
awsZone:
  id: <from aws-setup.yml>
  domainName: globex.sandbox3491.opentlc.com
  description: "kuadrant managed zone"
aws:
  accesskey: <AWS_ACCESS_KEY_ID from inventory>
  secretAccessKey: <AWS_SECRET_ACCESS_KEY from inventory>
registry:
  username: <from openshift pull secret>
  password: <from openshift pull secret>
```

**Safe to run?** ✅ **YES** (after namespace deletion completes)
- Creates new namespace and resources
- No conflicts with existing operators
- Uses your existing Kuadrant/Istio operators
- **BUT:** Uses different GitOps repo than your previous deployment

---

### 1.3 observability.yaml

**Purpose:** Creates ArgoCD Applications for monitoring/observability stack

**What it does:**

**Conditional:** Only if `ocp4_workload_connectivity_link_monitoring_hub: true`

1. **Creates ArgoCD Application** `observability-hub`
   - **Source:** `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
   - **Path:** `platform/observability-hub/overlays/openshift`
   - **Namespace:** `monitoring`
   - **Auto-sync:** Enabled

   **Deploys** (from GitOps repo inspection needed):
   - Likely: Grafana Operator
   - Likely: Grafana instance
   - Likely: Datasources for Prometheus/Thanos
   - Likely: Dashboards for Gateway API, Istio, Kuadrant

2. **Creates ArgoCD Application** `observability-worker`
   - **Source:** `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
   - **Path:** `platform/observability-worker/overlays/openshift`
   - **Namespace:** `monitoring`
   - **Auto-sync:** Enabled

   **Deploys** (likely):
   - ServiceMonitors for scraping metrics
   - PrometheusRules for alerting
   - Additional monitoring configuration

**Safe to run?** ⚠️ **UNKNOWN**
- Need to inspect GitOps repository contents to confirm
- May install Grafana Operator (check if you want this)
- May create resources in `monitoring` namespace
- Could conflict with existing monitoring setup

**Recommendation:** 🔴 **SKIP FOR NOW**
- Inspect GitOps repo first: https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm/tree/main/platform
- Check if Grafana is already installed in your cluster
- Review what monitoring dashboards you actually need

---

## 2. Configuration Comparison: Are Commented Out Components the Same?

### 2.1 RHCL Operator (rhcl-operator)

| Attribute | Your Current Setup | Ansible Wants | Match? |
|-----------|-------------------|---------------|--------|
| **Operator Name** | `rhcl-operator` | `rhcl-operator` | ✅ Same |
| **Namespace** | `kuadrant-system` | `kuadrant-system` | ✅ Same |
| **Channel** | `stable` | `stable` | ✅ Same |
| **Source** | `redhat-operators` | `redhat-operators` | ✅ Same |
| **Starting CSV** | (auto-latest) | `""` (auto-latest) | ✅ Same |
| **Install Plan** | Automatic | Automatic | ✅ Same |

**Verdict:** ✅ **IDENTICAL CONFIGURATION**

**BUT:** Your operator is managed by ArgoCD Application `rh-connectivity-link` from:
- Your repo: `https://github.com/lautou/ocp-open-env-install-tool.git`
- Path: `components/rh-connectivity-link/overlays/default`

Ansible wants to create ArgoCD Application `kuadrant-operator` from:
- Red Hat repo: `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
- Path: `platform/kuadrant-operator`

**Risk if ansible runs:** 🔴 **CONFLICT**
- Two ArgoCD Applications managing same subscription
- Constant sync wars between applications
- Potential operator reinstallation

---

### 2.2 Kuadrant CR

| Attribute | Your Current Setup | Ansible Wants | Match? |
|-----------|-------------------|---------------|--------|
| **CR Name** | `kuadrant` | `kuadrant` | ✅ Same |
| **Namespace** | `kuadrant-system` | `kuadrant-system` | ✅ Same |
| **Spec** | `observability: {}` | Unknown (from GitOps) | ❓ Unknown |
| **MTLS Authorino** | `false` | Unknown | ❓ Unknown |
| **MTLS Limitador** | `false` | Unknown | ❓ Unknown |

**Managed by:**
- Your setup: ArgoCD Application `rh-connectivity-link`
- Ansible setup: ArgoCD Application `kuadrant`

**Verdict:** ⚠️ **LIKELY SAME, BUT MANAGED DIFFERENTLY**

**Risk if ansible runs:** 🔴 **CONFLICT**
- Two ArgoCD Applications managing same Kuadrant CR
- Cannot have two ArgoCD apps own the same resource

---

### 2.3 Cert Manager Operator

| Attribute | Your Current Setup | Ansible Wants | Match? |
|-----------|-------------------|---------------|--------|
| **Operator Name** | `openshift-cert-manager-operator` | `openshift-cert-manager-operator` | ✅ Same |
| **Namespace** | `cert-manager-operator` | `cert-manager-operator` | ✅ Same |
| **Channel** | `stable-v1.18` | Unknown (not in defaults) | ❓ Unknown |
| **Source** | `redhat-operators` | `redhat-operators` | ✅ Same |

**Managed by:**
- Your setup: ArgoCD Application `cert-manager`
- Ansible setup: Direct subscription (no ArgoCD), uses `install_operator` role

**Verdict:** ⚠️ **DIFFERENT INSTALLATION METHOD**

**Ansible uses:** `install_operator` role with variables from... WHERE?

Looking at `cert-manager.yml`:
```yaml
vars:
  install_operator_name: openshift-cert-manager-operator
  install_operator_csv_nameprefix: cert-manager-operator
  install_operator_namespace: cert-manager-operator
  install_operator_channel: "{{ ocp4_workload_cert_manager_channel }}"
  install_operator_starting_csv: "{{ ocp4_workload_cert_manager_starting_csv }}"
```

**Problem:** Variables `ocp4_workload_cert_manager_channel` and `ocp4_workload_cert_manager_starting_csv` are **NOT defined** in `defaults/main.yml`!

**Risk if ansible runs:** 🔴 **WILL FAIL or USE WRONG CHANNEL**
- Undefined variables will cause ansible error OR
- Fall back to defaults from `install_operator` role (empty channel = default channel)
- May try to overwrite existing subscription
- Conflicts with ArgoCD management

---

### 2.4 Service Mesh Operator (servicemeshoperator3)

| Attribute | Your Current Setup | Ansible Wants | Match? |
|-----------|-------------------|---------------|--------|
| **Operator Name** | `servicemeshoperator3` | `servicemeshoperator3` | ✅ Same |
| **Current Namespace** | `openshift-operators` | Wants: `gateway-system` | 🔴 **DIFFERENT!** |
| **Channel** | `stable` | `""` (empty = default) | ⚠️ Likely same |
| **Source** | `redhat-operators` | `redhat-operators` | ✅ Same |
| **Starting CSV** | `servicemeshoperator3.v3.1.0` | `""` (auto-latest) | ⚠️ May upgrade |

**Verdict:** 🔴 **DIFFERENT NAMESPACE!**

**Your setup:**
- Installed in: `openshift-operators` (cluster-wide scope)
- Method: Unknown (not managed by ArgoCD `rh-connectivity-link`)

**Ansible wants:**
- Install in: `gateway-system` (namespace-scoped)
- Method: ArgoCD Application `servicemesh-operator`

**Risk if ansible runs:** 🔴 **CREATES SECOND OPERATOR**
- Two Service Mesh operators in cluster
- One in `openshift-operators` (cluster-wide)
- One in `gateway-system` (namespace-scoped)
- Both managing same CRDs
- **CLUSTER INSTABILITY LIKELY**

---

### 2.5 Istio CR

| Attribute | Your Current Setup | Ansible Wants | Match? |
|-----------|-------------------|---------------|--------|
| **CR Name** | `openshift-gateway` | Unknown (from GitOps) | ❓ Unknown |
| **Namespace** | `openshift-ingress` | Wants: `istio-system` | 🔴 **DIFFERENT!** |
| **Profile** | (empty) | Unknown | ❓ Unknown |
| **Managed By** | OpenShift Ingress Operator | ArgoCD `istio` app | 🔴 **DIFFERENT!** |
| **Version** | v1.26.2 | Unknown | ❓ Unknown |

**Verdict:** 🔴 **COMPLETELY DIFFERENT**

**Your setup:**
- Istio CR: `openshift-gateway` in `openshift-ingress`
- Purpose: Managed by OpenShift Ingress Operator for Gateway API integration
- Used by: RHOAI Gateway (`data-science-gateway`)
- Control plane: Single control plane for all Gateways

**Ansible wants:**
- Istio CR: Unknown name in `istio-system`
- Purpose: Standalone Istio control plane
- Method: ArgoCD Application `istio`

**Risk if ansible runs:** 🟡 **CREATES SECOND CONTROL PLANE**
- You'll have TWO Istio control planes:
  1. `openshift-gateway` (existing, used by RHOAI)
  2. New one in `istio-system` (from ansible)
- Both control planes will compete
- Unclear which manages which Gateways
- Increased resource usage
- **Technically supported** (OpenShift allows multiple control planes) but **NOT RECOMMENDED**

---

## 3. Summary: Safe vs Risky Tasks

### ✅ SAFE TO RUN

| Task | Why Safe | Notes |
|------|----------|-------|
| **aws-setup.yml** | Only modifies AWS Route53 | Idempotent, no cluster impact |
| **ingress-gateway.yml** | Creates new namespace/resources | Wait for namespace deletion first |
| **echo_api.yml** | New demo app | No conflicts |

### 🟡 CAUTION

| Task | Risk | Recommendation |
|------|------|----------------|
| **observability.yaml** | Unknown what it deploys | Inspect GitOps repo first |

### 🔴 DO NOT RUN

| Task | Why Dangerous | Impact |
|------|---------------|--------|
| **cert-manager.yml** | Duplicate operator, missing variables | Fails or conflicts with ArgoCD |
| **kuadrant.yml** | Duplicate Kuadrant CR | Two ArgoCD apps fight over same resource |
| **servicemesh.yml** | Creates second operator in different namespace | Cluster instability |

### ⚠️ RISKY

| Task | Risk | Why |
|------|------|-----|
| **openshift_gitops.yml** | May modify existing GitOps | Already installed |
| **openshift_gitops_setup.yml** | May change GitOps config | Already configured |

---

## 4. Configuration Drift Analysis

### Question: "Are we sure the configuration will be the same?"

**Answer:** 🔴 **NO, configurations are NOT guaranteed to be the same**

#### 4.1 Different GitOps Sources

**Your current setup uses:**
```
Repository: https://github.com/lautou/ocp-open-env-install-tool.git
Path: components/rh-connectivity-link/overlays/default
```

**Ansible uses:**
```
Repository: https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git
Paths:
  - platform/kuadrant-operator
  - platform/kuadrant
  - platform/sail-operator
  - platform/istio
  - platform/ingress-gateway
  - platform/observability-hub
  - platform/observability-worker
  - platform/echo-api
```

**Implication:** Different repos = different resource definitions, even if operator names match.

#### 4.2 Unknown Cert Manager Variables

Ansible references undefined variables:
- `{{ ocp4_workload_cert_manager_channel }}`
- `{{ ocp4_workload_cert_manager_starting_csv }}`

**Risk:** Unpredictable behavior (error or wrong channel).

#### 4.3 Service Mesh Namespace Mismatch

- Your setup: `openshift-operators` (cluster-scoped)
- Ansible: `gateway-system` (namespace-scoped)

**Result:** Different behavior, different scope.

#### 4.4 Istio Control Plane Architecture

- Your setup: Single control plane (`openshift-gateway`) managed by Ingress Operator
- Ansible: Creates additional control plane in `istio-system`

**Result:** Fundamentally different architecture.

---

## 5. Detailed Recommendations

### If you want to use the Red Hat demo setup:

1. ✅ **Run these tasks:**
   ```yaml
   - aws-setup.yml           # Creates Route53 subdomain
   - ingress-gateway.yml     # Creates Gateway resources
   - echo_api.yml           # Demo application
   ```

2. 🔴 **Skip these tasks:**
   ```yaml
   - cert-manager.yml        # Operator already exists
   - kuadrant.yml           # CR already exists
   - servicemesh.yml        # Operator already exists
   - openshift_gitops.yml   # Already installed
   - openshift_gitops_setup.yml  # Already configured
   ```

3. ⚠️ **Investigate before running:**
   ```yaml
   - observability.yaml     # Check GitOps repo to see what it deploys
   - user_workload_monitoring.yml  # Check what monitoring changes it makes
   ```

### Modification Required

**Edit:** `operator-setup/roles/ocp4_workload_connectivity_link/tasks/workload.yml`

**Keep only:**
```yaml
---
- name: AWS Route53 setup
  ansible.builtin.include_tasks: aws-setup.yml

- name: Install Ingress gateway
  ansible.builtin.include_tasks: ingress-gateway.yml

- name: Install Echo API Application
  ansible.builtin.include_tasks: echo_api.yml

# Optional: Uncomment after inspecting what it deploys
# - name: Install Observability
#   ansible.builtin.include_tasks: observability.yaml
```

---

## 6. Alternative: Continue with Your Own Setup

**Your current approach:**
- Repository: `https://github.com/lautou/ocp-usecase-connectivity-link.git`
- Kustomize-based (not Helm)
- ArgoCD Application: `usecase-connectivity-link`

**Advantages:**
- ✅ You understand the configuration
- ✅ No operator conflicts
- ✅ Known working state
- ✅ Full control over resources

**Disadvantages:**
- ❌ Not using "official" Red Hat demo
- ❌ May miss new features in official repo

**Recommendation:** Consider cherry-picking specific resources from Red Hat repo rather than running the full ansible playbook.

---

**Report saved to:** `/home/ltourrea/workspace/rhcl/ANSIBLE_DETAILED_TASK_ANALYSIS.md`
