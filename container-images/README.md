# Custom Container Images

This directory contains custom container image builds for the Connectivity Link project.

## Structure

```
container-images/
├── README.md                    # This file
└── globex-web/                  # Custom globex-web image
    ├── Containerfile            # Build instructions
    ├── README.md                # Specific documentation
    └── .containerignore         # Files to exclude from build
```

## Purpose

Custom images are needed when upstream images have issues that cannot be fixed through configuration alone. Examples:

- **globex-web**: Patches OAuth flow from Implicit to Authorization Code Flow
- Future: Additional custom images as needed

## General Workflow

1. **Build**:
   ```bash
   cd container-images/<image-name>
   podman build -t quay.io/YOUR_USERNAME/<image-name>:TAG .
   ```

2. **Test locally**:
   ```bash
   podman run --rm -p 8080:8080 quay.io/YOUR_USERNAME/<image-name>:TAG
   ```

3. **Push to registry**:
   ```bash
   podman login quay.io
   podman push quay.io/YOUR_USERNAME/<image-name>:TAG
   ```

4. **Update deployment**:
   - Edit `kustomize/base/<namespace>-deployment-<name>.yaml`
   - Change `image:` field to your custom image
   - Commit and push to trigger ArgoCD sync

## Image Registry

This project uses **Quay.io** as the container registry:
- Public images: `quay.io/YOUR_USERNAME/<image-name>`
- Private images: Require pull secret configuration

## Security Considerations

- **DO NOT** commit sensitive credentials to Containerfiles
- Use build arguments for secrets: `--build-arg SECRET=value`
- Use multi-stage builds to avoid leaking build-time secrets
- Scan images for vulnerabilities: `podman scan quay.io/YOUR_USERNAME/<image>`

## CI/CD Integration

Future enhancement: Automate builds with GitHub Actions or Tekton pipelines.

## See Also

- [Official Red Hat Globex images](https://quay.io/organization/cloud-architecture-workshop)
- [Podman documentation](https://docs.podman.io/)
- [Containerfile best practices](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
