# Architecture Hybride - ProductInfo via Gateway API

## Question de l'Utilisateur

> Peut-on faire en sorte de garder l'architecture actuelle et faire en sorte que ProductInfo soit appelé via la Gateway API? Quel serait l'impact?

---

## Architecture Proposée (Hybride)

### Architecture Actuelle (Baseline)

```
┌─────────────────┐
│ External User   │
└────────┬────────┘
         │ HTTPS
         ▼
┌────────────────────────────┐
│ OpenShift Route            │
│ globex-mobile              │
└────────┬───────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                            │
│                                                          │
│  ┌───────────────┐   ClusterIP (interne)                │
│  │ globex-mobile │   http://globex-mobile-gateway:8080  │
│  │ Pod           ├──────────────────┐                   │
│  └───────────────┘                  │                   │
│                                     ▼                    │
│                          ┌──────────────────────┐       │
│                          │ globex-mobile-       │       │
│                          │ gateway Pod          │       │
│                          └──────────┬───────────┘       │
│                                     │                    │
│                                     │ ClusterIP (interne)│
│                                     │ http://globex-     │
│                                     │ store-app:8080     │
│                                     ▼                    │
│                          ┌──────────────────────┐       │
│                          │ globex-store-app     │       │
│                          │ Pod                  │       │
│                          │ (ProductCatalog)     │       │
│                          └──────────────────────┘       │
└──────────────────────────────────────────────────────────┘

Caractéristiques:
✅ Tout en ClusterIP interne (east-west)
✅ Faible latence
✅ Simple
❌ Ne démontre pas Gateway API pour backend
```

### Architecture Hybride Proposée

```
┌─────────────────┐
│ External User   │
└────────┬────────┘
         │ HTTPS
         ▼
┌────────────────────────────┐
│ OpenShift Route            │
│ globex-mobile              │
└────────┬───────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                                │
│                                                              │
│  ┌───────────────┐   ClusterIP (interne)                    │
│  │ globex-mobile │   http://globex-mobile-gateway:8080      │
│  │ Pod           ├──────────────────┐                       │
│  └───────────────┘                  │                       │
│                                     ▼                        │
│                          ┌──────────────────────┐           │
│                          │ globex-mobile-       │           │
│                          │ gateway Pod          │           │
│                          └──────────┬───────────┘           │
│                                     │                        │
│                                     │ HTTPS (externe!)       │
│                                     │ https://product-info.  │
│                                     │ globex.<domain>        │
│                                     │                        │
│                                     │ (sort du namespace)    │
└─────────────────────────────────────┼────────────────────────┘
                                      │
                                      ▼
                           ┌──────────────────┐
                           │ Gateway API      │
                           │ (prod-web)       │
                           └────────┬─────────┘
                                    │
                                    │ ✅ HTTPRoute requis
                                    │ ✅ Policies appliquées
                                    │
                                    ▼
                           ┌──────────────────┐
                           │ HTTPRoute        │
                           │ product-info     │
                           └────────┬─────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────┐
│ Namespace: globex-apim-user1                                │
│                                                              │
│                          ┌──────────────────────┐           │
│                          │ Service:             │           │
│                          │ globex-store-app     │           │
│                          │ (ProductInfo API)    │           │
│                          └──────────┬───────────┘           │
│                                     │                        │
│                                     ▼                        │
│                          ┌──────────────────────┐           │
│                          │ globex-store-app     │           │
│                          │ Pod                  │           │
│                          └──────────────────────┘           │
└─────────────────────────────────────────────────────────────┘

Caractéristiques:
✅ Frontend → Backend: ClusterIP (rapide)
⚠️ Backend → ProductInfo: Gateway API (hairpin routing)
✅ Démontre Gateway API HTTPRoute necessity
⚠️ Latence accrue pour appels ProductInfo
```

---

## Analyse Détaillée de l'Impact

### 1. Impact sur la Latence

#### Appel Actuel (ClusterIP Direct)

```
globex-mobile-gateway Pod
  ↓ ClusterIP DNS lookup (1-2ms)
  ↓ Direct pod-to-pod (iptables/kube-proxy)
  ↓ Latence: ~5-10ms
  ↓
globex-store-app Pod
```

