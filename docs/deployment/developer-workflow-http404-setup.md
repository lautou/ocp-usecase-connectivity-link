# Developer Workflow HTTP 404 Demonstration Setup

This document describes all configuration changes required to demonstrate the developer-workflow HTTP 404 error scenario.

## Goal

Demonstrate that without an HTTPRoute for the ProductInfo API, the frontend displays a proper HTTP 404 error banner when clicking "Categories".

## Prerequisites

✅ All base infrastructure deployed (Gateway, Keycloak, Globex)
✅ OAuth login working with RHBK 26

## Critical Configuration Changes

### 1. Custom Image (rhbk26-authcode-flow-v3)

**File**: `kustomize/globex/globex-deployment-globex-mobile.yaml`

**Changes**:
```yaml
initContainers:
  - name: patch-placeholder
    image: quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3  # Changed from v2

containers:
  - name: globex-mobile
    image: quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3  # Changed from v2
    env:
      - name: GLOBEX_MOBILE_GATEWAY
        value: https://globex-mobile.globex.sandbox3491.opentlc.com  # Gateway API URL (NOT Route URL)
```

**Why**:
- v3 removes `offline_access` scope requests
- v3 prevents Keycloak token exchange errors
- Gateway API URL ensures traffic goes through Gateway (not direct Route)

**Build instructions**: See `container-images/globex-web/README.globex-mobile.md`

### 2. Keycloak Realm Configuration

**File**: `kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml`

**Changes**:

#### a) CORS Configuration (globex-mobile client)
```yaml
webOrigins:
  - "https://globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com"
  - "+"  # Allow origins from redirectUris
```

