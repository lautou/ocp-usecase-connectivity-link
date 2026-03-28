# Migration Gateway API pour Globex - Analyse Technique

## Questions de l'Utilisateur

1. Actuellement il y a-t-il une Gateway de Gateway API pour Globex?
2. Je voudrais utiliser uniquement une HTTPRoute, qu'est-ce que cela va m'apporter de plus?
3. Est-ce que la HTTPRoute va générer des CR Routes derrière?

---

## Question 1: Y a-t-il une Gateway pour Globex?

### Réponse: OUI, la Gateway `prod-web` existe déjà

**Gateway existante:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-web
  namespace: ingress-gateway
spec:
  gatewayClassName: istio
  listeners:
    - name: api
      hostname: '*.globex.sandbox3491.opentlc.com'  # ← Wildcard Globex!
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All  # ← Accepte HTTPRoutes de tous les namespaces
      tls:
        certificateRefs:
          - name: api-tls
        mode: Terminate
```

**Détails importants:**

| Propriété | Valeur | Signification |
|-----------|--------|---------------|
| **Hostname** | `*.globex.sandbox3491.opentlc.com` | Wildcard - accepte TOUS les sous-domaines |
| **Port** | 443 | HTTPS uniquement |
| **TLS** | Terminate | Gateway gère TLS, backend en HTTP |
| **allowedRoutes** | `from: All` | HTTPRoutes de n'importe quel namespace |
| **Load Balancer** | AWS ELB | `a7558ed31dbac4463b44c1689fb32092-...` |
| **Service** | `prod-web-istio` | LoadBalancer Type, port 443 |

**Policies déjà appliquées sur cette Gateway:**

```bash
$ oc get authpolicy,ratelimitpolicy,tlspolicy -n ingress-gateway

AuthPolicy:        prod-web-deny-all        # Deny by default
RateLimitPolicy:   prod-web-rlp-lowlimits   # 10 req/s global
TLSPolicy:         prod-web-tls-policy      # Let's Encrypt certs
DNSPolicy:         prod-web-dnspolicy       # Route53 DNS management
```

**État actuel:**

```yaml
status:
  listeners:
    - attachedRoutes: 1  # ← Seulement echo-api actuellement
      conditions:
        - type: Programmed
          status: "True"
        - type: kuadrant.io/AuthPolicyAffected
          status: "True"
        - type: kuadrant.io/RateLimitPolicyAffected
          status: "True"
```

### Conclusion Question 1

✅ **OUI, une Gateway existe déjà pour Globex**

- Name: `prod-web`
- Namespace: `ingress-gateway`
- Hostname: `*.globex.sandbox3491.opentlc.com` (wildcard - parfait pour Globex)
- Policies: AuthPolicy, RateLimitPolicy, TLSPolicy, DNSPolicy déjà configurées
- **Utilisée actuellement:** Seulement pour echo-api
- **Peut être utilisée pour Globex:** ✅ OUI, prête à l'emploi

**Pas besoin de créer une nouvelle Gateway!**

Juste créer HTTPRoute(s) pour Globex qui référencent `prod-web`.

---

## Question 2: Une Seule HTTPRoute vs Plusieurs - Qu'est-ce que Ça Apporte?

### Option A: Plusieurs HTTPRoutes (Une par Service)

```yaml
# HTTPRoute 1: Frontend
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-mobile
          port: 8080

---
# HTTPRoute 2: Backend API
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile-gateway.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-mobile-gateway
          port: 8080
```

**Avantages:**
- ✅ Séparation des responsabilités (un HTTPRoute par service)
- ✅ Policies indépendantes (AuthPolicy/RateLimit différentes par HTTPRoute)
- ✅ Déploiement indépendant (changer frontend sans toucher backend)
- ✅ Observability granulaire (metrics par HTTPRoute)
- ✅ Rollback facile (supprimer un HTTPRoute sans impacter l'autre)

**Inconvénients:**
- ⚠️ Plus de ressources à gérer (2 HTTPRoutes, 2 ReferenceGrants)
- ⚠️ Plus de configuration (répétition de parentRefs)

### Option B: Une Seule HTTPRoute avec Plusieurs Hostnames

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com
    - globex-mobile-gateway.globex.sandbox3491.opentlc.com
  rules:
    # Frontend
    - matches:
        - headers:
            - name: :authority  # Hostname matching
              value: globex-mobile.globex.sandbox3491.opentlc.com
      backendRefs:
        - name: globex-mobile
          port: 8080
    # Backend API
    - matches:
        - headers:
            - name: :authority
              value: globex-mobile-gateway.globex.sandbox3491.opentlc.com
      backendRefs:
        - name: globex-mobile-gateway
          port: 8080
```

