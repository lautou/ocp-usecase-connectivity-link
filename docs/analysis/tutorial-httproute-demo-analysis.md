# Analyse du Tutoriel Red Hat - Démonstration HTTPRoute

## Question de l'Utilisateur

> Ok tu confirmes que leur exemple n'est pas approprié pour le HTTPRoute?
> L'image product details existe bien?
> Comment faire en sorte que ce service externe soit appelé depuis la page categories?

---

## Réponse 1: L'exemple Red Hat EST approprié (mais différent de notre architecture)

### ✅ Le tutoriel Red Hat est APPROPRIÉ et CORRECT

**Tutoriel Red Hat:** https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.2-developer.html

Le tutoriel démontre parfaitement la nécessité d'HTTPRoute, MAIS avec une architecture spécifique:

### Architecture du Tutoriel Red Hat

```
┌─────────────┐
│ External    │
│ User        │
└──────┬──────┘
       │ HTTPS
       ▼
┌─────────────────┐
│ OpenShift Route │
│ globex-mobile   │
└────────┬────────┘
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ globex-mobile Pod                                    │
│                                                       │
│ Appelle:                                              │
│ https://globex-mobile.globex.<domain>/mobile/services│
│    ↓                                                  │
│    (sort du pod, va vers Gateway API)                │
└────────┬─────────────────────────────────────────────┘
         │
         ▼
┌──────────────────┐
│ Gateway API      │
│ (prod-web)       │
└────────┬─────────┘
         │
         │ ❌ SANS HTTPRoute → 404 Not Found
         │
         ▼
┌─────────────────────┐
│ HTTPRoute           │  ◄─── CRÉÉ par le developer
│ globex-mobile-      │
│ gateway             │
│                     │
│ Hostname:           │
│  globex-mobile.     │
│  globex.<domain>    │
│                     │
│ Paths:              │
│  /mobile/services/* │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ globex-mobile-      │
│ gateway Service     │
└─────────────────────┘
```

**Configuration Clé:**

```yaml
# Dans globex-mobile deployment
env:
  - name: GLOBEX_MOBILE_GATEWAY
    value: https://globex-mobile.globex.<domain>  # ← Via Gateway API!
```

**Pourquoi ça démontre HTTPRoute:**

1. globex-mobile appelle le gateway via **hostname externe** (pas ClusterIP interne)
2. Le trafic passe par **Gateway API**
3. **Sans HTTPRoute** → Gateway ne sait pas router → **404 Not Found**
4. **Avec HTTPRoute** → Gateway route vers globex-mobile-gateway → **200 OK**

---

## Notre Architecture (Différente mais Correcte)

### Pourquoi nous ne voyons PAS le 404

**Notre configuration:**

```yaml
# Dans globex-mobile deployment
env:
  - name: GLOBEX_MOBILE_GATEWAY
    value: http://globex-mobile-gateway:8080  # ← ClusterIP INTERNE!
```

**Notre architecture:**

```
globex-mobile → ClusterIP DNS (http://globex-mobile-gateway:8080)
               → Direct vers le service (pas via Gateway)
               → Kubernetes Service networking
               → TOUJOURS fonctionne (pas besoin d'HTTPRoute)
```

**C'est un pattern CORRECT pour production:**
- ✅ East-West traffic (service → service)
- ✅ Faible latence (pas de hop Gateway)
- ✅ Sécurisé (backend pas exposé)
- ✅ Standard Kubernetes

**MAIS ne démontre PAS la nécessité d'HTTPRoute:**
- ❌ Pas de trafic via Gateway API
- ❌ Pas de routing externe
- ❌ Pas de 404 possible (ClusterIP toujours disponible)

---

## Réponse 2: Image "product-details" n'existe PAS

### Ce que le tutoriel utilise VRAIMENT

Le tutoriel Red Hat ne mentionne **PAS un service "product-details" séparé**.

**Ce qu'ils utilisent:**
- Service: **globex-mobile-gateway** (existant)
- HTTPRoute pour: **globex-mobile-gateway**
- Pas de nouveau service à créer

**L'HTTPRoute du tutoriel:**

```yaml
kind: HTTPRoute
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  parentRefs:
    - kind: Gateway
      namespace: ingress-gateway
      name: prod-web
  hostnames:
    - globex-mobile.globex.%AWSROOTZONE%  # ← Hostname unique
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/mobile/services/product/category/"
          method: GET
      backendRefs:
        - name: globex-mobile-gateway  # ← Service existant
          namespace: globex-apim-user1
          port: 8080
    - matches:
        - path:
            type: Exact
            value: "/mobile/services/category/list"
          method: GET
      backendRefs:
        - name: globex-mobile-gateway
          namespace: globex-apim-user1
          port: 8080
```

