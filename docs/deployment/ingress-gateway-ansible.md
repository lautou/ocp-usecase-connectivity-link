## Ingress Gateway Deployment - Ansible Alignment ✅

**Status**: Successfully deployed ingress-gateway infrastructure matching Red Hat's ansible deployment **100%** (2026-03-27)

### Quick Summary

We validated **two deployment approaches** and achieved **100% resource alignment**:
- Red Hat's Ansible/Helm (connectivity-link-ansible repository)
- Our GitOps/ArgoCD (this repository - `kustomize/ingress-gateway/`)

**Result**: Identical infrastructure with exact same resource names, configuration, and behavior.

### Resource Names - 100% Match

| Resource | Ansible Name | Our Deployment | Match |
|----------|--------------|----------------|-------|
| Gateway hostname | `*.globex.sandbox3491.opentlc.com` | `*.globex.sandbox3491.opentlc.com` | ✅ Exact |
| Gateway geo-code label | `kuadrant.io/lb-attribute-geo-code: EU` | `kuadrant.io/lb-attribute-geo-code: EU` | ✅ Exact |
| TLSPolicy | `prod-web-tls-policy` | `prod-web-tls-policy` | ✅ Exact |
| RateLimitPolicy | `prod-web-rlp-lowlimits` | `prod-web-rlp-lowlimits` | ✅ Exact |
| AuthPolicy | `prod-web-deny-all` | `prod-web-deny-all` | ✅ Exact |
| ClusterIssuer | `prod-web-lets-encrypt-issuer` | `prod-web-lets-encrypt-issuer` | ✅ Exact |
| AWS Secret | `prod-web-aws-credentials` | `prod-web-aws-credentials` | ✅ Exact |
| DNSPolicy | ❌ NOT created | ❌ NOT created | ✅ Exact |
| Namespace label | ❌ Manual `oc label` | ✅ In Git manifests | **Better** |

### The ONE Critical Difference

**Namespace Label Management**:
- Ansible: Label NOT in Helm chart → requires manual `oc label` command
- Our GitOps: Label IN Git manifests → no manual step required ✅

**Why This Matters**: The label `argocd.argoproj.io/managed-by: openshift-gitops` triggers OpenShift GitOps **automatic RBAC creation**. Without it, deployment fails with Kuadrant RBAC errors.

### Deployment Status

**Gateway**:
- ✅ Hostname: `*.globex.sandbox3491.opentlc.com` (uses root domain, not cluster domain)
- ✅ Load Balancer: Ready
- ✅ Programmed: True

**TLS Certificate**:
- ✅ Issued by Let's Encrypt
- ✅ Subject: `*.globex.sandbox3491.opentlc.com`
- ✅ Valid until: Jun 23, 2026
- ✅ Status: Ready

**DNS**:
- ⏳ No DNSPolicy at this stage (matches ansible)
- Ansible Helm chart does NOT include DNSPolicy
- DNS records require manual creation or separate deployment

**Policies**:
- ✅ AuthPolicy: Deny-by-default (HTTP 403)
- ✅ RateLimitPolicy: 5 requests per 10 seconds
- ✅ TLSPolicy: Enforced

### Key Learnings

1. **Gateway Hostname Uses Root Domain**:
   - Ansible: `*.globex.sandbox3491.opentlc.com` (root domain)
   - NOT: `*.globex.myocp.sandbox3491.opentlc.com` (cluster domain)
   - Job calculates: `ROOT_DOMAIN=$(echo "${BASE_DOMAIN}" | sed 's/^[^.]*\.//')`

2. **Dedicated ClusterIssuer is Safer**:
   - Provides isolation, email notifications, independent lifecycle
   - Better than reusing generic `cluster` ClusterIssuer

3. **Self-Contained Overlays Work Best**:
   - Kustomize security prevents references outside overlay directory
   - Solution: Copy all manifests into overlay
   - Result: Fully portable and reproducible

4. **DNSPolicy is NOT Created by Ansible**:
   - Ansible Helm chart has `dns.routingStrategy: loadbalanced` and `loadBalancing.geo` values
   - **BUT**: No DNSPolicy template exists in the Helm chart
   - These values are **completely unused** (no template consumes them)
   - Only geo-related configuration: Gateway label `kuadrant.io/lb-attribute-geo-code: EU`
   - This label is **metadata only** - does nothing without DNSPolicy configured
   - To match ansible exactly: DNSPolicy must NOT be deployed

5. **Geo-Routing is NOT Enabled**:
   - Despite Helm values suggesting geo-routing and weighted load balancing
   - Ansible does NOT create ManagedZone or DNSPolicy resources
   - Gateway label exists but has no effect (requires DNSPolicy to work)
   - DNS automation is an enhancement available in our default overlay

**For complete details**, see [INGRESS_GATEWAY_DEPLOYMENT.md](INGRESS_GATEWAY_DEPLOYMENT.md)

