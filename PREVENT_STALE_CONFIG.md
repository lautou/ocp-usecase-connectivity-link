# Preventing Stale Configuration Issues

## Problem

When configuration changes (Keycloak settings, environment variables), running pods don't automatically restart, causing them to use outdated values.

## Solutions

### Solution 1: ConfigMap with Checksum Annotation (Best Practice)

Instead of patching deployments directly, use a ConfigMap for configuration and add its checksum as a pod annotation:

```yaml
# Create ConfigMap for configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: globex-web-config
  namespace: globex
data:
  SSO_AUTHORITY: "https://keycloak-keycloak.apps.CLUSTER_DOMAIN/realms/globex-user1"
  SSO_REDIRECT_LOGOUT_URI: "https://globex-web-globex.apps.CLUSTER_DOMAIN/home"
```

```yaml
# In deployment, add checksum annotation
spec:
  template:
    metadata:
      annotations:
        checksum/config: "{{ include (print $.Template.BasePath \"/configmap.yaml\") . | sha256sum }}"
    spec:
      containers:
      - name: globex-web
        envFrom:
        - configMapRef:
            name: globex-web-config
```

**How it works**: Any change to ConfigMap changes the checksum → triggers pod restart.

**Pros**:
- ✅ Automatic restart on config changes
- ✅ Clear separation of config and deployment
- ✅ Git-trackable configuration

**Cons**:
- ❌ Requires Helm or Kustomize transformers for checksum
- ❌ Still needs Job to populate cluster-specific values

### Solution 2: Job Watches Keycloak Changes (Current Approach +)

Enhance the current Job to trigger on Keycloak changes:

```yaml
# Add annotation to trigger Job on Keycloak changes
apiVersion: batch/v1
kind: Job
metadata:
  name: globex-env-setup
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

**Pros**:
- ✅ Automatic re-run on sync
- ✅ Minimal changes to current setup

**Cons**:
- ❌ Runs on every sync (even if config didn't change)
- ❌ May cause unnecessary pod restarts

### Solution 3: Version Annotation on Deployment

Add a version annotation that increments on every significant change:

```yaml
# In deployment template
spec:
  template:
    metadata:
      annotations:
        config-version: "2"  # Increment this when config changes
```

**Pros**:
- ✅ Simple and explicit
- ✅ Full control over when restarts happen

**Cons**:
- ❌ Manual process (easy to forget)
- ❌ Not automatic

### Solution 4: External Secrets Operator

Use External Secrets Operator to sync secrets/config from external source:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: globex-web-config
spec:
  refreshInterval: 1m  # Auto-refresh every minute
  secretStoreRef:
    name: cluster-config
  target:
    name: globex-web-config
```

**Pros**:
- ✅ Automatic sync from external source
- ✅ Production-ready secret management
- ✅ Supports rotation

**Cons**:
- ❌ Requires additional operator
- ❌ More complex setup

## Quick Fix (Current Issue)

When configuration changes don't seem to apply:

```bash
# 1. Delete the Job to trigger re-run
oc delete job globex-env-setup -n openshift-gitops

# 2. Wait for Job to complete
oc wait --for=condition=complete --timeout=60s job/globex-env-setup -n openshift-gitops

# 3. Verify rollout
oc rollout status deployment globex-web -n globex

# 4. Check pod logs
POD=$(oc get pods -n globex -l app.kubernetes.io/name=globex-web -o jsonpath='{.items[0].metadata.name}')
oc logs -n globex $POD -c patch-placeholder
```

## Recommended Approach for This Project

**Use Solution 2: ArgoCD PostSync Hook**

Modify `openshift-gitops-job-globex-env.yaml`:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

This ensures the Job runs after every sync, guaranteeing environment variables are always up-to-date.

**Trade-off**: Slightly longer sync times, but eliminates stale config issues.

## Monitoring

Set up alerts for configuration drift:

```bash
# Check if running config matches expected
oc get deployment globex-web -n globex -o jsonpath='{.spec.template.spec.containers[0].env}' | \
  jq '.[] | select(.name=="SSO_AUTHORITY")' | \
  grep -q "placeholder" && echo "WARNING: Stale config detected!"
```
