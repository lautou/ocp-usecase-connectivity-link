# Routing Architecture Comparison - Visual Diagrams

## 1. Current Architecture (What We Have)

```
┌─────────────┐
│ External    │
│ User        │
└──────┬──────┘
       │ HTTPS
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ OpenShift Router (Traditional Ingress)                   │
│                                                           │
│  Routes:                                                  │
│  - globex-mobile-globex-apim-user1.apps.<domain>        │
│  - globex-mobile-gateway-globex-apim-user1.apps.<domain>│
└──────┬───────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                             │
│                                                           │
│  ┌─────────────────┐   HTTP (internal)   ┌────────────┐ │
│  │ globex-mobile   ├───────────────────►  │ globex-    │ │
│  │ Pod             │   :8080              │ mobile-    │ │
│  │                 │                      │ gateway    │ │
│  │ (Angular SSR)   │                      │ Pod        │ │
│  └─────────────────┘                      │            │ │
│         ▲                                 │ (Quarkus)  │ │
│         │ Service ClusterIP               └─────┬──────┘ │
│         │ 172.30.174.139:8080                   │        │
│         │                                       │ HTTP   │
│  ┌──────┴──────┐                                │ :8080  │
│  │ globex-     │                                │        │
│  │ mobile      │                                ▼        │
│  │ Service     │                         ┌─────────────┐ │
│  └─────────────┘                         │ globex-     │ │
│                                          │ store-app   │ │
│                    Service ClusterIP     │ Pod         │ │
│                    172.30.28.134:8080    │             │ │
│                           ▲              │ (Quarkus)   │ │
│                           │              └─────────────┘ │
│                    ┌──────┴──────┐              ▲        │
│                    │ globex-     │              │        │
│                    │ mobile-     │ Service      │        │
│                    │ gateway     │ ClusterIP    │        │
│                    │ Service     │ 172.30.244.  │        │
│                    └─────────────┘ 210:8080     │        │
│                                         ┌───────┴──────┐ │
│                                         │ globex-      │ │
│                                         │ store-app    │ │
│                                         │ Service      │ │
│                                         └──────────────┘ │
└──────────────────────────────────────────────────────────┘

Key Points:
✅ External access via OpenShift Routes (NOT Gateway API)
✅ All service-to-service calls are INTERNAL (ClusterIP)
✅ No HTTPRoutes configured for Globex
❌ NOT using Gateway API for routing
❌ Cannot demonstrate HTTPRoute necessity
```

---

## 2. Red Hat Tutorial Architecture (Expected)

