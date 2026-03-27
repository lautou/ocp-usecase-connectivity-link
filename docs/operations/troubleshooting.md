## Troubleshooting

### Job Fails with "Timeout waiting for HostedZone"

**Cause**: HostedZone creation is slow or failed

**Fix**:
```bash
# Check HostedZone status
oc get hostedzone globex -n ack-system -o yaml

# Check ACK controller logs
oc logs -n ack-system deployment/ack-route53-controller
```

### RecordSet Creation Fails

**Cause**: Insufficient permissions or parent zone not accessible

**Fix**:
```bash
# Verify AWS credentials Secret exists
oc get secret ack-route53-user-secrets -n ack-system

# Check RecordSet status
oc describe recordset globex-ns-delegation -n ack-system

# Verify parent zone ID is correct
oc get dns cluster -o jsonpath='{.spec.publicZone.id}'
```

### DNS Not Resolving

**Cause**: DNS propagation delay or delegation not created

**Fix**:
```bash
# Check if RecordSet exists and is synced
oc get recordset globex-ns-delegation -n ack-system -o yaml

# Wait 5-10 minutes for DNS propagation
# Test with authoritative nameserver directly
dig @ns-451.awsdns-56.com globex.myocp.sandbox4993.opentlc.com SOA
```

### Gateway Hostname Not Updated

**Cause**: Gateway patch Job failed or not run

**Fix**:
```bash
# Check Job status
oc get job gateway-prod-web-setup -n openshift-gitops

# Check Job logs
oc logs -n openshift-gitops job/gateway-prod-web-setup

# Manually trigger by deleting Job (ArgoCD will recreate)
oc delete job gateway-prod-web-setup -n openshift-gitops
```

### HTTPRoute Hostname Not Updated

**Cause**: HTTPRoute patch Job failed or not run

**Fix**:
```bash
# Check Job status
oc get job echo-api-httproute-setup -n openshift-gitops

# Check Job logs
oc logs -n openshift-gitops job/echo-api-httproute-setup

# Manually trigger by deleting Job
oc delete job echo-api-httproute-setup -n openshift-gitops
```

### TLS Certificate Issues

**Cause**: cert-manager or TLSPolicy misconfiguration

**Fix**:
```bash
# Check ClusterIssuer
oc get clusterissuer cluster

# Check Certificate status
oc get certificate -n ingress-gateway

# Check TLSPolicy status
oc get tlspolicy prod-web -n ingress-gateway -o yaml

# Check cert-manager logs
oc logs -n cert-manager deployment/cert-manager
```

### ArgoCD Shows Out-of-Sync

**Cause**: ignoreDifferences not configured correctly

**Fix**:
```bash
# Verify ignoreDifferences in Application
oc get application usecase-connectivity-link -n openshift-gitops -o yaml | grep -A 10 ignoreDifferences

# Re-apply Application with ignoreDifferences
oc apply -f argocd/application.yaml
```

### Gateway Permission Errors

**Cause**: Missing RBAC permissions for Jobs

**Fix**:
```bash
# Check ClusterRole exists
oc get clusterrole gateway-manager

# Check ClusterRoleBinding exists
oc get clusterrolebinding gateway-manager-openshift-gitops-argocd-application-controller

# Verify ServiceAccount has permissions
oc auth can-i create gateways.gateway.networking.k8s.io --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

### DNSPolicy Not Creating DNS Records

**Cause**: Incorrect Secret type or missing AWS credentials

**Fix**:
```bash
# CRITICAL: Check Secret type (MUST be kuadrant.io/aws, NOT Opaque)
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.type}'
# Should output: kuadrant.io/aws

# If type is wrong, delete and recreate via Job
oc delete secret aws-credentials -n ingress-gateway
oc delete job aws-credentials-setup -n openshift-gitops

# Check DNSPolicy status
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.'

# Check DNS Operator logs for provider errors
oc logs -n openshift-operators deployment/dns-operator-controller-manager --tail=50 | grep -i "prod-web\|provider\|error"

