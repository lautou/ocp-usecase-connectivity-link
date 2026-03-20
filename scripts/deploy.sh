#!/bin/bash
# Deploy Red Hat Connectivity Link to OpenShift cluster
# This script automates the deployment process using configuration from config/cluster.yaml

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.yaml"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse YAML (simple parser for our use case)
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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if oc command exists
    if ! command -v oc &> /dev/null; then
        log_error "oc command not found. Please install OpenShift CLI."
        log_info "Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"
        exit 1
    fi

    # Check if config file exists
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        log_info "Copy config/cluster.yaml.example to config/cluster.yaml and fill in your values"
        log_info "  cp config/cluster.yaml.example config/cluster.yaml"
        exit 1
    fi

    # Check if yq is available (optional but helpful)
    if ! command -v yq &> /dev/null; then
        log_warning "yq not found. Using basic YAML parser."
        log_info "For better YAML parsing, install yq: https://github.com/mikefarah/yq"
    fi

    log_success "Prerequisites check passed"
}

# Load configuration
load_config() {
    log_info "Loading configuration from ${CONFIG_FILE}..."

    # Parse YAML config
    eval $(parse_yaml "${CONFIG_FILE}" "config_")

    # Validate required fields
    if [ -z "${config_cluster_url}" ]; then
        log_error "cluster.url not configured in ${CONFIG_FILE}"
        exit 1
    fi

    if [ "${config_cluster_auth_method}" == "token" ] && [ -z "${config_cluster_token}" ]; then
        log_error "cluster.token not configured in ${CONFIG_FILE}"
        exit 1
    fi

    if [ "${config_cluster_auth_method}" == "password" ]; then
        if [ -z "${config_cluster_username}" ] || [ -z "${config_cluster_password}" ]; then
            log_error "cluster.username or cluster.password not configured in ${CONFIG_FILE}"
            exit 1
        fi
    fi

    log_success "Configuration loaded successfully"
}

# Login to OpenShift cluster
login_cluster() {
    log_info "Logging into OpenShift cluster: ${config_cluster_url}"

    local login_cmd="oc login ${config_cluster_url}"

    # Add insecure skip TLS if configured
    if [ "${config_cluster_insecure_skip_tls_verify}" == "true" ]; then
        login_cmd="${login_cmd} --insecure-skip-tls-verify=true"
        log_warning "Skipping TLS verification (not recommended for production)"
    fi

    # Authenticate
    if [ "${config_cluster_auth_method}" == "token" ]; then
        login_cmd="${login_cmd} --token=${config_cluster_token}"
    elif [ "${config_cluster_auth_method}" == "password" ]; then
        login_cmd="${login_cmd} -u ${config_cluster_username} -p ${config_cluster_password}"
    else
        log_error "Invalid auth_method: ${config_cluster_auth_method}. Use 'token' or 'password'"
        exit 1
    fi

    # Execute login
    if ${login_cmd} > /dev/null 2>&1; then
        log_success "Successfully logged in to cluster"
    else
        log_error "Failed to login to cluster"
        exit 1
    fi

    # Show current context
    CURRENT_USER=$(oc whoami 2>/dev/null || echo "unknown")
    CURRENT_SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    log_info "Logged in as: ${CURRENT_USER}"
    log_info "Cluster: ${CURRENT_SERVER}"
}

# Validate cluster prerequisites
validate_cluster() {
    if [ "${config_validation_check_operators}" != "true" ]; then
        log_warning "Skipping operator validation (disabled in config)"
        return
    fi

    log_info "Validating cluster prerequisites..."

    # Check OpenShift GitOps (ArgoCD)
    log_info "Checking OpenShift GitOps operator..."
    if oc get subscription openshift-gitops-operator -n openshift-gitops-operator &> /dev/null || \
       oc get subscription openshift-gitops-operator -n openshift-operators &> /dev/null; then
        log_success "OpenShift GitOps operator found"
    else
        log_error "OpenShift GitOps operator not found"
        log_info "Install via OperatorHub or run:"
        log_info "  oc apply -f https://raw.githubusercontent.com/redhat-developer/gitops-operator/master/docs/OpenShift%20GitOps%20Quick%20Start%20Guide.md"
        exit 1
    fi

    # Check if openshift-gitops namespace exists
    if oc get namespace openshift-gitops &> /dev/null; then
        log_success "openshift-gitops namespace exists"
    else
        log_error "openshift-gitops namespace not found"
        exit 1
    fi

    # Check ACK Route53 controller
    log_info "Checking ACK Route53 controller..."
    if oc get namespace ack-system &> /dev/null; then
        if oc get deployment ack-route53-controller -n ack-system &> /dev/null; then
            log_success "ACK Route53 controller found"
        else
            log_warning "ack-system namespace exists but controller not found"
        fi
    else
        log_warning "ACK Route53 controller not found (may need to be installed)"
    fi

    # Check cert-manager
    log_info "Checking cert-manager..."
    if oc get clusterissuer cluster &> /dev/null; then
        log_success "cert-manager ClusterIssuer 'cluster' found"
    else
        log_warning "cert-manager ClusterIssuer 'cluster' not found (required for TLS)"
    fi

    # Check Kuadrant Operator
    log_info "Checking Kuadrant Operator..."
    if oc get crd tlspolicies.kuadrant.io &> /dev/null; then
        log_success "Kuadrant CRDs found"
    else
        log_warning "Kuadrant CRDs not found (may need to be installed)"
    fi

    # Check OpenShift Service Mesh 3 (Sail Operator)
    log_info "Checking OpenShift Service Mesh 3..."
    if oc get crd istios.sailoperator.io &> /dev/null; then
        log_success "Sail Operator (OSSM 3) CRDs found"
    else
        log_warning "Sail Operator CRDs not found (may need to be installed)"
    fi

    log_success "Cluster validation completed (warnings are acceptable if operators will be installed)"
}