```
┌─────────────┐
│ External    │
│ User        │
└──────┬──────┘
       │ HTTPS
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ Gateway API (prod-web)                                   │
│ Namespace: ingress-gateway                               │
│                                                           │
│ Hostname: *.globex.sandbox3491.opentlc.com              │
│                                                           │
│ Policies:                                                │
│ - TLSPolicy (Let's Encrypt certs)                       │
│ - AuthPolicy (deny by default)                          │
│ - RateLimitPolicy (10 req/s)                            │
└──────┬───────────────────────────────────────────────────┘
       │
       ├─────────────────┬─────────────────┬────────────────┐
       │                 │                 │                │
       ▼                 ▼                 ▼                ▼
┌─────────────┐   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│ HTTPRoute   │   │ HTTPRoute   │  │ HTTPRoute   │  │ HTTPRoute   │
│             │   │             │  │             │  │ ❌ MISSING  │
│ globex-     │   │ globex-     │  │ globex-     │  │             │
│ mobile      │   │ mobile-     │  │ store-app   │  │ product-    │
│             │   │ gateway     │  │             │  │ details     │
│ ✅ EXISTS   │   │ ✅ EXISTS   │  │ ⚠️ OPTIONAL │  │             │
└──────┬──────┘   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                 │                │                │
       │                 │                │                │
       ▼                 ▼                ▼                ▼
┌──────────────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                                     │
│                                                                   │
│  ┌─────────────┐                                                 │
│  │ globex-     │    HTTPS (via Gateway)                          │
│  │ mobile      │───────────────────────┐                         │
│  │ Pod         │                       │                         │
│  │             │                       ▼                         │
│  └─────────────┘        ┌──────────────────────────────┐         │
│       ▲                 │ Gateway (hairpin routing)    │         │
│       │                 │ globex-mobile-gateway.globex │         │
│       │                 │ .sandbox3491.opentlc.com     │         │
│  ┌────┴─────┐           └──────────┬───────────────────┘         │
│  │ globex-  │                      │                             │
│  │ mobile   │                      ▼                             │
│  │ Service  │           ┌────────────────┐                       │
│  └──────────┘           │ globex-mobile- │                       │
│                         │ gateway Pod    │                       │
│                         │                │  HTTPS (via Gateway)  │
│                         └────────┬───────┘──────────────┐        │
│                                  │                      │        │
│                                  ▼                      ▼        │
│                    ┌──────────────────────────────┐             │
│                    │ Gateway (hairpin routing)    │             │
│                    │ globex-store-app.globex      │             │
│                    │ .sandbox3491.opentlc.com     │             │
│                    └──────────┬───────────────────┘             │
│                               │                                 │
│                               ▼                                 │
│                    ┌────────────────┐                           │
│                    │ globex-store-  │                           │
│                    │ app Pod        │                           │
│                    │ (ProductCatalog)│                          │
│                    └────────────────┘                           │
│                                                                  │
│  Tutorial Demo: Access product-details BEFORE HTTPRoute exists  │
│                                                                  │
│  curl https://product-details.globex.<domain>/details/1         │
│  → 404 Not Found ❌ (no HTTPRoute configured)                   │
│                                                                  │
│  Then create HTTPRoute for product-details                      │
│                                                                  │
│  curl https://product-details.globex.<domain>/details/1         │
│  → 200 OK ✅ (HTTPRoute now routes to service)                  │
└──────────────────────────────────────────────────────────────────┘

Key Points:
✅ ALL traffic goes through Gateway API
✅ HTTPRoute REQUIRED for each externally accessible service
✅ Can demonstrate 404 when HTTPRoute missing
✅ Shows necessity of HTTPRoute for routing
⚠️ Higher latency (multiple Gateway hops)
⚠️ More complex (hairpin routing for internal calls)
```

---

## 3. Recommended Production Architecture (Hybrid)

```
┌─────────────┐
│ External    │
│ User        │
└──────┬──────┘
       │ HTTPS
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ Gateway API (prod-web)                                   │
│ Namespace: ingress-gateway                               │
│                                                           │
│ Hostname: *.globex.sandbox3491.opentlc.com              │
│                                                           │
│ Policies Applied:                                        │
│ - TLSPolicy → Let's Encrypt certificates                │
│ - AuthPolicy → Deny by default                          │
│ - RateLimitPolicy → 10 requests/second                  │
└──────┬───────────────────────────────────────────────────┘
       │
       │ ONLY user-facing services exposed
       │
       ▼
┌─────────────────┐
│ HTTPRoute       │
│ globex-mobile   │  ◄─── ONLY THIS exposed via Gateway
│                 │
│ Overrides:      │
│ - AuthPolicy    │
│   (allow auth)  │
│ - RateLimitPolicy│
│   (50 req/s)    │
└────────┬────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                             │
│                                                           │
│  ┌─────────────────┐                                     │
│  │ globex-mobile   │   HTTP (internal)                   │
│  │ Pod             ├──────────────────┐                  │
│  │                 │   ClusterIP       │                 │
│  │ (Angular SSR)   │   :8080           ▼                 │
│  └─────────────────┘         ┌──────────────────┐        │
│         ▲                    │ globex-mobile-   │        │
│         │                    │ gateway Pod      │        │
│         │                    │                  │        │
│  ┌──────┴──────┐             │ (Quarkus)        │        │
│  │ globex-     │             └────────┬─────────┘        │
│  │ mobile      │                      │                  │
│  │ Service     │                      │ HTTP (internal)  │
│  │ (ClusterIP) │                      │ ClusterIP :8080  │
│  └─────────────┘                      ▼                  │
│                            ┌──────────────────┐          │
│                            │ globex-store-app │          │
│  ❌ NOT exposed            │ Pod              │          │
│     via Gateway            │                  │          │
│  ❌ NO HTTPRoute           │ (Quarkus)        │          │
│     needed                 └──────────────────┘          │
│  ✅ Internal only                   ▲                    │
│                            ┌────────┴────────┐           │
│                            │ globex-store-   │           │
│                            │ app Service     │           │
│                            │ (ClusterIP)     │           │
│                            │                 │           │
│  ❌ NOT exposed            │ NOT accessible  │           │
│     externally             │ from outside    │           │
│                            └─────────────────┘           │
└──────────────────────────────────────────────────────────┘

Traffic Flow:
┌────────────────────────────────────────────────────────────────┐
│ North-South (External → Service)                               │
│                                                                 │
│ User → Gateway API → HTTPRoute → globex-mobile Service         │
│                                                                 │
│ ✅ Uses Gateway API (TLS, Auth, RateLimit applied)            │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ East-West (Service → Service)                                  │
│                                                                 │
│ globex-mobile → ClusterIP → globex-mobile-gateway              │
│ globex-mobile-gateway → ClusterIP → globex-store-app           │
│                                                                 │
│ ✅ Direct ClusterIP (low latency, no Gateway overhead)        │
└────────────────────────────────────────────────────────────────┘

Key Points:
✅ Gateway API for external access ONLY
✅ ClusterIP for internal service-to-service calls
✅ Lower latency (no unnecessary Gateway hops)
✅ Reduced attack surface (internal services not exposed)
✅ API Management policies applied at ingress point
✅ Standard Kubernetes networking patterns
⚠️ Cannot demonstrate HTTPRoute necessity for ALL services
✅ Can still demo for NEW externally-facing services
```

