#!/usr/bin/env bash
# WHAT: End-to-end functional test - source RC, create project/user/flavor/keypair/sec-group,
#       upload Cirros image, create network/subnet/router, boot a VM, attach floating IP, SSH in.
# PREREQ: 06-create-provider-network.sh has been run (the `public` network this test attaches
#       floating IPs from used to not exist anywhere in this repo - see that script's header).
set -euo pipefail

echo "== Get openstackclient pod and admin RC =="
OSP_POD=$(oc get pod -n openstack -l service=openstackclient -o jsonpath='{.items[0].metadata.name}')
oc exec -n openstack "$OSP_POD" -- bash -c "cat > /home/cloud-admin/smoke-test.sh" << 'INNER'
set -euo pipefail
source /home/cloud-admin/.config/openstack/clouds.yaml 2>/dev/null || true
export OS_CLOUD=default

echo "-- project/user/flavor/keypair/security group --"
openstack project create poc-project
openstack user create --project poc-project --password 'ChangeMe123!' poc-user   # CHANGE_ME password
openstack role add --project poc-project --user poc-user member
openstack flavor create --ram 512 --disk 1 --vcpus 1 m1.tiny.poc
openstack keypair create --public-key /home/cloud-admin/.ssh/id_rsa.pub poc-keypair   # CHANGE_ME path
openstack security group create poc-secgroup
openstack security group rule create --proto icmp poc-secgroup
openstack security group rule create --proto tcp --dst-port 22 poc-secgroup

echo "-- image upload (Cirros) --"
curl -L -o /tmp/cirros.qcow2 http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
openstack image create --disk-format qcow2 --container-format bare --file /tmp/cirros.qcow2 --public cirros

echo "-- network/subnet/router --"
openstack network create poc-net
openstack subnet create --network poc-net --subnet-range 192.168.100.0/24 poc-subnet
openstack router create poc-router
openstack router set --external-gateway public poc-router
openstack router add subnet poc-router poc-subnet

echo "-- boot VM --"
openstack server create --flavor m1.tiny.poc --image cirros --network poc-net \
  --key-name poc-keypair --security-group poc-secgroup poc-vm
openstack server show poc-vm

echo "-- wait for ACTIVE, then floating IP --"
for i in $(seq 1 30); do
  STATUS=$(openstack server show poc-vm -f value -c status)
  [ "$STATUS" = "ACTIVE" ] && break
  echo "  status=$STATUS, waiting..."; sleep 10
done
FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip poc-vm "$FIP"
echo "Floating IP: $FIP"

echo "-- SSH test (cirros default user 'cirros'/'gocubsgo') --"
sleep 20
ssh -o StrictHostKeyChecking=no -i /home/cloud-admin/.ssh/id_rsa cirros@"$FIP" 'echo SSH_OK'
INNER
oc exec -n openstack "$OSP_POD" -- bash /home/cloud-admin/smoke-test.sh
