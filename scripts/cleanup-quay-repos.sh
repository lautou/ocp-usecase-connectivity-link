#!/bin/bash
#
# Cleanup script for obsolete quay.io repositories
#
# This script deletes unnecessary container image repositories that were created
# during development/testing but are no longer needed for the production deployment.
#
# REPOSITORIES TO DELETE:
#   - globex-web (replaced by globex-mobile)
#   - my-custom-image (test image)
#
# REPOSITORIES TO KEEP:
#   - globex-mobile (RHBK 26 compatible, in production use)
#   - globex-store (NullPointerException fix, in production use)
#   - jukebox-ui (unrelated project, leave alone)
#

set -e

NAMESPACE="laurenttourreau"
REPOS_TO_DELETE=("globex-web" "my-custom-image")

echo "=========================================="
echo "Quay.io Repository Cleanup"
echo "=========================================="
echo ""
echo "Namespace: ${NAMESPACE}"
echo ""

# Check if QUAY_TOKEN is set
if [ -z "${QUAY_TOKEN}" ]; then
  echo "ERROR: QUAY_TOKEN environment variable not set"
  echo ""
  echo "To get your token:"
  echo "  1. Login to quay.io"
  echo "  2. Go to Account Settings → Robot Accounts (or use your user token)"
  echo "  3. Generate an API token with 'Delete repositories' permission"
  echo "  4. Export token: export QUAY_TOKEN='your-token-here'"
  echo ""
  exit 1
fi

echo "Repositories to delete:"
for repo in "${REPOS_TO_DELETE[@]}"; do
  echo "  - ${repo}"
done
echo ""

# Confirm deletion
read -p "Are you sure you want to delete these repositories? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted by user"
  exit 0
fi

echo ""
echo "Starting cleanup..."
echo ""

# Delete each repository
for repo in "${REPOS_TO_DELETE[@]}"; do
  echo "[DELETE] ${NAMESPACE}/${repo}"

  # Check if repository exists first
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${QUAY_TOKEN}" \
    "https://quay.io/api/v1/repository/${NAMESPACE}/${repo}")

  if [ "$HTTP_CODE" = "404" ]; then
    echo "  ⚠️  Repository not found, skipping"
    continue
  fi

  # Delete repository
  DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer ${QUAY_TOKEN}" \
    "https://quay.io/api/v1/repository/${NAMESPACE}/${repo}")

  if [ "$DELETE_CODE" = "204" ] || [ "$DELETE_CODE" = "200" ]; then
    echo "  ✅ Deleted successfully"
  else
    echo "  ❌ Failed to delete (HTTP ${DELETE_CODE})"
  fi

  echo ""
done

echo "=========================================="
echo "✅ Cleanup complete!"
echo "=========================================="
echo ""
echo "Remaining repositories in ${NAMESPACE}:"
curl -s -H "Authorization: Bearer ${QUAY_TOKEN}" \
  "https://quay.io/api/v1/repository?namespace=${NAMESPACE}&public=true" \
  | jq -r '.repositories[].name' 2>/dev/null || echo "Unable to list repositories"
echo ""
