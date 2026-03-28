# Globex Deployment - Critical Fixes Applied

## Overview

This document records all critical fixes that were necessary to make the Globex mobile application work correctly with RHBK 26 and the GitOps deployment.

**Status**: ✅ Working as of 2026-03-28

## Critical Issues Fixed

### 1. OAuth 2.0 Authorization Code Flow (RHBK 26 Compatibility)

**Problem**:
- Original globex-mobile used Implicit Flow (deprecated in RHBK 26)
- Application failed to authenticate users

**Solution**:
- Rebuilt globex-mobile with Authorization Code Flow + PKCE
- Custom image: `quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v2`

**Code changes in globex-mobile**:
```typescript
// src/app/auth/auth.service.ts
export const authCodeFlowConfig: AuthConfig = {
  issuer: this.ssoAuthority,
  redirectUri: window.location.origin,
  clientId: 'globex-mobile',
  responseType: 'code',           // Changed from 'id_token token'
  scope: 'openid profile email',
  showDebugInformation: false,
  useSilentRefresh: false
};
```

**References**:
- Image repository: https://quay.io/repository/laurenttourreau/globex-mobile
- Detailed fix: `docs/deployment/rhbk-26-compatibility.md`

---

### 2. JWT Token Audience Claim

**Problem**:
- Keycloak tokens did not include `aud` (audience) claim
- globex-mobile-gateway rejected tokens with error: "No Audience (aud) claim present"
- Categories API returned HTTP 500

**Solution - Step 1: Add Protocol Mapper in Keycloak**:

Modified `kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml`:

```yaml
clients:
  - clientId: globex-mobile
    # ... other config ...
    protocolMappers:
      - name: audience-mapper
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: globex-mobile
          access.token.claim: "true"
```

**Solution - Step 2: Configure OIDC Audience Validation**:

Modified `kustomize/globex/globex-deployment-globex-mobile-gateway.yaml`:

```yaml
env:
  - name: QUARKUS_OIDC_TOKEN_AUDIENCE
    value: globex-mobile
```

**Result**: JWT tokens now include `"aud": "globex-mobile"` claim

---

### 3. REST Client Configuration (globex-mobile-gateway)

**Problem**:
- globex-mobile-gateway failed to connect to globex-store-app
- Error: "Unable to determine the proper baseUrl/baseUri"
- Categories API returned HTTP 500

**Root Cause**:
- Quarkus REST client expected `QUARKUS_REST_CLIENT_GLOBEX_STORE_API_URL`
- Only `GLOBEX_STORE_APP_URL` was configured (wrong naming)

**Solution**:

Modified `kustomize/globex/globex-deployment-globex-mobile-gateway.yaml`:

```yaml
env:
  - name: GLOBEX_STORE_APP_URL
    value: http://globex-store-app:8080
  - name: QUARKUS_REST_CLIENT_GLOBEX_STORE_API_URL  # ADDED
    value: http://globex-store-app:8080
  - name: KEYCLOAK_AUTH_SERVER_URL
    value: placeholder  # Patched by PostSync Job
  - name: QUARKUS_OIDC_TOKEN_AUDIENCE
    value: globex-mobile
```

**Critical**: Both environment variables are now required:
- `GLOBEX_STORE_APP_URL` - Legacy/documentation
- `QUARKUS_REST_CLIENT_GLOBEX_STORE_API_URL` - Required by Quarkus REST client

---

### 4. Runtime Environment Variable Patching

**Problem**:
- Keycloak URL and OAuth redirect URLs cannot be hardcoded (cluster-specific)
- Need dynamic values: `https://keycloak-keycloak.apps.${CLUSTER_DOMAIN}/realms/globex-user1`

**Solution - PostSync Job**:

File: `kustomize/globex/openshift-gitops-job-globex-env.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: globex-env-setup
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/sync-wave: "4"
spec:
  template:
    spec:
      containers:
        - name: patch-globex-env
          command:
            - /bin/bash
            - -c
            - |
              BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
              KEYCLOAK_URL="https://keycloak-keycloak.apps.${BASE_DOMAIN}/realms/globex-user1"

              # Patch globex-mobile
              oc patch deployment globex-mobile -n globex-apim-user1 --type=json -p='[
                {"op": "replace", "path": "/spec/template/spec/initContainers/0/env/0/value", "value": "'"${KEYCLOAK_URL}"'"},
                {"op": "replace", "path": "/spec/template/spec/containers/0/env/4/value", "value": "'"${KEYCLOAK_URL}"'"},
                {"op": "replace", "path": "/spec/template/spec/containers/0/env/5/value", "value": "https://globex-mobile-globex-apim-user1.apps.'"${BASE_DOMAIN}"'"}
              ]'

              # Patch globex-mobile-gateway
              oc patch deployment globex-mobile-gateway -n globex-apim-user1 --type=json -p='[
                {"op": "replace", "path": "/spec/template/spec/containers/0/env/2/value", "value": "'"${KEYCLOAK_URL}"'"}
              ]'
```

