# Developer Workflow - Gateway API HTTPRoute Demo

## Purpose

Demonstrates application developer workflow: exposing backend ProductInfo service (globex-mobile-gateway) via Gateway API HTTPRoute with path-based routing.

**This is an optional tutorial component** - not deployed by default.

**Tutorial persona**: Application Developer

## What This Deploys

1. **HTTPRoute** for ProductInfo API:
   - **Hostname:** `globex-mobile.globex.sandbox3491.opentlc.com`
   - **Paths:**
     - `GET /mobile/services/product/category/*` → globex-mobile-gateway
     - `GET /mobile/services/category/list` → globex-mobile-gateway

2. **AuthPolicy** for JWT authentication:
   - **Issuer:** Keycloak (`https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1`)
   - **Extracts:** User ID from JWT `sub` claim
   - **Blocks:** Unauthenticated requests (HTTP 401)

3. **RateLimitPolicy** for API protection:
   - **Limit:** 100 requests per 10 seconds
   - **Per:** Authenticated user (based on `auth.identity.userid`)
   - **Response:** HTTP 429 Too Many Requests when exceeded

**No ReferenceGrant needed** - Gateway `prod-web` allows routes from all namespaces (`allowedRoutes.namespaces.from: All`)

## Architecture Pattern

This demonstrates **application developer workflow** with path-based routing:

```
https://globex-mobile.globex.sandbox3491.opentlc.com/
  │
  ├─ /mobile/services/product/category/* → globex-mobile-gateway (Gateway API)
  ├─ /mobile/services/category/list → globex-mobile-gateway (Gateway API)
  └─ /* (everything else) → No route (404 or frontend Route)
```

**Note:**
- Frontend UI remains on OpenShift Route (`globex-mobile-globex-apim-user1.apps.*`)
- Frontend internal communication uses ClusterIP (`http://globex-mobile-gateway:8080`) - unchanged
- This HTTPRoute provides external API access for testing/integration

## Expected Behavior

### Step 1: After HTTPRoute Deployment (Initial State)

```bash
# API endpoints accessible via Gateway API but blocked by deny-by-default AuthPolicy
curl -k https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
# → HTTP 403 Forbidden (AuthPolicy deny-by-default)

# Frontend UI still on Route
curl -k https://globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com/
# → HTTP 200 OK (frontend works)
```

### Step 2: After AuthPolicy Deployment (Next Tutorial Step)

Apply the AuthPolicy to allow authenticated requests:

```bash
oc apply -f solutions/developer-workflow/globex-apim-user1-authpolicy-globex-mobile-gateway.yaml
```

Now API calls with valid JWT tokens will succeed:

```bash
# Get access token from frontend (after login)
# Call API with Authorization header
curl -k -H "Authorization: Bearer $TOKEN" \
  https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
# → HTTP 200 OK (authenticated request allowed)
```

**In the browser:**
- Login to frontend
- Click "Categories"
- Should load products successfully (HTTP 200) instead of HTTP 403

**Why 403?** Gateway `prod-web` has deny-by-default AuthPolicy. Next tutorial step: add AuthPolicy for this HTTPRoute.

## Deployment

### Option 1: Using solutions.sh script (Recommended)

```bash
# Deploy
./scripts/solutions.sh deploy developer-workflow

# Check status
./scripts/solutions.sh status developer-workflow

# Remove
./scripts/solutions.sh delete developer-workflow
```

### Option 2: Using kubectl/oc directly

```bash
# Deploy
oc apply -k solutions/developer-workflow/

# Verify
oc get httproute globex-mobile-gateway -n globex-apim-user1

# Remove
oc delete -k solutions/developer-workflow/
```

### Option 3: Using ArgoCD (GitOps)

```bash
# Create ArgoCD Application
oc apply -f argocd/application-solutions-developer-workflow.yaml

# Sync
argocd app sync solutions-developer-workflow

# Check status
argocd app get solutions-developer-workflow
```

## Verification

```bash
# Check HTTPRoute created
oc get httproute globex-mobile-gateway -n globex-apim-user1

# Check HTTPRoute attached to Gateway
oc describe httproute globex-mobile-gateway -n globex-apim-user1

# Check HTTPRoute status
oc get httproute globex-mobile-gateway -n globex-apim-user1 -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True

# Test endpoint (expect 403 from AuthPolicy)
curl -k https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
# Expected: HTTP 403 Forbidden

# Verify Gateway allows cross-namespace routes
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}'
# Expected: All
```

