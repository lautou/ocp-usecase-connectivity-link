# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**Purpose**: GitOps deployment of Red Hat Connectivity Link on OpenShift using ACK Route53, Istio Gateway API, and Kuadrant.

**Architecture**: Istio Gateway API + ACK Route53 + Kuadrant + RHBK 26 + Globex monolith + Apicurio Studio

## Critical Rules (Always Follow)

### Kubernetes YAML Attribute Ordering

**IMPORTANT**: All Kubernetes YAML manifests MUST follow standard attribute ordering for consistency and readability.

**Top-Level Structure**:
```yaml
apiVersion: <version>
kind: <Kind>
metadata:
  <metadata attributes>
spec:
  <spec attributes>
```

**Metadata Section Ordering** (CRITICAL):
1. **name** - Resource name (always first)
2. **namespace** - Namespace (if namespaced)
3. **labels** - Key-value labels (if present)
4. **annotations** - Key-value annotations (if present)
5. Other metadata fields

**Enforcement**: All YAML files in `kustomize/` MUST follow this ordering

### Config Management Plugin (CMP) and Domain Placeholders

**CRITICAL SYSTEM**: This project uses ArgoCD Config Management Plugin (CMP) to replace cluster-specific domain placeholders during manifest generation.

**Why CMP:**
- Git manifests contain domain placeholders (`CLUSTER_DOMAIN`, `ROOT_DOMAIN`)
- CMP queries OpenShift DNS API to discover actual cluster domain
- Replacements happen during manifest generation (before Kubernetes validation)
- Works with partial sync, auto-sync, and all ArgoCD features
- No ignoreDifferences needed (Git is source of truth)

**How It Works:**

1. **ArgoCD detects kustomization.yaml** in repository path
2. **CMP sidecar is invoked** via plugin discovery (finds `**/kustomization.yaml`)
3. **CMP queries DNS object**:
   ```bash
   curl https://kubernetes.default.svc/apis/config.openshift.io/v1/dnses/cluster
   # Returns: { "spec": { "baseDomain": "myocp.sandbox3491.opentlc.com" } }
   ```
4. **CMP calculates domain values**:
   ```bash
   BASE_DOMAIN="myocp.sandbox3491.opentlc.com"     # From DNS API
   CLUSTER_DOMAIN="apps.${BASE_DOMAIN}"            # OpenShift routes domain
   ROOT_DOMAIN=$(echo "${BASE_DOMAIN}" | sed 's/^[^.]*\.//')  # Gateway API domain
   ```
5. **CMP builds and transforms manifests**:
   ```bash
   kustomize build . | sed "s|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|g; s|ROOT_DOMAIN|${ROOT_DOMAIN}|g"
   ```

**Domain Placeholder Usage:**

- **CLUSTER_DOMAIN** (`apps.myocp.sandbox3491.opentlc.com`):
  - OpenShift Routes
  - Keycloak URLs
  - All services using OpenShift ingress

- **ROOT_DOMAIN** (`sandbox3491.opentlc.com`):
  - Gateway API hostnames
  - DNS delegation zone
  - External DNS records

**CMP Configuration:**

Located in `argocd/openshift-gitops-configmap-cmp-plugin.yaml`:
- **Plugin name**: `cluster-domain-replacer`
- **Discovery**: Matches repositories with `kustomization.yaml`
- **Generate**: Runs kustomize + sed replacements
- **Authentication**: Uses ServiceAccount token from repo-server pod
- **RBAC**: ClusterRole `argocd-cmp-dns-reader` grants DNS read permission

**Verification Commands:**
```bash
# Check if domain placeholders are replaced
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[0].hostname}'
# Should be: *.globex.sandbox3491.opentlc.com

oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}'
# Should be: echo.globex.sandbox3491.opentlc.com

oc get deployment globex-mobile-gateway -n globex-apim-user1 -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KEYCLOAK_AUTH_SERVER_URL")].value}'
# Should be: https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1

# Check CMP sidecar is running
oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-repo-server
# Should show: 2/2 Running (main container + cmp sidecar)

# Check CMP plugin logs
oc logs -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-repo-server -c cmp-cluster-domain --tail=50
# Should show: [CMP] Discovered BASE_DOMAIN: myocp.sandbox3491.opentlc.com
```

