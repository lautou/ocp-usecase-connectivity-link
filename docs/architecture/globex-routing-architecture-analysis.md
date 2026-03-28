# Globex Routing Architecture - Analysis & Gap vs Red Hat Tutorial

## Current Architecture Discovery

### What We Actually Have

**External Access Pattern**:
```
External User
  ↓
  OpenShift Route: globex-mobile-globex-apim-user1.apps.<domain>
  ↓
  globex-mobile Service (ClusterIP: 172.30.174.139)
  ↓
  globex-mobile Pod
    ↓ (server-side call)
    http://globex-mobile-gateway:8080 (internal Service DNS)
    ↓
    globex-mobile-gateway Service (ClusterIP: 172.30.28.134)
    ↓
    globex-mobile-gateway Pod
      ↓ (internal call)
      http://globex-store-app:8080 (internal Service DNS)
      ↓
      globex-store-app Service (ClusterIP: 172.30.244.210)
      ↓
      globex-store-app Pod (ProductCatalog backend)
```

**Key Findings**:

1. ✅ **OpenShift Routes** (traditional ingress) - NOT Gateway API
2. ✅ **All inter-service calls are internal** (ClusterIP Service DNS)
3. ❌ **NO HTTPRoutes** for Globex services
4. ❌ **NOT using Gateway API** for Globex application routing

**Evidence**:

```bash
$ oc get httproute -A
NAMESPACE     NAME       HOSTNAMES
echo-api      echo-api   ["echo.globex.sandbox3491.opentlc.com"]
# ↑ Only echo-api uses Gateway API

$ oc get route -n globex-apim-user1
NAME                    HOST/PORT
globex-mobile           globex-mobile-globex-apim-user1.apps...
globex-mobile-gateway   globex-mobile-gateway-globex-apim-user1.apps...
# ↑ Globex uses OpenShift Routes

$ oc get deployment globex-mobile -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.[] | select(.name | contains("GATEWAY"))'
{
  "name": "GLOBEX_MOBILE_GATEWAY",
  "value": "http://globex-mobile-gateway:8080"  # ← Internal Service DNS
}
```

---

## Red Hat Tutorial Expected Architecture

**Reference**: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.2-developer.html

### Tutorial Scenario: Developer Persona

**Goal**: Demonstrate that external services REQUIRE HTTPRoutes to be accessible via Gateway API.

**Expected Architecture**:

```
External User
  ↓
  Gateway API (prod-web: *.globex.<domain>)
  ↓
  HTTPRoute: globex-mobile ← Exists, access works ✅
  ↓
  globex-mobile Service
  ↓
  globex-mobile Pod
    ↓ (calls via Gateway API)
    https://globex-mobile-gateway.globex.<domain>
    ↓
    Gateway API (prod-web)
    ↓
    HTTPRoute: globex-mobile-gateway ← Exists, access works ✅
    ↓
    globex-mobile-gateway Service
    ↓
    globex-mobile-gateway Pod
      ↓ (calls via Gateway API)
      https://product-catalog.globex.<domain>  ← NEW SERVICE
      ↓
      Gateway API (prod-web)
      ↓
      HTTPRoute: product-catalog ← MISSING initially = 404 ❌
      ↓
      (Developer creates HTTPRoute)
      ↓
      HTTPRoute: product-catalog ← Now exists = 200 ✅
      ↓
      product-catalog Service (globex-store-app)
```

**Tutorial Flow**:

