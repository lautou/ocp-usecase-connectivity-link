# Ingress Gateway Only Overlay

This overlay deploys **ONLY** the ingress-gateway infrastructure, matching ansible deployment exactly.

## What This Deploys

**Total: 15 resources**

**Cluster-scoped**:
1. GatewayClass `istio`
2. ClusterRole `gateway-manager`
3. ClusterRoleBinding `gateway-manager-openshift-gitops-argocd-application-controller`
4. ClusterIssuer `prod-web-lets-encrypt-issuer`

**Namespace**:
5. Namespace `ingress-gateway` (with label `argocd.argoproj.io/managed-by: openshift-gitops`)

**Gateway and Policies**:
6. Gateway `prod-web`
7. TLSPolicy `prod-web-tls-policy` (matches ansible name)
8. AuthPolicy `prod-web-deny-all`
9. RateLimitPolicy `prod-web-rlp-lowlimits` (matches ansible name)

**Monitoring**:
10. ServiceMonitor `prod-web-service-monitor`
11. PodMonitor `istio-proxies-monitor`
12. Service `prod-web-metrics-proxy`

**Jobs**:
13. Job `aws-credentials-setup` (creates Secret `prod-web-aws-credentials`)
14. Job `gateway-prod-web-setup` (patches Gateway hostname)

**Auto-created by controllers**:
15. Secret `prod-web-aws-credentials` (created by Job)
16. Secret `api-tls` (created by TLSPolicy + cert-manager)
17. Deployment `prod-web-istio` (created by Gateway controller)
18. Service `prod-web-istio` (created by Gateway controller)

## What This EXCLUDES (Not in Ansible)

- ❌ DNSPolicy (not in ansible deployment)
- ❌ echo-api application
- ❌ globex applications
- ❌ Keycloak realm
- ❌ HTTPRoutes
- ❌ DNS delegation (ACK HostedZone/RecordSet)

## Comparison with Ansible Deployment

| Resource | Ansible Name | Our Name | Match? |
|----------|--------------|----------|--------|
| ClusterIssuer | `prod-web-lets-encrypt-issuer` | `prod-web-lets-encrypt-issuer` | ✅ Exact |
| TLSPolicy | `prod-web-tls-policy` | `prod-web-tls-policy` | ✅ Exact |
| RateLimitPolicy | `prod-web-rlp-lowlimits` | `prod-web-rlp-lowlimits` | ✅ Exact |
| AWS Secret | `prod-web-aws-credentials` | `prod-web-aws-credentials` | ✅ Exact |
| AuthPolicy | `prod-web-deny-all` | `prod-web-deny-all` | ✅ Exact |
| ServiceMonitor | `prod-web-service-monitor` | `prod-web-service-monitor` | ✅ Exact |
| PodMonitor | `istio-proxies-monitor` | `istio-proxies-monitor` | ✅ Exact |
| Service | `prod-web-metrics-proxy` | `prod-web-metrics-proxy` | ✅ Exact |
| Gateway | `prod-web` | `prod-web` | ✅ Exact |

**Result**: 100% matching names with ansible deployment.

## Usage

### Deploy

```bash
# Update ArgoCD Application to use this overlay
# Edit argocd/application.yaml:
# path: kustomize/overlays/ingress-gateway-only

# Apply
oc apply -f argocd/application.yaml

# Watch sync
oc get application usecase-connectivity-link -n openshift-gitops -w
```

### Verify

```bash
# Check namespace label
oc get namespace ingress-gateway -o jsonpath='{.metadata.labels}' | grep argocd

# Check all resources
oc get gateway,tlspolicy,authpolicy,ratelimitpolicy,servicemonitor,podmonitor,service -n ingress-gateway

# Check Gateway hostname (should be patched to *.globex.<cluster-domain>)
oc get gateway prod-web -n ingress-gateway -o jsonpath='{.spec.listeners[0].hostname}'

# Check TLS certificate
oc get certificate -n ingress-gateway

# Check AWS Secret
oc get secret prod-web-aws-credentials -n ingress-gateway -o yaml
```