**Points clés:**
- ✅ Utilise service **globex-mobile-gateway** (déjà déployé)
- ✅ HTTPRoute avec paths spécifiques: `/mobile/services/*`
- ✅ Hostname: `globex-mobile.globex.<domain>` (UN SEUL hostname)
- ❌ PAS de service "product-details" séparé

---

## Réponse 3: Comment Démontrer HTTPRoute avec Notre Déploiement

### Option A: Suivre le Tutoriel Red Hat (Modifier Architecture)

**Étapes pour répliquer le tutoriel:**

#### 1. Créer HTTPRoute pour globex-mobile-gateway

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
    - globex-mobile.globex.sandbox3491.opentlc.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/mobile/services/"
      backendRefs:
        - name: globex-mobile-gateway
          port: 8080
```

#### 2. Créer ReferenceGrant (cross-namespace access)

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

#### 3. Modifier globex-mobile pour appeler via Gateway

```yaml
# kustomize/globex/globex-deployment-globex-mobile.yaml
env:
  - name: GLOBEX_MOBILE_GATEWAY
    value: https://globex-mobile.globex.sandbox3491.opentlc.com  # ← Via Gateway!
```

#### 4. Démontrer HTTPRoute Necessity

**4a. Supprimer HTTPRoute temporairement:**

```bash
oc delete httproute globex-mobile-gateway -n globex-apim-user1
```

**4b. Tester l'application:**

```bash
# Accéder à globex-mobile
https://globex-mobile-globex-apim-user1.apps.<domain>

# Login avec asilva/openshift
# Cliquer sur "Categories"

# Résultat: 404 Not Found ❌
# Pourquoi: Gateway n'a pas d'HTTPRoute pour router vers globex-mobile-gateway
```

**4c. Recréer HTTPRoute:**

```bash
oc apply -f globex-mobile-gateway-httproute.yaml
```

**4d. Retester:**

```bash
# Rafraîchir la page Categories

# Résultat: 200 OK, categories affichées ✅
# Pourquoi: HTTPRoute existe maintenant, Gateway peut router
```

**Résultat:** Démontre que HTTPRoute est REQUIS pour routing via Gateway API

---

### Option B: Créer Nouveau Service (Plus Propre)

**Créer un service "Product Reviews" pour la démo:**

#### 1. Créer un nouveau service simple

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: product-reviews
  namespace: globex-apim-user1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: product-reviews
  template:
    metadata:
      labels:
        app: product-reviews
    spec:
      containers:
        - name: product-reviews
          image: quay.io/redhattraining/simple-http:v1.0  # Simple HTTP server
          ports:
            - containerPort: 8080
          env:
            - name: RESPONSE
              value: '{"reviews": [{"rating": 5, "comment": "Great product!"}]}'
---
apiVersion: v1
kind: Service
metadata:
  name: product-reviews
  namespace: globex-apim-user1
spec:
  selector:
    app: product-reviews
  ports:
    - port: 8080
```

#### 2. Modifier globex-mobile pour appeler ce service

**Dans le frontend Angular (globex-mobile):**

Ajouter un bouton "Reviews" qui appelle:
```
https://product-reviews.globex.sandbox3491.opentlc.com/reviews
```

#### 3. Déployer SANS HTTPRoute

```bash
oc apply -f product-reviews-deployment.yaml
oc apply -f product-reviews-service.yaml
# Ne PAS créer HTTPRoute encore
```

#### 4. Tester → 404

```bash
curl -k https://product-reviews.globex.sandbox3491.opentlc.com/reviews
# Résultat: 404 Not Found
```

#### 5. Créer HTTPRoute

```yaml
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
```

```bash
oc apply -f product-reviews-httproute.yaml
```

#### 6. Retester → 200 OK

```bash
curl -k https://product-reviews.globex.sandbox3491.opentlc.com/reviews
# Résultat: {"reviews": [{"rating": 5, "comment": "Great product!"}]}
```

**Avantages de cette approche:**
- ✅ Ne modifie pas l'architecture existante
- ✅ Ajoute une nouvelle fonctionnalité
- ✅ Démontre clairement HTTPRoute necessity
- ✅ Plus facile à nettoyer après demo

---

## Modifications du Frontend pour Appeler via Gateway

### Comment Modifier globex-mobile pour Appeler Externes

**Scénario:** Modifier pour que Categories appelle via Gateway API

#### Étape 1: Modifier l'Environment Variable

