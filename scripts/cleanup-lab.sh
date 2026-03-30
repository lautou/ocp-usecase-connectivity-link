#!/bin/bash
# Cleanup Red Hat Connectivity Link lab deployment
# This script removes all ArgoCD Applications and namespaces created by this repository
#
# REMOVES:
#   - ArgoCD Applications (bootstrap, globex, rhbk, apicurio, solutions)
#   - Application namespaces (globex-apim-user1, keycloak, apicurio, echo-api, ingress-gateway)
#
# PRESERVES:
#   - GitOps operator (platform-managed)
#   - Cluster-wide operators (Kuadrant, cert-manager, ACK, RHBK operator, etc.)
#   - openshift-gitops namespace

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

# Check if oc is available
check_prerequisites() {
    if ! command -v oc &> /dev/null; then
        log_error "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
}

# Check if logged into OpenShift
check_login() {
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please run: oc login"
        exit 1
    fi

    local current_cluster=$(oc whoami --show-server)
    log_info "Connected to cluster: ${current_cluster}"
}

# Confirm cleanup
confirm_cleanup() {
    echo ""
    log_warning "This will DELETE the following resources:"
    echo ""
    echo "  ArgoCD Applications:"
    oc get application.argoproj.io -n openshift-gitops 2>/dev/null | grep -E "bootstrap-deployment|globex-apim|rhbk-stack|apicurio-studio|solutions-platform-engineer|solutions-developer" || echo "    (none found)"
    echo ""
    echo "  Namespaces:"
    oc get namespace 2>/dev/null | grep -E "globex-apim-user1|keycloak|apicurio|echo-api|ingress-gateway" || echo "    (none found)"
    echo ""
    log_warning "GitOps operator and cluster-wide operators will NOT be removed (platform-managed)"
    echo ""

    read -p "Are you sure you want to proceed? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
}

# Delete ArgoCD Applications
delete_argocd_applications() {
    log_info "Deleting ArgoCD Applications..."

    # List of Applications to delete (created by this repo)
    local apps=(
        "bootstrap-deployment"
        "globex"
        "rhbk"
        "apicurio-studio"
        "echo-api"
        "ingress-gateway"
        "solutions-platform-engineer-workflow"
        "solutions-developer-workflow"
    )

    for app in "${apps[@]}"; do
        if oc get application.argoproj.io "$app" -n openshift-gitops &> /dev/null; then
            log_info "  Deleting Application: $app"
            oc delete application.argoproj.io "$app" -n openshift-gitops --wait=false
        fi
    done

    log_success "ArgoCD Applications deletion initiated"
}

# Remove stuck finalizers from Applications
remove_application_finalizers() {
    log_info "Removing finalizers from stuck Applications..."

    local stuck_apps=$(oc get application.argoproj.io -n openshift-gitops 2>/dev/null | grep -E "globex|rhbk|apicurio|echo-api|ingress-gateway|bootstrap" | awk '{print $1}')

    for app in $stuck_apps; do
        log_info "  Removing finalizer from: $app"
        oc patch application.argoproj.io "$app" -n openshift-gitops -p '{"metadata":{"finalizers":null}}' --type=merge &> /dev/null || true
    done
}

# Wait for Applications to be deleted
wait_for_applications_deletion() {
    log_info "Waiting for Applications to finalize deletion (max 5 minutes)..."

    local timeout=300  # 5 minutes
    local elapsed=0
    local interval=10

    while [ $elapsed -lt $timeout ]; do
        local remaining=$(oc get application.argoproj.io -n openshift-gitops 2>/dev/null | grep -E "bootstrap-deployment|globex-apim|rhbk-stack|apicurio-studio|solutions-" | wc -l)

        if [ "$remaining" -eq 0 ]; then
            log_success "All Applications deleted"
            return 0
        fi

        log_info "  Waiting... ($remaining Applications remaining)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "Timeout waiting for Applications deletion. Proceeding anyway..."
}

# Delete namespaces
delete_namespaces() {
    log_info "Deleting application namespaces..."

    # List of namespaces created by this repo
    local namespaces=(
        "globex-apim-user1"
        "keycloak"
        "apicurio"
        "echo-api"
        "ingress-gateway"
    )

    for ns in "${namespaces[@]}"; do
        if oc get namespace "$ns" &> /dev/null; then
            log_info "  Deleting namespace: $ns"
            oc delete namespace "$ns" --wait=false
        fi
    done

    log_success "Namespace deletion initiated"
}

