# Custom Globex Mobile Container Image (RHBK 26 Compatible)

This directory contains a custom build of the `globex-mobile` container image that fixes OAuth authentication for RHBK 26.

## Problem

The official `quay.io/rh_soln_pattern_rhcl/globex-mobile:latest` image uses OAuth2 **Implicit Flow** which:
- Returns tokens directly in URL fragments (`#access_token=...`)
- Deprecated in RHBK 26
- Causes `unauthorized_client` error: "Client is not allowed to initiate browser login..."
- Requests `offline_access` scope which causes token exchange errors with missing CORS headers

## Solution (v3 Image)

This custom image (`rhbk26-authcode-flow-v3`) patches the JavaScript bundle to:
1. Use **Authorization Code Flow** (`response_type=code`)
2. Enable **PKCE** (required for public clients in RHBK 26)
3. **Remove offline_access scope** requests (prevents token exchange CORS errors)

## Build and Push

```bash
# Navigate to this directory
cd container-images/globex-web

# Build the image
podman build -f Containerfile.globex-mobile \
  -t quay.io/YOUR_USERNAME/globex-mobile:rhbk26-authcode-flow-v3 .

# Login to Quay.io
podman login quay.io

# Push the image
podman push quay.io/YOUR_USERNAME/globex-mobile:rhbk26-authcode-flow-v3
```

## Update Deployment

After building and pushing, update the deployment manifest:

```bash
# Edit kustomize/globex/globex-deployment-globex-mobile.yaml
# Change both init container and main container images:
# image: quay.io/YOUR_USERNAME/globex-mobile:rhbk26-authcode-flow-v3
```

Or manually update the running deployment:

```bash
oc set image deployment/globex-mobile \
  globex-mobile=quay.io/YOUR_USERNAME/globex-mobile:rhbk26-authcode-flow-v3 \
  -n globex-apim-user1

oc patch deployment globex-mobile -n globex-apim-user1 --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/initContainers/0/image",
        "value":"quay.io/YOUR_USERNAME/globex-mobile:rhbk26-authcode-flow-v3"}]'
```

## Required Keycloak Configuration

The custom image requires specific Keycloak client configuration in `keycloak-keycloakrealmimport-globex-user1.yaml`:

### 1. CORS Configuration

```yaml
webOrigins:
  - "https://globex-mobile-globex-apim-user1.apps.YOUR_CLUSTER"
  - "+"  # Keycloak special value: allow origins from redirectUris
```

**Why:** Wildcard `["*"]` doesn't work reliably for token endpoint CORS

### 2. Remove offline_access Scope

```yaml
optionalClientScopes:
  - address
  - phone
  - microprofile-jwt
  # offline_access REMOVED - v3 image doesn't request it
```

**Why:** Frontend requests this scope, Keycloak rejects it, error response has no CORS headers → appears as CORS error in browser

### 3. Enable PKCE

```yaml
attributes:
  pkce.code.challenge.method: S256
```

**Why:** Required for public clients using Authorization Code Flow in RHBK 26

## Testing

### Prerequisites

1. **Keycloak configuration updated** (see above)
2. **Keycloak pod restarted** to pick up configuration changes:
   ```bash
   oc rollout restart statefulset/keycloak -n keycloak
   ```
3. **Realm re-imported**:
   ```bash
   oc delete keycloakrealmimport globex-user1 -n keycloak
   oc apply -f kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml
   ```

### Test OAuth Login

1. **Use incognito/private window** (to avoid CORS cache):
   ```
   https://globex-mobile-globex-apim-user1.apps.YOUR_CLUSTER
   ```

2. **Click "Login" button**
   - Should redirect to Keycloak login page (no `unauthorized_client` error)

3. **Login with `user1/openshift`**
   - Should redirect back to frontend
   - Should show "Logout" button (logged in state)

4. **Check network tab** (no CORS errors):
   - Token endpoint POST should succeed (HTTP 200)
   - Should have `access-control-allow-origin` headers

### Test HTTP 404 Error Display

