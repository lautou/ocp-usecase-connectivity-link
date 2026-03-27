# Rate Limiting Alignment with Red Hat Demo

**Date**: 2026-03-27
**Status**: ✅ **VERIFIED - 100% Aligned**

## Overview

This document explains how our GitOps deployment achieves identical rate limiting behavior to the [Red Hat Connectivity Link Solution Pattern](https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html).

## Issue Discovered

Initially, rate limiting was not working as expected when testing the echo-api endpoint.

**Expected behavior** (from Red Hat demo):
```bash
$ for i in {1..10}; do curl -k -w "%{http_code}" https://echo.globex.<domain>; done
# Expected: 5× HTTP 200, then 5× HTTP 429 (Too Many Requests)
```

**Actual behavior** (before fix):
```bash
# Result: 10× HTTP 200 (no rate limiting)
```

## Root Cause

Our deployment had **two RateLimitPolicies** affecting the echo-api HTTPRoute:

1. **Gateway-level policy** (correct):
   - Name: `prod-web-rlp-lowlimits`
   - Target: Gateway `prod-web`
   - Limits: 5 requests / 10 seconds
   - Status: ❌ Overridden

2. **HTTPRoute-level policy** (extra, not in Red Hat demo):
   - Name: `echo-api-rlp`
   - Target: HTTPRoute `echo-api`
   - Limits: 10 requests / 12 seconds
   - Status: ✅ Enforced (taking precedence)

**Kuadrant Policy Hierarchy**: HTTPRoute-level policies **override** Gateway-level policies.

## Investigation Steps

1. **Checked Red Hat Helm charts**:
   ```bash
   # /tmp/cl-install-helm/platform/ingress-gateway/templates/low-limits-rlp.yaml
   # Confirmed: Gateway RateLimitPolicy only (5 req/10s)
   # No HTTPRoute-level policy in developer/echo-api chart
   ```

2. **Checked cluster status**:
   ```bash
   $ oc get ratelimitpolicy prod-web-rlp-lowlimits -n ingress-gateway -o yaml
   # Status showed: "RateLimitPolicy is overridden by [echo-api/echo-api-rlp]"
   ```

3. **Verified HTTPRoute status**:
   ```bash
   $ oc get httproute echo-api -n echo-api -o yaml | grep RateLimitPolicy
   # Showed: Affected by echo-api/echo-api-rlp (not Gateway policy)
   ```

## Fix Applied

### 1. Removed Extra HTTPRoute RateLimitPolicy

**File removed**:
- `kustomize/echo-api/echo-api-ratelimitpolicy-echo-api-rlp.yaml`

**Kustomization updated**:
```diff
# kustomize/echo-api/kustomization.yaml
resources:
  - cluster-ns-echo-api.yaml
  - echo-api-authpolicy-echo-api.yaml
  - echo-api-deployment-echo-api.yaml
  - echo-api-httproute-echo-api.yaml
  - echo-api-service-echo-api.yaml
- - echo-api-ratelimitpolicy-echo-api-rlp.yaml  # REMOVED
  - openshift-gitops-job-echo-api-httproute.yaml
```

**Git commit**:
```bash
git commit -m "Remove echo-api HTTPRoute RateLimitPolicy to match Red Hat demo behavior"
# Commit: adbcdf2
```

### 2. Fixed HTTPRoute Hostname

The HTTPRoute hostname was stuck at `echo.globex.placeholder` because the PostSync Job wasn't running automatically.

**Manual trigger**:
```bash
$ oc apply -f kustomize/echo-api/openshift-gitops-job-echo-api-httproute.yaml
job.batch/echo-api-httproute-setup created

$ oc logs -n openshift-gitops job/echo-api-httproute-setup
==========================================
✅ HTTPRoute setup completed!
Hostname: echo.globex.sandbox3491.opentlc.com
==========================================
```

**Verification**:
```bash
$ oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}'
echo.globex.sandbox3491.opentlc.com  # ✅ Fixed
```

### 3. Deployed DNSPolicy (for testing)

The DNS wasn't resolving initially. We deployed the optional DNSPolicy from the solution patterns:

```bash
$ oc apply -f solutions/platform-engineer/ingress-gateway-dnspolicy-prod-web.yaml
dnspolicy.kuadrant.io/prod-web-dnspolicy created
```

**Note**: This creates a wildcard CNAME:
- `*.globex.sandbox3491.opentlc.com` → Load Balancer

## Verification

### 1. Policy Status

**Gateway RateLimitPolicy**:
```bash
$ oc get ratelimitpolicy prod-web-rlp-lowlimits -n ingress-gateway -o jsonpath='{.status.conditions}'
{
  "type": "Enforced",
  "status": "True",
  "message": "RateLimitPolicy has been successfully enforced"
}
```