**ArgoCD Configuration** - Prevent Drift:

File: `argocd/application-globex.yaml`

```yaml
ignoreDifferences:
  # globex-mobile: Ignore runtime-patched SSO configuration
  - group: apps
    kind: Deployment
    name: globex-mobile
    jsonPointers:
      - /spec/template/spec/initContainers/0/env/0/value  # SSO_AUTHORITY (initContainer)
      - /spec/template/spec/containers/0/env/4/value      # SSO_AUTHORITY
      - /spec/template/spec/containers/0/env/5/value      # SSO_REDIRECT_LOGOUT_URI

  # globex-mobile-gateway: Ignore runtime-patched Keycloak URL
  - group: apps
    kind: Deployment
    name: globex-mobile-gateway
    jsonPointers:
      - /spec/template/spec/containers/0/env/2/value      # KEYCLOAK_AUTH_SERVER_URL
```

**Critical**: The `jsonPointers` array indices MUST match the position of environment variables in the deployment YAML.

---

## Deployment Order

1. **Base Infrastructure**: Keycloak, Istio Gateway
2. **Keycloak Realm Import**: `keycloak-keycloakrealmimport-globex-user1.yaml` (with audience mapper)
3. **Globex Deployments**: All 4 components deployed
4. **PostSync Job Execution**: Environment variables patched at sync wave 4
5. **Verification**: Login flow and categories API work

---

## Verification Steps

### 1. Check JWT Token Has Audience Claim

After login, extract token from browser console:
```javascript
document.cookie.split('; ').find(row => row.startsWith('globex_session_token'))
```

Decode JWT payload (between the two dots):
```bash
echo "<payload>" | base64 -d | jq .
```

Expected output:
```json
{
  "aud": "globex-mobile",
  "azp": "globex-mobile",
  "preferred_username": "asilva",
  ...
}
```

### 2. Check globex-mobile-gateway Can Reach globex-store-app

```bash
oc logs -n globex-apim-user1 deployment/globex-mobile-gateway --tail=50
```

Should NOT show: "Unable to determine baseUrl"

### 3. Test Categories API

Login to globex-mobile, navigate to Categories page.

Expected:
- HTTP 200 OK on `/api/getCategories/asilva`
- Categories list displayed: "Astronomy", "Ceramics", "Clothing", etc.

---

## Common Issues

### Categories Return HTTP 500

**Symptoms**:
- User logged in successfully
- Categories page blank
- Console shows: `GET /api/getCategories/asilva` → 500 Internal Server Error

**Debugging**:

1. Check globex-mobile-gateway logs:
```bash
oc logs -n globex-apim-user1 deployment/globex-mobile-gateway --tail=100
```

2. Look for specific errors:
   - **"No Audience (aud) claim present"** → Missing protocol mapper or `QUARKUS_OIDC_TOKEN_AUDIENCE`
   - **"Unable to determine baseUrl"** → Missing `QUARKUS_REST_CLIENT_GLOBEX_STORE_API_URL`
   - **"URI is not absolute"** → `KEYCLOAK_AUTH_SERVER_URL` still set to "placeholder"

3. Verify environment variables:
```bash
oc get deployment globex-mobile-gateway -n globex-apim-user1 -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .
```

### Login Redirects to "Page Not Found"

**Root Cause**: `SSO_REDIRECT_LOGOUT_URI` not set correctly

**Fix**: Verify PostSync job patched the value:
```bash
oc get deployment globex-mobile -n globex-apim-user1 -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SSO_REDIRECT_LOGOUT_URI")].value}'
```

Expected: `https://globex-mobile-globex-apim-user1.apps.<cluster-domain>`

---

## Files Modified

### Kubernetes Manifests

1. `kustomize/globex/keycloak-keycloakrealmimport-globex-user1.yaml`
   - Added protocol mapper for audience claim

2. `kustomize/globex/globex-deployment-globex-mobile-gateway.yaml`
   - Added `QUARKUS_REST_CLIENT_GLOBEX_STORE_API_URL`
   - Added `QUARKUS_OIDC_TOKEN_AUDIENCE`

3. `kustomize/globex/openshift-gitops-job-globex-env.yaml`
   - PostSync job for patching runtime environment variables

4. `argocd/application-globex.yaml`
   - Updated `ignoreDifferences` for globex-mobile and globex-mobile-gateway

### Custom Images

1. **globex-mobile**: `quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v2`
   - Source changes: OAuth Authorization Code Flow + PKCE
   - See: `docs/deployment/rhbk-26-compatibility.md`

---

## References

- RHBK 26 Compatibility: `docs/deployment/rhbk-26-compatibility.md`
- Troubleshooting Guide: `docs/operations/troubleshooting.md`
- Gap Analysis vs Ansible: `docs/comparisons/gap-analysis.md`

---

**Last Updated**: 2026-03-28
**Verified By**: Claude Code troubleshooting session
**Status**: ✅ Categories loading successfully
