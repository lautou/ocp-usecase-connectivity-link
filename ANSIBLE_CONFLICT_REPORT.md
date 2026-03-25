# Ansible Playbook Conflict Analysis Report

**Generated:** 2026-03-25
**Cluster:** myocp.sandbox3491.opentlc.com
**Playbook:** connectivity-link-ansible/operator-setup

---

## Executive Summary

The Ansible playbook will attempt to install several operators and create ArgoCD Applications that **WILL CONFLICT** with your existing installation. **DO NOT RUN THE PLAYBOOK AS-IS** - it will create duplicate operators and potentially break your cluster.

### ⚠️ CRITICAL CONFLICTS

| Component | Playbook Action | Current State | Conflict Level | Impact |
|-----------|----------------|---------------|----------------|--------|
| **RHCL Operator** | Create ArgoCD App | ✅ Already installed | 🔴 **HIGH** | Duplicate operator subscription |
| **Kuadrant CR** | Create ArgoCD App | ✅ Already exists | 🔴 **HIGH** | Duplicate Kuadrant instance |
| **Cert Manager** | Install operator | ✅ Already installed | 🔴 **HIGH** | Duplicate operator subscription |
| **Service Mesh Operator** | Create ArgoCD App | ✅ Already installed | 🔴 **HIGH** | Duplicate operator subscription |
| **Istio CR** | Create ArgoCD App | ✅ Already exists | 🟡 **MEDIUM** | Conflicts with existing `openshift-gateway` |
| **ingress-gateway namespace** | Create namespace | ⏳ Terminating | 🟡 **MEDIUM** | Will be recreated |

---

## Detailed Analysis

### 1. What the Ansible Playbook Will Install

The playbook creates **ArgoCD Applications** that manage resources via GitOps:

**Source Repository:** `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`

#### 1.1 Operators (via ArgoCD Applications)

| Application Name | Namespace | What It Installs | GitOps Path |
|-----------------|-----------|------------------|-------------|
| `kuadrant-operator` | `kuadrant-system` | RHCL operator subscription | `platform/kuadrant-operator` |
| `kuadrant` | `kuadrant-system` | Kuadrant CR | `platform/kuadrant` |
| `servicemesh-operator` | `gateway-system` | Sail Operator (OSSM 3) | `platform/sail-operator` |
| `istio` | `istio-system` | Istio CR | `platform/istio` |
| `ingress-gateway` | `ingress-gateway` | Gateway, DNSPolicy, TLSPolicy | `platform/ingress-gateway` |
| `echo-api` | (varies) | Echo API demo app | `platform/echo-api` |
| `observability` | (varies) | Observability stack | `platform/observability` |

#### 1.2 Direct Installs (not via ArgoCD)

| Component | Method | Namespace | Details |
|-----------|--------|-----------|---------|
| **Cert Manager Operator** | Direct subscription | `cert-manager-operator` | Uses `install_operator` role |
| **OpenShift GitOps** | Direct subscription | `openshift-operators` | Operator installation |

---

### 2. What's Already Installed in Your Cluster

#### 2.1 Operators (Subscriptions)

```
NAMESPACE                 OPERATOR                        CHANNEL      SOURCE
cert-manager-operator     openshift-cert-manager-operator stable-v1.18 redhat-operators
kuadrant-system          rhcl-operator                   stable       redhat-operators
kuadrant-system          authorino-operator              stable       redhat-operators
kuadrant-system          dns-operator                    stable       redhat-operators
kuadrant-system          limitador-operator              stable       redhat-operators
openshift-operators      servicemeshoperator3            stable       redhat-operators
```

**✅ All required operators are ALREADY installed!**

#### 2.2 Custom Resources

| Resource Type | Name | Namespace | Managed By |
|--------------|------|-----------|------------|
| **Istio** | `openshift-gateway` | `openshift-ingress` | OpenShift Ingress Operator |
| **Kuadrant** | `kuadrant` | `kuadrant-system` | ArgoCD App: `rh-connectivity-link` |
| **CertManager** | `cluster` | (cluster-scoped) | Cert Manager Operator |
| **ClusterIssuer** | `cluster` | (cluster-scoped) | ArgoCD App: `cert-manager` |

