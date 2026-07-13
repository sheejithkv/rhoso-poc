#!/usr/bin/env bash
# WHAT: Creates the two secrets manifests/05-data-plane/02-nodeset-compute.yaml's
#       ansibleVarsFrom references for RHEL subscription during the EDPM bootstrap Ansible run:
#       `subscription-manager` (activation-key credentials against Satellite) and
#       `redhat-registry` (container registry pull creds for any images Ansible needs to fetch
#       directly rather than via the mirror registry). This script existed nowhere before - RHEL
#       version pinning was previously missing from the whole repo (see 02-nodeset-compute.yaml's
#       header comment for the rest of that fix).
# VERIFY: oc get secret subscription-manager redhat-registry -n openstack
# ROLLBACK: oc delete secret subscription-manager redhat-registry -n openstack
set -euo pipefail
NAMESPACE=openstack

SATELLITE_ORG="CHANGE_ME_Org"                       # matches infra-bootstrap/01-satellite-content.sh
SATELLITE_ACTIVATION_KEY="rhoso-poc-edpm-key"        # matches infra-bootstrap/01-satellite-content.sh's AK_NAME
MIRROR_REGISTRY_USER="init"                          # matches infra-bootstrap/02-mirror-registry-install.sh
MIRROR_REGISTRY_PASSWORD="CHANGE_ME"                 # printed by that script's install output
MIRROR_REGISTRY_HOST="quay-mirror.CHANGE_ME.example.com:8443"

# rhc_auth expects an activation-key login, not a username/password, when registering against
# Satellite - subscription-manager on the EDPM node will use org + activationkey.
oc create secret generic subscription-manager \
  --namespace "${NAMESPACE}" \
  --from-literal=rhc_auth="{\"login\": {\"organization\": \"${SATELLITE_ORG}\", \"activation_keys\": [\"${SATELLITE_ACTIVATION_KEY}\"]}}" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic redhat-registry \
  --namespace "${NAMESPACE}" \
  --from-literal=edpm_container_registry_logins="{\"${MIRROR_REGISTRY_HOST}\": {\"${MIRROR_REGISTRY_USER}\": \"${MIRROR_REGISTRY_PASSWORD}\"}}" \
  --dry-run=client -o yaml | oc apply -f -

echo "subscription-manager + redhat-registry secrets ready in namespace ${NAMESPACE}."
