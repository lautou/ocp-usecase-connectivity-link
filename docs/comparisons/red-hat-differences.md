## Key Differences from Red Hat Demo (Summary)

### What We Changed (and Why)

This deployment is **100% functionally aligned** with Red Hat's Connectivity Link demo, but we had to make **4 forced changes** due to RHBK 26 compatibility and upstream bugs:

| Component | Red Hat Demo | Our Implementation | Change Type | Reason |
|-----------|--------------|-------------------|-------------|--------|
| **globex-mobile image** | `quay.io/cloud-architecture-workshop/globex-mobile:latest` | `quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v2` | ⚠️ **FORCED** | Upstream hardcoded OAuth Implicit Flow (removed in RHBK 26) |
| **globex-store-app image** | `quay.io/cloud-architecture-workshop/globex-store:latest` | `quay.io/laurenttourreau/globex-store:npe-fixed` | ⚠️ **FORCED** | Upstream has NullPointerException bug (line 63, null page param) |
| **Keycloak client config** | Standard Flow only | Both Standard + Implicit Flow enabled | ⚠️ **FORCED** | angular-auth-oidc-client needs both flows for session creation |
| **Environment variable** | Not documented | Added `GLOBEX_MOBILE_GATEWAY` + runtime patching | ⚠️ **FORCED** | Server.ts expects this exact variable name for backend API calls |

**Everything else is 100% identical** - same namespace naming (`globex-apim-user1`), same architecture (monolith), same Kuadrant policies, same Gateway API patterns.

### Custom Images We Built

**Required for production use:**
- ✅ `quay.io/laurenttourreau/globex-mobile:rhbk26-authcode-flow-v2` - Single line change: `responseType: 'code'`
- ✅ `quay.io/laurenttourreau/globex-store:npe-fixed` - Null-safe page parameter handling

**Obsolete (created during development, should be deleted):**
- ❌ `quay.io/laurenttourreau/globex-web:*` - 4 tags, replaced by globex-mobile
- ❌ `quay.io/laurenttourreau/my-custom-image:0.0.1` - Test image

### Cleanup Script for quay.io

A cleanup script is provided to remove obsolete repositories:

```bash
# Set your quay.io API token
export QUAY_TOKEN='your-token-here'

# Run cleanup script
./scripts/cleanup-quay-repos.sh
```

**What it does:**
- Deletes `globex-web` repository (all 4 tags: rhbk26-authcode-flow-v2, rhbk26-authcode-flow, fixed-pkce, fixed)
- Deletes `my-custom-image` repository (test image)
- Keeps `globex-mobile` and `globex-store` (in production use)
- Leaves `jukebox-ui` alone (unrelated project)

**Getting your Quay.io API token:**
1. Login to https://quay.io
2. Go to Account Settings → Robot Accounts (or use your user token)
3. Generate an API token with "Delete repositories" permission
4. Export: `export QUAY_TOKEN='your-token-here'`

### Why These Changes Are Permanent

These are not temporary workarounds - they represent **permanent improvements** over the upstream images:

1. **RHBK 26 compatibility**: OAuth Implicit Flow is deprecated industry-wide (OAuth 2.0 Security BCP)
2. **Bug fix**: NullPointerException would affect any deployment using the upstream image
3. **Better OAuth configuration**: Both flows enabled is the recommended pattern for angular-auth-oidc-client
4. **Correct environment variable naming**: Matches the server.ts implementation

If Red Hat updates their upstream images to fix these issues, we could switch back. Until then, our custom images are **required for production use**.

### GLOBEX_MOBILE_GATEWAY Configuration: Internal vs External URL

**Critical Architectural Difference**: How the globex-mobile frontend reaches the globex-mobile-gateway backend.

#### Red Hat's Demo Configuration

Red Hat's official Connectivity Link demo configures `GLOBEX_MOBILE_GATEWAY` to use the **external Gateway API URL**:

```yaml
# From Red Hat's Ansible deployment
# https://github.com/rh-soln-pattern-connectivity-link/connectivity-link-ansible
ocp4_workload_cloud_architecture_workshop_mobile_gateway_url: "https://globex-mobile.globex.%AWSROOTZONE%"

# Translates to:
GLOBEX_MOBILE_GATEWAY=https://globex-mobile.globex.<cluster-domain>
```

