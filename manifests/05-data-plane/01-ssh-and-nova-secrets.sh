#!/usr/bin/env bash
# WHAT: Creates the SSH key secret the OpenStack Operator uses to run Ansible against the RHEL
#       Compute node (dataplane-ansible-ssh-private-key-secret). Nova/libvirt live-migration
#       trust between Compute nodes is set up separately by the `nova` edpm-ansible service
#       itself during the data-plane deployment, not by a secret created here.
# VERIFY: oc get secret dataplane-ansible-ssh-private-key-secret -n openstack
set -euo pipefail
NAMESPACE=openstack
ssh-keygen -t rsa -b 4096 -f /tmp/dataplane_ssh_key -N "" -C "rhoso-dataplane"   # CHANGE_ME path
oc create secret generic dataplane-ansible-ssh-private-key-secret \
  --namespace "$NAMESPACE" \
  --from-file=ssh-privatekey=/tmp/dataplane_ssh_key \
  --from-file=ssh-publickey=/tmp/dataplane_ssh_key.pub \
  --type=Opaque
echo "Add /tmp/dataplane_ssh_key.pub to authorized_keys on every RHEL Compute node (CHANGE_ME - your provisioning method, e.g. cloud-init/kickstart)."
