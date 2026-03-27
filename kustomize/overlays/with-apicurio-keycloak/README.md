# Overlay: with-apicurio-keycloak

This overlay extends the base Connectivity Link deployment with additional applications:

## Additional Components

1. **Apicurio Studio** (Red Hat build of Apicurio Registry 3)
   - Schema registry and API design platform
   - Namespace: `apicurio`
   - ArgoCD Application: `apicurio-studio`

2. **Keycloak** (RHBK 26.x)
   - OAuth 2.0 / OIDC authentication server
   - Namespace: `keycloak`
   - ArgoCD Application: `keycloak`
   - Realms: `apicurio` (for Apicurio Studio authentication)

## Usage

To deploy with Apicurio Studio and Keycloak:

```bash
# Apply this overlay instead of the default overlay
oc apply -k kustomize/overlays/with-apicurio-keycloak
```

Or update your ArgoCD Application to use this overlay:

```yaml
spec:
  source:
    path: kustomize/overlays/with-apicurio-keycloak
```

## What Gets Deployed

**Base components** (from `../../base`):
- Ingress Gateway infrastructure
- Echo API demo application
- All Gateway API resources (Gateway, TLSPolicy, AuthPolicy, etc.)

**Additional components** (this overlay):
- Apicurio Studio with PostgreSQL backend
- Keycloak instance with apicurio realm
- OAuth integration between Apicurio and Keycloak

## Notes

- This overlay is **NOT** the default deployment
- Default overlay (`kustomize/overlays/default`) includes only base infrastructure
- Use this overlay when you need schema registry and OAuth capabilities
- Both applications are managed via separate ArgoCD Applications
