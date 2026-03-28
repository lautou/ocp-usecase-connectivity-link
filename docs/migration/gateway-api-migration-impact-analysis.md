# Migration Gateway API SANS Policies - Analyse d'Impact

## Contexte

**Objectif:** Migrer de OpenShift Routes vers Gateway API HTTPRoute **SANS activer de policies Kuadrant**

**Contrainte:** Comportement iso-fonctionnel (pas de changement utilisateur visible)

**Scope:** Globex mobile application

## Architecture Philosophy

**IMPORTANT:** This migration demonstrates **Gateway API for consuming external services**.

**ProductInfo Service Simulation:**
- `globex-mobile-gateway` deployment represents **ProductInfo service**
- Simulated as external product catalog API (like Akeneo, commercetools)
- Accessed via Gateway API (not ClusterIP) to demonstrate external service consumption pattern
- See `docs/architecture/external-service-simulation.md` for full rationale

**Components:**
- **globex-mobile**: Frontend application (internal)
- **ProductInfo service** (globex-mobile-gateway): External product catalog API (simulated)
- **globex-store-app**: Internal backend (database layer)

---

## État Actuel (Baseline)

### Routes OpenShift Existantes

**Route 1: globex-mobile (Frontend)**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
spec:
  host: globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect  # HTTP → HTTPS
  to:
    kind: Service
    name: globex-mobile
    weight: 100
```

**Route 2: globex-mobile-gateway (Backend API)**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: globex-mobile-gateway
  namespace: globex-apim-user1
spec:
  host: globex-mobile-gateway-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: globex-mobile-gateway
    weight: 100
```

### Infrastructure Actuelle

**Ingress:**
- OpenShift Router (HAProxy)
- Hostname pattern: `*-<namespace>.apps.<cluster-domain>`
- TLS: Edge termination (certs gérés par OpenShift)
- Load Balancer: OpenShift Router default

**DNS:**
- globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com → OpenShift Router
- globex-mobile-gateway-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com → OpenShift Router

**Accès utilisateur:**
```
User → DNS → OpenShift Router (HAProxy) → Service → Pod
```

---

## État Cible (Gateway API)

### Gateway Existante

**Gateway prod-web (déjà déployée):**
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
      hostname: '*.globex.sandbox3491.opentlc.com'  # ← Pattern différent!
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        certificateRefs:
          - name: api-tls
        mode: Terminate
```

**Load Balancer:**
- Type: AWS ELB
- Address: `a7558ed31dbac4463b44c1689fb32092-790405266.eu-central-1.elb.amazonaws.com`

### HTTPRoutes à Créer

**HTTPRoute 1: globex-mobile (Frontend)**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
  labels:
    app: globex-mobile
    app.kubernetes.io/name: globex-mobile
    app.kubernetes.io/part-of: globex
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - globex-mobile.globex.sandbox3491.opentlc.com  # ← Nouveau hostname!
  rules:
    - backendRefs:
        - name: globex-mobile
          port: 8080
```

**HTTPRoute 2: ProductInfo Service (External API - Simulated)**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: productinfo  # ← Business function name
  namespace: globex-apim-user1
  labels:
    app: globex-mobile-gateway  # ← Links to actual deployment
    app.kubernetes.io/name: productinfo
    app.kubernetes.io/component: external-api
    app.kubernetes.io/part-of: globex
spec:
  parentRefs:
    - name: prod-web
      namespace: ingress-gateway
  hostnames:
    - productinfo.globex.sandbox3491.opentlc.com  # ← Clear service name
  rules:
    - backendRefs:
        - name: globex-mobile-gateway  # ← Actual K8s service
          port: 8080
