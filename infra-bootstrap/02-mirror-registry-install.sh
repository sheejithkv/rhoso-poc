#!/usr/bin/env bash
# WHAT: Installs "mirror registry for Red Hat OpenShift" - a small, self-contained Quay
#       instance whose only job is to hold the OCP release + operator-catalog + RHOSO images
#       for a disconnected install. This is the registry every quay-mirror.CHANGE_ME.example.com
#       reference in manifests/00-prereqs/ points at.
# WHAT THIS IS NOT: a production/HA registry. Red Hat explicitly scopes this tool to bootstrap
#       content only (local filesystem storage, single node). If you already run Quay/Artifactory/
#       Nexus/Harbor, skip this script and just point 03-oc-mirror-run.sh at that instead.
# PREREQS (manual, one-time):
#   1. Download mirror-registry.tar.gz from https://console.redhat.com/openshift/downloads
#      ("OpenShift disconnected installation tools") to the target RHEL 8/9 host.
#   2. RHEL 8/9 host with Podman >= 3.4.2, OpenSSL, and a resolvable FQDN.
# VERIFY: podman login -u init -p <password-from-install-output> <registry-host>:8443 --tls-verify=false
#         curl -sk https://<registry-host>:8443/health/instance
# ROLLBACK: ./mirror-registry uninstall -v --quayRoot <same --quayRoot value used at install>
set -euo pipefail

REGISTRY_HOSTNAME="quay-mirror.CHANGE_ME.example.com"
QUAY_ROOT="${HOME}/quay-install"

echo "== Extracting mirror-registry tool =="
tar xzf mirror-registry.tar.gz

echo "== Installing (local host, local storage under ${QUAY_ROOT}) =="
./mirror-registry install -v \
  --quayHostname "${REGISTRY_HOSTNAME}" \
  --quayRoot "${QUAY_ROOT}"

cat <<EOF

Install finished. Credentials were printed above (user "init" + generated password) - save them.

Next steps:
  1. podman login -u init -p <password> ${REGISTRY_HOSTNAME}:8443 --tls-verify=false
  2. Trust its CA cert cluster-wide later via install-config.yaml's additionalTrustBundle
     (terraform/templates/install-config.yaml.tmpl) - the cert lives at:
       ${QUAY_ROOT}/quay-rootCA/rootCA.pem
  3. bash 03-oc-mirror-run.sh to actually populate it with OCP + RHOSO images.
EOF
