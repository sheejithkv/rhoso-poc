#!/usr/bin/env bash
# WHAT: Pulls the ceph-external-cluster-details-exporter.py script that matches the installed
#       ODF version, so it can be run against the external Ceph cluster
#       (infra-bootstrap/04-ceph-cluster-bootstrap.sh) to generate the connection JSON that
#       02-storagecluster-external.yaml's rook-ceph-external-cluster-details secret needs.
# WHY THIS IS SEMI-MANUAL: the script must run ON the Ceph side (it shells out to the local
#       `ceph` CLI), while the CSV/ConfigMap it's fetched from only exists on the OpenShift
#       side, once the ODF operator install (01-namespace-og-sub.yaml) has finished. There is no
#       single host with both `oc` and Ceph admin access by default, so this script fetches the
#       exporter and prints the copy/run/copy-back steps rather than assuming SSH connectivity
#       between the two that may not exist in your environment.
# VERIFY: oc get secret rook-ceph-external-cluster-details -n openshift-storage
# ROLLBACK: oc delete secret rook-ceph-external-cluster-details -n openshift-storage
set -euo pipefail

CEPH_ADMIN_HOST="__CEPH_MON_IP__"   # the host infra-bootstrap/04-ceph-cluster-bootstrap.sh ran on
RBD_POOL="volumes"            # matches the pool infra-bootstrap/04-ceph-cluster-bootstrap.sh creates
RGW_ENDPOINT=""                # CHANGE_ME - leave empty if not using RGW/Swift-alternative

echo "== [1/3] Fetching the exporter script matching your installed ODF CSV =="
CSV=$(oc get csv -n openshift-storage -o name | grep rook-ceph-operator || true)
if [ -z "${CSV}" ]; then
  echo "ERROR: no rook-ceph-operator CSV found in openshift-storage yet." >&2
  echo "  Wait for 'oc get csv -n openshift-storage' to show odf-operator/ocs-operator Succeeded first." >&2
  exit 1
fi
# ODF >= 4.19: script lives in a ConfigMap. ODF < 4.19: annotation on the CSV. Try both.
if oc get cm rook-ceph-external-cluster-script-config -n openshift-storage >/dev/null 2>&1; then
  oc get cm rook-ceph-external-cluster-script-config -n openshift-storage \
    -o jsonpath='{.data.script}' | base64 --decode > ./ceph-external-cluster-details-exporter.py
else
  oc get "${CSV}" -n openshift-storage \
    -o jsonpath='{.metadata.annotations.externalClusterScript}' | base64 --decode > ./ceph-external-cluster-details-exporter.py
fi
echo "-> wrote ./ceph-external-cluster-details-exporter.py"

cat <<EOF

== [2/3] Manual step - run this ON the Ceph admin host (${CEPH_ADMIN_HOST}) ==
  scp ./ceph-external-cluster-details-exporter.py ${CEPH_ADMIN_HOST}:~/
  ssh ${CEPH_ADMIN_HOST} 'python3 ~/ceph-external-cluster-details-exporter.py \\
      --rbd-data-pool-name ${RBD_POOL} \\
      --namespace openshift-storage \\
      --run-as-user client.openshift-storage \\
      ${RGW_ENDPOINT:+--rgw-endpoint ${RGW_ENDPOINT}} \\
      > external-cluster-details.json'
  scp ${CEPH_ADMIN_HOST}:~/external-cluster-details.json .

== [3/3] Once external-cluster-details.json is back on this host, run: ==
  oc create secret generic rook-ceph-external-cluster-details \\
    --from-file=external_cluster_details=./external-cluster-details.json \\
    -n openshift-storage
  oc apply -f 02-storagecluster-external.yaml
EOF