```

**Note:** ProductInfo service is deployed as `globex-mobile-gateway` but named `productinfo` in HTTPRoute to reflect its business function (external product catalog API). This demonstrates Gateway API pattern for consuming external services.

### ReferenceGrant à Créer

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

---

## Impact Détaillé

### 1. ⚠️ IMPACT MAJEUR: Changement de Hostnames

#### Ancien (Routes OpenShift)

```
Frontend:  globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
Backend:   globex-mobile-gateway-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
```

#### Nouveau (Gateway API)

```
Frontend:          globex-mobile.globex.sandbox3491.opentlc.com
ProductInfo API:   productinfo.globex.sandbox3491.opentlc.com
```

**Note:** ProductInfo service (deployed as `globex-mobile-gateway`) uses business function hostname `productinfo.*` to reflect its role as external product catalog API.

**Raison du changement:**
- Gateway `prod-web` accepte seulement: `*.globex.sandbox3491.opentlc.com`
- Les anciens hostnames (`*.apps.*`) ne matchent PAS ce pattern

**Impact utilisateur:**
- ❌ Ancienne URL ne fonctionne PLUS
- ✅ Nouvelle URL doit être communiquée
- ⚠️ Bookmarks utilisateurs cassés
- ⚠️ Documentation à mettre à jour

**Alternatives pour éviter ce changement:**

**Option A: Modifier Gateway pour accepter les deux patterns**
```yaml
Gateway:
  listeners:
    - name: globex-pattern
      hostname: '*.globex.sandbox3491.opentlc.com'
    - name: apps-pattern      # ← Nouveau listener
      hostname: '*.apps.myocp.sandbox3491.opentlc.com'
```

**Option B: Redirection DNS**
```
Ancienne URL → CNAME → Nouvelle URL
globex-mobile-globex-apim-user1.apps.* → CNAME → globex-mobile.globex.*
```

**Option C: Garder anciennes URLs avec HTTPRoute**
```yaml
HTTPRoute:
  hostnames:
    - globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
    - globex-mobile.globex.sandbox3491.opentlc.com  # Alias
```
→ Nécessite modifier Gateway listener hostname pattern

**Recommandation:** Option C ou A pour transition douce

---

### 2. 📁 Impact sur les Fichiers du Projet

#### Fichiers à CRÉER

**Nouveaux fichiers dans `kustomize/globex/`:**

1. `globex-apim-user1-httproute-globex-mobile.yaml` (nouveau)
```yaml
# Frontend application HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: globex-mobile
  namespace: globex-apim-user1
# ... (spec ci-dessus)
```

2. `globex-apim-user1-httproute-productinfo.yaml` (nouveau)
```yaml
# ProductInfo service (external API simulation) HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: productinfo  # Business function name
  namespace: globex-apim-user1
# Backend: globex-mobile-gateway deployment
# ... (spec ci-dessus)
```

3. `ingress-gateway-referencegrant-globex.yaml` (nouveau)
```yaml
# Allow globex namespace to reference prod-web Gateway
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: globex-to-gateway
  namespace: ingress-gateway
# ... (spec ci-dessus)
```

**Total: 3 nouveaux fichiers**

**Naming convention:**
- HTTPRoutes use business function names (`productinfo`) not deployment names (`globex-mobile-gateway`)
- This reflects the external service simulation pattern
- Technical deployment name preserved in labels and backend refs

#### Fichiers à SUPPRIMER

1. `kustomize/globex/globex-route-globex-mobile.yaml` (supprimer)
2. `kustomize/globex/globex-route-globex-mobile-gateway.yaml` (supprimer)

**Total: 2 fichiers supprimés**

#### Fichiers à MODIFIER

**1. `kustomize/globex/kustomization.yaml`**

```yaml
# AVANT
resources:
  # ...
  - globex-route-globex-mobile-gateway.yaml
  # ...
  - globex-route-globex-mobile.yaml

# APRÈS
resources:
  # ...
  - globex-apim-user1-httproute-globex-mobile.yaml      # Frontend HTTPRoute
  - globex-apim-user1-httproute-productinfo.yaml        # ProductInfo service HTTPRoute
  - ingress-gateway-referencegrant-globex.yaml          # Cross-namespace permission
