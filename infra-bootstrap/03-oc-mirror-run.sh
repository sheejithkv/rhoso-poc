#!/usr/bin/env bash
# WHAT: Runs oc-mirror v2 against imageset-config.yaml to populate the mirror registry, then
#       drops the generated ImageDigestMirrorSet/ImageTagMirrorSet/CatalogSource YAMLs into
#       ../manifests/00-prereqs/ so they get applied in the normal deploy-all.sh flow.
# WHY BOTH IDMS AND ITMS: oc-mirror v2 generates an ImageTagMirrorSet automatically whenever any
#       image in the set is referenced by tag rather than digest (this repo's
#       openstack-must-gather-rhel9:18.0 and rhceph-7-rhel9:latest additionalImages are tag
#       references) - IDMS alone would silently miss those pulls. See manifests/00-prereqs/02-itms.yaml.
# VERIFY: ls ./workspace/working-dir/cluster-resources/
#         oc apply -f ./workspace/working-dir/cluster-resources -o name  (dry look, don't actually
#           apply here - manifests/00-prereqs/ is the reviewed, checked-in copy)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="__MIRROR_REGISTRY_HOST__:8443/mirror"

echo "== oc-mirror v2: mirror to disk then disk to mirror =="
echo "-> requires internet access from THIS host; the target registry does not need it"
oc-mirror --v2 -c "${SCRIPT_DIR}/imageset-config.yaml" \
  --workspace "file://${SCRIPT_DIR}/workspace" \
  "docker://${REGISTRY}"

RESOURCES_DIR="${SCRIPT_DIR}/workspace/working-dir/cluster-resources"
echo "== Copying generated cluster resources for review =="
ls -la "${RESOURCES_DIR}"

cat <<EOF

oc-mirror finished. Generated resources are in:
  ${RESOURCES_DIR}

Manual step (intentional - review before committing):
  Compare ${RESOURCES_DIR}/idms-oc-mirror.yaml   against manifests/00-prereqs/01-idms.yaml
  Compare ${RESOURCES_DIR}/itms-oc-mirror.yaml   against manifests/00-prereqs/02-itms.yaml
  Compare ${RESOURCES_DIR}/catalogSource-*.yaml  against manifests/00-prereqs/03-catalogsource-disconnected.yaml
  and merge the actual digests oc-mirror resolved into those checked-in files, then:
    oc apply -f ${REPO_ROOT}/manifests/00-prereqs/signature-configmap.json   # if present, release signatures
EOF