**Latency Breakdown:**
- DNS lookup: 1-2ms
- Network hop (pod-to-pod): 3-5ms
- Service processing: variable
- **Total overhead: ~5-10ms**

#### Appel via Gateway API (Hairpin Routing)

```
globex-mobile-gateway Pod
  ↓ DNS lookup externe (5-10ms)
  ↓ TLS handshake (10-50ms si pas de keep-alive)
  ↓ Exit namespace → External network
  ↓ AWS Load Balancer (10-20ms)
  ↓ Istio Gateway Pod - Envoy proxy (5-10ms)
  ↓   - TLS termination
  ↓   - HTTPRoute matching
  ↓   - AuthPolicy validation (si activée)
  ↓   - RateLimitPolicy check (si activée)
  ↓ Re-enter namespace
  ↓ Service routing (5ms)
  ↓ Latence: ~50-100ms
  ↓
globex-store-app Pod
```

**Latency Breakdown:**
- DNS lookup: 5-10ms
- TLS handshake (first request): 10-50ms
- Load Balancer: 10-20ms
- Istio Gateway processing: 5-10ms
- AuthPolicy/RateLimitPolicy: 5-15ms
- Service routing: 5ms
- **Total overhead: ~50-120ms (first request)**
- **Keep-alive requests: ~30-50ms**

**Impact Latence:**
- ⚠️ **Augmentation: 5-10x** (de 10ms à 50-100ms)
- ⚠️ Plus variable (dépend de LB, policies, etc.)
- ⚠️ Premier appel plus lent (TLS handshake)

#### Mesure Réelle Attendue

| Métrique | ClusterIP | Via Gateway API | Delta |
|----------|-----------|-----------------|-------|
| **P50 latency** | 10ms | 50ms | +40ms (+400%) |
| **P95 latency** | 15ms | 120ms | +105ms (+700%) |
| **P99 latency** | 25ms | 200ms | +175ms (+700%) |
| **TLS overhead** | 0ms | 10-50ms | First request |
| **Keep-alive** | N/A | Réduit à 30-50ms | Après warmup |

---

### 2. Impact sur la Complexité

#### Configuration Requise

**Nouveau HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: product-info
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - product-info.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-store-app
          port: 8080
```

**Nouveau ReferenceGrant (si pas déjà existant):**
```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: globex-to-gateway
  namespace: ingress-gateway
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: globex-apim-user1
  to:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: prod-web
```

**Modifier globex-mobile-gateway deployment:**
```yaml
env:
  # Ancien (ClusterIP):
  - name: GLOBEX_STORE_APP_URL
    value: http://globex-store-app:8080

  # Nouveau (Gateway API):
  - name: GLOBEX_STORE_APP_URL
    value: https://product-info.globex.sandbox3491.opentlc.com
```

**DNS externe:**
```
product-info.globex.sandbox3491.opentlc.com
  → CNAME → a7558ed31dbac4463b44c1689fb32092-...elb.amazonaws.com
```

**Complexité ajoutée:**
- ✅ 1 HTTPRoute supplémentaire
- ✅ 1 ReferenceGrant (si pas déjà là)
- ✅ 1 enregistrement DNS
- ✅ Configuration TLS (géré par TLSPolicy)
- ⚠️ Debugging plus complexe (plus de hops)

---

### 3. Impact sur la Sécurité

#### Exposition du Service

**Avant (ClusterIP):**
```
globex-store-app:
  - Accessible SEULEMENT depuis l'intérieur du namespace
  - Pas d'exposition externe
  - Pas de risque d'accès direct non autorisé
```

**Après (Gateway API):**
```
globex-store-app:
  - Accessible via Gateway API
  - MAIS protégé par:
    ✅ TLS termination (Gateway)
    ✅ AuthPolicy (si configurée)
    ✅ RateLimitPolicy (si configurée)
    ✅ NetworkPolicies Kubernetes (si configurées)
