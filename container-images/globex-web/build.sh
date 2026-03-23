#!/bin/bash
#
# Build and push custom globex-web image
#
# Usage:
#   ./build.sh <quay-username> [tag]
#
# Examples:
#   ./build.sh myusername             # Builds and pushes with tag 'fixed'
#   ./build.sh myusername v1.0        # Builds and pushes with tag 'v1.0'
#

set -e

# Check arguments
if [ -z "$1" ]; then
    echo "Error: Quay.io username required"
    echo ""
    echo "Usage: $0 <quay-username> [tag]"
    echo ""
    echo "Examples:"
    echo "  $0 myusername             # Uses tag 'fixed'"
    echo "  $0 myusername v1.0        # Uses tag 'v1.0'"
    exit 1
fi

QUAY_USER="$1"
TAG="${2:-fixed}"
IMAGE="quay.io/${QUAY_USER}/globex-web:${TAG}"

echo "=========================================="
echo "Building Custom Globex Web Image"
echo "=========================================="
echo ""
echo "Image: ${IMAGE}"
echo ""

# Check if podman is available
if ! command -v podman &> /dev/null; then
    echo "Error: podman not found. Please install podman first."
    exit 1
fi

# Build the image
echo "[1/3] Building image..."
podman build -t "${IMAGE}" .

if [ $? -ne 0 ]; then
    echo "Error: Build failed"
    exit 1
fi

echo ""
echo "[2/3] Image built successfully: ${IMAGE}"
echo ""

# Verify the patch
echo "[3/3] Verifying OAuth patch..."
podman run --rm "${IMAGE}" sh -c \
    'grep -r "response_type" /opt/app-root/src/dist/globex-web/browser/ | head -3 || true'

echo ""
echo "=========================================="
echo "Build Complete!"
echo "=========================================="
echo ""
echo "Image: ${IMAGE}"
echo ""
echo "Next steps:"
echo "  1. Login to Quay.io:"
echo "     podman login quay.io"
echo ""
echo "  2. Push the image:"
echo "     podman push ${IMAGE}"
echo ""
echo "  3. Update deployment:"
echo "     Edit kustomize/base/globex-deployment-globex-web.yaml"
echo "     Change image to: ${IMAGE}"
echo ""
echo "  4. Commit and push to trigger ArgoCD sync"
echo ""