```

**Note:** Le ReferenceGrant doit être déployé dans namespace `ingress-gateway`, donc il peut nécessiter un kustomization séparé OU inclusion dans le kustomize de globex.

**Impact kustomization:** Ligne changée: 3 fichiers remplacés

---

### 3. 🔧 Impact Infrastructure

#### Load Balancer

**Ancien:**
```
OpenShift Router (HAProxy)
  - Type: ClusterIP/NodePort (géré par OpenShift)
  - Hostname: router-default.apps.myocp.sandbox3491.opentlc.com
```

**Nouveau:**
```
Istio Gateway (Envoy)
  - Type: LoadBalancer (AWS ELB)
  - Hostname: a7558ed31dbac4463b44c1689fb32092-790405266.eu-central-1.elb.amazonaws.com
  - Service: prod-web-istio (ingress-gateway namespace)
```

**Impact:**
- ✅ Pas de changement (Gateway déjà déployée)
- ✅ Load Balancer déjà existant

#### TLS Certificates

**Ancien (Routes):**
```
Certificats:
  - Gérés automatiquement par OpenShift
  - Self-signed ou cluster default cert
  - Pas de Let's Encrypt
```

**Nouveau (Gateway API):**
```
Certificats:
  - Gérés par TLSPolicy (déjà configurée)
  - Let's Encrypt wildcard certificate
  - Secret: api-tls (ingress-gateway namespace)
  - Auto-renewal via cert-manager
```

**Impact:**
- ✅ Amélioration: Let's Encrypt certs (trusted)
- ✅ Auto-renewal (pas de maintenance manuelle)
- ✅ Wildcard cert (couvre tous *.globex.*)

**Vérification:**
```bash
oc get tlspolicy -n ingress-gateway
NAME                  AGE
prod-web-tls-policy   43h  # ← Déjà existante
```

#### DNS Configuration

**Ancien:**
```
DNS:
  - *.apps.myocp.sandbox3491.opentlc.com → OpenShift Router
  - Géré par OpenShift cluster DNS
```

**Nouveau:**
```
DNS:
  - *.globex.sandbox3491.opentlc.com → AWS ELB (Istio Gateway)
  - Nécessite création enregistrements DNS:

    globex-mobile.globex.sandbox3491.opentlc.com
      → CNAME → a7558ed31dbac4463b44c1689fb32092-...elb.amazonaws.com

    productinfo.globex.sandbox3491.opentlc.com
      → CNAME → a7558ed31dbac4463b44c1689fb32092-...elb.amazonaws.com
```

**Note:** `productinfo.*` hostname reflects business function (product catalog API), not deployment name.

**Impact DNS:**
- ⚠️ **Nouveaux enregistrements DNS à créer**
- ⚠️ Dépend de DNSPolicy (si activée) OU création manuelle

**Vérification DNSPolicy:**
```bash
oc get dnspolicy -n ingress-gateway
NAME                AGE
prod-web-dnspolicy  43h  # ← Existe!
```

**Si DNSPolicy activée:**
- ✅ DNS créé AUTOMATIQUEMENT (Route53)
- ✅ Pas d'action manuelle requise

**Si DNSPolicy PAS activée:**
- ❌ Créer manuellement les enregistrements DNS

---

### 4. 🚀 Impact Déploiement & CI/CD

#### ArgoCD Application

**Fichier:** `argocd/application-globex.yaml`

**AUCUN changement requis!**

L'ArgoCD Application pointe vers `kustomize/globex/` qui contiendra les nouveaux HTTPRoutes.

ArgoCD détectera automatiquement:
- ✅ Suppression des Routes
- ✅ Création des HTTPRoutes
- ✅ Création du ReferenceGrant

#### Ordre de Déploiement

**Séquence critique pour éviter downtime:**

```
1. Créer ReferenceGrant (ingress-gateway namespace)
   → Autoriser cross-namespace reference

2. Créer HTTPRoutes (globex-apim-user1 namespace)
   → Routing via Gateway configuré

3. Vérifier HTTPRoutes attachés à Gateway
   oc get httproute -n globex-apim-user1