```yaml
# kustomize/globex/globex-deployment-globex-mobile.yaml
containers:
  - name: globex-mobile
    env:
      # Ancien (interne):
      - name: GLOBEX_MOBILE_GATEWAY
        value: http://globex-mobile-gateway:8080

      # Nouveau (externe via Gateway):
      - name: GLOBEX_MOBILE_GATEWAY
        value: https://globex-mobile.globex.sandbox3491.opentlc.com
```

#### Étape 2: Modifier server.ts (si nécessaire)

**Le code actuel dans server.ts:**

```typescript
server.get(ANGULR_API_GETCATEGORIES + '/:custId', (req, res) => {
  const sessionToken = req.cookies['globex_session_token'];
  const configHeader = {
    headers: { Authorization: `Bearer ${accessTokenSessions.get(sessionToken)}` }
  };
  const custId = req.params.custId;

  var url = GLOBEX_MOBILE_GATEWAY + "/mobile/services/category/list";
  axios.get(url, configHeader)  // ← Utilisera la nouvelle URL externe
    .then(response => {
      res.status(200).send(response.data)
    })
    .catch(error => {
      console.log("ANGULR_API_GETCATEGORIES", error);
      res.status(500).send();
    })
});
```

**Ce code fonctionne DÉJÀ avec l'URL externe!**

Pas besoin de modification de code, juste changer la variable d'environnement.

#### Étape 3: Redéployer

```bash
# Appliquer la nouvelle configuration
oc apply -f kustomize/globex/globex-deployment-globex-mobile.yaml

# Attendre le rollout
oc rollout status deployment/globex-mobile -n globex-apim-user1
```

#### Étape 4: Tester la Démo

**Sans HTTPRoute:**
```bash
# Supprimer HTTPRoute
oc delete httproute globex-mobile-gateway -n globex-apim-user1

# Accéder à globex-mobile et cliquer sur Categories
# → 404 ou erreur réseau
```

**Avec HTTPRoute:**
```bash
# Créer HTTPRoute
oc apply -f globex-mobile-gateway-httproute.yaml

# Accéder à globex-mobile et cliquer sur Categories
# → Categories s'affichent correctement
```

---

## Recommandation Finale

### Pour Démo HTTPRoute Necessity

**Je recommande Option B** (Nouveau service):

**Pourquoi:**
- ✅ N'impacte pas l'architecture production existante
- ✅ Plus facile à nettoyer après la démo
- ✅ Démontre clairement le concept
- ✅ Peut ajouter un bouton "Reviews" dans l'UI sans casser Categories

**Implementation:**

1. Créer service simple "product-reviews"
2. Ajouter bouton "Reviews" dans globex-mobile UI (optionnel)
3. Déployer sans HTTPRoute → voir 404
4. Créer HTTPRoute → voir 200 OK

### Pour Suivre Tutoriel Red Hat Exactement

**Utilisez Option A** (Modifier architecture):

**Pourquoi:**
- ✅ Réplique exactement le tutoriel Red Hat
- ✅ Démontre pattern réel (frontend → backend via Gateway)
- ✅ Enseigne routing complexe

**Trade-offs:**
- ⚠️ Change l'architecture de production
- ⚠️ Latence augmentée (extra Gateway hop)
- ⚠️ Plus complexe à maintenir

---

## Conclusion

### Réponses aux Questions

1. **L'exemple Red Hat est-il approprié?**
   - ✅ **OUI**, il est approprié
   - Il démontre HTTPRoute necessity
   - MAIS requiert que les appels passent par Gateway API (pas ClusterIP interne)

2. **L'image product-details existe-t-elle?**
   - ❌ **NON**, le tutoriel Red Hat n'utilise PAS un service "product-details"
   - Utilise **globex-mobile-gateway** (existant)
   - Peut créer un service simple pour la démo si souhaité

3. **Comment faire appeler un service externe depuis Categories?**
   - **Modifier env var** `GLOBEX_MOBILE_GATEWAY` pour pointer vers hostname externe
   - **Créer HTTPRoute** pour exposer le service via Gateway API
   - **Démo:** Supprimer HTTPRoute → 404, Recréer → 200

### Architecture Recommandée

**Production:** ClusterIP interne (notre approche actuelle)
- Meilleure performance
- Meilleure sécurité
- Pattern standard

**Demo/Tutorial:** Gateway API (approche Red Hat)
- Démontre HTTPRoute necessity
- Enseigne concepts Gateway API
- Montre API Management patterns

**Les deux sont CORRECTES mais pour des objectifs différents!**

---

**Last Updated**: 2026-03-28
**Tutorial Reference**: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.2-developer.html
**Recommendation**: Option B (nouveau service) pour démo propre