#### 2.3 ArgoCD Applications

| Application | What It Manages |
|-------------|----------------|
| `rh-connectivity-link` | RHCL operators (rhcl, authorino, dns, limitador) + Kuadrant CR |
| `cert-manager` | Cert Manager operator subscription + ClusterIssuer |

**Note:** NO ServiceMesh/Istio ArgoCD Applications exist - operators were installed some other way.

---

### 3. Conflict Details

#### 🔴 CONFLICT #1: RHCL Operator

**Playbook wants to create:**
- ArgoCD Application: `kuadrant-operator` in `openshift-gitops`
- Manages: Subscription for `rhcl-operator` in `kuadrant-system`

**Already exists:**
- ArgoCD Application: `rh-connectivity-link` manages `rhcl-operator` subscription
- Subscription: `rhcl-operator` already installed

**Impact if playbook runs:**
- ❌ Duplicate operator subscription (same name, same namespace)
- ❌ ArgoCD will show conflicts / out-of-sync
- ❌ May cause operator reinstallation or upgrade conflicts

---

#### 🔴 CONFLICT #2: Kuadrant CR

**Playbook wants to create:**
- ArgoCD Application: `kuadrant` in `openshift-gitops`
- Manages: Kuadrant CR named `kuadrant` in `kuadrant-system`

**Already exists:**
- Kuadrant CR: `kuadrant` in `kuadrant-system` (managed by `rh-connectivity-link`)

**Impact if playbook runs:**
- ❌ Duplicate Kuadrant instance (same name, same namespace)
- ❌ Two ArgoCD Applications managing the same resource
- ❌ Constant sync conflicts

---

#### 🔴 CONFLICT #3: Cert Manager Operator

**Playbook wants to create:**
- Subscription: `openshift-cert-manager-operator` in `cert-manager-operator`
- Via role: `install_operator` (direct installation, not ArgoCD)

**Already exists:**
- Subscription: `openshift-cert-manager-operator` already installed
- ArgoCD Application: `cert-manager` manages it

**Impact if playbook runs:**
- ❌ Duplicate subscription creation attempt
- ❌ May overwrite existing subscription configuration
- ❌ Could break ArgoCD management

---

#### 🔴 CONFLICT #4: Service Mesh Operator

**Playbook wants to create:**
- ArgoCD Application: `servicemesh-operator` in `openshift-gitops`
- Target namespace: `gateway-system` (NEW namespace)
- Manages: Subscription for `servicemeshoperator3`

**Already exists:**
- Subscription: `servicemeshoperator3` in `openshift-operators` (different namespace!)

**Impact if playbook runs:**
- ❌ Creates SECOND Service Mesh operator in different namespace
- ❌ Two operators managing the same CRDs
- ❌ Potential cluster instability

---

#### 🟡 CONFLICT #5: Istio CR

**Playbook wants to create:**
- ArgoCD Application: `istio` in `openshift-gitops`
- Target namespace: `istio-system` (NEW namespace)
- Creates: Istio CR (name unknown from template)

**Already exists:**
- Istio CR: `openshift-gateway` in `openshift-ingress` namespace
- Managed by: OpenShift Ingress Operator (for Gateway API integration)

**Impact if playbook runs:**
- ⚠️ Creates SECOND Istio control plane
- ⚠️ Both control planes will compete for resources
- ⚠️ Your RHOAI Gateway uses `openshift-gateway` - could be disrupted
- ⚠️ Unclear which control plane will manage Gateways

**Note:** OpenShift supports multiple Istio control planes, but having two is unusual and could cause confusion.

---

#### 🟡 CONFLICT #6: ingress-gateway Namespace

**Playbook wants to create:**
- Namespace: `ingress-gateway`
- ArgoCD Application: `ingress-gateway` in `openshift-gitops`
- Creates: Gateway `prod-web`, DNSPolicy, TLSPolicy, ManagedZone