1. **Developer deploys ProductCatalog service**
2. **NO HTTPRoute created** initially
3. **Access fails with 404** (Gateway doesn't know how to route)
4. **Developer creates HTTPRoute** for ProductCatalog
5. **Access now works** (Gateway routes to ProductCatalog Service)

**Learning Objective**: HTTPRoutes are REQUIRED to expose services via Gateway API

---

## Why Our Architecture Doesn't Show 404 Errors

### Root Cause: We're NOT Using Gateway API for Globex

**Reason 1: OpenShift Routes Instead of HTTPRoutes**

We're using OpenShift's traditional ingress (Routes), not Gateway API:

```yaml
# We have this (OpenShift Route):
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  host: globex-mobile-globex-apim-user1.apps.<domain>
  to:
    kind: Service
    name: globex-mobile

# Red Hat tutorial expects this (Gateway API HTTPRoute):
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.<domain>
  rules:
    - backendRefs:
        - name: globex-mobile
          port: 8080
```

**Reason 2: Internal Service-to-Service Communication**

All Globex services communicate using **internal Kubernetes Service DNS**:

```
globex-mobile → http://globex-mobile-gateway:8080 (internal)
globex-mobile-gateway → http://globex-store-app:8080 (internal)
```

This is **east-west traffic** (service-to-service), NOT **north-south traffic** (external → service).

**East-West Traffic**:
- Stays within cluster
- Uses Kubernetes Service networking
- Doesn't go through Gateway API
- NO HTTPRoute needed
- NO 404 errors possible (Service DNS always resolves)

**North-South Traffic** (what the tutorial expects):
- External → Gateway API → HTTPRoute → Service
- HTTPRoute required for routing
- Missing HTTPRoute = 404 error

---

## Why This Architecture Gap Exists

### Red Hat Tutorial Assumptions

1. **All external access** goes through Gateway API
2. **All service-to-service calls** also go through Gateway API (north-south pattern)
3. **HTTPRoutes required** for ALL externally-accessible services
4. **Demonstrates API Management** (rate limiting, auth) at Gateway level

### Our Current Implementation

1. **External access** via OpenShift Routes (traditional)
2. **Service-to-service calls** via internal ClusterIP Services (east-west pattern)
3. **NO Gateway API** used for Globex routing
4. **API Management** (AuthPolicy, RateLimitPolicy) NOT applied to Globex

**Why We Did This**:

- **Ansible playbook** (our reference) uses OpenShift Routes
- **Simpler to deploy** (no HTTPRoute + ReferenceGrant complexity)
- **Works correctly** (functionality is identical)
- **BUT**: Doesn't demonstrate Gateway API patterns

---

## Correct Architecture for Tutorial Scenario

### Option 1: Full Gateway API (Red Hat Tutorial Approach)

**Migrate ALL Globex routing to Gateway API**:

#### Step 1: Create HTTPRoute for globex-mobile

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: globex-mobile
          port: 8080
```

#### Step 2: Create ReferenceGrant (cross-namespace access)

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: globex-to-gateway
  namespace: ingress-gateway
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: globex-apim-user1
  to:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: prod-web
```

#### Step 3: Create HTTPRoute for globex-mobile-gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile-gateway.globex.sandbox3491.opentlc.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: globex-mobile-gateway
          port: 8080
```

#### Step 4: Update globex-mobile to call gateway via HTTPRoute

**Change environment variable**:

```yaml
# OLD (internal call):
- name: GLOBEX_MOBILE_GATEWAY
  value: http://globex-mobile-gateway:8080

# NEW (via Gateway API):
- name: GLOBEX_MOBILE_GATEWAY
  value: https://globex-mobile-gateway.globex.sandbox3491.opentlc.com
```

#### Step 5: Demonstrate HTTPRoute Necessity

**5a. Deploy globex-store-app Service (NO HTTPRoute)**

```bash
oc apply -f globex-deployment-globex-store-app.yaml
oc apply -f globex-service-globex-store-app.yaml
# NO HTTPRoute created yet
```

**5b. Try to access externally → 404**

```bash
curl -k https://globex-store-app.globex.sandbox3491.opentlc.com/catalog/category/list
# Expected: 404 Not Found (no HTTPRoute configured)
```

**5c. Create HTTPRoute for globex-store-app**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-store-app
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-store-app.globex.sandbox3491.opentlc.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: globex-store-app
          port: 8080
```

**5d. Access now works → 200**

```bash
curl -k https://globex-store-app.globex.sandbox3491.opentlc.com/catalog/category/list
# Expected: 200 OK with categories JSON
```

**5e. Update globex-mobile-gateway to call via HTTPRoute**

```yaml
# OLD (internal call):
- name: GLOBEX_STORE_APP_URL
  value: http://globex-store-app:8080

# NEW (via Gateway API):
- name: GLOBEX_STORE_APP_URL
  value: https://globex-store-app.globex.sandbox3491.opentlc.com
```

**Result**: Now ALL calls go through Gateway API, demonstrating HTTPRoute necessity.

---

### Option 2: Hybrid Approach (Recommended for Production)

**Gateway API for North-South, ClusterIP for East-West**:

#### North-South (External → Service)

Use Gateway API + HTTPRoute:

```
External User
  → Gateway API (prod-web)
    → HTTPRoute: globex-mobile
      → globex-mobile Service
```

**Benefits**:
- TLS termination at Gateway
- Rate limiting via RateLimitPolicy
- Authentication via AuthPolicy
- Centralized ingress management

#### East-West (Service → Service)

Use internal ClusterIP Services (current approach):

```
globex-mobile Pod
  → http://globex-mobile-gateway:8080 (internal DNS)
    → globex-mobile-gateway Service (ClusterIP)
      → http://globex-store-app:8080 (internal DNS)
        → globex-store-app Service (ClusterIP)
```

**Benefits**:
- Lower latency (no extra Gateway hop)
- Simpler configuration (no ReferenceGrant needed)
- Standard Kubernetes networking pattern
- Reduced attack surface (internal services not exposed)

**This is the CORRECT production architecture!**

---

## Tutorial Demonstration: How It SHOULD Work

### Scenario: Developer Adds New ProductDetails Service

**Goal**: Show that HTTPRoute is required for external access.

#### Step 1: Deploy Service WITHOUT HTTPRoute

```bash
oc apply -f product-details-deployment.yaml
oc apply -f product-details-service.yaml
```

#### Step 2: Try External Access → 404

```bash
$ curl -k https://product-details.globex.sandbox3491.opentlc.com/details/1
404 Not Found  # ← Gateway has no route configured
```

#### Step 3: Create HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: product-details
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - product-details.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: product-details
          port: 8080
```

```bash
oc apply -f product-details-httproute.yaml
```

#### Step 4: Access Now Works → 200

```bash
$ curl -k https://product-details.globex.sandbox3491.opentlc.com/details/1
{"id": 1, "name": "Quarkus T-Shirt", ...}  # ← Works!
```

**Learning**: HTTPRoute required for Gateway API routing.

---

## Architectural Recommendations

### For Tutorial Demonstration

✅ **Use Option 1** (Full Gateway API) to demonstrate:
- HTTPRoute necessity
- ReferenceGrant for cross-namespace access
- AuthPolicy and RateLimitPolicy at Gateway level
- TLSPolicy for automatic certificates

**Trade-offs**:
- ⚠️ Higher latency (extra Gateway hops)
- ⚠️ More complex configuration
- ⚠️ All internal calls go through Gateway (unnecessary)
- ✅ Clear demonstration of Gateway API patterns

### For Production Deployment

✅ **Use Option 2** (Hybrid Approach):
- Gateway API for external access ONLY
- Internal ClusterIP for service-to-service calls
- Apply API management policies at Gateway level

**Benefits**:
- ✅ Lower latency
- ✅ Standard Kubernetes patterns
- ✅ Reduced attack surface
- ✅ Simpler troubleshooting

**Example**:

```yaml
# Expose to external users via Gateway API
External → Gateway → HTTPRoute(globex-mobile) → globex-mobile

# Internal service calls stay internal
globex-mobile → ClusterIP(globex-mobile-gateway) → globex-mobile-gateway
globex-mobile-gateway → ClusterIP(globex-store-app) → globex-store-app
```

---

## Current State vs Desired State

| Aspect | Current State | Red Hat Tutorial | Recommended Production |
|--------|---------------|------------------|----------------------|
| **External Access** | OpenShift Routes | Gateway API + HTTPRoute | Gateway API + HTTPRoute |
| **Service-to-Service** | Internal ClusterIP | Gateway API (hairpin) | Internal ClusterIP |
| **Tutorial 404 Demo** | ❌ Not possible | ✅ Works as intended | ⚠️ Only for new external services |
| **Latency** | ✅ Low | ❌ High (extra hops) | ✅ Low |
| **Complexity** | ✅ Simple | ⚠️ Complex | ✅ Moderate |
| **API Management** | ❌ Not applied | ✅ At Gateway | ✅ At Gateway (external only) |
| **Attack Surface** | ⚠️ All services exposed | ⚠️ All services exposed | ✅ Only public services exposed |

---

## Action Items

### To Align with Red Hat Tutorial (Option 1)

1. ✅ Create HTTPRoutes for globex-mobile and globex-mobile-gateway
2. ✅ Create ReferenceGrant for cross-namespace access
3. ✅ Update environment variables to use Gateway hostnames
4. ✅ Apply AuthPolicy and RateLimitPolicy at HTTPRoute level
5. ✅ Delete OpenShift Routes (migrate to Gateway API)
6. ✅ Demonstrate 404 error with missing HTTPRoute for new service

**Outcome**: 100% alignment with tutorial, demonstrates HTTPRoute necessity

### To Implement Production-Ready Architecture (Option 2)

1. ✅ Create HTTPRoute ONLY for globex-mobile (user-facing)
2. ✅ Keep internal service calls using ClusterIP
3. ✅ Apply AuthPolicy at globex-mobile HTTPRoute
4. ✅ Apply RateLimitPolicy at globex-mobile HTTPRoute
5. ❌ Do NOT expose globex-store-app externally
6. ❌ Do NOT route internal calls through Gateway

**Outcome**: Best practice architecture for production

---

## Conclusion

**Why you don't see 404 errors**:

1. ✅ We're using **OpenShift Routes**, not Gateway API HTTPRoutes
2. ✅ **All service calls are internal** (ClusterIP), not through Gateway
3. ✅ **No external access to globex-store-app** is attempted

**Why the tutorial expects 404 errors**:

1. ❌ Tutorial assumes **ALL access** goes through Gateway API
2. ❌ Tutorial expects **missing HTTPRoute** = 404 error
3. ❌ Tutorial demonstrates HTTPRoute is **required for routing**

**Correct Architecture**:

The **Hybrid Approach (Option 2)** is the correct production architecture:
- Use Gateway API for north-south traffic (external → service)
- Use ClusterIP for east-west traffic (service → service)
- Only expose user-facing services via HTTPRoute
- Keep internal services private

**For Tutorial Demonstration**: Use Option 1 (Full Gateway API) to show HTTPRoute necessity, but understand this is for DEMONSTRATION purposes, not production recommendation.

---

**Last Updated**: 2026-03-28
**Current Architecture**: OpenShift Routes + Internal ClusterIP
**Tutorial Architecture**: Full Gateway API (all traffic through Gateway)
**Recommended Architecture**: Hybrid (Gateway for external, ClusterIP for internal)
