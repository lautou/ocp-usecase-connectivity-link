#!/bin/bash
# Setup Red Hat Connectivity Link tutorial solutions
#
# This script deploys optional tutorial resources on top of the base lab infrastructure.
# Prerequisites: Base lab must be deployed first (run ./setup-lab.sh)
# See solutions/README.md for detailed documentation.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOLUTIONS_DIR="${PROJECT_ROOT}/solutions"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Available solutions
AVAILABLE_SOLUTIONS=(
  "platform-engineer-workflow"
  "developer-workflow"
)

#######################################
# Print usage information
#######################################
usage() {
  cat <<EOF
${BLUE}Connectivity Link Solution Pattern Deployment Script${NC}

Deploy optional tutorial resources on top of the base GitOps infrastructure.

${YELLOW}USAGE:${NC}
  $0 <command> [solution-name]

${YELLOW}COMMANDS:${NC}
  list                List available solutions
  deploy <solution>   Deploy a solution pattern
  delete <solution>   Delete a solution pattern
  status <solution>   Check status of a solution pattern
  help                Show this help message

${YELLOW}AVAILABLE SOLUTIONS:${NC}
  platform-engineer-workflow   Platform Engineer tutorial (DNSPolicy, RateLimitPolicy)
  developer-workflow           Developer tutorial (HTTPRoute for ProductInfo API)

${YELLOW}EXAMPLES:${NC}
  # List all available solutions
  $0 list

  # Deploy platform-engineer-workflow tutorial resources
  $0 deploy platform-engineer-workflow

  # Deploy developer-workflow tutorial resources
  $0 deploy developer-workflow

  # Check status
  $0 status platform-engineer-workflow

  # Remove resources
  $0 delete developer-workflow

${YELLOW}MORE INFO:${NC}
  Documentation: solutions/README.md
  Tutorial: https://www.solutionpatterns.io/soln-pattern-connectivity-link/

EOF
}

#######################################
# Print error message and exit
#######################################
error() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

#######################################
# Print success message
#######################################
success() {
  echo -e "${GREEN}✓ $1${NC}"
}

#######################################
# Print info message
#######################################
info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

#######################################
# Print warning message
#######################################
warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

#######################################
# Validate solution name
#######################################
validate_solution() {
  local solution="$1"

  if [[ " ${AVAILABLE_SOLUTIONS[*]} " != *" ${solution} "* ]]; then
    error "Unknown solution: ${solution}\nAvailable solutions: ${AVAILABLE_SOLUTIONS[*]}"
  fi

  if [[ ! -d "${SOLUTIONS_DIR}/${solution}" ]]; then
    error "Solution directory not found: ${SOLUTIONS_DIR}/${solution}"
  fi
}

#######################################
# Check prerequisites
#######################################
check_prerequisites() {
  info "Checking prerequisites..."

  # Check oc/kubectl
  if ! command -v oc &> /dev/null; then
    error "oc command not found. Please install OpenShift CLI."
  fi

  # Check cluster connection
  if ! oc whoami &> /dev/null; then
    error "Not connected to an OpenShift cluster. Please login first."
  fi

  # Check if base infrastructure is deployed
  if ! oc get gateway prod-web -n ingress-gateway &> /dev/null; then
    warning "Base Gateway 'prod-web' not found. Deploy base infrastructure first."
    echo "Run: ./scripts/deploy.sh"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi

  success "Prerequisites check passed"
}