# Verify AWS region is set
oc get secret aws-credentials -n ingress-gateway -o jsonpath='{.data.AWS_REGION}' | base64 -d
```

### Echo API Returns HTTP 403 Forbidden

**Cause**: The echo-api AuthPolicy may not be deployed or is misconfigured

**Expected Behavior**: echo-api should return HTTP 200 because it has an allow-all AuthPolicy (`echo-api-authpolicy-echo-api.yaml`) that overrides the Gateway deny-by-default.

**Fix**:
```bash
# Verify echo-api AuthPolicy exists
oc get authpolicy echo-api -n echo-api

# Check AuthPolicy status
oc describe authpolicy echo-api -n echo-api

# If missing, check ArgoCD sync status
oc get application usecase-connectivity-link -n openshift-gitops

# Check Gateway-level AuthPolicy (should exist)
oc get authpolicy prod-web-deny-all -n ingress-gateway -o yaml
```

### Echo API Not Accessible from Internet (After Allowing Auth)

**Cause**: DNS records not created or DNS propagation delay

**Fix**:
```bash
# Check DNSPolicy is enforced
oc get dnspolicy prod-web -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="Enforced")'
# Should show: "status": "True", "message": "DNSPolicy has been successfully enforced"

# Check DNS resolution
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
dig +short $HOSTNAME
# Should return Load Balancer hostname and IPs

# Check Gateway Load Balancer address
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.status.addresses}'

# Test HTTPS connectivity
curl -v https://$HOSTNAME

# Check TLS certificate
echo | openssl s_client -connect $HOSTNAME:443 -servername $HOSTNAME 2>/dev/null | openssl x509 -noout -subject -issuer
```

### Globex Web OAuth Login Completes But Session Not Maintained

**Symptoms**:
- User clicks "Login", redirected to Keycloak, authenticates successfully
- Redirected back to Globex application
- "Login" button remains (should change to "Logout")
- Session is not maintained, user not logged in
- Browser redirects to `globex-mobile-globex.placeholder` domain (non-existent)

**Root Causes**:

1. **SSO_CLIENT_ID environment variable conflict** (if present):
   - The application uses `SSO_CUSTOM_CONFIG` to specify the client_id
   - Adding `SSO_CLIENT_ID` creates a conflict and breaks session management
   - **Solution**: Remove `SSO_CLIENT_ID` from deployment, only use 4 SSO env vars

2. **Placeholder domain hardcoded in JavaScript bundle**:
   - Environment variables only affect server-side code (Node.js)
   - Client-side JavaScript has placeholder domains baked in at build time
   - OAuth redirect_uri in browser uses `https://globex-mobile-globex.placeholder/...`
   - After Keycloak auth, redirect fails because domain doesn't exist
   - **Solution**: Use initContainer to patch JavaScript files at runtime

**Fix**:

```bash
# 1. Verify only 4 SSO environment variables are present
oc get deployment globex-mobile -n globex -o jsonpath='{.spec.template.spec.containers[0].env}' | jq 'map(select(.name | startswith("SSO_")))'
# Should show: SSO_CUSTOM_CONFIG, SSO_AUTHORITY, SSO_REDIRECT_LOGOUT_URI, SSO_LOG_LEVEL

# 2. Check if SSO_CLIENT_ID is present (WRONG - should be removed)
oc get deployment globex-mobile -n globex -o jsonpath='{.spec.template.spec.containers[0].env}' | jq 'map(select(.name == "SSO_CLIENT_ID"))'
# Should return empty array []

# 3. Verify initContainer is present to patch JavaScript files
oc get deployment globex-mobile -n globex -o jsonpath='{.spec.template.spec.initContainers[0].name}'
# Should show: patch-placeholder

# 4. Check initContainer logs to verify patching worked
oc logs -n globex -l app.kubernetes.io/name=globex-mobile -c patch-placeholder --tail=10
# Should show: "Apps domain: apps.<cluster-domain>" and "Placeholder domains replaced"

# 5. Verify placeholder is removed from JavaScript
curl -sk 'https://globex-mobile-globex.apps.<cluster-domain>/main.js' | grep -o 'placeholder' | wc -l
# Should return: 0

# 6. Verify actual cluster domain is present in JavaScript
curl -sk 'https://globex-mobile-globex.apps.<cluster-domain>/main.js' | grep -o 'apps\.<cluster-domain>' | head -3
# Should return actual domain multiple times

# 7. If initContainer is missing, check ArgoCD sync status
oc get application.argoproj.io usecase-connectivity-link -n openshift-gitops -o jsonpath='{.status.sync.status}'

# 8. If sync is OK but initContainer missing, force re-sync
oc annotate application.argoproj.io usecase-connectivity-link -n openshift-gitops argocd.argoproj.io/refresh=normal --overwrite

# 9. If everything looks correct, restart deployment to apply changes
oc rollout restart deployment globex-mobile -n globex
oc rollout status deployment globex-mobile -n globex --timeout=3m
```

