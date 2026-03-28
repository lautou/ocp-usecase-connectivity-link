# Solution Patterns - Tutorial Resources

This directory contains optional resources for following the [Red Hat Connectivity Link Solution Pattern](https://www.solutionpatterns.io/soln-pattern-connectivity-link/) tutorials.

## Overview

The base GitOps deployment in `kustomize/` provides a production-ready infrastructure. This `solutions/` directory contains **additional, optional resources** that demonstrate specific use cases and personas from the solution pattern tutorials.

These resources are:
- **Not deployed by default** - They are additive to the base deployment
- **Tutorial-focused** - Designed for learning and demonstration
- **Independently managed** - Can be deployed/removed without affecting base infrastructure
- **Labeled for tracking** - All resources have `solution-pattern.kuadrant.io/tutorial` labels

## Directory Structure

```
solutions/
├── README.md                         # This file
├── platform-engineer-workflow/       # Platform Engineer persona tutorial
│   ├── kustomization.yaml
│   ├── ingress-gateway-dnspolicy-prod-web.yaml
│   └── echo-api-ratelimitpolicy-echo-api.yaml
└── developer-workflow/               # Application Developer persona tutorial
    ├── kustomization.yaml
    ├── globex-apim-user1-httproute-globex-mobile-gateway.yaml
    └── README.md
```

## Prerequisites

Before deploying solution pattern resources, ensure:

1. ✅ Base infrastructure is deployed and healthy:
   ```bash
   oc get gateway prod-web -n ingress-gateway
   oc get httproute -A
   ```

2. ✅ ArgoCD Applications are synced:
   ```bash
   oc get application -n openshift-gitops | grep -E "ingress-gateway|echo-api"
   ```

3. ✅ AWS credentials configured (for DNSPolicy):
   ```bash
   oc get secret prod-web-aws-credentials -n ingress-gateway
   ```

## Usage

### Option 1: Using the solutions.sh script (Recommended)

```bash
# Deploy platform-engineer-workflow tutorial resources
./scripts/solutions.sh deploy platform-engineer-workflow

# Deploy developer-workflow tutorial resources
./scripts/solutions.sh deploy developer-workflow

# Check status
./scripts/solutions.sh status platform-engineer-workflow

# Remove resources
./scripts/solutions.sh delete developer-workflow

# List available solutions
./scripts/solutions.sh list
```

### Option 2: Using kubectl/oc directly

```bash
# Deploy platform-engineer-workflow
oc apply -k solutions/platform-engineer-workflow/

# Deploy developer-workflow
oc apply -k solutions/developer-workflow/

# Verify
oc get dnspolicy -n ingress-gateway -l solution-pattern.kuadrant.io/tutorial=platform-engineer-workflow
oc get httproute -n globex-apim-user1 -l solution-pattern.kuadrant.io/tutorial=developer-workflow

# Remove
oc delete -k solutions/platform-engineer-workflow/
oc delete -k solutions/developer-workflow/
```

### Option 3: Using ArgoCD (GitOps)

```bash
# Create ArgoCD Applications
oc apply -f argocd/application-solutions-platform-engineer-workflow.yaml
oc apply -f argocd/application-solutions-developer-workflow.yaml

# Sync
argocd app sync solutions-platform-engineer-workflow
argocd app sync solutions-developer-workflow
```

## Available Solutions

### 1. Platform Engineer Workflow

**Tutorial URL**: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html

**What it deploys**:
- DNSPolicy for Gateway `prod-web` - Automated DNS record management via Route53
- RateLimitPolicy for HTTPRoute `echo-api` - Per-route rate limiting (10 req/12s)

**Resources created**:
```yaml
DNSPolicy: ingress-gateway/prod-web-dnspolicy
DNSRecord: ingress-gateway/prod-web-api (created automatically by DNSPolicy)
RateLimitPolicy: echo-api/echo-api-rlp
Route53 Record: *.globex.<cluster-domain> → Load Balancer CNAME
```

**Expected behavior**:
- Wildcard DNS record `*.globex.<cluster-domain>` created in Route53
- HTTPRoutes automatically get DNS records
- Rate limiting: 10 req/12s for echo-api (HTTPRoute policy overrides Gateway policy of 5 req/10s)

**Deployment**:
```bash
./scripts/solutions.sh deploy platform-engineer-workflow
```

**Verification**:
```bash
# Check DNSPolicy
oc get dnspolicy prod-web-dnspolicy -n ingress-gateway

# Check DNSRecord (created automatically)
oc get dnsrecord.kuadrant.io -n ingress-gateway

# Check RateLimitPolicy
oc get ratelimitpolicy echo-api-rlp -n echo-api

# Test DNS resolution
dig echo.globex.<cluster-domain>

# Test rate limiting (should see 10× 200, then 2× 429)
# HTTPRoute policy (10 req/12s) overrides Gateway policy (5 req/10s)
for i in {1..12}; do
  curl -k -w " %{http_code}\n" -o /dev/null https://echo.globex.<cluster-domain>
done
# Expected: 10× 200 (allowed), then 2× 429 (rate limited)
```

### 2. Developer Workflow

**Tutorial**: Gateway API HTTPRoute demonstration for ProductInfo service

**What it deploys**:
- HTTPRoute for ProductInfo API (globex-mobile-gateway) with path-based routing
- Demonstrates application developer workflow: exposing backend services via Gateway API

**Resources created**:
```yaml
HTTPRoute: globex-apim-user1/globex-mobile-gateway
  Hostname: globex-mobile.globex.<cluster-domain>
  Paths:
    - GET /mobile/services/product/category/*
    - GET /mobile/services/category/list
```

**Expected behavior**:
- ProductInfo API endpoints accessible via Gateway API
- Returns HTTP 403 (AuthPolicy deny-by-default) - add AuthPolicy in next tutorial step
- Frontend UI remains on OpenShift Route (unchanged)
- Frontend internal communication still uses ClusterIP (unchanged)

**Deployment**:
```bash
./scripts/solutions.sh deploy developer-workflow
```

**Verification**:
```bash
# Check HTTPRoute created
oc get httproute globex-mobile-gateway -n globex-apim-user1

# Check HTTPRoute attached to Gateway
oc describe httproute globex-mobile-gateway -n globex-apim-user1

# Test API endpoint (expect 403)
curl -k https://globex-mobile.globex.<cluster-domain>/mobile/services/category/list
# Expected: HTTP 403 Forbidden (AuthPolicy deny-by-default)
```

**See**: `solutions/developer-workflow/README.md` for next tutorial steps

## Base vs Solutions - What's Included Where?

### Base Deployment (`kustomize/ingress-gateway/`)

Production-ready infrastructure:
- ✅ Gateway API Gateway (`prod-web`)
- ✅ TLSPolicy (Let's Encrypt wildcard certificates)
- ✅ AuthPolicy (deny-by-default)
- ✅ RateLimitPolicy (5 req/10s Gateway-level, applies to all routes)
- ✅ AWS credentials Secret
- ❌ DNSPolicy (optional - in solutions/)
- ❌ HTTPRoute-level RateLimitPolicy (optional - in solutions/)

### Solutions Deployment

Tutorial-specific additions:

**Platform Engineer Workflow** (`solutions/platform-engineer-workflow/`):
- ✅ DNSPolicy (automated DNS via Route53)
- ✅ RateLimitPolicy for echo-api HTTPRoute (10 req/12s, overrides Gateway policy)

**Developer Workflow** (`solutions/developer-workflow/`):
- ✅ HTTPRoute for ProductInfo API (path-based routing)
- ✅ Demonstrates Gateway API usage for backend services

## Why Separate Solutions?

1. **Production-ready base**: The base deployment is production-ready without tutorial-specific configurations
2. **Learning flexibility**: Follow tutorials without modifying core infrastructure
3. **Clean state**: Easy to reset tutorial progress without redeploying everything
4. **GitOps optional**: Solutions can be deployed imperatively (for learning) or via GitOps

## Cleanup

### Remove all solution resources

```bash
# Using script
./scripts/solutions.sh delete platform-engineer-workflow
./scripts/solutions.sh delete developer-workflow

# Or manually
oc delete -k solutions/platform-engineer-workflow/
oc delete -k solutions/developer-workflow/
```

### Verify cleanup

**Platform Engineer Workflow:**
```bash
# Check DNSPolicy removed
oc get dnspolicy -n ingress-gateway
# Expected: No resources found

# Check DNSRecord removed
oc get dnsrecord.kuadrant.io -n ingress-gateway
# Expected: No resources found (or only base records)

# Verify Route53 cleanup (if AWS CLI available)
# The wildcard CNAME should be removed
```

**Developer Workflow:**
```bash
# Check HTTPRoute removed
oc get httproute globex-mobile-gateway -n globex-apim-user1
# Expected: No resources found

# Verify API endpoint no longer accessible
curl -k https://globex-mobile.globex.<cluster-domain>/mobile/services/category/list
# Expected: HTTP 404 Not Found
```

## Troubleshooting

### DNSPolicy not creating DNS records

```bash
# Check DNSPolicy status
oc describe dnspolicy prod-web-dnspolicy -n ingress-gateway

# Check DNS operator logs
oc logs -n kuadrant-system -l app.kubernetes.io/component=dns-operator --tail=50

# Verify AWS credentials
oc get secret prod-web-aws-credentials -n ingress-gateway -o yaml
```

### DNS records not resolving externally

```bash
# Check authoritative nameservers
dig NS globex.<cluster-domain> @8.8.8.8

# Query authoritative server directly
dig '*.globex.<cluster-domain>' @<nameserver-from-above>

# Check DNS propagation
dig echo.globex.<cluster-domain> @8.8.8.8
```

### Rate limiting not working

```bash
# Verify RateLimitPolicy applied to Gateway
oc get gateway prod-web -n ingress-gateway -o yaml | grep -A 5 RateLimitPolicy

# Check HTTPRoute affected by policy
oc get httproute echo-api -n echo-api -o yaml | grep -A 5 RateLimitPolicy

# Check Limitador logs
oc logs -n kuadrant-system -l app=limitador --tail=50
```

## Related Documentation

- [Main Documentation](../CLAUDE.md)
- [Deployment Guide](../docs/deployment/)
- [Troubleshooting Guide](../docs/operations/troubleshooting.md)
- [Red Hat Solution Pattern](https://www.solutionpatterns.io/soln-pattern-connectivity-link/)

## Contributing

To add new solution patterns:

1. Create a new directory: `solutions/<solution-name>/`
2. Add `kustomization.yaml` and resource manifests
3. Add labels: `solution-pattern.kuadrant.io/tutorial: <name>`
4. Update this README with usage instructions
5. Update `scripts/solutions.sh` with the new solution
6. Test deploy/delete cycle