```

**Évaluation Sécurité:**

| Aspect | ClusterIP | Via Gateway API |
|--------|-----------|-----------------|
| **Exposition** | ❌ Interne uniquement | ⚠️ Via Gateway (contrôlé) |
| **TLS** | ❌ Non (HTTP interne) | ✅ Oui (HTTPS) |
| **Authentication** | ⚠️ Implicite (network) | ✅ Explicite (AuthPolicy) |
| **Rate Limiting** | ❌ Non | ✅ Oui (RateLimitPolicy) |
| **Network Attack** | ✅ Protégé (pas exposé) | ⚠️ Exposé mais policies |
| **Man-in-the-Middle** | ⚠️ Possible (HTTP interne) | ✅ Impossible (TLS) |

**Recommandation Sécurité:**

Si vous exposez via Gateway API:
```yaml
# MUST HAVE: AuthPolicy pour protéger
apiVersion: kuadrant.io/v1beta2
kind: AuthPolicy
metadata:
  name: product-info-auth
  namespace: globex-apim-user1
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: product-info
  rules:
    authentication:
      "service-to-service":
        jwt:
          issuerUrl: https://keycloak.../realms/globex-user1

# MUST HAVE: RateLimitPolicy pour éviter abuse
apiVersion: kuadrant.io/v1beta2
kind: RateLimitPolicy
metadata:
  name: product-info-ratelimit
  namespace: globex-apim-user1
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: product-info
  limits:
    "backend-api":
      rates:
        - limit: 100
          duration: 10
          unit: second
```

**Sans ces policies:** ⚠️ **Service backend exposé sans protection!**

---

### 4. Impact sur l'Observability

#### Metrics Disponibles

**ClusterIP (Actuel):**
```
Metrics:
  - Service metrics (Prometheus)
  - Pod metrics (CPU, memory)
  - Application metrics (custom)

Limitation:
  - Pas de metrics au niveau Gateway
  - Pas de metrics de traffic externe
  - Pas de métriques AuthPolicy/RateLimitPolicy
```

**Gateway API:**
```
Metrics supplémentaires:
  ✅ HTTPRoute metrics:
     - Requests per second
     - Latency (p50, p95, p99)
     - Error rate (5xx)
     - Status code distribution

  ✅ Gateway metrics:
     - Traffic par HTTPRoute
     - TLS handshakes
     - Connection pool stats

  ✅ Policy metrics:
     - AuthPolicy: auth success/failure
     - RateLimitPolicy: rate limit hits
     - TLSPolicy: cert rotation events

  ✅ Istio/Envoy metrics:
     - Upstream/downstream bytes
     - Connection duration
     - Circuit breaker stats
```

**Dashboards possibles:**
```yaml
# Grafana Dashboard pour HTTPRoute
- Request Rate by HTTPRoute
- Latency Distribution (P50/P95/P99)
- Error Rate (4xx/5xx)
- Rate Limit Hit Rate
- Auth Failure Rate
- Top Consumers (by IP/User)
```

**Impact Observability:**
- ✅ **Beaucoup plus de visibilité**
- ✅ Metrics centralisées au Gateway
- ✅ Corrélation traffic externe/interne
- ⚠️ Plus de données à monitorer

---

### 5. Impact sur le Debugging

#### Debugging ClusterIP (Simple)

```
Problem: globex-mobile-gateway ne peut pas récupérer produits

Debugging:
1. Check pod logs: oc logs globex-mobile-gateway
2. Check service: oc get service globex-store-app
3. Test direct: oc exec globex-mobile-gateway -- curl http://globex-store-app:8080/catalog/category/list
4. Check network policy: oc get networkpolicy

Étapes: 4
Temps: ~5-10 minutes
```

#### Debugging via Gateway API (Plus Complexe)

```
Problem: globex-mobile-gateway ne peut pas récupérer produits via Gateway

Debugging:
1. Check pod logs: oc logs globex-mobile-gateway
2. Check HTTPRoute exists: oc get httproute product-info
3. Check HTTPRoute status: oc get httproute product-info -o yaml
4. Check ReferenceGrant: oc get referencegrant -n ingress-gateway
5. Check Gateway status: oc get gateway prod-web -n ingress-gateway
6. Check DNS resolution: nslookup product-info.globex.<domain>
7. Check TLS certificate: curl -v https://product-info.globex.<domain>
8. Check Istio Gateway logs: oc logs -n ingress-gateway deployment/prod-web-istio
9. Check AuthPolicy: oc get authpolicy product-info-auth -o yaml
10. Check RateLimitPolicy: oc get ratelimitpolicy product-info-ratelimit -o yaml
11. Test from pod: oc exec globex-mobile-gateway -- curl -k https://product-info.globex.<domain>/catalog/category/list
12. Check Envoy config: istioctl proxy-config routes <gateway-pod>