**Configure Gateway API URL** (to demonstrate HTTPRoute is missing):

```bash
oc set env deployment/globex-mobile -n globex-apim-user1 \
  GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.YOUR_CLUSTER
```

**Test:**
1. Login to frontend
2. Click "Categories" button
3. Should display **red error banner**:
   - "We are sorry, but an error has occurred."
   - "Error Status Code: 404"
   - "Error Status Text: Not Found"

**Deploy HTTPRoute** (next tutorial step):

```bash
./scripts/solutions.sh deploy developer-workflow
```

Now clicking "Categories" should show HTTP 403 Forbidden (deny-by-default AuthPolicy).

## Technical Details

The `Containerfile.globex-mobile` performs these patches on the JavaScript bundle:

### 1. Authorization Code Flow
```bash
# response_type:"token" → response_type:"code"
sed -i 's/response_type[:"'\'']*token[^"'\'']*"/response_type:"code"/g'
```

### 2. Enable PKCE
```bash
# usePkce:false → usePkce:true
sed -i 's/usePkce[:"'\'']*false/usePkce:true/g'

# usePkce:!1 → usePkce:!0 (minified code)
sed -i 's/usePkce:!1/usePkce:!0/g'
```

### 3. Remove offline_access Scope
```bash
# Remove from scope strings in various formats
sed -i 's/offline_access[[:space:]]*//g'
sed -i 's/+offline_access//g'
sed -i 's/offline_access+//g'
sed -i 's/%20offline_access//g'
sed -i 's/offline_access%20//g'
```

## Version History

### v3 (Current - RECOMMENDED)
- Authorization Code Flow ✅
- PKCE enabled ✅
- offline_access scope removed ✅
- **Works with RHBK 26** ✅
- **Proper error banner for HTTP 404** ✅

### v2 (Deprecated)
- Authorization Code Flow ✅
- PKCE enabled ✅
- offline_access scope still requested ❌
- **Caused token exchange CORS errors** ❌

### Official Image (Not compatible with RHBK 26)
- Implicit Flow (deprecated) ❌
- No PKCE ❌
- **Does NOT work with RHBK 26** ❌

## Risks and Limitations

⚠️ **This is a fragile patch**:
- Modifies minified JavaScript using regex
- May break if upstream image changes
- Should be considered a **temporary workaround**

**Proper solution** would be:
1. Fork the globex-mobile source repository
2. Update OIDC configuration in TypeScript source code
3. Build from source with proper OAuth Code Flow configuration
4. Maintain custom source code

## Troubleshooting

### Login fails with "unauthorized_client"
- **Cause**: Using old v1/v2 image or official image
- **Fix**: Ensure using v3 image in both init and main container

### CORS errors on token endpoint
- **Cause**: Keycloak `webOrigins` not configured or browser cache
- **Fix**:
  1. Update Keycloak configuration (see above)
  2. Restart Keycloak pod
  3. Re-import realm
  4. Test in fresh incognito window

### Init container logs show "Apps domain: placeholder"
- **Cause**: PostSync Job didn't patch init container SSO_AUTHORITY
- **Fix**: Manually patch:
  ```bash
  oc patch deployment globex-mobile -n globex-apim-user1 --type=json -p='[
    {"op": "replace",
     "path": "/spec/template/spec/initContainers/0/env/0/value",
     "value":"https://keycloak-keycloak.apps.YOUR_CLUSTER/realms/globex-user1"}
  ]'
  ```

### No HTTP 404 error banner displayed
- **Cause**: GLOBEX_MOBILE_GATEWAY pointing to Route URL (same origin, returns products successfully)
- **Fix**: Set to Gateway API URL to demonstrate missing HTTPRoute:
  ```bash
  oc set env deployment/globex-mobile -n globex-apim-user1 \
    GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.YOUR_CLUSTER
  ```

## Related Documentation

- `docs/deployment/rhbk-26-compatibility.md` - RHBK 26 migration guide
- `solutions/developer-workflow/README.md` - Developer workflow tutorial
- `CLAUDE.md` - Project configuration and critical rules
