#!/usr/bin/env bash
# WHAT: Phase 1 - ODF operator in EXTERNAL mode, connected to the Ceph cluster bootstrapped by
#       infra-bootstrap/04-ceph-cluster-bootstrap.sh. This REPLACES the original internal-mode
#       flow (worker-node disk labeling + a 3-node in-cluster Ceph build) - see
#       manifests/01-storage-odf/01-namespace-og-sub.yaml's header comment for why internal mode
#       is unsupported for RHOSO 18.0.
# MANUAL STEP IN THE MIDDLE: 02-fetch-and-run-exporter.sh cannot be fully scripted end-to-end
# (it needs to run partly on the Ceph side, see that script's header) - this wrapper stops and
# tells you exactly what to do before continuing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

STORAGE_DIR="${REPO_ROOT}/manifests/01-storage-odf"

echo "== Installing ODF operator =="
oc apply -f "${STORAGE_DIR}/01-namespace-og-sub.yaml"
wait_and_approve openshift-storage odf-operator

echo "== Fetching the external-cluster exporter script =="
(cd "${STORAGE_DIR}" && bash ./02-fetch-and-run-exporter.sh)

if ! oc get secret rook-ceph-external-cluster-details -n openshift-storage >/dev/null 2>&1; then
  cat <<'EOF'

STOPPING HERE - manual step required.
Follow the instructions just printed above (run the exporter script against your Ceph cluster,
create the rook-ceph-external-cluster-details secret), then re-run this script - it will pick up
from the StorageCluster apply below once that secret exists.
EOF
  exit 1
fi

echo "== Applying external StorageCluster =="
oc apply -f "${STORAGE_DIR}/03-storagecluster-external.yaml"

echo "-> waiting for StorageCluster to become Ready (external mode is usually faster than internal - a few minutes)..."
until [ "$(oc get storagecluster ocs-external-storagecluster -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" = "Ready" ]; do
  echo "  ...still Progressing"; sleep 20
done
oc get storageclass | grep ocs-external
oc get cephcluster -n openshift-storage