**Troubleshooting:**
```bash
# Clear ArgoCD cache and force re-generation
oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-redis
argocd app get <app-name> --hard-refresh
argocd app sync <app-name>

# Test CMP plugin manually
POD=$(oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-repo-server -o name | head -1)
oc exec -n openshift-gitops $POD -c cmp-cluster-domain -- sh -c '
KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s -H "Authorization: Bearer ${KUBE_TOKEN}" \
  --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  https://kubernetes.default.svc/apis/config.openshift.io/v1/dnses/cluster | grep baseDomain
'
# Should return: "baseDomain": "myocp.sandbox3491.opentlc.com"

# Verify RBAC permissions
oc auth can-i get dnses.config.openshift.io \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-repo-server
# Should return: yes
```

### Security Rules

- ⚠️ **DEMO SECRETS** in `keycloak-keycloakrealmimport-globex-user1.yaml` - OAuth client secrets
- ⚠️ **DEMO SECRETS** in `globex-secret-globex-db.yaml` - Database credentials
- **NOT FOR PRODUCTION** - See `docs/reference/security.md` and `SECURITY.md`

## Key Components

### Infrastructure
- **Gateway API**: `prod-web` in `ingress-gateway` namespace - `*.globex.<cluster-domain>`
- **DNS Base**: ACK Route53 Controller (HostedZone + RecordSet for subdomain delegation)
- **DNS Optional**: Kuadrant DNSPolicy (in `solutions/platform-engineer/` - not deployed by default)
- **Kuadrant**: TLSPolicy, AuthPolicy (deny-by-default), RateLimitPolicy
- **cert-manager**: Let's Encrypt wildcard certificates via DNS-01

### Applications
- **Echo API**: Demo HTTPRoute in `echo-api` namespace
- **Globex**: Monolith e-commerce (4 components) in `globex-apim-user1` namespace
  - globex-db (PostgreSQL with 41 products)
  - globex-store-app (Quarkus backend - NPE-fixed custom image)
  - globex-mobile (Angular frontend - RHBK 26 compatible custom image)
  - globex-mobile-gateway (Quarkus mobile API with OAuth)
    - **Note:** Acts as **ProductInfo service** in the architecture narrative
    - Simulates external product catalog API for Gateway API demonstration
    - See `docs/architecture/external-service-simulation.md` for rationale
- **RHBK 26**: Red Hat build of Keycloak in `keycloak` namespace
- **Apicurio Studio**: Schema registry in `apicurio` namespace

### Custom Images (Bug Fixes)
- `quay.io/laurenttourreau/globex-store:npe-fixed` - Fixes NullPointerException in CatalogResource.java
- `quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3` - RHBK 26 OAuth Code Flow + PKCE + No offline_access scope
  - **v3 changes**: Removed offline_access scope requests to prevent Keycloak token exchange errors
  - Built with: `container-images/globex-web/Containerfile.globex-mobile`
  - Patches: response_type, usePkce, and removes offline_access from JavaScript bundle

## Architecture Philosophy

### ProductInfo Service - External API Simulation

**CRITICAL CONCEPT:** This project demonstrates **Gateway API for consuming external services**.

**globex-mobile-gateway deployment** represents **ProductInfo service**, an external product catalog API:

**Conceptual Role (Documentation/Narrative):**
- External product information service (like Akeneo, commercetools)
- Partner product catalog API
- Microservice owned by separate team

**Technical Reality (Deployment):**
- Deployed as `globex-mobile-gateway` in same cluster
- For demo simplicity and reproducibility
- But architecturally treated as external dependency

**Why This Matters:**

In modern applications, consuming external services is common:
- Product catalogs from data providers
- Payment APIs (Stripe, PayPal)
- Shipping/logistics APIs
- Inventory management systems

**Gateway API demonstrates:**
- ✅ How to consume external APIs with policies (rate limiting, auth)
- ✅ Realistic architecture pattern for production
- ✅ Separation between internal (ClusterIP) and external (Gateway API) services

**Architecture Pattern:**
```
globex-mobile (Frontend)
  → Gateway API HTTPRoute → ProductInfo service (external - simulated)
  → ClusterIP (internal) → globex-store-app (internal backend)
```

**See:** `docs/architecture/external-service-simulation.md` for complete explanation

**Documentation Convention:**
- **Business/Narrative:** "ProductInfo service" (what it represents)
- **Technical/Code:** "globex-mobile-gateway" (actual deployment name)

## File Structure