4. Vérifier DNS resolution
   nslookup globex-mobile.globex.sandbox3491.opentlc.com

5. Tester accès via nouvelle URL
   curl -k https://globex-mobile.globex.sandbox3491.opentlc.com

6. SI TOUT OK: Supprimer Routes OpenShift
   → Finaliser migration
```

**Stratégie Zero-Downtime:**

**Option A: Blue-Green (deux URLs en parallèle)**
```
Phase 1: Déployer HTTPRoutes (nouvelles URLs)
  - Ancienne URL fonctionne (Routes OpenShift)
  - Nouvelle URL fonctionne (Gateway API)
  - Les deux coexistent

Phase 2: Tester nouvelle URL
  - Validation complète
  - Performance testing

Phase 3: Migrer utilisateurs progressivement
  - Communiquer nouvelle URL
  - Garder ancienne active temporairement

Phase 4: Supprimer Routes OpenShift (après validation)
  - Ancienne URL arrête de fonctionner
```

**Option B: DNS Switch (même hostname)**
```
Nécessite modifier Gateway listener pattern pour accepter *.apps.*

Phase 1: Modifier Gateway listener
  hostname: '*.apps.myocp.sandbox3491.opentlc.com'

Phase 2: Créer HTTPRoutes avec anciens hostnames
  hostnames:
    - globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com

Phase 3: Supprimer Routes OpenShift
  → Traffic bascule automatiquement vers Gateway

Phase 4: Plus tard, migrer vers nouveaux hostnames (*.globex.*)
```

**Recommandation:** Option B pour zero-downtime avec hostname inchangé

---

### 5. 📊 Impact Observability

#### Metrics

**Ancien (Routes OpenShift):**
```
Metrics HAProxy:
  - haproxy_backend_http_responses_total
  - haproxy_backend_response_time_average_seconds
  - Dashboards OpenShift Console
```

**Nouveau (Gateway API + Istio):**
```
Metrics Gateway API:
  - gateway_api_httproute_requests_total
  - gateway_api_httproute_request_duration_seconds
  - istio_requests_total
  - istio_request_duration_milliseconds

Dashboards:
  - Kiali (service mesh observability)
  - Grafana (Gateway API dashboards)
  - OpenShift Console (limité pour Gateway API)
```

**Impact:**
- ✅ Plus de metrics disponibles
- ✅ Observability améliorée (Istio)
- ⚠️ Dashboards différents (migration requis)
- ⚠️ Alerting à mettre à jour (nouvelles metric names)

#### Logs

**Ancien:**
```
Logs:
  - HAProxy access logs (OpenShift Router pods)
  - oc logs -n openshift-ingress deployment/router-default
```

**Nouveau:**
```
Logs:
  - Envoy access logs (Istio Gateway pods)
  - oc logs -n ingress-gateway deployment/prod-web-istio
  - Format différent (Envoy JSON)
```

**Impact:**
- ⚠️ Log aggregation à mettre à jour
- ⚠️ Parsing rules différents
- ✅ Plus d'informations (Envoy headers, tracing, etc.)

---

### 6. 🔒 Impact Sécurité

#### Exposition Services

**Ancien:**
```
Exposition:
  - Services exposés via Routes OpenShift
  - HAProxy edge termination
  - Pas de policies additionnelles
```

**Nouveau:**
```
Exposition:
  - Services exposés via Gateway API HTTPRoutes
  - Istio Envoy edge termination
  - Policies Kuadrant DISPONIBLES mais NON activées (pour rester iso)