# Remove stuck resources with finalizers
remove_stuck_resources() {
    log_info "Checking for stuck resources with finalizers..."

    # Remove ApicurioRegistry3 finalizers (apicurio namespace)
    local apicurio_resources=$(oc get apicurioregistries3.registry.apicur.io -n apicurio 2>/dev/null | tail -n +2 | awk '{print $1}')
    for resource in $apicurio_resources; do
        log_info "  Removing finalizer from ApicurioRegistry3: $resource"
        oc patch apicurioregistries3.registry.apicur.io "$resource" -n apicurio -p '{"metadata":{"finalizers":null}}' --type=merge &> /dev/null || true
    done

    # Remove DNSRecord finalizers (ingress-gateway namespace)
    local dns_records=$(oc get dnsrecords.kuadrant.io -n ingress-gateway 2>/dev/null | tail -n +2 | awk '{print $1}')
    for resource in $dns_records; do
        log_info "  Removing finalizer from DNSRecord: $resource"
        oc patch dnsrecords.kuadrant.io "$resource" -n ingress-gateway -p '{"metadata":{"finalizers":null}}' --type=merge &> /dev/null || true
    done

    # Remove Keycloak finalizers (keycloak namespace)
    local keycloak_resources=$(oc get keycloak -n keycloak 2>/dev/null | tail -n +2 | awk '{print $1}')
    for resource in $keycloak_resources; do
        log_info "  Removing finalizer from Keycloak: $resource"
        oc patch keycloak "$resource" -n keycloak -p '{"metadata":{"finalizers":null}}' --type=merge &> /dev/null || true
    done

    local keycloakrealmimport_resources=$(oc get keycloakrealmimport -n keycloak 2>/dev/null | tail -n +2 | awk '{print $1}')
    for resource in $keycloakrealmimport_resources; do
        log_info "  Removing finalizer from KeycloakRealmImport: $resource"
        oc patch keycloakrealmimport "$resource" -n keycloak -p '{"metadata":{"finalizers":null}}' --type=merge &> /dev/null || true
    done
}

# Wait for namespaces to be deleted
wait_for_namespaces_deletion() {
    log_info "Waiting for namespaces to be deleted (max 5 minutes)..."

    local timeout=300  # 5 minutes
    local elapsed=0
    local interval=10

    while [ $elapsed -lt $timeout ]; do
        local remaining=$(oc get namespace 2>/dev/null | grep -E "globex-apim-user1|keycloak|apicurio|echo-api|ingress-gateway" | wc -l)

        if [ "$remaining" -eq 0 ]; then
            log_success "All namespaces deleted"
            return 0
        fi

        log_info "  Waiting... ($remaining namespaces remaining)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "Timeout waiting for namespace deletion. Some resources may still be terminating."
}

# Show cleanup summary
show_summary() {
    echo ""
    log_success "Lab cleanup completed!"
    echo ""
    log_info "Resources removed:"
    echo "  ✓ ArgoCD Applications (bootstrap, globex, rhbk, apicurio, solutions)"
    echo "  ✓ Application namespaces (globex-apim-user1, keycloak, apicurio, echo-api, ingress-gateway)"
    echo ""
    log_info "Resources preserved (platform-managed):"
    echo "  ✓ GitOps operator (openshift-gitops namespace)"
    echo "  ✓ Cluster-wide operators (Kuadrant, cert-manager, ACK, RHBK operator, etc.)"
    echo ""
    log_info "To redeploy the lab, run: ./scripts/setup-lab.sh"
    echo ""
}

# Main cleanup flow
main() {
    echo ""
    log_info "Red Hat Connectivity Link - Lab Cleanup"
    echo ""

    check_prerequisites
    check_login
    confirm_cleanup

    echo ""
    delete_argocd_applications
    wait_for_applications_deletion
    remove_application_finalizers

    echo ""
    delete_namespaces
    remove_stuck_resources
    wait_for_namespaces_deletion

    show_summary
}

# Run main function
main