## Path Matching Behavior

| Request | Matches? | Backend |
|---------|----------|---------|
| `GET /mobile/services/product/category/123` | ✅ Yes | globex-mobile-gateway |
| `GET /mobile/services/product/category/` | ✅ Yes | globex-mobile-gateway |
| `GET /mobile/services/category/list` | ✅ Yes | globex-mobile-gateway |
| `GET /mobile/services/category` | ❌ No | 404 |
| `GET /mobile/services/product/123` | ❌ No | 404 |
| `POST /mobile/services/category/list` | ❌ No | 405 (method not allowed) |
| `GET /` | ❌ No | 404 |

**Note:** Only specific paths match. Method must be GET.

## Next Tutorial Steps

### 1. Add AuthPolicy to Allow Authenticated Access

**Current State:** HTTPRoute deployed, Gateway blocks all requests (HTTP 403)

**Apply AuthPolicy:**
```bash
# Deploy AuthPolicy to allow Keycloak JWT token authentication
oc apply -f solutions/developer-workflow/globex-apim-user1-authpolicy-globex-mobile-gateway.yaml
```

**What the AuthPolicy does:**
- Validates JWT tokens from Keycloak (`https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1`)
- Allows authenticated requests (HTTP 200)
- Blocks unauthenticated requests (HTTP 401)
- Extracts user ID from JWT `sub` claim for logging/monitoring

**Test after AuthPolicy deployment:**
```bash
# In browser:
# 1. Login to frontend (get JWT token in browser session)
# 2. Click "Categories" button
# 3. Should load products successfully (HTTP 200)

# Via curl (with token from browser):
curl -k -H "Authorization: Bearer $TOKEN" \
  https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
# Expected: HTTP 200 OK
```

**AuthPolicy spec:**
```yaml
spec:
  targetRef:
    kind: HTTPRoute
    name: globex-mobile-gateway
  rules:
    authentication:
      "keycloak-users":
        jwt:
          issuerUrl: https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1
    response:
      success:
        filters:
          identity:
            json:
              properties:
                userid:
                  selector: auth.identity.sub
```

### 2. (Optional) Add RateLimitPolicy to Protect API

```bash
# Example: Limit to 10 requests per minute per user
# Create your own RateLimitPolicy based on platform-engineer-workflow example
```

### 3. (Optional) Update Frontend to Use Gateway API URL

```bash
# Change frontend to call ProductInfo API via Gateway (cross-origin)
oc set env deployment/globex-mobile -n globex-apim-user1 \
  GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.sandbox3491.opentlc.com
```

**Note:** This is already configured for the HTTP 404 demonstration. Revert to Route URL if you want same-origin calls:
```bash
oc set env deployment/globex-mobile -n globex-apim-user1 \
  GLOBEX_MOBILE_GATEWAY=https://globex-mobile-gateway-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
```

## Troubleshooting

### HTTPRoute not attaching to Gateway

```bash
# Check HTTPRoute status
oc describe httproute globex-mobile-gateway -n globex-apim-user1

# Check Gateway allows routes from this namespace
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}'
# Should be: All
```

### 404 Not Found

```bash
# Verify HTTPRoute is attached
oc get httproute globex-mobile-gateway -n globex-apim-user1 -o yaml | grep -A 10 status

# Check exact path matching
curl -kv https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
```

### 403 Forbidden (Expected)

This is normal! Gateway `prod-web` has deny-by-default AuthPolicy. Add an AuthPolicy for this HTTPRoute in the next tutorial step.

## Removal

```bash
# Using solutions script
./scripts/solutions.sh delete developer-workflow

# Or manually
oc delete -k solutions/developer-workflow/

# Or via ArgoCD
oc delete -f argocd/application-solutions-developer-workflow.yaml
```

## See Also

- `docs/architecture/external-service-simulation.md` - ProductInfo service simulation rationale
- `solutions/platform-engineer-workflow/` - Platform Engineer tutorial (DNSPolicy)
- Red Hat Connectivity Link tutorial: https://www.solutionpatterns.io/soln-pattern-connectivity-link/
