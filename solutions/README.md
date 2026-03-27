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
├── README.md                    # This file
├── platform-engineer/           # Platform Engineer persona tutorial
│   ├── kustomization.yaml
│   └── ingress-gateway-dnspolicy-prod-web.yaml
└── application-developer/       # Application Developer persona (future)
    └── ...
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
# Deploy platform-engineer tutorial resources
./scripts/solutions.sh deploy platform-engineer

# Check status
./scripts/solutions.sh status platform-engineer

# Remove resources
./scripts/solutions.sh delete platform-engineer

# List available solutions
./scripts/solutions.sh list
```

### Option 2: Using kubectl/oc directly

```bash
# Deploy
oc apply -k solutions/platform-engineer/

# Verify
oc get dnspolicy -n ingress-gateway -l solution-pattern.kuadrant.io/tutorial=platform-engineer

# Remove
oc delete -k solutions/platform-engineer/
```

### Option 3: Using ArgoCD (GitOps)

```bash
# Create ArgoCD Application
oc apply -f argocd/application-solutions-platform-engineer.yaml

# Sync
argocd app sync solutions-platform-engineer
```

## Available Solutions

### 1. Platform Engineer Tutorial

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

### 2. Application Developer Tutorial (Future)

**Tutorial URL**: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.2-app-developer.html

**Status**: Not yet implemented

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

### Solutions Deployment (`solutions/platform-engineer/`)

Tutorial-specific additions:
- ✅ DNSPolicy (automated DNS via Route53)
- ✅ RateLimitPolicy for echo-api HTTPRoute (10 req/12s, overrides Gateway policy)
- Future: Additional tutorial resources per persona

## Why Separate Solutions?

1. **Production-ready base**: The base deployment is production-ready without tutorial-specific configurations
2. **Learning flexibility**: Follow tutorials without modifying core infrastructure
3. **Clean state**: Easy to reset tutorial progress without redeploying everything
4. **GitOps optional**: Solutions can be deployed imperatively (for learning) or via GitOps

## Cleanup

### Remove all solution resources

```bash
# Using script
./scripts/solutions.sh delete platform-engineer

# Or manually
oc delete -k solutions/platform-engineer/
```

### Verify cleanup

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
