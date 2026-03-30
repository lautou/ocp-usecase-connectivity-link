#!/bin/bash
# Test script for deploy.sh - validates configuration without connecting to cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Testing deployment script..."
echo ""

# Test 1: Check if config file exists
echo -n "Test 1: Config file exists... "
if [ -f "${PROJECT_ROOT}/config/cluster.yaml" ]; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Run: cp config/cluster.yaml.example config/cluster.yaml"
    exit 1
fi

# Test 2: Parse YAML function
echo -n "Test 2: YAML parsing... "
# Extract and source only the parse_yaml function
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    # First strip inline comments from the file
    sed -e 's/[[:space:]]*#.*$//' $1 |
    # Then parse the cleaned YAML
    sed -ne "s|^\($s\):|\1|" \
         -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
         -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" |
    awk -F$fs '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);
            printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
        }
    }'
}
eval $(parse_yaml "${PROJECT_ROOT}/config/cluster.yaml" "config_")
if [ -n "${config_cluster_url}" ] && [ -n "${config_argocd_app_name}" ]; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 3: Check required config values
echo -n "Test 3: Required configuration... "
MISSING=""
[ -z "${config_cluster_url}" ] && MISSING="${MISSING} cluster.url"
[ -z "${config_cluster_auth_method}" ] && MISSING="${MISSING} cluster.auth_method"
[ -z "${config_argocd_repo_url}" ] && MISSING="${MISSING} argocd.repo_url"

if [ -z "$MISSING" ]; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    echo "  Missing:$MISSING"
    exit 1
fi

# Test 4: Validate auth method
echo -n "Test 4: Auth method validation... "
if [ "${config_cluster_auth_method}" = "token" ]; then
    if [ -n "${config_cluster_token}" ] && [ "${config_cluster_token}" != "sha256~XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Token not configured or using placeholder value"
        exit 1
    fi
elif [ "${config_cluster_auth_method}" = "password" ]; then
    if [ -n "${config_cluster_username}" ] && [ -n "${config_cluster_password}" ]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
        echo "  Username or password not configured"
        exit 1
    fi
else
    echo -e "${RED}FAIL${NC}"
    echo "  Invalid auth_method: ${config_cluster_auth_method}"
    exit 1
fi

# Test 5: Check script syntax
echo -n "Test 5: Script syntax... "
if bash -n "${SCRIPT_DIR}/deploy.sh" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}All tests passed!${NC}"
echo ""
echo "Configuration summary:"
echo "  Cluster: ${config_cluster_url}"
echo "  Auth method: ${config_cluster_auth_method}"
echo "  ArgoCD app: ${config_argocd_app_name}"
echo "  Namespace: ${config_argocd_namespace}"
echo "  Wait for sync: ${config_validation_wait_for_sync}"
echo ""
echo "To deploy, run:"
echo "  ./scripts/deploy.sh"