**HTTPRoute Status**:
```bash
$ oc get httproute echo-api -n echo-api -o yaml | grep RateLimitPolicy
message: Object affected by RateLimitPolicy [ingress-gateway/prod-web-rlp-lowlimits]
```

### 2. Rate Limiting Test

**From cluster (using --resolve to bypass local DNS cache)**:
```bash
$ for i in {1..10}; do
    curl -s -w " HTTP_%{http_code}\n" -o /dev/null \
      --resolve echo.globex.sandbox3491.opentlc.com:443:52.28.229.57 \
      https://echo.globex.sandbox3491.opentlc.com
  done

 HTTP_200  ✅ Request 1
 HTTP_200  ✅ Request 2
 HTTP_200  ✅ Request 3
 HTTP_200  ✅ Request 4
 HTTP_200  ✅ Request 5
 HTTP_429  ⛔ Request 6 - Too Many Requests
 HTTP_429  ⛔ Request 7 - Too Many Requests
 HTTP_429  ⛔ Request 8 - Too Many Requests
 HTTP_429  ⛔ Request 9 - Too Many Requests
 HTTP_429  ⛔ Request 10 - Too Many Requests
```

**From external (after DNS propagation)**:
```bash
$ for i in {1..10}; do curl -k -w "%{http_code}" https://echo.globex.sandbox3491.opentlc.com; done
200 200 200 200 200 429 429 429 429 429  ✅ Perfect alignment!
```

## Current Architecture

### Base Deployment (Production-Ready)

**File**: `kustomize/ingress-gateway/ingress-gateway-ratelimitpolicy-prod-web.yaml`

```yaml
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: prod-web-rlp-lowlimits
  namespace: ingress-gateway
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: prod-web
  limits:
    default-limits:
      rates:
      - limit: 5
        window: 10s
```

**Scope**: Applies to all HTTPRoutes attached to Gateway `prod-web`

### HTTPRoute Configuration

**File**: `kustomize/echo-api/echo-api-httproute-echo-api.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-api
  namespace: echo-api
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - echo.globex.placeholder  # Patched by PostSync Job to actual domain
  rules:
    - backendRefs:
        - name: echo-api
          port: 8080
```

**Note**: Hostname is patched at runtime by `openshift-gitops-job-echo-api-httproute.yaml`

### DNS Configuration (Optional)

**File**: `solutions/platform-engineer/ingress-gateway-dnspolicy-prod-web.yaml`

```yaml
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: prod-web-dnspolicy
  namespace: ingress-gateway
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: prod-web
  providerRefs:
    - name: prod-web-aws-credentials
```

**Deployment**: Optional - use `./scripts/solutions.sh deploy platform-engineer`

## Comparison with Red Hat Demo

| Aspect | Red Hat Demo (Ansible) | Our GitOps Deployment |
|--------|------------------------|------------------------|
| **Gateway RateLimitPolicy** | ✅ 5 req/10s | ✅ 5 req/10s |
| **HTTPRoute RateLimitPolicy** | ❌ None | ❌ None (removed) |
| **Effective Limit** | 5 req/10s | 5 req/10s |
| **Test Result** | 5× 200, 5× 429 | 5× 200, 5× 429 |
| **DNS Management** | boto3 (imperative) | ACK + DNSPolicy (declarative) |
| **Alignment** | — | ✅ **100%** |

## Key Learnings

1. **Kuadrant Policy Hierarchy**:
   - HTTPRoute-level policies take precedence over Gateway-level policies
   - Check policy status to see if overridden

2. **Testing Rate Limiting**:
   - Use rapid sequential requests (not parallel)
   - Observe HTTP status codes (429 = Too Many Requests)
   - Check Limitador logs if unexpected behavior

3. **DNS Troubleshooting**:
   - Local DNS resolvers may cache negative responses
   - Use authoritative nameservers for testing: `dig @ns-194.awsdns-24.com`
   - Google DNS (8.8.8.8) respects TTLs better than some ISP resolvers
   - Use `--resolve` flag in curl for DNS bypass testing

4. **PostSync Jobs**:
   - ArgoCD hooks may not run if Application is already synced
   - Manual trigger: `oc apply -f <job.yaml>`
   - Jobs use `argocd.argoproj.io/hook: PostSync` annotation

## Related Resources

- [Red Hat Solution Pattern - Platform Engineer](https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html)
- [Kuadrant RateLimitPolicy Documentation](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/ratelimitpolicy/)
- [Gateway API Policy Attachment](https://gateway-api.sigs.k8s.io/references/policy-attachment/)
- [Solutions README](../../solutions/README.md)

## Status

- ✅ **VERIFIED**: Rate limiting matches Red Hat demo behavior
- ✅ **ALIGNED**: Same Gateway-level policy (5 req/10s)
- ✅ **TESTED**: HTTP 429 responses after 5 requests
- ✅ **DOCUMENTED**: Architecture and troubleshooting steps captured