**Important Notes**:
- The globex-mobile is an Angular 15 SSR (Server-Side Rendering) application
- Environment variables are injected server-side but client-side code is pre-built
- The initContainer pattern is required to patch client-side JavaScript at runtime
- InitContainer must mount at `/opt/app-root/src/dist/globex-mobile/browser` (NOT parent directory)
- Mounting at `/opt/app-root/src/dist` breaks the Node.js server (CrashLoopBackOff)
- The Job `globex-env-setup` patches both initContainer and main container env vars
- ArgoCD ignoreDifferences must include initContainer env var path to avoid drift

**Debugging OAuth Flow**:

```bash
# Check Keycloak client configuration
oc get keycloakrealmimport globex-user1 -n keycloak -o jsonpath='{.spec.realm.clients[?(@.clientId=="globex-mobile-gateway")]}' | jq '{clientId, redirectUris, webOrigins, implicitFlowEnabled}'

# Test login with browser developer tools:
# 1. Open browser DevTools → Network tab
# 2. Click "Login" button
# 3. Check the Keycloak redirect URL - should contain:
#    redirect_uri=https://globex-mobile-globex.apps.<actual-domain>/...
# 4. After auth, check if redirect_uri matches the current domain
# 5. Check Application → Cookies for Keycloak session cookies
```

### Keycloak Userinfo Endpoint Returns 401 Unauthorized

**Symptoms**:
- OAuth login redirects to Keycloak and back successfully
- Browser receives valid access token and ID token in URL fragment
- Multiple requests to `/protocol/openid-connect/userinfo` return **HTTP 401 Unauthorized**
- Keycloak logs show error: `user_session_not_found`
- User session doesn't persist, "Login" button remains instead of showing username

**Root Cause**:

Keycloak client using **OAuth2 Implicit Flow only** (`implicitFlowEnabled: true`) without **Authorization Code Flow** (`standardFlowEnabled: false` or not set).

The Implicit Flow:
- Returns tokens directly in URL fragment (`#`)
- **Does NOT create server-side sessions** in Keycloak
- Fails when calling `/userinfo` because Keycloak can't find the session
- Token introspection returns `"active": false`

**Keycloak Error Log**:
```
type="USER_INFO_REQUEST_ERROR", error="user_session_not_found", auth_method="validate_access_token"
```

**Fix**:

Enable **Authorization Code Flow** alongside Implicit Flow in the Keycloak client:

```yaml
# kustomize/base/keycloak-keycloakrealmimport-globex-user1.yaml
- clientId: globex-mobile-gateway
  standardFlowEnabled: true  # ← ADD THIS
  implicitFlowEnabled: true
  # ... rest of config
```

**Verification Steps**:

```bash
# 1. Check Keycloak client configuration
oc get keycloakrealmimport globex-user1 -n keycloak -o jsonpath='{.spec.realm.clients[?(@.clientId=="globex-mobile-gateway")]}' | jq '{clientId, standardFlowEnabled, implicitFlowEnabled}'
# Should show: standardFlowEnabled: true, implicitFlowEnabled: true

# 2. Check Keycloak logs for errors
oc logs -n keycloak -l app=keycloak --tail=20 | grep -i "user_session_not_found\|userinfo"

# 3. After fixing, clear browser cache and storage
# Run in browser console:
localStorage.clear();
sessionStorage.clear();
location.reload(true);

# 4. Test userinfo endpoint after login
# Should return HTTP 200 with user profile data
```

**Important**:
- Modern OAuth2 best practice: Use **Authorization Code Flow with PKCE** for SPAs
- Implicit Flow has known security issues and doesn't maintain sessions
- Both flows enabled ensures compatibility while fixing session issues
- After changing Keycloak config, ArgoCD will sync and Keycloak Operator applies changes automatically

