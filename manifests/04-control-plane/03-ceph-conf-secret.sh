#!/usr/bin/env bash
# WHAT: Creates the `ceph-conf-files` Secret that Cinder/Glance/Nova mount directly (via
#       extraMounts in 04-openstackcontrolplane.yaml) to talk to the external Ceph cluster's RBD
#       pools for volumes/images/ephemeral disk. This is SEPARATE from ODF's own
#       rook-ceph-external-cluster-details secret (manifests/01-storage-odf/02-fetch-and-run-exporter.sh) -
#       that one only gets OpenShift-internal PVC StorageClasses working; this one is what makes
#       `rbd_user=openstack` in the Cinder customServiceConfig block actually resolve.
# PREREQ: infra-bootstrap/04-ceph-cluster-bootstrap.sh has run and produced
#         /etc/ceph/ceph.conf + /etc/ceph/ceph.client.openstack.keyring on the host you run this from
#         (copy them over first if this isn't the same host).
# VERIFY: oc get secret ceph-conf-files -n openstack
#         oc get secret ceph-conf-files -o json -n openstack | jq -r '.data."ceph.conf"' | base64 -d | grep fsid
# ROLLBACK: oc delete secret ceph-conf-files -n openstack
set -euo pipefail

CEPH_CONF="${CEPH_CONF:-/etc/ceph/ceph.conf}"
CEPH_KEYRING="${CEPH_KEYRING:-/etc/ceph/ceph.client.openstack.keyring}"

for f in "${CEPH_CONF}" "${CEPH_KEYRING}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: ${f} not found - run infra-bootstrap/04-ceph-cluster-bootstrap.sh first (or copy" >&2
    echo "  its output files here / set CEPH_CONF and CEPH_KEYRING to their actual location)." >&2
    exit 1
  fi
done

oc create secret generic ceph-conf-files \
  --namespace openstack \
  --from-file=ceph.conf="${CEPH_CONF}" \
  --from-file=ceph.client.openstack.keyring="${CEPH_KEYRING}" \
  --dry-run=client -o yaml | oc apply -f -

echo "ceph-conf-files secret ready. FSID:"
grep fsid "${CEPH_CONF}" || true
