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

## Deployment Status (Latest)

**Last Verified**: 2026-03-25

**Gateway**:
- ✅ Hostname: `*.globex.sandbox3491.opentlc.com` (root domain, matches ansible)
- ✅ Programmed: True
- ✅ Load Balancer: Ready (`a3eaa314bea1a4ceb9a0b3b2b6481b56-2122933903.eu-central-1.elb.amazonaws.com`)

**TLS Certificate**:
- ✅ Issued by Let's Encrypt
- ✅ Subject: `*.globex.sandbox3491.opentlc.com`
- ✅ Valid until: Jun 23, 2026
- ✅ Status: Ready

**DNS**:
- ⏳ No DNSPolicy (expected - matches ansible)
- ⏳ No automatic DNS records created
- Manual DNS records or DNSPolicy deployment required for external access

**Policies**:
- ✅ AuthPolicy: Deny-by-default (returns HTTP 403)
- ✅ RateLimitPolicy: 5 requests per 10 seconds
- ✅ TLSPolicy: Enforced (cert auto-managed)

**Monitoring**:
- ✅ ServiceMonitor: Collecting Gateway metrics
- ✅ PodMonitor: Collecting Istio proxy metrics
- ✅ Metrics Service: Port 15020 exposed

**Namespace**:
- ✅ Label `argocd.argoproj.io/managed-by: openshift-gitops` present
- ✅ Auto-created Role and RoleBinding for ArgoCD

## Key Differences from Ansible

**The ONLY delta** between ansible and this deployment:

| Aspect | Ansible | Our Deployment | Impact |
|--------|---------|----------------|--------|
| **Namespace label** | ❌ Manual `oc label` | ✅ In Git manifests | **Better** - Fully GitOps |
| **Resource names** | ✅ | ✅ | Identical |
| **Gateway hostname** | `*.globex.<root-domain>` | `*.globex.<root-domain>` | Identical |
| **ClusterIssuer** | `prod-web-lets-encrypt-issuer` | `prod-web-lets-encrypt-issuer` | Identical |
| **DNSPolicy** | ❌ Not included | ❌ Not included | Identical |

**Result**: 100% functional match + better GitOps integration ✅

## Related Documentation

- [INGRESS_GATEWAY_DEPLOYMENT.md](../../../INGRESS_GATEWAY_DEPLOYMENT.md) - Complete deployment analysis
- [CLEANUP_AND_REDEPLOY.md](../../../CLEANUP_AND_REDEPLOY.md) - Step-by-step cleanup guide
- [CLAUDE.md](../../../CLAUDE.md) - Full project documentation