```

**Impact:**
- ✅ Même niveau de sécurité (TLS edge termination)
- ✅ Possibilité d'ajouter AuthPolicy/RateLimitPolicy plus tard
- ⚠️ Gateway API expose namespace ingress-gateway (crossnamespace ref)

#### Network Policies

**Vérifier NetworkPolicies existantes:**
```bash
oc get networkpolicy -n globex-apim-user1
oc get networkpolicy -n ingress-gateway
```

**Impact:**
- ⚠️ Vérifier que traffic depuis ingress-gateway vers globex-apim-user1 autorisé
- ⚠️ Si NetworkPolicies strictes, ajouter règles pour Istio Gateway

---

### 7. 🧪 Impact Testing & Validation

#### Tests à Exécuter Avant Migration

**1. Test Gateway existe et fonctionne:**
```bash
oc get gateway prod-web -n ingress-gateway
# Expected: Status Programmed=True
```

**2. Test echo-api (référence existante):**
```bash
curl -k https://echo.globex.sandbox3491.opentlc.com
# Expected: HTTP 200 OK (echo-api fonctionne)
```

**3. Test DNS resolution (après création HTTPRoutes):**
```bash
nslookup globex-mobile.globex.sandbox3491.opentlc.com
# Expected: Résout vers AWS ELB
```

**4. Test TLS certificate:**
```bash
curl -v https://globex-mobile.globex.sandbox3491.opentlc.com 2>&1 | grep -i "certificate"
# Expected: Let's Encrypt certificate valid
```

**5. Test fonctionnel complet:**
```
1. Accéder: https://globex-mobile.globex.sandbox3491.opentlc.com
2. Login: asilva / openshift
3. Cliquer: Categories
4. Vérifier: Categories s'affichent
```

#### Tests de Régression

**Comparer performances:**
```
Routes OpenShift (baseline):
  - Latency P50: X ms
  - Latency P95: Y ms
  - Throughput: Z req/s

Gateway API:
  - Latency P50: doit être ≈ X ms (±10%)
  - Latency P95: doit être ≈ Y ms (±15%)
  - Throughput: doit être ≥ Z req/s
```

**Load testing:**
```bash
# Avant migration (Routes)
ab -n 1000 -c 10 https://globex-mobile-globex-apim-user1.apps.*/

# Après migration (Gateway API)
ab -n 1000 -c 10 https://globex-mobile.globex.*/

# Comparer résultats
```

---

### 8. 📋 Impact Documentation

#### Documentation à Mettre à Jour

**1. README.md**
- Nouvelles URLs d'accès
- Architecture diagram (Routes → Gateway API)

**2. docs/deployment/**
- Instructions déploiement mises à jour
- Références HTTPRoute au lieu de Route

**3. docs/operations/troubleshooting.md**
- Debugging HTTPRoute (au lieu de Route)
- Logs Istio Gateway (au lieu de HAProxy)

**4. CLAUDE.md**
- Mise à jour architecture overview
- Nouvelles URLs de vérification

**5. docs/architecture/**
- Diagrammes mis à jour
- Gateway API au lieu de Routes

---

## Synthèse des Impacts

### Impacts MAJEURS (Breaking Changes)

| Impact | Détail | Mitigation |
|--------|--------|-----------|
| **Hostnames changent** | *.apps.* → *.globex.* | Option 1: Modifier Gateway listener pour accepter les deux<br>Option 2: Redirection DNS<br>Option 3: Communication utilisateurs |
| **DNS records à créer** | Nouveaux CNAME vers AWS ELB | Si DNSPolicy activée: automatique<br>Sinon: création manuelle |
| **3 nouveaux fichiers** | HTTPRoutes + ReferenceGrant | Création manifests |
| **2 fichiers supprimés** | Routes OpenShift | Suppression après validation |

### Impacts MINEURS (Transparents)

| Impact | Détail |
|--------|--------|
| **Load Balancer** | Déjà existant (Gateway prod-web) |
| **TLS Certificates** | Déjà gérés (TLSPolicy) |
| **ArgoCD** | Aucun changement requis |
| **Déploiements** | Aucun changement requis |

### Impacts POSITIFS (Améliorations)

| Bénéfice | Détail |
|----------|--------|
| **TLS** | Let's Encrypt (trusted) au lieu de self-signed |
| **Observability** | Metrics Istio + Gateway API |
| **Future-proof** | Possibilité d'ajouter policies plus tard |
| **Standards** | Gateway API (Kubernetes standard) |

---

## Plan de Migration Recommandé

### Phase 1: Préparation (Pas de changement prod)

```
1. Créer nouveaux manifests HTTPRoute + ReferenceGrant
   - ingress-gateway-httproute-globex-mobile.yaml
   - ingress-gateway-httproute-globex-mobile-gateway.yaml
   - ingress-gateway-referencegrant-globex.yaml

