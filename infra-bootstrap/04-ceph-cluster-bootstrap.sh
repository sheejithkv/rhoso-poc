#!/usr/bin/env bash
# WHAT: Bootstraps a minimal external Red Hat Ceph Storage cluster via cephadm. This is the
#       storage backend ODF connects to in EXTERNAL mode (manifests/01-storage-odf/) and that
#       Cinder/Glance/Nova talk to directly (manifests/04-control-plane/03-ceph-conf-secret.sh).
#
# WHY THIS EXISTS: RHOSO 18.0 does not support ODF *internal* mode (Ceph running as pods inside
#       the OpenShift cluster consuming worker local disks) - see docs/troubleshooting.md #10.
#       A real external Ceph cluster (or ODF in external mode pointed at one) is mandatory.
#       This script gives you the smallest cluster that satisfies that requirement so the POC is
#       self-contained; for anything beyond a POC, follow the Red Hat Ceph Storage Hardware Guide
#       instead of this script (POC here = 1 node is allowed, real deployments need 3+ mon/osd
#       hosts for quorum and data redundancy).
#
# PREREQS: one or more RHEL 9 hosts with at least one free, unpartitioned block device each
#          (cephadm/OSD needs a raw disk, not a filesystem path). CHANGE_ME below.
# VERIFY: cephadm shell -- ceph -s        (HEALTH_OK, expected mon/osd count)
# ROLLBACK: cephadm rm-cluster --fsid $(cephadm shell -- ceph fsid) --force
set -euo pipefail

MON_IP="__CEPH_MON_IP__"                 # this host's IP on the storage network
CLUSTER_HOSTS=("__CEPH_CLUSTER_HOSTS__")  # additional hosts to add via `ceph orch host add`; POC can be just this one
DATA_DEVICE="__CEPH_DATA_DEVICE__"            # e.g. /dev/sdb - must be a raw, unused block device
# Never hardcoded, even by scripts/configure.py: export CEPH_DASHBOARD_PASSWORD before running
# this script, or source .rhoso-poc-secrets.env (written by scripts/configure.py, gitignored).
CEPH_DASHBOARD_PASSWORD="${CEPH_DASHBOARD_PASSWORD:-CHANGE_ME}"

echo "== [1/5] Installing cephadm =="
dnf install -y cephadm

echo "== [2/5] Bootstrapping the cluster (mon+mgr on this host) =="
cephadm bootstrap --mon-ip "${MON_IP}" --initial-dashboard-password "${CEPH_DASHBOARD_PASSWORD}" --dashboard-password-noupdate

echo "== [3/5] Adding OSD(s) =="
cephadm shell -- ceph orch apply osd --all-available-devices || \
  cephadm shell -- ceph orch daemon add osd "$(hostname -s):${DATA_DEVICE}"

echo "== [4/5] Creating pools for RHOSO (vms/nova, volumes/cinder, images/glance) =="
# RHOSO docs: for P in vms volumes images; do ceph osd pool create $P; ceph osd pool application enable $P rbd; done
for P in vms volumes images backups; do
  cephadm shell -- ceph osd pool create "${P}" 2>/dev/null || true
  cephadm shell -- ceph osd pool application enable "${P}" rbd 2>/dev/null || true
done

echo "== [5/5] Creating the openstack client keyring RHOSO services will use directly =="
# This is separate from ODF's own client.healthchecker/csi-* users created by the exporter
# script in manifests/01-storage-odf/02-fetch-and-run-exporter.sh - this one is for Cinder/
# Glance/Nova's direct RBD access (customServiceConfig rbd_user=openstack in
# manifests/04-control-plane/04-openstackcontrolplane.yaml).
cephadm shell -- ceph auth get-or-create client.openstack \
  mon 'profile rbd' \
  osd 'profile rbd pool=vms, profile rbd pool=volumes, profile rbd pool=images, profile rbd pool=backups' \
  mgr 'allow rw' \
  -o /etc/ceph/ceph.client.openstack.keyring

cephadm shell -- ceph fsid | tee /etc/ceph/fsid.txt

cat <<EOF

Ceph cluster bootstrapped. Files needed downstream (copy these to wherever you run
manifests/04-control-plane/03-ceph-conf-secret.sh from):
  /etc/ceph/ceph.conf
  /etc/ceph/ceph.client.openstack.keyring
  /etc/ceph/fsid.txt

Next:
  1. bash manifests/01-storage-odf/02-fetch-and-run-exporter.sh   (needs ODF operator installed first)
  2. bash manifests/04-control-plane/03-ceph-conf-secret.sh
EOF