---

## 4. Tutorial Demo: Demonstrating HTTPRoute Necessity

### Scenario: Add New External Service

```
Developer wants to expose a new "ProductReviews" service

Step 1: Deploy Service WITHOUT HTTPRoute
─────────────────────────────────────────────────────────────
oc apply -f product-reviews-deployment.yaml
oc apply -f product-reviews-service.yaml

Step 2: Try to Access Externally
─────────────────────────────────────────────────────────────
$ curl -k https://product-reviews.globex.sandbox3491.opentlc.com/reviews/1

❌ 404 Not Found

Why: Gateway has no HTTPRoute configured for this hostname
     Gateway doesn't know how to route the request

Step 3: Create HTTPRoute
─────────────────────────────────────────────────────────────
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: product-reviews
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - product-reviews.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: product-reviews
          port: 8080

oc apply -f product-reviews-httproute.yaml

Step 4: Access Now Works
─────────────────────────────────────────────────────────────
$ curl -k https://product-reviews.globex.sandbox3491.opentlc.com/reviews/1

✅ 200 OK
{
  "productId": 1,
  "rating": 5,
  "review": "Excellent Quarkus T-Shirt!"
}

Why: HTTPRoute now tells Gateway how to route to the service
```

**Learning Objective**: HTTPRoute is REQUIRED to expose services via Gateway API

---

## Architecture Decision Matrix

| Requirement | Current (OpenShift Routes) | Tutorial (Full Gateway) | Recommended (Hybrid) |
|-------------|---------------------------|-------------------------|---------------------|
| **External Access** | ✅ Works | ✅ Works | ✅ Works |
| **Internal Calls** | ✅ ClusterIP (fast) | ⚠️ Via Gateway (slow) | ✅ ClusterIP (fast) |
| **API Management** | ❌ Not applied | ✅ Applied everywhere | ✅ Applied at ingress |
| **Latency** | ✅ Low | ❌ High | ✅ Low |
| **Security** | ⚠️ All exposed | ⚠️ All exposed | ✅ Only public exposed |
| **Tutorial Demo** | ❌ Cannot show 404 | ✅ Shows 404 | ⚠️ Only for new services |
| **Complexity** | ✅ Simple | ⚠️ Complex | ✅ Moderate |
| **Production Ready** | ⚠️ Traditional | ⚠️ Over-engineered | ✅ Best practice |

---

## Recommendation

**For Learning/Tutorial**: Use **Tutorial Architecture** (Full Gateway API)
- Demonstrates HTTPRoute necessity
- Shows 404 errors when HTTPRoute missing
- Teaches Gateway API concepts

**For Production**: Use **Hybrid Architecture** (Gateway + ClusterIP)
- Best performance (low latency)
- Best security (minimal exposure)
- Industry standard pattern
- Simpler to operate

---

**Last Updated**: 2026-03-28
**Current State**: OpenShift Routes (not using Gateway API for Globex)
**Tutorial Expects**: Full Gateway API (all traffic through Gateway)
**Recommended**: Hybrid (Gateway for north-south, ClusterIP for east-west)