**Avantages:**
- ✅ Une seule ressource à gérer
- ✅ Un seul ReferenceGrant
- ✅ Configuration centralisée

**Inconvénients:**
- ❌ Policies communes (même AuthPolicy/RateLimit pour tous)
- ❌ Pas de séparation des responsabilités
- ❌ Déploiement couplé (modifier un service = modifier HTTPRoute global)
- ❌ Moins flexible pour canary deployments

### Option C: Une HTTPRoute avec Path-Based Routing (Pattern Tutorial)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com  # ← UN SEUL hostname
  rules:
    # Backend API endpoints
    - matches:
        - path:
            type: PathPrefix
            value: /mobile/services/
      backendRefs:
        - name: globex-mobile-gateway
          port: 8080

    # Frontend (catch-all)
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: globex-mobile
          port: 8080
```

**Avantages:**
- ✅ Une seule hostname (simplifie DNS)
- ✅ Path-based routing (moderne, RESTful)
- ✅ Frontend et backend sur même domaine (pas de CORS)
- ✅ Une seule ressource HTTPRoute
- ✅ **C'est exactement le pattern du tutoriel Red Hat!**

**Inconvénients:**
- ⚠️ Ordre des rules important (plus spécifique d'abord)
- ⚠️ Frontend doit appeler backend via path `/mobile/services/*`
- ⚠️ Policies communes pour frontend et backend

### Comparaison Détaillée

| Aspect | Option A (Multiples) | Option B (Un + Headers) | Option C (Un + Paths) |
|--------|---------------------|------------------------|---------------------|
| **Nombre HTTPRoutes** | 2 | 1 | 1 |
| **Nombre Hostnames** | 2 | 2 | 1 |
| **Policies séparées** | ✅ Oui | ❌ Non | ❌ Non |
| **Complexité DNS** | 2 enregistrements | 2 enregistrements | 1 enregistrement |
| **CORS** | Nécessaire | Nécessaire | ❌ Pas besoin |
| **Rollback** | ✅ Facile | ⚠️ Moyen | ⚠️ Moyen |
| **Canary Deploy** | ✅ Par HTTPRoute | ⚠️ Difficile | ⚠️ Difficile |
| **Observability** | ✅ Granulaire | ⚠️ Groupée | ⚠️ Groupée |
| **Pattern** | Microservices | Custom | **Tutorial Red Hat** |

### Recommandation

**Pour Production avec API Management:** ✅ **Option A (Multiples HTTPRoutes)**

**Pourquoi:**
- Policies différentes par service (frontend: 50 req/s, backend: 10 req/s)
- Canary deployments indépendants
- Rollback granulaire
- Observability par service
- Séparation des responsabilités

**Pour Tutorial/Demo:** ✅ **Option C (Path-based routing)**

**Pourquoi:**
- C'est exactement le pattern Red Hat
- Démontre path-based routing
- Plus simple à comprendre
- Une seule hostname

### Ce qu'Une Seule HTTPRoute Apporte

**Avantages:**
- ✅ Moins de ressources à gérer (1 au lieu de 2)
- ✅ Configuration centralisée
- ✅ Un seul point d'entrée (hostname unique avec path-based routing)

**Mais vous perdez:**
- ❌ Policies indépendantes par service
- ❌ Canary deployments granulaires
- ❌ Rollback facile
- ❌ Observability séparée

**Mon conseil:** Si vous avez besoin d'API Management sérieux (rate limiting différent par service, auth différente), utilisez **plusieurs HTTPRoutes**.

---

## Question 3: HTTPRoute Génère-t-il des Routes OpenShift Derrière?

### Réponse: NON, Aucune Route OpenShift Créée

**Vérification:**

```bash
$ oc get httproute echo-api -n echo-api
NAME       HOSTNAMES                                  AGE
echo-api   ["echo.globex.sandbox3491.opentlc.com"]   43h

$ oc get route -n echo-api
No resources found in echo-api namespace.
# ↑ AUCUNE Route OpenShift créée!
```

**Architecture Réelle:**

```
┌─────────────────┐
│ External User   │
└────────┬────────┘
         │ HTTPS
         │ DNS: echo.globex.sandbox3491.opentlc.com
         │      → a7558ed31dbac4463b44c1689fb32092-...elb.amazonaws.com
         │
         ▼
┌────────────────────────────────────────────────────┐
│ AWS ELB (Load Balancer)                            │
│ a7558ed31dbac4463b44c1689fb32092-790405266...      │
└────────────────┬───────────────────────────────────┘
                 │ Port 443
                 ▼
┌────────────────────────────────────────────────────┐
│ Kubernetes Service: prod-web-istio                 │
│ Type: LoadBalancer                                 │
│ Namespace: ingress-gateway                         │
│ IP: 172.30.143.208                                 │
│ Ports: 443 → 443                                   │
└────────────────┬───────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────────┐
│ Istio Gateway Pod (prod-web-istio)                 │
│                                                     │
│ ┌─────────────────────────────────────────┐       │
│ │ Envoy Proxy                              │       │
│ │                                           │       │
│ │ Lit HTTPRoute CR:                        │       │
│ │ - Hostname: echo.globex.<domain>         │       │
│ │ - Backend: echo-api:8080                 │       │
│ │ - Policies: Auth, RateLimit, TLS         │       │
│ │                                           │       │
│ │ Configure Routing Dynamiquement:         │       │
│ │ - TLS termination                        │       │
│ │ - Host header matching                   │       │
│ │ - Backend selection                      │       │
│ │ - Apply AuthPolicy filters               │       │
│ │ - Apply RateLimitPolicy quotas           │       │
│ └─────────────────────────────────────────┘       │
└────────────────┬───────────────────────────────────┘
                 │ HTTP (backend)
                 ▼
┌────────────────────────────────────────────────────┐
│ Backend Service: echo-api                          │
│ Namespace: echo-api                                │
│ Port: 8080                                         │
└────────────────┬───────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────────┐
│ Backend Pod: echo-api                              │
└────────────────────────────────────────────────────┘
```

### Pourquoi AUCUNE Route OpenShift?

**Gateway API avec Istio est une implémentation NATIVE:**

1. **HTTPRoute est une Custom Resource (CR):**
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   ```
   - C'est un CR Kubernetes standard
   - Pas une abstraction sur Routes OpenShift

2. **Istio Gateway Controller lit directement HTTPRoute:**
   - Istio Envoy proxy lit les HTTPRoute CRs
   - Configure le routing dynamiquement
   - Pas besoin de créer Routes OpenShift

3. **Routes OpenShift et HTTPRoute sont PARALLÈLES:**
   ```
   Routes OpenShift → OpenShift Router (HAProxy)
   HTTPRoute → Istio Gateway (Envoy)

   Deux systèmes indépendants!
   ```

### Différence avec Certaines Implémentations

**Certains Gateway API controllers créent Routes:**

| Controller | Crée Routes OpenShift? | Backend |
|------------|----------------------|---------|
| **Istio** | ❌ NON | Envoy proxy natif |
| **OpenShift Service Mesh** | ❌ NON | Istio/Envoy |
| **Nginx Gateway** | ⚠️ Peut-être | Dépend de l'implémentation |
| **OpenShift Router v4.x** | ✅ Oui (si configuré) | HAProxy avec translation |

**Notre configuration (Istio):**
- ❌ Ne crée PAS de Routes OpenShift
- ✅ Routing natif dans Envoy
- ✅ HTTPRoute → Configuration Envoy directe

### Vérification de l'Architecture

```bash
# 1. Gateway existe
$ oc get gateway prod-web -n ingress-gateway
NAME       CLASS   ADDRESS                          PROGRAMMED
prod-web   istio   a7558ed...elb.amazonaws.com      True

# 2. Service LoadBalancer expose Gateway
$ oc get service prod-web-istio -n ingress-gateway
NAME             TYPE           EXTERNAL-IP
prod-web-istio   LoadBalancer   a7558ed...elb.amazonaws.com

# 3. HTTPRoute référence Gateway
$ oc get httproute echo-api -n echo-api -o yaml
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - echo.globex.sandbox3491.opentlc.com

# 4. AUCUNE Route OpenShift créée
$ oc get route -n echo-api
No resources found.

# 5. AUCUNE Route OpenShift dans ingress-gateway
$ oc get route -n ingress-gateway
No resources found.
```

**Conclusion:** HTTPRoute configure directement Istio Envoy, pas de Routes OpenShift créées.

---

## Synthèse des Réponses

### Question 1: Gateway pour Globex?

✅ **OUI, la Gateway `prod-web` existe déjà**

- Namespace: `ingress-gateway`
- Hostname: `*.globex.sandbox3491.opentlc.com` (wildcard)
- Policies: AuthPolicy, RateLimitPolicy, TLSPolicy, DNSPolicy
- **Prête à utiliser pour Globex - pas besoin d'en créer une nouvelle!**

### Question 2: Une Seule HTTPRoute - Qu'est-ce que Ça Apporte?

**Avantages:**
- ✅ Moins de ressources (1 au lieu de 2)
- ✅ Configuration centralisée
- ✅ Hostname unique (si path-based routing)

**Inconvénients:**
- ❌ Policies communes (pas de différenciation frontend/backend)
- ❌ Rollback moins granulaire
- ❌ Canary deployments plus difficiles

**Recommandation:**
- **Production:** Plusieurs HTTPRoutes (policies indépendantes)
- **Tutorial:** Une HTTPRoute (pattern Red Hat)

### Question 3: HTTPRoute Crée Routes OpenShift?

✅ **NON, aucune Route OpenShift créée**

**Pourquoi:**
- Istio Gateway est une implémentation native Gateway API
- HTTPRoute configure directement Envoy proxy
- Routes OpenShift et HTTPRoute sont deux systèmes parallèles

**Architecture:**
```
HTTPRoute → Istio Gateway (Envoy) → Backend Service
            (pas de Routes OpenShift)
```

---

## Migration Recommandée pour Globex

### Étape 1: Créer HTTPRoute(s)

**Option Production (Recommandée):**

```yaml
# HTTPRoute pour frontend (globex-mobile)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-mobile
          port: 8080

---
# HTTPRoute pour backend API (globex-mobile-gateway)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile-gateway.globex.sandbox3491.opentlc.com
  rules:
    - backendRefs:
        - name: globex-mobile-gateway
          port: 8080
```

### Étape 2: Créer ReferenceGrant

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

### Étape 3: Appliquer Policies Kuadrant

```yaml
# AuthPolicy pour globex-mobile (frontend)
apiVersion: kuadrant.io/v1beta2
kind: AuthPolicy
metadata:
  name: globex-mobile-auth
  namespace: globex-apim-user1
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: globex-mobile
  rules:
    authentication:
      "keycloak-users":
        jwt:
          issuerUrl: https://keycloak-keycloak.apps.myocp.sandbox3491.opentlc.com/realms/globex-user1

---
# RateLimitPolicy pour globex-mobile (50 req/10s per user)
apiVersion: kuadrant.io/v1beta2
kind: RateLimitPolicy
metadata:
  name: globex-mobile-ratelimit
  namespace: globex-apim-user1
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: globex-mobile
  limits:
    "per-user":
      rates:
        - limit: 50
          duration: 10
          unit: second
```

### Étape 4: Tester

```bash
# HTTPRoute créé, attaché à Gateway
oc get httproute -n globex-apim-user1

# Policies appliquées
oc get authpolicy,ratelimitpolicy -n globex-apim-user1

# Accès via Gateway API
curl -k https://globex-mobile.globex.sandbox3491.opentlc.com
```

### Étape 5: Supprimer OpenShift Routes (optionnel)

Une fois que Gateway API fonctionne:

```bash
# Supprimer Routes traditionnelles
oc delete route globex-mobile -n globex-apim-user1
oc delete route globex-mobile-gateway -n globex-apim-user1
```

---

**Last Updated**: 2026-03-28
**Gateway Status**: `prod-web` existe, prête à utiliser
**HTTPRoute Creates Routes**: NON (Istio native implementation)
**Recommendation**: Plusieurs HTTPRoutes pour production (policies indépendantes)