**Current state:**
- Namespace: `ingress-gateway` is **Terminating** (you just deleted it)
- Will be fully deleted soon

**Impact if playbook runs:**
- ✅ Safe to recreate (namespace will be gone)
- ⚠️ But will use DIFFERENT GitOps source than your previous deployment
- ⚠️ Configuration may differ from what you had before

**Your previous setup:**
- Source: `https://github.com/lautou/ocp-usecase-connectivity-link.git`
- Path: `kustomize/overlays/default`

**Playbook setup:**
- Source: `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
- Path: `platform/ingress-gateway`

---

### 4. What Resources Would Be Created (No Conflicts)

These are **safe** to create as they don't currently exist:

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **echo-api Application** | (via ArgoCD) | Demo application |
| **observability Application** | (via ArgoCD) | Grafana/monitoring stack |
| **ingress-gateway** | `ingress-gateway` | Gateway resources (after namespace deletion completes) |
| **Istio CR** | `istio-system` | Second Istio control plane (not recommended but won't break cluster) |

---

## 5. Recommendations

### ❌ Option 1: DO NOT RUN the Playbook As-Is

**Why:** It will create duplicate operators and cause conflicts.

---

### ✅ Option 2: Skip Operator Installation, Only Deploy Applications

**Modify the playbook to skip operator installation:**

1. **Edit** `operator-setup/roles/ocp4_workload_connectivity_link/tasks/workload.yml`
2. **Comment out** these tasks:
   ```yaml
   # - name: Install Cert Manager
   #   ansible.builtin.include_tasks: cert-manager.yml

   # - name: Install Kuadrant
   #   ansible.builtin.include_tasks: kuadrant.yml

   # - name: Install Service mesh and Istio
   #   ansible.builtin.include_tasks: servicemesh.yml
   ```

3. **Keep only:**
   ```yaml
   - name: AWS Route53 setup
     ansible.builtin.include_tasks: aws-setup.yml

   - name: Install Ingress gateway
     ansible.builtin.include_tasks: ingress-gateway.yml

   - name: Install Echo API Application
     ansible.builtin.include_tasks: echo_api.yml

   - name: Install Observability
     ansible.builtin.include_tasks: observability.yaml
   ```

**Result:**
- ✅ Operators remain untouched
- ✅ Creates ingress-gateway with Gateway API resources
- ✅ Creates echo-api demo
- ✅ Sets up DNS with Route53
- ❌ Won't create duplicate Istio control plane

---

### ✅ Option 3: Manually Cherry-Pick What You Need

**If you only want ingress-gateway:**

1. Wait for `ingress-gateway` namespace to finish deleting:
   ```bash
   oc get namespace ingress-gateway
   # Should return "NotFound"
   ```

2. Clone the GitOps repository:
   ```bash
   git clone https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git
   cd cl-install-helm/platform/ingress-gateway
   ```

3. Review and manually apply resources

---

### ✅ Option 4: Use Your Original Repository

**Your previous deployment used:**
- Repository: `https://github.com/lautou/ocp-usecase-connectivity-link.git`
- Worked well for your use case
- You understand the configuration

**Continue using your own approach** rather than the official Ansible playbook.

---

## 6. Summary Matrix

| Component | Ansible Wants | Current State | Recommended Action |
|-----------|--------------|---------------|-------------------|
| RHCL Operator | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| Authorino Operator | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| DNS Operator | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| Limitador Operator | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| Kuadrant CR | Create | ✅ Exists | ❌ **SKIP** - Already exists |
| Cert Manager | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| Service Mesh Operator | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| Istio CR | Create | ✅ Exists (`openshift-gateway`) | ⚠️ **SKIP** - Avoid second control plane |
| ClusterIssuer | Create | ✅ Exists | ❌ **SKIP** - Already exists |
| OpenShift GitOps | Install | ✅ Installed | ❌ **SKIP** - Already exists |
| ingress-gateway | Create | ⏳ Terminating | ✅ **SAFE** - Can create after deletion |
| echo-api | Create | ❌ Not exists | ✅ **SAFE** - No conflicts |
| observability | Create | ❌ Not exists | ✅ **SAFE** - No conflicts |
| AWS Route53 Setup | Configure | ❓ Unknown | ✅ **SAFE** - Configuration only |

