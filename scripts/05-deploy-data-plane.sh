#!/usr/bin/env bash
# WHAT: Phase 5 - RHEL subscription secrets, SSH secret, the Compute NodeSet, and the
#       OpenStackDataPlaneDeployment that triggers the actual Ansible run against it.
# CHANGED: now creates the subscription-manager/redhat-registry secrets first - previously
#       manifests/05-data-plane/02-nodeset-compute.yaml referenced these secrets in
#       ansibleVarsFrom but nothing in this repo ever created them, so the `redhat` service
#       (first in the services list) would have failed immediately with a missing-secret error.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DP_DIR="${REPO_ROOT}/manifests/05-data-plane"

bash "${DP_DIR}/00-subscription-manager-secrets.sh"
bash "${DP_DIR}/01-ssh-and-nova-secrets.sh"
oc apply -f "${DP_DIR}/02-nodeset-compute.yaml"
oc apply -f "${DP_DIR}/03-dataplane-deployment.yaml"
echo "-> tailing Ansible execution job (Ctrl+C to stop watching, deployment continues)..."
sleep 15
oc get pods -n openstack -l app=openstackansibleee
oc get openstackdataplanedeployment -n openstack -w &
WPID=$!; sleep 120; kill $WPID 2>/dev/null || true
