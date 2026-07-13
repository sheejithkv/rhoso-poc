#!/usr/bin/env bash
# WHAT: Phase 3 - the openstack-operator meta-operator, which in turn installs ~20 dependent
#       service operators (keystone-operator, nova-operator, etc.) as part of its own InstallPlan.
# CHANGED: installPlanApproval is now Manual (see docs/troubleshooting.md #11), so this script
#       explicitly approves the InstallPlan instead of assuming OLM does it automatically.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OP_DIR="${REPO_ROOT}/manifests/03-openstack-operator"

oc apply -f "${OP_DIR}/01-namespace.yaml"
oc apply -f "${OP_DIR}/02-operatorgroup.yaml"
oc apply -f "${OP_DIR}/03-subscription.yaml"
wait_and_approve openstack-operators openstack-operator
echo "-> waiting for all service operators to come up (5-10 min)..."
sleep 60
oc get pods -n openstack-operators