#######################################
# List available solutions
#######################################
list_solutions() {
  echo -e "${BLUE}Available Solution Patterns:${NC}\n"

  for solution in "${AVAILABLE_SOLUTIONS[@]}"; do
    local solution_dir="${SOLUTIONS_DIR}/${solution}"
    local status=""

    # Check if deployed
    if oc get -k "${solution_dir}" &> /dev/null; then
      status="${GREEN}[DEPLOYED]${NC}"
    else
      status="${YELLOW}[NOT DEPLOYED]${NC}"
    fi

    echo -e "  • ${solution} ${status}"

    # Show brief description
    case "${solution}" in
      platform-engineer-workflow)
        echo -e "    ${BLUE}Platform Engineer Tutorial${NC}"
        echo -e "    Deploys: DNSPolicy + RateLimitPolicy (HTTPRoute-level)"
        echo -e "    Tutorial: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html"
        ;;
      developer-workflow)
        echo -e "    ${BLUE}Application Developer Tutorial${NC}"
        echo -e "    Deploys: HTTPRoute for ProductInfo API (path-based routing)"
        echo -e "    Tutorial: Gateway API HTTPRoute demonstration"
        ;;
    esac
    echo ""
  done

  echo -e "${YELLOW}USAGE:${NC}"
  echo -e "  Deploy:  $0 deploy <solution-name>"
  echo -e "  Remove:  $0 delete <solution-name>"
  echo -e "  Status:  $0 status <solution-name>"
  echo ""
}

#######################################
# Deploy a solution
#######################################
deploy_solution() {
  local solution="$1"
  validate_solution "${solution}"

  info "Deploying solution: ${solution}"
  echo ""

  local solution_dir="${SOLUTIONS_DIR}/${solution}"

  # Apply resources
  echo "Applying resources from ${solution_dir}..."
  oc apply -k "${solution_dir}/"
  echo ""

  success "Solution deployed: ${solution}"
  echo ""

  # Show next steps based on solution
  case "${solution}" in
    platform-engineer-workflow)
      echo -e "${BLUE}Next Steps:${NC}"
      echo ""
      echo "1. Wait for DNSPolicy to be enforced:"
      echo "   oc get dnspolicy prod-web-dnspolicy -n ingress-gateway -w"
      echo ""
      echo "2. Verify DNS record created:"
      echo "   oc get dnsrecord.kuadrant.io -n ingress-gateway"
      echo ""
      echo "3. Check RateLimitPolicy status:"
      echo "   oc get ratelimitpolicy echo-api-rlp -n echo-api"
      echo ""
      echo "4. Check DNS resolution:"
      CLUSTER_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "<cluster-domain>")
      ROOT_DOMAIN=$(echo "${CLUSTER_DOMAIN}" | sed 's/^[^.]*\.//')
      echo "   dig echo.globex.${ROOT_DOMAIN}"
      echo ""
      echo "5. Test rate limiting (HTTPRoute policy: 10 req/12s):"
      echo "   for i in {1..12}; do curl -k -w ' %{http_code}\n' -o /dev/null https://echo.globex.${ROOT_DOMAIN}; done"
      echo "   Expected: 10× 200, then 2× 429"
      echo ""
      echo -e "${YELLOW}Note:${NC} HTTPRoute RateLimitPolicy (10 req/12s) overrides Gateway policy (5 req/10s)"
      echo ""
      echo "Tutorial: https://www.solutionpatterns.io/soln-pattern-connectivity-link/solution-pattern/03.1-platform.html"
      ;;
    developer-workflow)
      echo -e "${BLUE}Next Steps:${NC}"
      echo ""
      echo "1. Check HTTPRoute created and attached to Gateway:"
      echo "   oc get httproute globex-mobile-gateway -n globex-apim-user1"
      echo ""
      echo "2. Verify HTTPRoute status:"
      echo "   oc describe httproute globex-mobile-gateway -n globex-apim-user1"
      echo ""
      CLUSTER_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "<cluster-domain>")
      ROOT_DOMAIN=$(echo "${CLUSTER_DOMAIN}" | sed 's/^[^.]*\.//')
      echo "3. Test ProductInfo API endpoint (expect HTTP 403):"
      echo "   curl -k https://globex-mobile.globex.${ROOT_DOMAIN}/mobile/services/category/list"
      echo "   Expected: HTTP 403 Forbidden (AuthPolicy deny-by-default)"
      echo ""
      echo "4. Test product category endpoint:"
      echo "   curl -k https://globex-mobile.globex.${ROOT_DOMAIN}/mobile/services/product/category/"
      echo "   Expected: HTTP 403 Forbidden"
      echo ""
      echo -e "${YELLOW}Note:${NC} Gateway has deny-by-default AuthPolicy. Next step: add AuthPolicy for this HTTPRoute."
      echo ""
      echo "See: solutions/developer-workflow/README.md for next tutorial steps"
      ;;
  esac
}

