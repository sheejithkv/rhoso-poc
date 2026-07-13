#!/usr/bin/env bash
# Orchestrates the full deployment, or tears it all down with --teardown.
# NOTE: infra-bootstrap/ (Satellite + mirror registry + Ceph cluster) is intentionally NOT
# orchestrated here - it is one-time, per-environment infrastructure that predates any of this
# and that a teardown of the OpenShift/RHOSO layer should not touch. See infra-bootstrap/README.md.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ "${1:-}" = "--teardown" ]; then
  echo "== Tearing down (reverse order) =="
  echo "-- data plane --"
  oc delete -f manifests/05-data-plane/03-dataplane-deployment.yaml --ignore-not-found
  oc delete -f manifests/05-data-plane/02-nodeset-compute.yaml --ignore-not-found
  oc delete secret dataplane-ansible-ssh-private-key-secret subscription-manager redhat-registry -n openstack --ignore-not-found

  echo "-- control plane --"
  oc delete -f manifests/04-control-plane/04-openstackcontrolplane.yaml --ignore-not-found
  oc delete secret osp-secret ceph-conf-files -n openstack --ignore-not-found

  echo "-- openstack-operator (was Manual approval - delete any pending InstallPlan too) --"
  oc delete -f manifests/03-openstack-operator/03-subscription.yaml --ignore-not-found
  oc delete installplan --all -n openstack-operators --ignore-not-found
  oc delete -f manifests/03-openstack-operator/02-operatorgroup.yaml --ignore-not-found
  oc delete -f manifests/03-openstack-operator/01-namespace.yaml --ignore-not-found

  echo "-- networking (was previously left mostly in place - now fully reversed) --"
  oc delete -f manifests/02-networking/06-metallb-ipaddresspool.yaml --ignore-not-found
  oc delete -f manifests/02-networking/05-metallb-sub.yaml --ignore-not-found
  oc delete metallb metallb -n metallb-system --ignore-not-found
  oc delete -f manifests/02-networking/04-network-attachment-definitions.yaml --ignore-not-found
  oc delete nncp -l app=rhoso-poc-worker-vlans --ignore-not-found
  oc delete -f manifests/02-networking/02-netconfig.yaml --ignore-not-found
  oc delete -f manifests/02-networking/01-nmstate-sub.yaml --ignore-not-found
  oc delete nmstate nmstate --ignore-not-found
  oc delete -f manifests/02-networking/00-openstack-namespace.yaml --ignore-not-found

  echo "-- storage (ODF external mode) --"
  oc delete -f manifests/01-storage-odf/03-storagecluster-external.yaml --ignore-not-found
  oc delete secret rook-ceph-external-cluster-details -n openshift-storage --ignore-not-found
  oc delete -f manifests/01-storage-odf/01-namespace-og-sub.yaml --ignore-not-found

  echo "-- cert-manager (was previously never installed, so also never torn down) --"
  oc delete -f manifests/00-prereqs/00-cert-manager-operator.yaml --ignore-not-found

  echo "-- prereqs --"
  oc delete -f manifests/00-prereqs/03-catalogsource-disconnected.yaml --ignore-not-found
  oc delete -f manifests/00-prereqs/02-itms.yaml --ignore-not-found
  oc delete -f manifests/00-prereqs/01-idms.yaml --ignore-not-found

  echo "Teardown submitted."
  echo "NOT torn down by this script (intentionally):"
  echo "  - Terraform-provisioned OCP nodes themselves: run 'terraform destroy' in terraform/ if needed."
  echo "  - infra-bootstrap/ (Satellite, mirror registry, external Ceph cluster): these are shared,"
  echo "    persistent, per-environment infrastructure - tear down manually per infra-bootstrap/README.md"
  echo "    only if you actually want to decommission them, not just this one cluster."
  echo "  - The cluster-wide pull-secret patch from 00-prereqs-check.sh (not reversible cleanly - it's"
  echo "    a merge, not a separate object; leaving mirror auth in place is harmless)."
  exit 0
fi

echo "== Stage 0: prereqs / disconnected registry / cert-manager =="
bash scripts/00-prereqs-check.sh
echo "== Stage 1: storage (ODF external mode) =="
bash scripts/01-deploy-storage.sh
echo "== Stage 2: networking (NMState/NetConfig/NNCP/NAD/MetalLB) =="
bash scripts/02-deploy-networking.sh
echo "== Stage 3: openstack-operator =="
bash scripts/03-deploy-openstack-operator.sh
echo "== Stage 4: control plane =="
bash scripts/04-deploy-control-plane.sh
echo "== Stage 5: data plane =="
bash scripts/05-deploy-data-plane.sh
echo "== Stage 6: provider network =="
bash scripts/06-create-provider-network.sh
echo "== Stage 7: smoke test =="
bash scripts/07-smoke-test.sh
echo "== DONE =="