```
kustomize/
├── ingress-gateway/    # Gateway, TLSPolicy, AuthPolicy, RateLimitPolicy, HTTPRoutes
├── echo-api/           # Demo HTTPRoute application
├── globex/             # Globex monolith (4 deployments)
├── rhbk/               # RHBK 26 operator + Keycloak CR + realm
└── apicurio/           # Apicurio Studio (schema registry)

solutions/                        # Optional tutorial resources (NOT in base GitOps)
├── README.md                     # Solutions documentation
├── platform-engineer-workflow/   # Platform Engineer tutorial (DNSPolicy, RateLimitPolicy)
│   ├── kustomization.yaml
│   ├── ingress-gateway-dnspolicy-prod-web.yaml
│   └── echo-api-ratelimitpolicy-echo-api.yaml
└── developer-workflow/           # Developer tutorial (HTTPRoute + AuthPolicy + RateLimitPolicy)
    ├── kustomization.yaml
    ├── globex-apim-user1-httproute-globex-mobile-gateway.yaml
    ├── globex-apim-user1-authpolicy-globex-mobile-gateway.yaml
    ├── globex-apim-user1-ratelimitpolicy-globex-mobile-gateway.yaml
    └── README.md

argocd/
├── application.yaml                                      # Bootstrap application (default overlay)
├── application-globex.yaml                               # Globex application
├── application-rhbk.yaml                                 # RHBK stack
├── application-apicurio.yaml                             # Apicurio Studio
├── application-solutions-platform-engineer-workflow.yaml # Optional: Platform Engineer tutorial (GitOps)
└── application-solutions-developer-workflow.yaml         # Optional: Developer tutorial (GitOps)

scripts/
├── deploy.sh           # Deploy base infrastructure
├── test-deploy.sh      # Test deployment
├── cleanup-quay-repos.sh
└── solutions.sh        # Deploy/manage solution pattern tutorials
```

**File naming convention**: `<namespace>-<kind>-<name>.yaml`

## Solution Patterns (Optional Tutorial Resources)

**Location**: `solutions/` directory