**Before**: `["*"]` (wildcard doesn't work reliably for token endpoint)

#### b) Remove offline_access Scope
```yaml
optionalClientScopes:
  - address
  - phone
  - microprofile-jwt
  # offline_access REMOVED
```

**Before**: Included `offline_access` which frontend requested but Keycloak rejected

**Why**: Keycloak error responses don't include CORS headers, causing browser to block and report as CORS error

### 3. Init Container SSO_AUTHORITY Patching

**Issue**: PostSync Job (`openshift-gitops-job-globex-env.yaml`) patches main container but not init container `SSO_AUTHORITY`.

**Current Job**:
```yaml
oc patch deployment globex-mobile -n globex-apim-user1 --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/initContainers/0/env/0/value", "value": "'"${KEYCLOAK_URL}"'"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/env/4/value", "value": "'"${KEYCLOAK_URL}"'"},
  ...
]'
```

**Verification**:
```bash
oc get deployment globex-mobile -n globex-apim-user1 \
  -o jsonpath='Init: {.spec.template.spec.initContainers[0].env[0].value}{"\n"}'

# Should return: https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1
# NOT: placeholder
```

**Manual fix if needed**:
```bash
oc patch deployment globex-mobile -n globex-apim-user1 --type=json -p='[
  {"op": "replace",
   "path": "/spec/template/spec/initContainers/0/env/0/value",
   "value":"https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1"}
]'
```

## Deployment Steps

### Step 1: Build and Push Custom Image (if not already done)

```bash
cd container-images/globex-web

podman build -f Containerfile.globex-mobile \
  -t quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3 .

podman login quay.io
podman push quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3
```

### Step 2: Update Keycloak Configuration

```bash
# Update kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml
# (See section 2 above for required changes)

# Apply changes
oc delete keycloakrealmimport globex-user1 -n keycloak
oc apply -f kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml

# Wait for realm import to complete
oc get job globex-user1 -n keycloak -w
```

### Step 3: Restart Keycloak (to pick up configuration)

```bash
oc rollout restart statefulset/keycloak -n keycloak
oc rollout status statefulset/keycloak -n keycloak --timeout=3m
```

### Step 4: Update globex-mobile Deployment

```bash
# Update both containers to use v3 image
oc set image deployment/globex-mobile \
  globex-mobile=quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3 \
  -n globex-apim-user1

oc patch deployment globex-mobile -n globex-apim-user1 --type='json' -p='[
  {"op": "replace",
   "path": "/spec/template/spec/initContainers/0/image",
   "value":"quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v3"}
]'

# Set Gateway API URL
oc set env deployment/globex-mobile -n globex-apim-user1 \
  GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.sandbox3491.opentlc.com

# Wait for rollout
oc rollout status deployment/globex-mobile -n globex-apim-user1 --timeout=3m
```

### Step 5: Verify Init Container SSO_AUTHORITY

```bash
oc get deployment globex-mobile -n globex-apim-user1 \
  -o jsonpath='Init SSO_AUTHORITY: {.spec.template.spec.initContainers[0].env[0].value}{"\n"}'

# If shows "placeholder", apply manual fix (see section 3 above)
```

## Testing

### Test 1: OAuth Login

**Use incognito/private window** to avoid browser CORS cache:

```
https://globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
```

1. Click "Login"
2. Should redirect to Keycloak (no `unauthorized_client` error)
3. Login with `user1/openshift`
4. Should successfully log in and redirect back
5. Should show "Logout" button (logged in state)

**Network tab verification**:
- POST to `/realms/globex-user1/protocol/openid-connect/token` → HTTP 200 ✅
- Response has `access-control-allow-origin` header ✅
- No CORS errors ✅

### Test 2: HTTP 404 Error Display (No HTTPRoute)

**Verify HTTPRoute does NOT exist**:
```bash
oc get httproute -n globex-apim-user1
# Should return: No resources found
```

**Test**:
1. Login to frontend (incognito window)
2. Click "Categories" button
3. **Expected result**: Red error banner displays:
   - "We are sorry, but an error has occurred."
   - "Error Status Code: 404"
   - "Error Status Text: Not Found"

**Network tab**:
```
GET https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
→ HTTP 404 Not Found
```

### Test 3: HTTP 403 Error Display (HTTPRoute + AuthPolicy)

**Deploy developer-workflow HTTPRoute**:
```bash
./scripts/solutions.sh deploy developer-workflow
```

**Test**:
1. Refresh page
2. Click "Categories" button
3. **Expected result**: Error (HTTP 403 Forbidden)
   - Gateway has deny-by-default AuthPolicy
   - HTTPRoute exists but no AuthPolicy allows the request

**Network tab**:
```
GET https://globex-mobile.globex.sandbox3491.opentlc.com/mobile/services/category/list
→ HTTP 403 Forbidden
```

**Next tutorial step**: Add AuthPolicy to allow authenticated requests (see Red Hat tutorial)

## Troubleshooting

### Issue: CORS errors on token endpoint

**Symptoms**:
- Network tab shows: "CORS Missing Allow Origin" for POST to `/token`
- Login flow fails after Keycloak redirect

**Causes**:
1. Keycloak `webOrigins` not updated
2. Keycloak pod not restarted
3. Realm not re-imported
4. Browser CORS cache

**Fix**:
```bash
# 1. Verify Keycloak configuration
oc get keycloakrealmimport globex-user1 -n keycloak \
  -o jsonpath='{.spec.realm.clients[?(@.clientId=="globex-mobile")].webOrigins}'
# Should return: ["https://globex-mobile-globex-apim-user1.apps...","+"]

# 2. Restart Keycloak
oc rollout restart statefulset/keycloak -n keycloak

# 3. Re-import realm
oc delete keycloakrealmimport globex-user1 -n keycloak
oc apply -f kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml

# 4. Test in fresh incognito window
```

### Issue: No HTTP 404 error banner, categories load successfully

**Symptoms**:
- Categories page shows products instead of error
- Network tab shows HTTP 200 for category list

**Cause**: GLOBEX_MOBILE_GATEWAY points to Route URL (bypasses Gateway)

**Fix**:
```bash
# Check current value
oc get deployment globex-mobile -n globex-apim-user1 \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GLOBEX_MOBILE_GATEWAY")].value}'

# Should be Gateway API URL:
# https://globex-mobile.globex.sandbox3491.opentlc.com

# If shows Route URL (.apps.), update:
oc set env deployment/globex-mobile -n globex-apim-user1 \
  GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.sandbox3491.opentlc.com
```

### Issue: Init container logs show "Apps domain: placeholder"

**Symptoms**:
```bash
oc logs -n globex-apim-user1 deployment/globex-mobile -c patch-placeholder
# Shows: Apps domain: placeholder
```

**Cause**: Init container SSO_AUTHORITY not patched by PostSync Job

**Fix**: See section 3 above for manual patch command

### Issue: "offline_access" errors in Keycloak logs

**Symptoms**:
```bash
oc logs -n keycloak keycloak-0 | grep offline_access
# Shows: "Offline tokens not allowed for the user or client"
```

**Cause**: Using old v2 image that still requests offline_access scope

**Fix**: Ensure using v3 image (see Step 4 above)

## Summary of File Changes

| File | Changes | Reason |
|------|---------|--------|
| `kustomize/globex/globex-deployment-globex-mobile.yaml` | Image: v2 → v3<br>GLOBEX_MOBILE_GATEWAY: Route URL → Gateway URL | Remove offline_access requests<br>Route traffic through Gateway |
| `kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml` | webOrigins: "*" → specific URL + "+"<br>Remove offline_access from scopes | Fix token endpoint CORS<br>Prevent token exchange errors |
| `container-images/globex-web/Containerfile.globex-mobile` | New file | Build v3 image with offline_access removed |
| `CLAUDE.md` | Document v3 image and requirements | Critical configuration reference |

## Verification Checklist

Before testing, verify:

- [ ] Custom image v3 built and pushed to Quay.io
- [ ] Deployment uses v3 image (both init and main container)
- [ ] GLOBEX_MOBILE_GATEWAY = Gateway API URL (not Route URL)
- [ ] Keycloak webOrigins includes frontend URL + "+"
- [ ] Keycloak optionalClientScopes does NOT include offline_access
- [ ] Keycloak pod restarted and realm re-imported
- [ ] Init container SSO_AUTHORITY = Keycloak URL (not "placeholder")
- [ ] HTTPRoute does NOT exist in globex-apim-user1 namespace
- [ ] Testing in incognito/private window

## Next Steps

1. **Test HTTP 404** (current state)
2. **Deploy HTTPRoute**: `./scripts/solutions.sh deploy developer-workflow`
3. **Test HTTP 403** (deny-by-default AuthPolicy blocks request)
4. **Create AuthPolicy** to allow authenticated requests (next tutorial step)
5. **Test successful product catalog loading**

## Related Documentation

- `container-images/globex-web/README.globex-mobile.md` - Custom image build instructions
- `solutions/developer-workflow/README.md` - Developer workflow tutorial
- `docs/deployment/rhbk-26-compatibility.md` - RHBK 26 OAuth configuration
- `CLAUDE.md` - Project configuration and critical rules
