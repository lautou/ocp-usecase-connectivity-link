# Security Policy

## Secret Management in This Repository

### ⚠️ Demo Secrets Notice

This repository contains **hardcoded OAuth client secrets** in the following files:
- `kustomize/base/keycloak-keycloakrealmimport-globex-user1.yaml`

**These secrets are FOR DEMO/TESTING PURPOSES ONLY** and originate from Red Hat's Globex workshop materials.

### Why Are Secrets Committed?

This is a **GitOps demo repository** that showcases Red Hat Connectivity Link patterns. The Keycloak realm configuration includes:
- OAuth client secrets from upstream demo materials
- Pre-hashed demo user passwords
- Test service account credentials

**These are publicly known demo secrets and should NEVER be used in production environments.**

### Production Secret Management

For production deployments, use one of these approaches:

#### Option 1: Sealed Secrets (Recommended for GitOps)
```bash
# Install Sealed Secrets Operator
oc apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Seal a secret
echo -n "my-secret-value" | kubectl create secret generic my-secret \
  --dry-run=client --from-file=secret=/dev/stdin -o yaml | \
  kubeseal -o yaml > my-sealed-secret.yaml

# Commit sealed secret to Git (safe!)
git add my-sealed-secret.yaml
```

#### Option 2: External Secrets Operator
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: keycloak-client-secrets
spec:
  secretStoreRef:
    name: vault-backend
  target:
    name: keycloak-secrets
  data:
    - secretKey: client-secret
      remoteRef:
        key: secret/keycloak/client-manager
```

#### Option 3: Dynamic Secret Generation via Jobs
See `openshift-gitops-job-*.yaml` files for examples of Jobs that create secrets at runtime.

#### Option 4: HashiCorp Vault Integration
Use Vault Agent Injector or External Secrets Operator with Vault backend.

### Preventing Secret Leaks

#### 1. Install `rh-pre-commit`
```bash
# Install rh-pre-commit hooks
pip install rh-pre-commit
rh-pre-commit install

# This will scan commits for secrets before they're pushed
```

#### 2. Use `.gitleaks.toml` Allowlist
This repository includes a `.gitleaks.toml` file that explicitly allows known demo secrets. Review and update this file when adding new demo materials.

#### 3. Mark Demo Files Clearly
All files containing demo secrets should:
- Include `# DEMO SECRET` or `# FOR TESTING ONLY` comments
- Have a header warning explaining they're not for production
- Be documented in this SECURITY.md file

### Reporting Security Issues

If you discover a **real secret leak** (production credentials, API keys, etc.), please:

1. **DO NOT** create a public GitHub issue
2. **Contact** Red Hat Information Security immediately: infosec@redhat.com
3. **Include** details about the leak location and potential impact

### Security Contact

For security concerns related to this repository:
- Red Hat Information Security: infosec@redhat.com
- Repository Maintainer: Check CODEOWNERS file

---

## Demo Secrets Inventory

| Location | Secret Type | Value | Status |
|----------|-------------|-------|--------|
| `keycloak-keycloakrealmimport-globex-user1.yaml:49` | OAuth Client Secret | `9JRzL6le4K47JJkcSs6kjd9j2Mmfh1Jc` | Demo (upstream) |
| `keycloak-keycloakrealmimport-globex-user1.yaml:89` | OAuth Client Secret | `X0zRVwSWDVoUpKFhZwtQmZhDtoJ3MkcI` | Demo (generated) |
| `keycloak-keycloakrealmimport-globex-user1.yaml:134` | OAuth Client Secret | `Aob7zLHHStk2RCSn2DVwjmhSwoxOwHW7` | Demo (generated) |

**Last Updated**: 2026-03-19

---

**Remember**: When in doubt, treat all secrets as production credentials and use proper secret management tools!