#######################################
# Delete a solution
#######################################
delete_solution() {
  local solution="$1"
  validate_solution "${solution}"

  warning "This will delete all resources for solution: ${solution}"
  read -p "Are you sure? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Cancelled"
    exit 0
  fi

  info "Deleting solution: ${solution}"
  echo ""

  local solution_dir="${SOLUTIONS_DIR}/${solution}"

  # Delete resources
  echo "Deleting resources from ${solution_dir}..."
  oc delete -k "${solution_dir}/" || true
  echo ""

  success "Solution deleted: ${solution}"
  echo ""

  # Show verification steps
  case "${solution}" in
    platform-engineer-workflow)
      echo -e "${BLUE}Verification:${NC}"
      echo ""
      echo "1. Check DNSPolicy removed:"
      echo "   oc get dnspolicy -n ingress-gateway"
      echo "   Expected: No resources found"
      echo ""
      echo "2. Check RateLimitPolicy removed:"
      echo "   oc get ratelimitpolicy echo-api-rlp -n echo-api"
      echo "   Expected: No resources found"
      echo ""
      echo "3. Check DNSRecord removed:"
      echo "   oc get dnsrecord.kuadrant.io -n ingress-gateway"
      echo "   Expected: No resources found"
      echo ""
      echo "4. Verify Gateway policy active again:"
      echo "   oc get ratelimitpolicy prod-web-rlp-lowlimits -n ingress-gateway -o jsonpath='{.status.conditions}'"
      echo "   Expected: Enforced: True (was Overridden before)"
      echo ""
      echo "Note: DNS records in Route53 may take a few minutes to be cleaned up."
      ;;
    developer-workflow)
      echo -e "${BLUE}Verification:${NC}"
      echo ""
      echo "1. Check HTTPRoute removed:"
      echo "   oc get httproute globex-mobile-gateway -n globex-apim-user1"
      echo "   Expected: No resources found"
      echo ""
      echo "2. Verify API endpoint no longer accessible via Gateway:"
      CLUSTER_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "<cluster-domain>")
      ROOT_DOMAIN=$(echo "${CLUSTER_DOMAIN}" | sed 's/^[^.]*\.//')
      echo "   curl -k https://globex-mobile.globex.${ROOT_DOMAIN}/mobile/services/category/list"
      echo "   Expected: HTTP 404 Not Found (no route)"
      echo ""
      echo "3. Verify frontend still accessible via Route:"
      echo "   curl -k https://globex-mobile-globex-apim-user1.apps.${CLUSTER_DOMAIN}/"
      echo "   Expected: HTTP 200 OK (frontend unchanged)"
      ;;
  esac
}