Étapes: 12
Temps: ~30-60 minutes
```

**Impact Debugging:**
- ⚠️ **Beaucoup plus de points de défaillance**
- ⚠️ Debugging 3-6x plus long
- ⚠️ Nécessite connaissance Istio/Envoy
- ✅ Mais meilleure observability aide

---

### 6. Impact sur la Démo HTTPRoute Necessity

#### Valeur pour Tutorial

**Scénario Demo:**

```
1. État initial: globex-mobile-gateway appelle globex-store-app en ClusterIP
   → Categories fonctionnent ✅

2. Modifier globex-mobile-gateway:
   env:
     GLOBEX_STORE_APP_URL: https://product-info.globex.<domain>

3. Redéployer (SANS créer HTTPRoute)
   → Categories retournent 404 ❌
   → Démontre: HTTPRoute nécessaire!

4. Créer HTTPRoute pour product-info
   → Categories fonctionnent ✅
   → Démontre: HTTPRoute résout le problème

5. Bonus: Appliquer RateLimitPolicy
   → Faire 100 requêtes rapides
   → Voir rate limiting en action
```

**Valeur Pédagogique:**

| Aspect | Valeur |
|--------|--------|
| **Démontre HTTPRoute necessity** | ✅✅✅ Excellent |
| **Montre API Management** | ✅✅✅ Rate limiting visible |
| **Réalisme** | ⚠️⚠️ Artificiel (hairpin routing) |
| **Production pattern** | ❌ Pas recommandé pour ce cas |
| **Complexité** | ⚠️ Moyenne |

---

## Comparaison des Architectures

### Option 1: Tout ClusterIP (Actuel)

```
Frontend → Backend → ProductCatalog
(ClusterIP) (ClusterIP)
```

**Pros:**
- ✅ Faible latence (10ms)
- ✅ Simple
- ✅ Sécurisé (pas exposé)
- ✅ Easy debugging

**Cons:**
- ❌ Ne démontre pas Gateway API
- ❌ Pas de rate limiting backend
- ❌ Pas d'observability Gateway

**Use case:** Production standard

---

### Option 2: Hybride (Proposée)

```
Frontend → Backend → Gateway API → ProductCatalog
(ClusterIP)         (hairpin)
```

**Pros:**
- ✅ Démontre HTTPRoute necessity
- ✅ Rate limiting backend visible
- ✅ Observability Gateway pour backend
- ⚠️ Garde frontend→backend rapide

**Cons:**
- ⚠️ Latence backend accrue (50-100ms)
- ⚠️ Hairpin routing (artificiel)
- ⚠️ Plus complexe (debugging, config)
- ⚠️ Service backend exposé (besoin policies)

**Use case:** Tutorial/Demo, pas production

---

### Option 3: Tout Gateway API

```
Frontend → Gateway → Backend → Gateway → ProductCatalog
         (HTTPRoute)          (HTTPRoute)
```

**Pros:**
- ✅✅ Démontre Gateway API partout
- ✅✅ API Management complet
- ✅✅ Observability maximale

**Cons:**
- ❌❌ Latence très élevée (100-200ms)
- ❌ Over-engineering extrême
- ❌ Debugging très complexe

**Use case:** Tutorial uniquement, jamais production

---

## Recommandation Finale

### Pour Démo/Tutorial: ✅ OUI, Architecture Hybride Acceptable

**Si votre objectif est:**
- Démontrer HTTPRoute necessity
- Montrer rate limiting backend
- Enseigner concepts Gateway API
- Ne pas toucher au frontend (garde ClusterIP rapide)

**Alors l'architecture hybride est un bon compromis:**

```yaml
# Garder:
globex-mobile → (ClusterIP) → globex-mobile-gateway

# Modifier SEULEMENT:
globex-mobile-gateway → (Gateway API) → globex-store-app
```

**Configuration:**

```yaml
# 1. HTTPRoute pour product-info
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: product-info
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - product-info.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-store-app
          port: 8080

---
# 2. AuthPolicy (REQUIS pour sécurité)
apiVersion: kuadrant.io/v1beta2
kind: AuthPolicy
metadata:
  name: product-info-auth
  namespace: globex-apim-user1
