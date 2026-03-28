# External Service Simulation - Pedagogical Architecture

## Context

This project demonstrates **Gateway API for consuming external services**. For practical reasons, the external service (ProductInfo) is deployed in the same cluster, but it represents **conceptually an external/partner API**.

---

## ProductInfo Service - External API Simulation

### What is ProductInfo Service?

**Business Function:**
- Product catalog API
- Provides product details, categories, pricing
- Core data source for e-commerce frontend

**In Production (Real World):**
- Partner product catalog API (e.g., Akeneo, commercetools)
- External product information provider
- Microservice owned by separate team/organization
- Third-party product data service

**In This Demo:**
- **Deployed as:** `globex-mobile-gateway` (Quarkus REST API)
- **Simulated as:** External ProductInfo service
- **Accessed via:** Gateway API HTTPRoute (not ClusterIP)
- **Located:** Same cluster (for demo simplicity)

### Why Not ClusterIP Direct?

**ClusterIP would be simpler technically, BUT:**

❌ Doesn't demonstrate Gateway API for external services
❌ Doesn't reflect real architecture (external API consumption)
❌ Doesn't allow testing policies (AuthPolicy, RateLimitPolicy)
❌ Misses the pedagogical point of the demo

**Gateway API demonstrates:**

✅ Pattern for consuming external/partner APIs
✅ Applying policies on external service calls
✅ Architecture aligned with real production use cases
✅ Separation of concerns (internal vs external services)

---

## Architecture Overview

### Component Roles

**globex-mobile** (Frontend - Internal Application)
- Angular SPA
- Main application owned by organization
- Deployed and managed internally

**ProductInfo Service** (External API - Simulated)
- **Conceptual role:** External product catalog provider
- **Technical implementation:** `globex-mobile-gateway` deployment
- **Why external:** Simulates partner API or separate team's service
- **Access pattern:** Via Gateway API (like calling Stripe, Twilio, etc.)

**globex-store-app** (Internal Backend - Database Layer)
- Quarkus monolith
- Internal database access and business logic
- Not exposed externally
- ClusterIP communication only

### Data Flow

```
User Browser
  │
  │ HTTPS (north-south)
  ▼
┌─────────────────────────────────────────────┐
│ globex-mobile                               │
│ (Frontend Application - Internal)           │
└────────────────┬────────────────────────────┘
                 │
                 │ Gateway API HTTPRoute
                 │ https://productinfo.globex.<domain>
                 │ (Simulates external API call)
                 ▼
┌─────────────────────────────────────────────┐
│ ProductInfo Service                         │
│ (External Product Catalog API - Simulated)  │
│                                             │
│ Technical:                                  │
│   Deployment: globex-mobile-gateway         │
│   Service: globex-mobile-gateway:8080       │
│                                             │
│ Conceptual:                                 │
│   External partner product data API         │
│   Accessed via Gateway API                  │
│                                             │
│ Endpoints:                                  │
│   GET /mobile/services/product/{id}         │
│   GET /mobile/services/category/list        │
└────────────────┬────────────────────────────┘
                 │
                 │ ClusterIP (east-west)
                 │ http://globex-store-app:8080
                 │ (Internal backend communication)
                 ▼
┌─────────────────────────────────────────────┐
│ globex-store-app                            │
│ (Internal Database Backend)                 │
│                                             │
│   PostgreSQL access                         │
│   Business logic                            │
│   Not exposed externally                    │
└─────────────────────────────────────────────┘
```

---

## Real-World Production Patterns

This architecture simulates common production patterns where applications consume external services.

### Pattern 1: E-commerce with Partner APIs

**Real Architecture:**
```
E-commerce Frontend (React/Angular)
  ↓ Gateway API
Product Catalog API (Akeneo - external partner)
  ↓ Gateway API
Payment API (Stripe - external service)
  ↓ Gateway API
Shipping API (Shippo - external service)
```

**Globex Simulation:**
```
globex-mobile (Frontend)
  ↓ Gateway API
ProductInfo Service (simulated external catalog)
  ↓ Internal
globex-store-app (internal backend)
```

### Pattern 2: Microservices Multi-Team

**Real Architecture:**
```
Mobile App (Team A)
  ↓ Gateway API
User Service (Team B - separate deployment)
  ↓ Gateway API
Order Service (Team C - separate deployment)
  ↓ Gateway API
Analytics Service (Team D - separate deployment)
```

**Globex Simulation:**
```
globex-mobile (Team Frontend)
  ↓ Gateway API
ProductInfo Service (Team Catalog - simulated separation)
  ↓ Internal
globex-store-app (shared backend)
```

### Pattern 3: SaaS Platform with Add-ons

**Real Architecture:**
```
SaaS Platform Frontend
  ↓ Gateway API
Core Platform API (internal)
  ↓ Gateway API
Add-on Service 1 (external partner)
  ↓ Gateway API
Add-on Service 2 (external partner)
```