---

## 7. Ansible Playbook Modification Guide

If you choose to proceed with a modified playbook:

### File: `operator-setup/roles/ocp4_workload_connectivity_link/tasks/workload.yml`

**Replace this:**
```yaml
---
- name: AWS Route53 setup
  ansible.builtin.include_tasks: aws-setup.yml

- name: User workload monitoring
  ansible.builtin.include_tasks: user_workload_monitoring.yml

- name: Install OpenShift Gitops
  ansible.builtin.include_tasks: openshift_gitops.yml

- name: Setup OpenShift Gitops
  ansible.builtin.include_tasks: openshift_gitops_setup.yml

- name: Install Cert Manager
  ansible.builtin.include_tasks: cert-manager.yml

- name: Install Kuadrant
  ansible.builtin.include_tasks: kuadrant.yml

- name: Install Service mesh and Istio
  ansible.builtin.include_tasks: servicemesh.yml

- name: Install Ingress gateway
  ansible.builtin.include_tasks: ingress-gateway.yml

- name: Install Observability
  ansible.builtin.include_tasks: observability.yaml

- name: Install Echo API Application
  ansible.builtin.include_tasks: echo_api.yml
```

**With this:**
```yaml
---
# MODIFIED: Skip operator installations (already exist in cluster)

- name: AWS Route53 setup
  ansible.builtin.include_tasks: aws-setup.yml

# SKIPPED: User workload monitoring
# - name: User workload monitoring
#   ansible.builtin.include_tasks: user_workload_monitoring.yml

# SKIPPED: OpenShift GitOps (already installed)
# - name: Install OpenShift Gitops
#   ansible.builtin.include_tasks: openshift_gitops.yml

# SKIPPED: OpenShift GitOps Setup
# - name: Setup OpenShift Gitops
#   ansible.builtin.include_tasks: openshift_gitops_setup.yml

# SKIPPED: Cert Manager (already installed)
# - name: Install Cert Manager
#   ansible.builtin.include_tasks: cert-manager.yml

# SKIPPED: Kuadrant (already installed)
# - name: Install Kuadrant
#   ansible.builtin.include_tasks: kuadrant.yml

# SKIPPED: Service Mesh and Istio (already installed)
# - name: Install Service mesh and Istio
#   ansible.builtin.include_tasks: servicemesh.yml

- name: Install Ingress gateway
  ansible.builtin.include_tasks: ingress-gateway.yml

- name: Install Observability
  ansible.builtin.include_tasks: observability.yaml

- name: Install Echo API Application
  ansible.builtin.include_tasks: echo_api.yml
```

---

## 8. Questions to Answer Before Running

1. **Do you want the official Red Hat demo ingress-gateway setup?**
   - If YES: Wait for namespace deletion, then run modified playbook
   - If NO: Continue with your own setup

2. **Do you need the echo-api demo?**
   - Simple echo application for testing
   - Safe to install

3. **Do you want observability (Grafana)?**
   - Enhanced monitoring dashboards
   - Safe to install

4. **Do you want to use the official GitOps repository?**
   - Official: `https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm.git`
   - Your repo: `https://github.com/lautou/ocp-usecase-connectivity-link.git`

---

## 9. Final Recommendation

**DO NOT run the playbook without modifications.**

**Safest approach:**
1. ✅ Wait for `ingress-gateway` namespace deletion to complete
2. ✅ Modify `workload.yml` to skip operator installations (see section 7)
3. ✅ Run modified playbook to get only:
   - ingress-gateway resources
   - echo-api demo
   - Observability stack (optional)

**Alternative:**
- Continue using your own GitOps repository and deployment method
- Only reference the official repo for configuration examples

---

**Generated by:** Claude Code Analysis
**Report saved to:** `/home/ltourrea/workspace/rhcl/ANSIBLE_CONFLICT_REPORT.md`
