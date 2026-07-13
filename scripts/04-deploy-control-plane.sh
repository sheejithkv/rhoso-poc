#!/usr/bin/env bash
# WHAT: Phase 4 - osp-secret, the direct-Ceph-access secret, and the OpenStackControlPlane CR
#       itself (Keystone/Glance/Nova/Neutron/Cinder/Barbican/Telemetry/...).
# CHANGED: now also creates ceph-conf-files (needed by the external-Ceph Cinder/Glance/Nova
#       wiring in 04-openstackcontrolplane.yaml - see that file's header comment) before applying
#       the control plane CR, since the CR's extraMounts reference that secret by name and pods
#       would CrashLoop on a missing volume mount without it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CP_DIR="${REPO_ROOT}/manifests/04-control-plane"

bash "${CP_DIR}/01-osp-secret-gen.sh"
oc apply -f "${CP_DIR}/02-osp-secret.yaml"
bash "${CP_DIR}/03-ceph-conf-secret.sh"
oc apply -f "${CP_DIR}/04-openstackcontrolplane.yaml"
echo "-> waiting for OpenStackControlPlane to reach Ready (15-30 min)..."
until [ "$(oc get openstackcontrolplane openstack-control-plane -n openstack -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; do
  echo "  ...still deploying"; oc get pods -n openstack | tail -5; sleep 30
done
oc get openstackcontrolplane -n openstack
