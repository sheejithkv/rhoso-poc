#!/usr/bin/env bash
# WHAT: Phase 2 - NMState operator, the `openstack` namespace, NetConfig (IPAM), per-worker
#       bonded NNCPs, Multus NAD definitions, MetalLB.
# FIXED ORDERING BUG: the original script applied NetworkAttachmentDefinitions into namespace
# `openstack` before that namespace existed anywhere (it was only created in
# scripts/03-deploy-openstack-operator.sh, which ran AFTER this script) - `oc apply` on the NADs
# would fail outright on a from-scratch run. 00-openstack-namespace.yaml now creates it here too.
# FIXED: previously applied a single static NNCP hardcoded to worker-0 only; now generates and
# applies one per actual worker node (03-generate-nncp.sh), each with the bonded pair + VLANs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

NET_DIR="${REPO_ROOT}/manifests/02-networking"

echo "== Creating openstack namespace early (fixes ordering bug - see header comment) =="
oc apply -f "${NET_DIR}/00-openstack-namespace.yaml"

echo "== Installing NMState operator =="
oc apply -f "${NET_DIR}/01-nmstate-sub.yaml"
wait_and_approve openshift-nmstate kubernetes-nmstate-operator
# The operator creates an NMState CR itself in most installs; if not, this is idempotent:
oc apply -f - <<'EOF' 2>/dev/null || true
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF
sleep 15

echo "== Applying NetConfig (IPAM for ctlplane/internalapi/storage/tenant) =="
oc apply -f "${NET_DIR}/02-netconfig.yaml"

echo "== Generating and applying per-worker bonded NNCPs =="
bash "${NET_DIR}/03-generate-nncp.sh"
echo "-> watching NNCE rollout for 60s (Ctrl+C-safe, deployment continues in background)..."
oc get nnce -w & WPID=$!; sleep 60; kill $WPID 2>/dev/null || true

echo "== Applying NetworkAttachmentDefinitions (namespace now exists) =="
oc apply -f "${NET_DIR}/04-network-attachment-definitions.yaml"

echo "== Installing MetalLB =="
oc apply -f "${NET_DIR}/05-metallb-sub.yaml"
wait_and_approve metallb-system metallb-operator
sleep 10
oc apply -f - <<'EOF' 2>/dev/null || true
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF
sleep 15
oc apply -f "${NET_DIR}/06-metallb-ipaddresspool.yaml"
oc get ipaddresspool -n metallb-system