#######################################
# Check solution status
#######################################
status_solution() {
  local solution="$1"
  validate_solution "${solution}"

  info "Checking status of solution: ${solution}"
  echo ""

  local solution_dir="${SOLUTIONS_DIR}/${solution}"
  local label="solution-pattern.kuadrant.io/tutorial=${solution}"

  case "${solution}" in
    platform-engineer-workflow)
      echo -e "${BLUE}=== DNSPolicy ===${NC}"
      if oc get dnspolicy prod-web-dnspolicy -n ingress-gateway &> /dev/null; then
        oc get dnspolicy prod-web-dnspolicy -n ingress-gateway
        echo ""
        echo -e "${BLUE}Status:${NC}"
        oc get dnspolicy prod-web-dnspolicy -n ingress-gateway -o jsonpath='{.status.conditions}' | jq '.'
      else
        warning "DNSPolicy not deployed"
      fi
      echo ""

      echo -e "${BLUE}=== RateLimitPolicy ===${NC}"
      if oc get ratelimitpolicy echo-api-rlp -n echo-api &> /dev/null; then
        oc get ratelimitpolicy echo-api-rlp -n echo-api
        echo ""
        echo -e "${BLUE}Status:${NC}"
        oc get ratelimitpolicy echo-api-rlp -n echo-api -o jsonpath='{.status.conditions}' | jq '.'
        echo ""
        echo -e "${BLUE}Effective Rate Limit:${NC} 10 requests / 12 seconds"
        echo -e "${YELLOW}Note:${NC} HTTPRoute policy overrides Gateway policy (5 req/10s)"
      else
        warning "RateLimitPolicy not deployed"
      fi
      echo ""

      echo -e "${BLUE}=== DNSRecord ===${NC}"
      if oc get dnsrecord.kuadrant.io -n ingress-gateway &> /dev/null; then
        oc get dnsrecord.kuadrant.io -n ingress-gateway
      else
        warning "No DNSRecords found"
      fi
      echo ""

      echo -e "${BLUE}=== DNS Resolution ===${NC}"
      CLUSTER_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null)
      ROOT_DOMAIN=$(echo "${CLUSTER_DOMAIN}" | sed 's/^[^.]*\.//')
      echo "Testing: echo.globex.${ROOT_DOMAIN}"
      dig +short "echo.globex.${ROOT_DOMAIN}" || warning "DNS not resolving"
      echo ""
      ;;
    developer-workflow)
      echo -e "${BLUE}=== HTTPRoute ===${NC}"
      if oc get httproute globex-mobile-gateway -n globex-apim-user1 &> /dev/null; then
        oc get httproute globex-mobile-gateway -n globex-apim-user1
        echo ""
        echo -e "${BLUE}Status:${NC}"
        oc get httproute globex-mobile-gateway -n globex-apim-user1 -o jsonpath='{.status.parents[0].conditions}' | jq '.'
        echo ""
        echo -e "${BLUE}Attached to Gateway:${NC}"
        oc get httproute globex-mobile-gateway -n globex-apim-user1 -o jsonpath='{.status.parents[0].parentRef.name}'
        echo ""
      else
        warning "HTTPRoute not deployed"
      fi
      echo ""

      echo -e "${BLUE}=== API Endpoint Test ===${NC}"
      CLUSTER_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null)
      ROOT_DOMAIN=$(echo "${CLUSTER_DOMAIN}" | sed 's/^[^.]*\.//')
      echo "Testing: https://globex-mobile.globex.${ROOT_DOMAIN}/mobile/services/category/list"
      HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" "https://globex-mobile.globex.${ROOT_DOMAIN}/mobile/services/category/list" 2>/dev/null || echo "000")
      if [[ "${HTTP_CODE}" == "403" ]]; then
        success "Endpoint accessible (HTTP 403 - expected, AuthPolicy deny-by-default)"
      elif [[ "${HTTP_CODE}" == "404" ]]; then
        warning "HTTP 404 - HTTPRoute not working or not attached to Gateway"
      else
        echo "HTTP ${HTTP_CODE}"
      fi
      echo ""

      echo -e "${BLUE}=== Path Matching ===${NC}"
      echo "Configured paths:"
      echo "  • GET /mobile/services/product/category/*"
      echo "  • GET /mobile/services/category/list"
      echo ""
      ;;
  esac

  echo -e "${BLUE}=== All Resources with Label ===${NC}"
  oc get all,dnspolicy,dnsrecord -n ingress-gateway -l "${label}" 2>/dev/null || info "No resources found with label: ${label}"
}

#######################################
# Main
#######################################
main() {
  local command="${1:-}"
  local solution="${2:-}"

  case "${command}" in
    list)
      list_solutions
      ;;
    deploy)
      if [[ -z "${solution}" ]]; then
        error "Solution name required.\nUsage: $0 deploy <solution-name>"
      fi
      check_prerequisites
      deploy_solution "${solution}"
      ;;
    delete)
      if [[ -z "${solution}" ]]; then
        error "Solution name required.\nUsage: $0 delete <solution-name>"
      fi
      delete_solution "${solution}"
      ;;
    status)
      if [[ -z "${solution}" ]]; then
        error "Solution name required.\nUsage: $0 status <solution-name>"
      fi
      status_solution "${solution}"
      ;;
    help|--help|-h)
      usage
      ;;
    "")
      usage
      exit 1
      ;;
    *)
      error "Unknown command: ${command}\n$(usage)"
      ;;
  esac
}

main "$@"