2. Modifier kustomization.yaml
   - Ajouter HTTPRoutes
   - Commenter (NE PAS supprimer) Routes

3. Test en dev/staging
   - Appliquer manifests
   - Valider fonctionnement
```

### Phase 2: Décision Hostname

**Option A: Garder anciens hostnames (*.apps.*)**
```
1. Modifier Gateway prod-web:
   listeners:
     - hostname: '*.globex.sandbox3491.opentlc.com'
     - hostname: '*.apps.myocp.sandbox3491.opentlc.com'  # ← Nouveau

2. HTTPRoutes avec anciens hostnames:
   hostnames:
     - globex-mobile-globex-apim-user1.apps.myocp.sandbox3491.opentlc.com
```

**Option B: Nouveaux hostnames (*.globex.*) - Recommandé**
```
1. HTTPRoutes avec nouveaux hostnames:
   hostnames:
     - globex-mobile.globex.sandbox3491.opentlc.com

2. Communication utilisateurs (nouvelle URL)

3. Garder Routes actives temporairement (coexistence)
```

**Recommandation:** Option B (align avec pattern Tutorial Red Hat)

### Phase 3: Déploiement Production

```
1. Commit + Push manifests HTTPRoute + ReferenceGrant
   git add kustomize/globex/ingress-gateway-*.yaml
   git commit -m "Add Gateway API HTTPRoutes for Globex"

2. ArgoCD Sync (ou auto-sync)
   - HTTPRoutes créés
   - ReferenceGrant créé
   - Routes OpenShift RESTENT actives

3. Validation
   - oc get httproute -n globex-apim-user1
   - curl https://globex-mobile.globex.sandbox3491.opentlc.com
   - Test fonctionnel complet

4. Coexistence (1-7 jours)
   - Ancienne URL fonctionne (Routes)
   - Nouvelle URL fonctionne (Gateway API)
   - Monitoring comparatif

5. Supprimer Routes (si validation OK)
   git rm kustomize/globex/globex-route-*.yaml
   git commit -m "Remove OpenShift Routes (migrated to Gateway API)"
```

### Phase 4: Cleanup & Documentation

```
1. Mettre à jour documentation
   - README.md (nouvelles URLs)
   - Troubleshooting (HTTPRoute debugging)

2. Mettre à jour monitoring/alerting
   - Nouvelles metrics (Gateway API)
   - Nouveaux dashboards

3. Communication équipes
   - Nouvelles URLs
   - Changements observability