**Globex Simulation:**
```
globex-mobile (platform frontend)
  ↓ Gateway API
ProductInfo Service (simulated add-on)
  ↓ Internal
globex-store-app (core platform)
```

---

## Why This Matters for Gateway API Demo

### What We're Demonstrating

**Without this narrative:**
- "Why not just use ClusterIP everywhere?" ❓
- "This seems over-engineered" ❓
- "Gateway API doesn't add value here" ❓

**With ProductInfo as external service:**
- "Ah! We're calling an external product catalog API" ✅
- "Gateway API is how we manage external dependencies" ✅
- "This is realistic - apps call partner APIs all the time" ✅

### Gateway API Value Proposition

**For ProductInfo service (external), Gateway API enables:**

1. **Policies on external calls:**
   - RateLimitPolicy: Limit calls to partner API (avoid costs)
   - AuthPolicy: Secure API key validation
   - TLSPolicy: Automated certificate management

2. **Routing strategies:**
   - Canary: Test new partner API version (10% traffic)
   - Blue-Green: Switch between API providers
   - Failover: Backup ProductInfo provider

3. **Observability:**
   - Monitor external API latency
   - Track external API errors
   - Alert on partner API issues

4. **Cost control:**
   - Rate limiting prevents runaway API costs
   - Circuit breaking for degraded partners
   - Quota management per partner

---

## Documentation Conventions

### Naming in Documentation

**Business/Conceptual Level:**
- ✅ "ProductInfo service"
- ✅ "External product catalog API"
- ✅ "Partner ProductInfo API"

**Technical/Implementation Level:**
- ✅ "globex-mobile-gateway deployment"
- ✅ "globex-mobile-gateway service"
- ✅ "globex-mobile-gateway:8080"

**Example sentence:**
```
"The frontend calls the ProductInfo service (implemented as
globex-mobile-gateway) via Gateway API HTTPRoute to retrieve
product catalog data."
```

### Architecture Diagrams

**Diagram labels:**
- Primary label: "ProductInfo Service"
- Subtitle: "(External API - Simulated)"
- Technical note: "Deployment: globex-mobile-gateway"

**HTTPRoute resource:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: productinfo  # Business function
  labels:
    app: globex-mobile-gateway  # Technical deployment
    app.kubernetes.io/component: external-api
spec:
  hostnames:
    - productinfo.globex.sandbox3491.opentlc.com  # Clear naming
  rules:
    - backendRefs:
        - name: globex-mobile-gateway  # Actual K8s service
          port: 8080
```

---

## Justification for Architecture Choices

### Why Simulate, Not Use Real External API?

**Practical reasons:**
- ✅ Demo doesn't depend on external service availability
- ✅ No API keys or paid accounts required
- ✅ Reproducible in any environment
- ✅ Faster (no external network latency)

**Pedagogical reasons:**
- ✅ Same architecture patterns apply
- ✅ Demonstrates Gateway API usage clearly
- ✅ Allows testing all scenarios (failures, rate limits, etc.)

### Why Not Service Mesh for East-West?

This project focuses on **Gateway API**, not Service Mesh (Istio).

**Service Mesh** is for:
- East-west traffic (service-to-service internal)
- mTLS between services
- Internal traffic policies

**Gateway API** is for:
- North-south traffic (external → cluster)
- External service consumption
- Ingress with policies

**Our choice:**
- ProductInfo = North-south (external service) → **Gateway API** ✅
- globex-store-app = East-west (internal) → **ClusterIP** ✅

---

## Production Deployment Considerations

### When This Pattern Applies

**Use Gateway API for external services when:**

✅ Service is owned by external partner/vendor
✅ Service is managed by separate team/organization
✅ Need policies on external calls (rate limits, auth, quotas)
✅ Want observability on external dependencies
✅ Need routing flexibility (canary, failover, blue-green)

### When NOT to Use This Pattern

**Don't use Gateway API for:**

❌ Internal service-to-service communication (use ClusterIP)
❌ Tightly-coupled components of same application
❌ Database connections
❌ Internal message queues

**For those cases:**
- Use ClusterIP for simple internal communication
- Use Service Mesh (Istio) if you need policies on internal traffic

---

## Summary

**ProductInfo service is simulated as external to demonstrate:**

1. ✅ Gateway API pattern for consuming external/partner APIs
2. ✅ Realistic architecture for modern composite applications
3. ✅ Value of policies on external service dependencies
4. ✅ Production-ready patterns in a reproducible demo

**This is intentional pedagogical architecture**, not accidental complexity.

The pattern demonstrated here applies directly to real production scenarios where applications consume external product catalogs, payment gateways, shipping APIs, or microservices from other teams.

---

**Last Updated**: 2026-03-28
**Purpose**: Explain ProductInfo service simulation rationale
**Key Concept**: External service pattern demonstration via Gateway API
