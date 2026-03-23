# Custom Globex Web Container Image

This directory contains a custom build of the `globex-web` container image that fixes the OAuth authentication flow.

## Problem

The official `quay.io/cloud-architecture-workshop/globex-web:latest` image uses OAuth2 **Implicit Flow** which:
- Returns tokens directly in URL fragments (`#access_token=...`)
- **Does NOT create server-side sessions in Keycloak**
- Fails on `/userinfo` endpoint with `user_session_not_found` error
- Cannot maintain persistent login state

## Solution

This custom image patches the JavaScript bundle to use **Authorization Code Flow** which:
- Uses server-side token exchange (`response_type=code`)
- Creates proper Keycloak sessions
- Works correctly with `/userinfo` endpoint
- Maintains persistent login state

## Build and Push

```bash
# Navigate to this directory
cd container-images/globex-web

# Build the image (replace YOUR_USERNAME with your Quay.io username)
podman build -t quay.io/YOUR_USERNAME/globex-web:fixed .

# Login to Quay.io
podman login quay.io

# Push the image
podman push quay.io/YOUR_USERNAME/globex-web:fixed

# Tag as latest (optional)
podman tag quay.io/YOUR_USERNAME/globex-web:fixed quay.io/YOUR_USERNAME/globex-web:latest
podman push quay.io/YOUR_USERNAME/globex-web:latest
```

## Update Deployment

After building and pushing, update the deployment to use your custom image:

```bash
# Edit the deployment
oc edit deployment globex-web -n globex

# Change:
# image: quay.io/cloud-architecture-workshop/globex-web:latest
# To:
# image: quay.io/YOUR_USERNAME/globex-web:fixed
```

Or update the base YAML file:

```bash
# Edit kustomize/base/globex-deployment-globex-web.yaml
# Change the image field to your custom image
```

## Testing

After deploying the custom image:

1. **Clear browser cache and storage**:
   ```javascript
   // In browser console
   localStorage.clear();
   sessionStorage.clear();
   location.reload(true);
   ```

2. **Test login flow**:
   - Navigate to https://globex-web-globex.apps.YOUR_CLUSTER/home
   - Click "Login" button
   - Authenticate with Keycloak (user: asilva, password: openshift)
   - Should redirect back and show "Logout" button with username
   - Session should persist on page refresh

3. **Verify Keycloak logs** (should NOT show `user_session_not_found`):
   ```bash
   oc logs -n keycloak -l app=keycloak --tail=20 | grep -i "user_session_not_found"
   # Should return empty
   ```

4. **Check network traffic** in browser DevTools:
   - Authorization request should have `response_type=code` (NOT `response_type=token`)
   - Should see `/token` endpoint call (server-side token exchange)
   - `/userinfo` endpoint should return HTTP 200 with user profile

## Technical Details

The Containerfile performs these patches on the JavaScript bundle:

1. Replaces `response_type:"token"` → `response_type:"code"`
2. Replaces `response_type:"id_token token"` → `response_type:"code"`
3. Replaces `responseType:"token"` → `responseType:"code"`
4. Replaces `responseType:"id_token token"` → `responseType:"code"`

This changes the Angular OIDC client library configuration from Implicit Flow to Authorization Code Flow.

## Risks and Limitations

⚠️ **This is a fragile patch**:
- Modifies minified JavaScript using regex
- May break if upstream image changes
- Should be considered a **temporary workaround**

**Proper solution** would be:
1. Fork the globex-web source repository
2. Change OIDC configuration at build time
3. Maintain custom source code

## Alternative: Official Fix

Consider reporting this issue to Red Hat:
- Repository: https://github.com/rh-soln-pattern-connectivity-link/globex-helm
- The official solution pattern has the same issue
- Request they update the source code to use Authorization Code Flow

## Verification Commands

```bash
# Check if image is using Authorization Code Flow
podman run --rm quay.io/YOUR_USERNAME/globex-web:fixed sh -c \
  'grep -r "response_type" /opt/app-root/src/dist/globex-web/browser/ | head -5'

# Should show "code" instead of "token"
```
