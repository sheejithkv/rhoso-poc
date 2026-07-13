#!/usr/bin/env bash
# WHAT: Merges your registry.redhat.io + internal mirror auth into the cluster-wide pull secret.
#       Without this, kubelet on every node can authenticate to registry.redhat.io fine but has
#       no credentials for __MIRROR_REGISTRY_HOST__, so any image the IDMS/ITMS redirect
#       there (i.e. everything, in a disconnected install) fails to pull with ImagePullBackOff.
# WHAT CHANGED: this script existed before but nothing ever called it - see scripts/00-prereqs-check.sh,
#       which now runs it right after applying the IDMS/ITMS/CatalogSource.
# VERIFY: oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq '.auths | keys'
set -euo pipefail
MIRROR_AUTH_FILE="${MIRROR_AUTH_FILE:-__MIRROR_AUTH_FILE_PATH__}"

if [ ! -f "${MIRROR_AUTH_FILE}" ]; then
  echo "ERROR: ${MIRROR_AUTH_FILE} not found." >&2
  echo "  Generate it with: podman login -u init -p <password> <registry-host>:8443 --authfile mirror-auth.json" >&2
  echo "  (credentials printed by infra-bootstrap/02-mirror-registry-install.sh)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${WORKDIR}/pull-secret.json"
python3 - "${MIRROR_AUTH_FILE}" "${WORKDIR}/pull-secret.json" "${WORKDIR}/pull-secret-merged.json" << 'PYEOF'
import json, sys
mirror_auth_file, pull_secret_file, merged_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(pull_secret_file) as f:
    base = json.load(f)
with open(mirror_auth_file) as f:
    mirror = json.load(f)
base['auths'].update(mirror['auths'])
with open(merged_file, 'w') as f:
    json.dump(base, f)
PYEOF
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${WORKDIR}/pull-secret-merged.json"
echo "Pull secret patched with mirror auth from ${MIRROR_AUTH_FILE}."
