#!/usr/bin/env bash
# WHAT: Shared helpers, sourced by every script in this repo via:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"   # (or ../lib/common.sh from manifests/*/)
# This is what replaces every hardcoded /home/claude/rhoso-poc/... path in the original repo -
# every script now finds the repo root relative to its own location, so the repo works from any
# checkout path, for any user.

# repo_root: prints the absolute path to the repository root, given the path of the script that
# sourced this file (pass "${SCRIPT_DIR}" from a script one level under repo root, e.g.
# scripts/, or two levels for manifests/*/).
repo_root() {
  local dir="$1"
  (cd "${dir}" && git rev-parse --show-toplevel 2>/dev/null) || (cd "${dir}/.." && pwd)
}

# wait_for_csv <namespace> <package-name-substring>
# Polls until a CSV matching the substring reaches Succeeded, or times out after ~10 minutes.
wait_for_csv() {
  local ns="$1" pkg="$2" i=0
  echo "-> waiting for CSV matching '${pkg}' in ${ns} to reach Succeeded..."
  while [ "${i}" -lt 60 ]; do
    if oc get csv -n "${ns}" 2>/dev/null | grep -i "${pkg}" | grep -q Succeeded; then
      echo "-> ${pkg} Succeeded"
      return 0
    fi
    sleep 10
    i=$((i + 1))
  done
  echo "WARNING: ${pkg} did not reach Succeeded in ${ns} after 10m - continuing anyway, check manually:" >&2
  echo "  oc get csv -n ${ns}; oc get installplan -n ${ns}" >&2
  return 0
}

# approve_installplan <namespace>
# Every Subscription in this repo uses installPlanApproval: Manual (see docs/troubleshooting.md
# #11 for why) - this finds the newest InstallPlan in a namespace and approves it. Safe to call
# repeatedly; a no-op if there's nothing pending.
approve_installplan() {
  local ns="$1" ip
  ip=$(oc get installplan -n "${ns}" -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null | awk '{print $1}')
  if [ -n "${ip}" ]; then
    echo "-> approving InstallPlan ${ip} in ${ns}"
    oc patch installplan "${ip}" -n "${ns}" --type merge -p '{"spec":{"approved":true}}'
    sleep 5
  fi
}

# wait_and_approve <namespace> <package-name-substring>
# Polls for an InstallPlan to appear (Manual approval means it can take a few seconds after the
# Subscription is created), approves it, then waits for the CSV.
wait_and_approve() {
  local ns="$1" pkg="$2" i=0
  echo "-> waiting for an InstallPlan to appear in ${ns}..."
  while [ "${i}" -lt 18 ]; do
    if [ -n "$(oc get installplan -n "${ns}" -o name 2>/dev/null)" ]; then
      break
    fi
    sleep 5
    i=$((i + 1))
  done
  approve_installplan "${ns}"
  wait_for_csv "${ns}" "${pkg}"
}
