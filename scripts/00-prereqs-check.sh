#!/usr/bin/env bash
# WHAT: Phase 0 - disconnected registry prereqs + cert-manager (hard RHOSO 18.0 prerequisite,
#       TLS-e is on by default). Assumes infra-bootstrap/ has already been run.
# CHANGED FROM ORIGINAL: now applies 00-cert-manager-operator.yaml and 02-itms.yaml (both were
# missing), and actually calls 04-pull-secret-patch.sh (previously it existed but nothing invoked
# it - image pulls from the mirror would have failed on every node with no mirror auth present).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

echo "== Checking cluster reachability =="
oc whoami
oc get clusterversion

echo "== Applying disconnected registry prereqs (IDMS + ITMS + CatalogSource) =="
oc apply -f "${REPO_ROOT}/manifests/00-prereqs/01-idms.yaml"
oc apply -f "${REPO_ROOT}/manifests/00-prereqs/02-itms.yaml"
oc apply -f "${REPO_ROOT}/manifests/00-prereqs/03-catalogsource-disconnected.yaml"

echo "-> waiting for MachineConfigPools to finish rolling (can take 5-15 min)..."
oc wait mcp --all --for=condition=Updated=True --timeout=20m

echo "-> verify catalog pod is Running:"
oc get pods -n openshift-marketplace | grep rhoso-mirror-catalog

echo "== Patching cluster pull secret with mirror auth =="
bash "${REPO_ROOT}/manifests/00-prereqs/04-pull-secret-patch.sh"

echo "== Installing cert-manager operator (hard prerequisite - RHOSO 18.0 TLS-e is on by default) =="
oc apply -f "${REPO_ROOT}/manifests/00-prereqs/00-cert-manager-operator.yaml"
wait_and_approve cert-manager-operator cert-manager-operator
oc wait --for=condition=Available deployment -n cert-manager --all --timeout=5m || \
  echo "WARNING: cert-manager operand pods not Available yet - check 'oc get pods -n cert-manager'" >&2

echo "== Prereqs done =="
