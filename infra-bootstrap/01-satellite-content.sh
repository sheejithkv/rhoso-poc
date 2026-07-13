#!/usr/bin/env bash
# WHAT: Uploads the subscription manifest, enables + syncs the RPM repos the RHEL 9.4 EDPM
#       (Compute) node needs, and produces a Lifecycle Environment + Content View + Activation
#       Key. The activation key name printed at the end goes into
#       manifests/05-data-plane/00-subscription-manager-secrets.sh.
# WHAT: repo list matches manifests/05-data-plane/02-nodeset-compute.yaml's rhc_repositories
#       block exactly - keep the two in sync if you add/remove a repo here.
# VERIFY: hammer activation-key info --name "${AK_NAME}" --organization "${ORG}"
# ROLLBACK: hammer activation-key delete --name "${AK_NAME}" --organization "${ORG}"
#           hammer content-view delete --name "${CV_NAME}" --organization "${ORG}"
set -euo pipefail

ORG="CHANGE_ME_Org"
MANIFEST_ZIP="CHANGE_ME/manifest_rhoso-poc.zip"   # downloaded from console.redhat.com > Subscriptions > Manifests
LCE_NAME="RHOSO-POC"
CV_NAME="rhoso-poc-cv"
AK_NAME="rhoso-poc-edpm-key"

echo "== [1/6] Creating organization (skip if it already exists) =="
hammer organization create --name "${ORG}" --label "${ORG}" 2>/dev/null || true

echo "== [2/6] Uploading subscription manifest =="
hammer subscription upload --organization "${ORG}" --file "${MANIFEST_ZIP}"

echo "== [3/6] Enabling RPM repos for RHEL 9.4 EDPM + RHOSO 18.0 =="
# This list mirrors the RHOSO 18.0 documented repo set for data-plane nodes:
#   rhel-9-for-x86_64-baseos-eus-rpms, rhel-9-for-x86_64-appstream-eus-rpms,
#   rhel-9-for-x86_64-highavailability-eus-rpms, fast-datapath-for-rhel-9-x86_64-rpms,
#   rhoso-18.0-for-rhel-9-x86_64-rpms, rhceph-7-tools-for-rhel-9-x86_64-rpms
for REPO in \
  "rhel-9-for-x86_64-baseos-eus-rpms:9.4" \
  "rhel-9-for-x86_64-appstream-eus-rpms:9.4" \
  "rhel-9-for-x86_64-highavailability-eus-rpms:9.4" \
  "fast-datapath-for-rhel-9-x86_64-rpms:" \
  "rhoso-18.0-for-rhel-9-x86_64-rpms:" \
  "rhceph-7-tools-for-rhel-9-x86_64-rpms:" ; do
  NAME="${REPO%%:*}"
  VER="${REPO##*:}"
  if [ -n "$VER" ]; then
    hammer repository-set enable --organization "${ORG}" --product "Red Hat Enterprise Linux for x86_64" \
      --name "${NAME}" --releasever "${VER}" --basearch x86_64
  else
    hammer repository-set enable --organization "${ORG}" --product "Red Hat Enterprise Linux for x86_64" \
      --name "${NAME}" --basearch x86_64
  fi
done

echo "== [4/6] Syncing repos (this can take a long time on first sync) =="
hammer product synchronize --organization "${ORG}" --name "Red Hat Enterprise Linux for x86_64" --async
echo "-> tail progress with: hammer task list --search 'Synchronize'"

echo "== [5/6] Lifecycle Environment + Content View (publish, then promote) =="
hammer lifecycle-environment create --organization "${ORG}" --name "${LCE_NAME}" --prior Library
hammer content-view create --organization "${ORG}" --name "${CV_NAME}"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "rhel-9-for-x86_64-baseos-eus-rpms"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "rhel-9-for-x86_64-appstream-eus-rpms"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "rhel-9-for-x86_64-highavailability-eus-rpms"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "fast-datapath-for-rhel-9-x86_64-rpms"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "rhoso-18.0-for-rhel-9-x86_64-rpms"
hammer content-view add-repository --organization "${ORG}" --name "${CV_NAME}" \
  --product "Red Hat Enterprise Linux for x86_64" --repository "rhceph-7-tools-for-rhel-9-x86_64-rpms"
hammer content-view publish --organization "${ORG}" --name "${CV_NAME}"
hammer content-view version promote --organization "${ORG}" --content-view "${CV_NAME}" \
  --to-lifecycle-environment "${LCE_NAME}"

echo "== [6/6] Activation key =="
hammer activation-key create --organization "${ORG}" --name "${AK_NAME}" \
  --lifecycle-environment "${LCE_NAME}" --content-view "${CV_NAME}" --unlimited-hosts
hammer activation-key update --organization "${ORG}" --name "${AK_NAME}" --auto-attach false
# Repos default to disabled on the client until overridden per activation key:
for LABEL in \
  rhel-9-for-x86_64-baseos-eus-rpms rhel-9-for-x86_64-appstream-eus-rpms \
  rhel-9-for-x86_64-highavailability-eus-rpms fast-datapath-for-rhel-9-x86_64-rpms \
  rhoso-18.0-for-rhel-9-x86_64-rpms rhceph-7-tools-for-rhel-9-x86_64-rpms ; do
  hammer activation-key content-override --organization "${ORG}" --name "${AK_NAME}" \
    --content-label "${LABEL}" --value 1 || true
done

echo "Activation key ready: ${AK_NAME} (org: ${ORG})"
echo "Use this in manifests/05-data-plane/00-subscription-manager-secrets.sh"