spec:
  targetRef:
    kind: HTTPRoute
    name: product-info
  rules:
    authentication:
      "jwt-validation":
        jwt:
          issuerUrl: https://keycloak.../realms/globex-user1

---
# 3. RateLimitPolicy (démo)
apiVersion: kuadrant.io/v1beta2
kind: RateLimitPolicy
metadata:
  name: product-info-ratelimit
  namespace: globex-apim-user1
spec:
  targetRef:
    kind: HTTPRoute
    name: product-info
  limits:
    "backend-limit":
      rates:
        - limit: 10  # Très bas pour démo visible
          duration: 10
          unit: second

---
# 4. Modifier deployment
kind: Deployment
metadata:
  name: globex-mobile-gateway
spec:
  template:
    spec:
      containers:
        - name: globex-mobile-gateway
          env:
            - name: GLOBEX_STORE_APP_URL
              value: https://product-info.globex.sandbox3491.opentlc.com
```

### Pour Production: ❌ NON, Garder ClusterIP

**Raisons:**
- Performance: 5-10x latence accrue pas justifiée
- Simplicité: Debugging beaucoup plus complexe
- Sécurité: Exposer backend nécessite policies strictes
- Standard: East-west traffic devrait rester interne

**Si besoin d'API Management en production:**
```
Frontend → (Gateway API HTTPRoute) → globex-mobile
globex-mobile → (ClusterIP) → globex-mobile-gateway
globex-mobile-gateway → (ClusterIP) → globex-store-app

API Management appliqué SEULEMENT au point d'entrée (frontend)
```

---

## Impact Summary Table

| Aspect | ClusterIP | Hybride (Proposé) | Tout Gateway |
|--------|-----------|-------------------|--------------|
| **Latence frontend→backend** | 10ms ✅ | 10ms ✅ | 50-100ms ❌ |
| **Latence backend→catalog** | 10ms ✅ | 50-100ms ⚠️ | 50-100ms ❌ |
| **Latence totale** | 20ms ✅ | 60-110ms ⚠️ | 100-200ms ❌ |
| **Complexité** | Simple ✅ | Moyenne ⚠️ | Haute ❌ |
| **Debugging** | Facile ✅ | Moyen ⚠️ | Difficile ❌ |
| **Sécurité** | Haute ✅ | Moyenne ⚠️ | Haute ✅ |
| **Demo value** | Aucune ❌ | Bonne ✅ | Excellente ✅ |
| **Production ready** | Oui ✅ | Non ❌ | Non ❌ |
| **Observability** | Basique ⚠️ | Bonne ✅ | Excellente ✅ |

---

## Conclusion

### Réponse Directe

**Peut-on garder l'architecture actuelle et faire ProductInfo via Gateway API?**
→ ✅ **OUI, techniquement possible**

**Quel serait l'impact?**

**Positif:**
- ✅ Démontre HTTPRoute necessity (404 sans HTTPRoute)
- ✅ Montre rate limiting backend en action
- ✅ Observability améliorée pour backend
- ✅ Garde frontend→backend rapide (ClusterIP)

**Négatif:**
- ⚠️ Latence backend→catalog: **5-10x plus lente** (10ms → 50-100ms)
- ⚠️ Hairpin routing (sort et rentre dans cluster - artificiel)
- ⚠️ Debugging **3-6x plus complexe**
- ⚠️ Backend exposé via Gateway (nécessite AuthPolicy + RateLimitPolicy)
- ⚠️ **Pas un pattern production** (seulement pour demo)

### Ma Recommandation

**Pour Tutorial/Demo:** ✅ **C'est une bonne approche de compromis**
- Démontre les concepts Gateway API
- Impact utilisateur limité (frontend toujours rapide)
- Permet de montrer 404 → HTTPRoute → 200

**Pour Production:** ❌ **Garder ClusterIP pour backend→catalog**
- Performance critique
- Simplicité opérationnelle
- Pattern standard Kubernetes

**Si besoin API Management en prod:** Appliquer Gateway API **SEULEMENT au point d'entrée** (frontend), pas pour east-west traffic.

---

**Last Updated**: 2026-03-28
**Architecture**: Hybride (ClusterIP + Gateway API partiel)
**Production Ready**: Non (Demo/Tutorial uniquement)
**Performance Impact**: Backend latency 5-10x slower
