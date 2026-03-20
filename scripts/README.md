# Deployment Scripts

Automation scripts for deploying Red Hat Connectivity Link to OpenShift clusters.

## Prerequisites

- **OpenShift CLI (`oc`)** - Download from [OpenShift Mirror](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/)
- **Cluster access** - API URL and credentials (token or password)
- **Configuration file** - `config/cluster.yaml` (see setup below)

## Setup

1. **Create configuration file**:
   ```bash
   cp config/cluster.yaml.example config/cluster.yaml
   ```

2. **Edit `config/cluster.yaml`** with your cluster details:
   ```yaml
   cluster:
     url: "https://api.mycluster.example.com:6443"
     auth_method: "token"  # or "password"
     token: "sha256~YOUR_ACTUAL_TOKEN_HERE"
     # OR for password auth:
     # username: "kubeadmin"
     # password: "YOUR_PASSWORD"

   argocd:
     repo_url: "https://github.com/lautou/ocp-usecase-connectivity-link.git"
     target_revision: "main"
     path: "kustomize/overlays/default"

   validation:
     check_operators: true      # Validate required operators
     wait_for_sync: true        # Wait for ArgoCD sync
     sync_timeout: 600          # Timeout in seconds
   ```

3. **Get your cluster token** (if using token auth):
   ```bash
   # Login to cluster first
   oc login https://api.mycluster.example.com:6443

   # Get token
   oc whoami -t
   ```

## Usage

### Test Configuration

Validate your configuration without deploying:

```bash
./scripts/test-deploy.sh
```

Expected output:
```
Test 1: Config file exists... PASS
Test 2: YAML parsing... PASS
Test 3: Required configuration... PASS
Test 4: Auth method validation... PASS
Test 5: Script syntax... PASS

Configuration summary:
  Cluster: https://api.mycluster.example.com:6443
  Auth method: token
  ArgoCD app: usecase-connectivity-link
  ...
```

### Deploy

Run the deployment script:

```bash
./scripts/deploy.sh
```

The script will:
1. ✅ Check prerequisites (`oc` CLI, config file)
2. ✅ Load and validate configuration
3. ✅ Login to OpenShift cluster
4. ✅ Validate cluster prerequisites (operators, namespaces)
5. ❓ Ask for confirmation before deploying
6. 🚀 Deploy ArgoCD Application
7. ⏳ Wait for ArgoCD sync (optional)
8. 📊 Show deployment status and verification commands

### Interactive Prompts

The script will ask for confirmation at key steps:

1. **Before deployment**:
   ```
   Ready to deploy ArgoCD Application? (y/N):
   ```

2. **If application already exists**:
   ```
   ArgoCD Application 'usecase-connectivity-link' already exists
   Do you want to update it? (y/N):
   ```

Press `y` to continue, `N` to skip.

## Configuration Options

### Cluster Authentication

**Token authentication** (recommended):
```yaml
cluster:
  auth_method: "token"
  token: "sha256~YOUR_TOKEN"
```

**Password authentication**:
```yaml
cluster:
  auth_method: "password"
  username: "kubeadmin"
  password: "YOUR_PASSWORD"
```

### TLS Verification

For dev/test clusters with self-signed certificates:
```yaml
cluster:
  insecure_skip_tls_verify: true  # NOT recommended for production
```

### Validation Options

Skip operator checks (faster, but may fail deployment):
```yaml
validation:
  check_operators: false
  check_namespaces: false
```

Don't wait for sync (deploy and exit immediately):
```yaml
validation:
  wait_for_sync: false
```

Increase sync timeout for slow networks:
```yaml
validation:
  sync_timeout: 1200  # 20 minutes
```

## Verification Commands

After deployment, use these commands to monitor progress:

```bash
# Watch ArgoCD sync status
oc get application usecase-connectivity-link -n openshift-gitops -w

# Check Job completion
oc get jobs -n openshift-gitops | grep -E "aws-credentials|globex-ns-delegation|gateway-prod-web|echo-api-httproute"

# View Job logs
oc logs -n openshift-gitops job/globex-ns-delegation
oc logs -n openshift-gitops job/gateway-prod-web-setup

# Check Gateway resources
oc get gateway prod-web -n ingress-gateway
oc get httproute echo-api -n echo-api

# Test echo-api endpoint
HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')
curl https://$HOSTNAME
```

## Troubleshooting

### "oc command not found"

Install OpenShift CLI:
```bash
# Download
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz

# Extract
tar xvf openshift-client-linux.tar.gz

# Move to PATH
sudo mv oc /usr/local/bin/
```

### "Failed to login to cluster"

Check your credentials:
```bash
# Test login manually
oc login https://api.mycluster.example.com:6443 --token=YOUR_TOKEN

# Or with password
oc login https://api.mycluster.example.com:6443 -u kubeadmin -p YOUR_PASSWORD
```

### "OpenShift GitOps operator not found"

Install the operator:
```bash
# Via OperatorHub in OpenShift Console
# OR using CLI:
oc create -f https://raw.githubusercontent.com/redhat-developer/gitops-operator/master/config/samples/gitops_v1alpha1_gitopsservice.yaml
```

### "Configuration file not found"

Create the config file:
```bash
cp config/cluster.yaml.example config/cluster.yaml
# Then edit with your values
```

### ArgoCD Application stays "OutOfSync"

Check Job logs for errors:
```bash
oc get jobs -n openshift-gitops
oc logs -n openshift-gitops job/globex-ns-delegation
```

Force resync:
```bash
oc delete job globex-ns-delegation gateway-prod-web-setup echo-api-httproute-setup -n openshift-gitops
oc annotate application usecase-connectivity-link -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
```

## Security Notes

⚠️ **IMPORTANT**: Never commit `config/cluster.yaml` to Git!

- The file is in `.gitignore` for safety
- Contains sensitive credentials (tokens, passwords)
- Only commit `config/cluster.yaml.example` with placeholders

## What Gets Deployed

The script deploys an ArgoCD Application that manages:

1. **DNS Infrastructure** (Route53 hosted zone + delegation)
2. **Istio Gateway** (HTTPS ingress with TLS)
3. **Kuadrant Policies** (DNS, TLS, Auth, RateLimit)
4. **Echo API** (demo application)
5. **Keycloak Realm** (optional, if `keycloak.deploy_realm: true`)

See [README.md](../README.md) for full architecture details.

## Files

- **deploy.sh** - Main deployment script
- **test-deploy.sh** - Configuration validation script
- **README.md** - This file

## Related Documentation

- [Project README](../README.md) - Full architecture and deployment guide
- [CLAUDE.md](../CLAUDE.md) - Developer documentation and design decisions
- [SECURITY.md](../SECURITY.md) - Security policy and secret management
