#!/usr/bin/env bash
# WHAT: Installs Red Hat Satellite 6 on a dedicated RHEL 9 host. Satellite is the RPM content
#       source for the RHEL 9.4 Compute (EDPM) node(s) in a disconnected/sovereign environment -
#       this is what manifests/05-data-plane/02-nodeset-compute.yaml registers against instead
#       of registry.redhat.io / subscription.rhsm.redhat.com.
# WHAT THIS DOES NOT DO: this host still needs ONE of the following to get content in:
#   (a) direct internet access during this bootstrap only (simplest, then air-gap it), or
#   (b) an inter-satellite-sync / disconnected manifest workflow (see Red Hat docs for your
#       specific air-gap policy - that workflow is organization-specific and not scripted here).
# PREREQS (manual, one-time, per Red Hat account):
#   1. A RHEL 9 host/VM sized per Red Hat sizing guide (POC minimum: 4 vCPU / 32GB RAM / 300GB disk).
#   2. A subscription manifest downloaded from https://console.redhat.com/insights/connector/activation-keys
#      (Subscriptions > Manifests) as a .zip - the path goes in 01-satellite-content.sh, not here.
#   3. DNS: this host's FQDN must resolve (forward AND reverse) before satellite-installer runs.
# VERIFY: hammer ping   (all services should report "ok")
#         systemctl status satellite --no-pager | grep -i active
# ROLLBACK: satellite-maintain packages install ...  # see docs; full uninstall is not scripted
#           here on purpose - Satellite removal is destructive and organization-specific.
set -euo pipefail

SATELLITE_FQDN="__SATELLITE_FQDN__"   # must match forward+reverse DNS
SATELLITE_ORG="__ORG_NAME__"
# Never hardcoded, even by scripts/configure.py: export SATELLITE_ADMIN_PASSWORD before running
# this script, or source .rhoso-poc-secrets.env (written by scripts/configure.py, gitignored).
SATELLITE_ADMIN_PASSWORD="${SATELLITE_ADMIN_PASSWORD:-CHANGE_ME}"

echo "== [1/4] Registering this host and enabling the Satellite 6.16 repos =="
# CHANGE_ME: if this host is itself air-gapped, mirror these repos in first (reposync from a
# connected staging host) and point subscription-manager/dnf at that local mirror instead.
subscription-manager register --org="${SATELLITE_ORG}"   # prompts for activation key or user/pass
subscription-manager release --set=9.4
subscription-manager repos --disable "*"
subscription-manager repos \
  --enable=satellite-6.16-for-rhel-9-x86_64-rpms \
  --enable=satellite-maintenance-6.16-for-rhel-9-x86_64-rpms \
  --enable=rhel-9-for-x86_64-baseos-rpms \
  --enable=rhel-9-for-x86_64-appstream-rpms

echo "== [2/4] Installing Satellite packages =="
dnf module enable -y satellite:el9
dnf install -y satellite

echo "== [3/4] Setting hostname (must match forward+reverse DNS) =="
hostnamectl set-hostname "${SATELLITE_FQDN}"

echo "== [4/4] Running satellite-installer (POC-sized, self-signed cert) =="
# For a real deployment add: --certs-server-cert / --certs-server-key / --certs-server-ca-cert
# pointing at a proper CA, and tune --foreman-proxy-content-* for your storage layout.
satellite-installer --scenario satellite \
  --foreman-initial-organization "${SATELLITE_ORG}" \
  --foreman-initial-admin-username admin \
  --foreman-initial-admin-password "${SATELLITE_ADMIN_PASSWORD}" \
  --foreman-proxy-dns false \
  --foreman-proxy-dhcp false \
  --foreman-proxy-tftp false

echo "Satellite installed. Log in at https://${SATELLITE_FQDN} (admin / \$SATELLITE_ADMIN_PASSWORD)."
echo "Next: bash 01-satellite-content.sh"
