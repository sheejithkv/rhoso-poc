#!/usr/bin/env bash
# WHAT: Creates the Neutron "public" provider network that 07-smoke-test.sh's floating IP and
#       router commands assume already exists. THIS WAS ENTIRELY MISSING from the original repo -
#       the smoke test referenced a `public` network in `openstack router set --external-gateway
#       public` and `openstack floating ip create public`, but nothing anywhere created it.
# HOW THIS MAPS TO THE UNDERLYING BRIDGE: `--provider-physical-network datacentre` matches the
#       `edpm_ovn_bridge_mappings: ["datacentre:br-ex"]` set on the Compute node in
#       manifests/05-data-plane/02-nodeset-compute.yaml, and `--provider-segment 30` matches that
#       same file's br-ex/bond0.30 VLAN. If you change one, change all three.
# WHAT THIS DOES NOT GIVE YOU: without a real upstream router/uplink physically connected to
#       that VLAN, floating IPs are allocated and attach/detach correctly (enough to demonstrate
#       and test the control-plane path end-to-end) but will not reach the public internet - see
#       docs/troubleshooting.md #7.
# VERIFY: oc rsh -n openstack openstackclient openstack network show public
# ROLLBACK: oc rsh -n openstack openstackclient openstack router delete poc-router
#           oc rsh -n openstack openstackclient openstack network delete public
set -euo pipefail

PHYSNET="datacentre"      # CHANGE_ME - must match edpm_ovn_bridge_mappings in 02-nodeset-compute.yaml
SEGMENT="30"                # CHANGE_ME - must match the VLAN id used for bond0.30/br-ex there
SUBNET_CIDR="10.20.20.0/24" # CHANGE_ME - matches manifests/02-networking/02-netconfig.yaml's "external" note
ALLOCATION_START="10.20.20.100"
ALLOCATION_END="10.20.20.200"
GATEWAY="10.20.20.1"        # CHANGE_ME - your real upstream router IP if you have one, else leave
                             # as a placeholder (floating IPs stay local to this VLAN - see header)

oc rsh -n openstack openstackclient openstack network create public \
  --external \
  --provider-network-type vlan \
  --provider-physical-network "${PHYSNET}" \
  --provider-segment "${SEGMENT}"

oc rsh -n openstack openstackclient openstack subnet create public-subnet \
  --network public \
  --subnet-range "${SUBNET_CIDR}" \
  --allocation-pool "start=${ALLOCATION_START},end=${ALLOCATION_END}" \
  --gateway "${GATEWAY}" \
  --no-dhcp

echo "Provider network 'public' ready. Next: bash 07-smoke-test.sh"