**What this means**:
- Frontend (globex-mobile) runs in a pod inside the cluster
- Frontend calls backend API at `https://globex-mobile.globex.<cluster-domain>/mobile/services/category/list`
- This URL points to the external Gateway API (HTTPRoute)
- **Requires pods to reach their own external hostname** (hairpin routing)

**Why Red Hat designed it this way**:
- Demonstrates dependency on HTTPRoute for application functionality
- Without HTTPRoute deployed: User clicks "Categories" → HTTP 404 error
- With HTTPRoute deployed: User clicks "Categories" → Works ✅
- Shows Gateway API value proposition clearly

#### Our Implementation

We use the **internal ClusterIP service URL** instead:

```yaml
# kustomize/base/globex-apim-user1-deployment-globex-mobile.yaml
- name: GLOBEX_MOBILE_GATEWAY
  value: "http://globex-mobile-gateway:8080"  # Internal service
```

**What this means**:
- Frontend (globex-mobile) calls backend via Kubernetes internal DNS
- No dependency on external Gateway or HTTPRoute
- Application works regardless of HTTPRoute existence
- HTTPRoute still valuable for **external API consumers** (not web browsers)

**Why we changed this**:
- Current cluster does **NOT support hairpin routing** (pods cannot reach own external IPs/hostnames)
- Using external URL resulted in **NetworkError** when clicking Categories
- Internal service URL always works (standard Kubernetes service discovery)

#### The Hairpin Routing Problem

**What is hairpin routing?**

Hairpin routing (also called hairpin NAT or NAT loopback) allows network nodes to reach their own external IP addresses:

```
┌─────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                 │
│                                                     │
│  ┌──────────────┐                                  │
│  │ Pod (source) │                                  │
│  │ 10.0.1.5     │                                  │
│  └──────┬───────┘                                  │
│         │                                          │
│         │ Request to: https://app.example.com     │
│         │ (cluster's own external hostname)       │
│         ↓                                          │
│  ┌─────────────────┐                              │
│  │ Router/Gateway  │                              │
│  │                 │                              │
│  │ Detects this is │                              │
│  │ own public IP   │                              │
│  │                 │                              │
│  │ Hairpin route:  │                              │
│  │ Redirect back   │                              │
│  │ into cluster    │                              │
│  └────────┬────────┘                              │
│           │                                        │
│           ↓                                        │
│  ┌──────────────────┐                             │
│  │ Service/Pod      │                             │
│  │ (destination)    │                             │
│  └──────────────────┘                             │
│                                                    │
└────────────────────────────────────────────────────┘
```

**Without hairpin routing**:
- Pod tries to reach `https://globex-mobile.globex.<cluster-domain>`
- Request goes to external internet/load balancer
- Load balancer cannot route back to originating cluster
- Result: Connection timeout or NetworkError

#### How Red Hat's Demo Works (Possible Explanations)

Red Hat's documentation does **NOT explain** how hairpin routing is enabled. Possible explanations:

**1. AWS Network Load Balancer (NLB) Hairpin Mode**:
- AWS NLB may support hairpin connections natively in certain configurations
- OpenShift on AWS uses NLB for LoadBalancer services
- Some AWS regions/setups enable this automatically

**2. OpenShift Ingress Operator Magic**:
- The Ingress Operator managing Gateway API might have built-in hairpin logic
- Could detect internal-to-external calls and short-circuit to ClusterIP
- Not documented publicly

**3. Custom VPC Routing**:
- Red Hat demo clusters (ROSA, Red Hat Demo Platform) might have custom VPC route tables
- Could enable pods to reach Load Balancer public IPs via internal routing
- Specific to Red Hat's demo infrastructure

**4. Split-Horizon DNS (CoreDNS)**:
- CoreDNS could be configured to return internal IPs for external hostnames
- When pods query `globex-mobile.globex.<domain>`, CoreDNS returns ClusterIP
- External clients get public IP, internal clients get ClusterIP
- Not standard CoreDNS configuration for OpenShift

**5. Documentation Gap**:
- Feature works in Red Hat's demo environment but isn't documented
- May be specific to their workshop/demo clusters
- Not intended for production use

#### Our Solution: Internal Service URL

**Current configuration**:
```yaml
GLOBEX_MOBILE_GATEWAY=http://globex-mobile-gateway:8080
```