The `solutions/` directory contains **optional resources** for following the [Red Hat Connectivity Link Solution Pattern](https://www.solutionpatterns.io/soln-pattern-connectivity-link/) tutorials. These are:
- **Not deployed by default** - They are additive to the base deployment
- **Tutorial-focused** - Designed for learning specific use cases
- **Independently managed** - Deploy/remove without affecting base infrastructure

**Available Solutions**:
- **platform-engineer-workflow**: DNSPolicy + RateLimitPolicy for Platform Engineer persona
  - Tutorial: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html
  - Deploys: DNSPolicy targeting Gateway `prod-web`, RateLimitPolicy for echo-api HTTPRoute
- **developer-workflow**: HTTPRoute + AuthPolicy + RateLimitPolicy for ProductInfo API (Application Developer persona)
  - Tutorial: Gateway API HTTPRoute demonstration with HTTP 404/403/401 error progression
  - Deploys:
    - HTTPRoute for globex-mobile-gateway with path-based routing (`/mobile/services/category/list`, `/mobile/services/product/category/*`)
    - AuthPolicy with Keycloak JWT authentication
    - RateLimitPolicy (100 requests per 10s per user)
  - **Prerequisites**:
    - `GLOBEX_MOBILE_GATEWAY` must be set to Gateway API URL (not Route URL)
    - OAuth login must work (RHBK 26 compatible image + Keycloak CORS configured)
  - **Testing Progression** (demonstrates Gateway API security layers):
    1. **HTTP 404** (no HTTPRoute): Click "Categories" → Red banner "Not Found"
    2. **HTTP 401** (HTTPRoute + AuthPolicy deployed): Click "Categories" → "Unauthorized"
    3. **HTTP 200** (after login): Login → Click "Categories" → Products load successfully
  - **Full Deployment** (HTTPRoute + AuthPolicy together):
    ```bash
    ./scripts/solutions.sh deploy developer-workflow
    # Deploys both HTTPRoute and AuthPolicy via kustomize
    ```

**Usage**:
```bash
# List available solutions
./scripts/solutions.sh list

# Deploy platform-engineer-workflow tutorial resources
./scripts/solutions.sh deploy platform-engineer-workflow

# Deploy developer-workflow tutorial resources
./scripts/solutions.sh deploy developer-workflow

# Check status
./scripts/solutions.sh status platform-engineer-workflow

# Remove resources
./scripts/solutions.sh delete developer-workflow
```

**See**: `solutions/README.md` for detailed documentation

## Quick Verification

```bash
# ArgoCD Applications
oc get application.argoproj.io -n openshift-gitops | grep -E "globex|rhbk|ingress-gateway|echo-api|apicurio"

# Globex health (should be 4 deployments, all 1/1 Ready)
oc get deployment -n globex-apim-user1
oc get route -n globex-apim-user1

# Gateway status
oc get gateway -n ingress-gateway -o custom-columns=NAME:.metadata.name,HOSTNAME:.spec.listeners[0].hostname

# HTTPRoutes
oc get httproute -A

# DNS infrastructure (ACK Route53 - base)
oc get hostedzone -n ack-system
oc get recordset -n ack-system

# Optional: DNSPolicy (if solution deployed)
oc get dnspolicy -n ingress-gateway
oc get dnsrecord.kuadrant.io -n ingress-gateway

# RHBK 26
oc get keycloak -n keycloak
oc get deployment -n keycloak

# Apicurio Studio
oc get apicurioregistry3 -n apicurio
oc get route -n apicurio
```

## Critical Architecture Decisions

### DNS Management
- **Base (Required)**: ACK Route53 Controller for subdomain delegation
  - Creates HostedZone for `globex.<cluster-domain>`
  - Creates NS RecordSet in parent zone
  - Deployed by default in `kustomize/` manifests
- **Optional (Tutorial)**: Kuadrant DNSPolicy for automated DNS
  - Automatically creates CNAME records for HTTPRoutes
  - Wildcard DNS: `*.globex.<cluster-domain>` → Load Balancer
  - Available in `solutions/platform-engineer/`
  - **NOT deployed by default** - Use `./scripts/solutions.sh deploy platform-engineer`
- **Why separate?**: Base provides production subdomain delegation, DNSPolicy is tutorial-specific for automated record management
- **Details**: `docs/deployment/dns-delegation-testing.md`

### Gateway Hostname Pattern
- **Uses**: Specific hostname `echo.globex.<cluster-domain>` (NOT wildcard)
- **Why**: Avoids cert-manager #5751 wildcard CNAME + DNS-01 race condition
- **Details**: `docs/architecture/gateway-hostname-decision.md`

### RHBK 26 Compatibility
- **Requires**: OAuth 2.0 Authorization Code Flow + PKCE
- **Removed**: Implicit Flow (deprecated in RHBK 26)
- **Custom images**: globex-mobile with Code Flow implementation (v3)
- **Details**: `docs/deployment/rhbk-26-compatibility.md`

**Critical Keycloak Configuration (`keycloak-keycloakrealmimport-globex-user1.yaml`):**
- `webOrigins`: Must include frontend URL + "+" for CORS
  ```yaml
  webOrigins:
    - "https://globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com"
    - "+"  # Allows origins from redirectUris
  ```
- `optionalClientScopes`: Must NOT include `offline_access` (causes token exchange errors)
  ```yaml
  optionalClientScopes:
    - address
    - phone
    - microprofile-jwt
    # offline_access REMOVED - frontend v3 doesn't request it
  ```
- `pkce.code.challenge.method`: Must be `S256` in client attributes

**Critical globex-mobile Deployment Configuration:**
- **Image**: Must use `rhbk26-authcode-flow-v3` (both init and main container)
- **GLOBEX_MOBILE_GATEWAY**:
  - For developer-workflow demo (HTTP 404): `https://globex-mobile.globex.sandbox3491.opentlc.com` (Gateway API URL)
  - For production: `https://globex-mobile-gateway-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com` (Route URL)
- **Init container SSO_AUTHORITY**: PostSync Job patches this, but verify it's not "placeholder"
  ```bash
  oc get deployment globex-mobile -n globex-apim-user1 \
    -o jsonpath='{.spec.template.spec.initContainers[0].env[0].value}'
  # Should return: https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1
  # NOT: placeholder
  ```
- **Browser cache**: After Keycloak configuration changes, test in incognito/private window to avoid CORS cache issues

### Globex Architecture
- **Pattern**: Monolith (NOT microservices)
- **Components**: 1 DB + 1 backend API + 1 frontend + 1 mobile gateway
- **Why**: Red Hat's official pattern, simpler deployment
- **Details**: `docs/comparisons/red-hat-differences.md`

## Common Issues → Quick Links

| Issue | Documentation |
|-------|--------------|
| Globex pods not ready | `docs/operations/troubleshooting.md#globex-pods-not-ready` |
| Gateway hostname not patched | `docs/operations/troubleshooting.md#gateway-hostname-not-updated` |
| RHBK 26 OAuth errors | `docs/deployment/rhbk-26-compatibility.md` |
| Apicurio deployment issues | `docs/deployment/apicurio-deployment.md` |
| DNS not resolving | `docs/operations/troubleshooting.md#dns-not-resolving` |
| Certificate issues | `docs/operations/troubleshooting.md#tls-certificate-issues` |

**Full troubleshooting guide**: `docs/operations/troubleshooting.md`

## Documentation Index

### Deployment Guides
- `docs/deployment/rhbk-26-compatibility.md` - RHBK 26 migration and OAuth configuration
- `docs/deployment/apicurio-deployment.md` - Apicurio Studio deployment details
- `docs/deployment/dns-delegation-testing.md` - DNS testing and verification
- `docs/deployment/ingress-gateway-ansible.md` - Ingress gateway alignment with ansible

### Architecture References
- `docs/architecture/components.md` - Detailed component descriptions (coming soon)
- `docs/architecture/gateway-hostname-decision.md` - Gateway hostname pattern rationale (coming soon)
- `docs/architecture/job-management.md` - PostSync Job execution details (coming soon)

### Operations
- `docs/operations/troubleshooting.md` - Complete troubleshooting guide
- `docs/operations/verification.md` - Deployment verification steps (coming soon)

### Comparisons with Red Hat Demo
- `docs/comparisons/gap-analysis.md` - Gap analysis vs Red Hat Connectivity Link demo
- `docs/comparisons/red-hat-differences.md` - Key differences summary
- `docs/comparisons/ansible-vs-gitops.md` - Ansible playbook comparison (in `/tmp`)

### Reference
- `docs/reference/security.md` - Security best practices (coming soon)
- `docs/reference/prerequisites.md` - Detailed prerequisites (coming soon)
- `docs/reference/configuration.md` - Configuration details (coming soon)
- `SECURITY.md` - Secret management and security guidelines
- `README.md` - User-facing documentation

## When to Read Which Doc

**Deploying fresh cluster**:
1. Review prerequisites in this file
2. Follow deployment steps (automated via `scripts/deploy.sh`)

**Troubleshooting deployment**:
1. Check `docs/operations/troubleshooting.md`
2. For RHBK 26 issues → `docs/deployment/rhbk-26-compatibility.md`
3. For Apicurio issues → `docs/deployment/apicurio-deployment.md`

**Understanding architecture**:
1. Review "Key Components" section above
2. For DNS details → `docs/deployment/dns-delegation-testing.md`
3. For comparisons with Red Hat → `docs/comparisons/gap-analysis.md`

**Modifying deployment**:
1. Follow YAML ordering rules (top of this file)
2. Check relevant component in architecture docs
3. Test changes in dev environment first

## Critical Constraints

- **RHBK 26**: Requires Authorization Code Flow + PKCE (NO Implicit Flow)
- **Gateway hostname**: Specific hostname required (wildcard causes cert-manager race)
- **DNS management**: ACK Route53 (NOT Kuadrant DNSPolicy)
- **Globex architecture**: Monolith (NOT microservices)
- **Job management**: PostSync hooks for runtime patching
- **ArgoCD**: ignoreDifferences for runtime-patched fields

## Related Projects

- [ocp-open-env-install-tool](https://github.com/lautou/ocp-open-env-install-tool) - Dynamic configuration injection pattern
- [connectivity-link-ansible](https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible) - Original Ansible approach
- [cl-install-helm](https://github.com/rh-soln-pattern-connectivity-link/cl-install-helm) - Helm chart for echo-api

## File Naming Convention

All Kubernetes manifests follow: `<namespace>-<kind>-<name>.yaml`

Examples:
- `cluster-gatewayclass-istio.yaml` - Cluster-scoped resources use `cluster-` prefix
- `ingress-gateway-gateway-prod-web.yaml` - Namespaced: `<namespace>-<kind>-<name>`
- `globex-deployment-globex-db.yaml` - Deployment in globex namespace
- `openshift-gitops-job-aws-credentials.yaml` - Job in openshift-gitops namespace