```

---

## Checklist Migration

### Pré-Migration

- [ ] Gateway `prod-web` existe et fonctionne
- [ ] TLSPolicy configurée (Let's Encrypt)
- [ ] DNSPolicy configurée (Route53) OU DNS manuel possible
- [ ] Backup configuration actuelle (Routes)
- [ ] Tests fonctionnels baseline (Routes)

### Création Manifests

- [ ] `ingress-gateway-httproute-globex-mobile.yaml` créé
- [ ] `ingress-gateway-httproute-globex-mobile-gateway.yaml` créé
- [ ] `ingress-gateway-referencegrant-globex.yaml` créé
- [ ] `kustomization.yaml` mis à jour
- [ ] Validation syntax YAML (yamllint)

### Déploiement

- [ ] Git commit + push
- [ ] ArgoCD sync
- [ ] HTTPRoutes créés (oc get httproute)
- [ ] ReferenceGrant créé (oc get referencegrant -n ingress-gateway)
- [ ] HTTPRoutes attachés à Gateway (status.parents)

### Validation

- [ ] DNS resolution fonctionne
- [ ] TLS certificate valid (Let's Encrypt)
- [ ] Accès frontend (https://globex-mobile.globex.*)
- [ ] Login utilisateur fonctionne
- [ ] Categories chargent
- [ ] Performance acceptable (≈ baseline)
- [ ] Pas d'erreurs logs Gateway

### Post-Migration

- [ ] Routes OpenShift supprimées (après validation)
- [ ] Documentation mise à jour
- [ ] Monitoring/alerting mis à jour
- [ ] Communication équipes (nouvelles URLs)

---

## Risques & Mitigation

| Risque | Probabilité | Impact | Mitigation |
|--------|-------------|--------|-----------|
| **Hostname change casse bookmarks** | Haute | Moyen | Phase de coexistence (Routes + HTTPRoutes)<br>Communication utilisateurs |
| **DNS ne résout pas** | Basse | Haut | Vérifier DNSPolicy activée<br>Test DNS avant suppression Routes |
| **NetworkPolicy bloque traffic** | Basse | Haut | Vérifier NetworkPolicies<br>Test avant suppression Routes |
| **Performance dégradée** | Basse | Moyen | Load testing comparatif<br>Rollback possible (Routes) |
| **TLS certificate invalide** | Très basse | Haut | TLSPolicy déjà testée (echo-api)<br>Validation pré-migration |

---

## Rollback Plan

**Si problème détecté après migration:**

```
1. Rollback Git:
   git revert <commit-migration>
   git push

2. ArgoCD Sync:
   - HTTPRoutes supprimés
   - Routes OpenShift recréées

3. Validation:
   - Ancienne URL fonctionne à nouveau
   - Traffic revient sur OpenShift Router

Temps estimé: 5-10 minutes
```

**Condition rollback:**
- Erreurs 5xx > 1%
- Latency P95 > 2x baseline
- Feature critique cassée (login, categories, etc.)

---

## Timeline Estimée

| Phase | Durée | Détail |
|-------|-------|--------|
| **Préparation** | 2-4h | Création manifests, validation syntax |
| **Test dev/staging** | 4-8h | Validation complète environnement non-prod |
| **Déploiement prod** | 30min | Git commit, ArgoCD sync, validation initiale |
| **Coexistence** | 1-7 jours | Routes + HTTPRoutes en parallèle, monitoring |
| **Cleanup** | 1h | Suppression Routes, documentation |
| **Total** | **1-2 semaines** | Migration complète avec validation |

---

## Conclusion

### Migration Recommandée: OUI

**Raisons:**
- ✅ Gateway déjà existante (prod-web)
- ✅ TLSPolicy et DNSPolicy déjà configurées
- ✅ Pattern aligné avec Tutorial Red Hat
- ✅ Future-proof (possibilité d'ajouter policies)
- ✅ Amélioration TLS (Let's Encrypt)

### Impact Global: MOYEN

**Breaking changes:**
- ⚠️ Hostnames changent (mitigable avec phase de coexistence)
- ⚠️ DNS à créer (automatique si DNSPolicy)

**Bénéfices:**
- ✅ Standard Kubernetes (Gateway API)
- ✅ Observability améliorée
- ✅ Évolution possible (policies plus tard)

### Recommandation Stratégie

**Pour migration iso-fonctionnelle SANS downtime:**

1. **Phase de coexistence** (1 semaine)
   - Déployer HTTPRoutes (nouvelles URLs)
   - Garder Routes OpenShift (anciennes URLs)
   - Les deux fonctionnent en parallèle

2. **Communication utilisateurs**
   - Nouvelles URLs communiquées
   - Ancienne URL deprecated (à supprimer bientôt)

3. **Validation complète**
   - Tests fonctionnels
   - Performance monitoring
   - Feedback utilisateurs

4. **Cleanup**
   - Suppression Routes OpenShift (après validation)

**Temps total:** 1-2 semaines pour migration sécurisée

---

**Last Updated**: 2026-03-28
**Scope**: Globex mobile migration Routes → Gateway API (SANS policies)
**Status**: Analysis complete - Ready for implementation