**Benefits**:
- ✅ Works on **any** Kubernetes/OpenShift cluster
- ✅ No dependency on hairpin routing support
- ✅ Faster (no external network hop)
- ✅ More secure (traffic never leaves cluster)
- ✅ Standard Kubernetes service discovery pattern

**Trade-offs**:
- ❌ HTTPRoute not required for app to function (less dramatic demo)
- ℹ️ HTTPRoute still valuable for external API consumers

#### HTTPRoute Purpose and Value

Even though our frontend doesn't use HTTPRoute, it's still valuable for:

**1. External API Access**:
```bash
# Direct API access from internet with JWT authentication
curl -H "Authorization: Bearer $TOKEN" \
  https://globex-mobile.globex.<cluster-domain>/mobile/services/category/list
```

**2. API Consumer Integration**:
- Third-party applications consuming the mobile API
- Mobile apps calling backend directly
- Microservices architecture (if we had microservices)

**3. Gateway API Demonstration**:
- Shows HTTPRoute path-based routing
- Demonstrates AuthPolicy with JWT validation
- Shows RateLimitPolicy enforcement (20 req/10s)
- Proves cross-namespace service access via ReferenceGrant

**4. Production API Management**:
- Rate limiting prevents API abuse
- JWT authentication secures endpoints
- DNS automation for API consumers
- TLS termination at Gateway

#### Architecture Comparison

**Red Hat Demo (requires hairpin routing)**:
```
User clicks "Categories"
  ↓
Frontend (Angular) calls https://globex-mobile.globex.<domain>/mobile/services/category/list
  ↓
Pod → Cluster Egress → External Load Balancer → Hairpin Route → HTTPRoute → Backend
  ↓
Without HTTPRoute: 404 error (demonstrates Gateway API dependency)
With HTTPRoute: Works ✅ (dramatic demo effect)
```

**Our Implementation (hairpin routing not supported)**:
```
User clicks "Categories"
  ↓
Frontend (Angular) calls http://globex-mobile-gateway:8080/mobile/services/category/list
  ↓
Pod → Internal ClusterIP Service → Backend
  ↓
Always works ✅ (standard Kubernetes pattern)

Separate flow:
External API consumer → https://globex-mobile.globex.<domain> → HTTPRoute → Backend
                                                                    ↓
                                                         AuthPolicy + RateLimitPolicy
```

#### When to Use Each Approach

**Use External URL (Red Hat's approach)** when:
- ✅ Cluster supports hairpin routing (verify first!)
- ✅ Demonstrating Gateway API dependency is critical
- ✅ All API consumers (internal + external) should use same URL
- ✅ Centralized policy enforcement required for all traffic

**Use Internal URL (our approach)** when:
- ✅ Hairpin routing not supported or uncertain
- ✅ Performance is critical (avoid external network hop)
- ✅ Security is critical (keep internal traffic internal)
- ✅ Standard Kubernetes patterns preferred
- ✅ HTTPRoute for external consumers only

#### Verification: Testing Hairpin Routing

To test if your cluster supports hairpin routing:

```bash
# 1. Get Gateway external hostname
EXTERNAL_URL=$(oc get httproute productcatalog -n ingress-gateway -o jsonpath='{.spec.hostnames[0]}')

# 2. Test from inside a pod
oc exec -n globex-apim-user1 deployment/globex-mobile -- \
  curl -sk "https://${EXTERNAL_URL}/services/catalog/product" -w "\n%{http_code}\n"

# Expected with hairpin routing: HTTP 200 + JSON response
# Expected without hairpin routing: Connection timeout or NetworkError
```

If the test **succeeds**, your cluster supports hairpin routing and you could use Red Hat's external URL pattern.

If the test **fails**, hairpin routing is not supported and you must use internal service URLs.

#### Conclusion

**Our implementation is production-ready and more portable** than Red Hat's demo configuration:

- ✅ Works on **any** Kubernetes/OpenShift cluster (no hairpin routing required)
- ✅ Follows **standard Kubernetes networking patterns** (service discovery)
- ✅ Better **performance and security** (no external network hop)
- ✅ HTTPRoute still provides **value for external API consumers**
- ✅ **Same user experience** (41 products, 7 categories, OAuth login)
- ✅ **Same Gateway API demonstration** (just for external consumers, not internal frontend)

Red Hat's approach creates a more dramatic demo (without HTTPRoute → app breaks), but requires cluster infrastructure support (hairpin routing) that may not be available in all environments.