# Deploy ArgoCD Application
deploy_argocd_app() {
    log_info "Deploying ArgoCD Application..."

    local app_name="${config_argocd_app_name:-usecase-connectivity-link}"
    local namespace="${config_argocd_namespace:-openshift-gitops}"
    local repo_url="${config_argocd_repo_url}"
    local target_revision="${config_argocd_target_revision:-main}"
    local path="${config_argocd_path:-kustomize/overlays/default}"

    # Check if application already exists
    if oc get application "${app_name}" -n "${namespace}" &> /dev/null; then
        log_warning "ArgoCD Application '${app_name}' already exists"
        read -p "Do you want to update it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping application deployment"
            return
        fi
        log_info "Updating existing application..."
        oc delete application "${app_name}" -n "${namespace}"
        sleep 2
    fi

    # Apply ArgoCD Application
    log_info "Creating ArgoCD Application from ${PROJECT_ROOT}/argocd/application.yaml"
    oc apply -f "${PROJECT_ROOT}/argocd/application.yaml"

    log_success "ArgoCD Application deployed"
    log_info "Application: ${app_name}"
    log_info "Namespace: ${namespace}"
    log_info "Repository: ${repo_url}"
    log_info "Revision: ${target_revision}"
    log_info "Path: ${path}"
}

# Wait for ArgoCD sync
wait_for_sync() {
    if [ "${config_validation_wait_for_sync}" != "true" ]; then
        log_warning "Skipping sync wait (disabled in config)"
        return
    fi

    local app_name="${config_argocd_app_name:-usecase-connectivity-link}"
    local namespace="${config_argocd_namespace:-openshift-gitops}"
    local timeout="${config_validation_sync_timeout:-600}"
    local elapsed=0
    local interval=5

    log_info "Waiting for ArgoCD to sync (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        local sync_status=$(oc get application "${app_name}" -n "${namespace}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(oc get application "${app_name}" -n "${namespace}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

        echo -ne "\r${BLUE}[INFO]${NC} Sync: ${sync_status} | Health: ${health_status} | Elapsed: ${elapsed}s     "

        if [ "$sync_status" == "Synced" ] && [ "$health_status" == "Healthy" ]; then
            echo ""
            log_success "Application synced and healthy!"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo ""
    log_warning "Timeout waiting for sync. Check ArgoCD UI for details."
    return 1
}

# Show post-deployment information
show_status() {
    log_info "Getting deployment status..."

    local app_name="${config_argocd_app_name:-usecase-connectivity-link}"
    local namespace="${config_argocd_namespace:-openshift-gitops}"

    echo ""
    echo "=========================================="
    echo "Deployment Status"
    echo "=========================================="

    # ArgoCD Application status
    if oc get application "${app_name}" -n "${namespace}" &> /dev/null; then
        echo ""
        echo "ArgoCD Application:"
        oc get application "${app_name}" -n "${namespace}"
    fi

    # Gateway status
    echo ""
    echo "Gateway:"
    if oc get gateway prod-web -n ingress-gateway &> /dev/null; then
        oc get gateway prod-web -n ingress-gateway
    else
        echo "  Not yet created (waiting for sync)"
    fi

    # Jobs status
    echo ""
    echo "Jobs:"
    oc get jobs -n openshift-gitops | grep -E "aws-credentials|globex-ns-delegation|gateway-prod-web|echo-api-httproute" || echo "  No jobs found yet"

    # Echo API HTTPRoute
    echo ""
    echo "Echo API HTTPRoute:"
    if oc get httproute echo-api -n echo-api &> /dev/null; then
        HOSTNAME=$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || echo "not-set")
        echo "  Hostname: ${HOSTNAME}"
    else
        echo "  Not yet created (waiting for sync)"
    fi

    echo ""
    echo "=========================================="
    echo "Verification Commands"
    echo "=========================================="
    echo ""
    echo "# Watch ArgoCD sync progress:"
    echo "oc get application ${app_name} -n ${namespace} -w"
    echo ""
    echo "# Check Jobs status:"
    echo "oc get jobs -n openshift-gitops"
    echo ""
    echo "# Get echo-api hostname:"
    echo "oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}'"
    echo ""
    echo "# Test echo-api (once DNS is propagated):"
    echo "curl https://\$(oc get httproute echo-api -n echo-api -o jsonpath='{.spec.hostnames[0]}')"
    echo ""
    echo "# ArgoCD Web UI:"
    ARGOCD_ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-found")
    echo "https://${ARGOCD_ROUTE}"
    echo ""
}

# Main deployment flow
main() {
    echo "=========================================="
    echo "Red Hat Connectivity Link Deployment"
    echo "=========================================="
    echo ""

    check_prerequisites
    load_config
    login_cluster
    validate_cluster

    echo ""
    read -p "Ready to deploy ArgoCD Application? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled"
        exit 0
    fi

    deploy_argocd_app
    wait_for_sync
    show_status

    echo ""
    log_success "Deployment completed!"
    log_info "Monitor progress in ArgoCD UI or use the verification commands above"
}

# Run main function
main "$@"
