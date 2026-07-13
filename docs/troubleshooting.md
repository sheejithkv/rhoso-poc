# RHOSO POC Troubleshooting

Format: symptom → diagnostic commands → likely fix.

## 1. Operator not installing (openstack-operator, ODF, NMState, MetalLB)

```bash
oc get csv -A | grep -v Succeeded
oc get installplan -n <namespace>
oc describe installplan <name> -n <namespace>
oc get subscription <name> -n <namespace> -o yaml | grep -A5 conditions
oc get catalogsource -n openshift-marketplace
oc get pods -n openshift-marketplace
oc logs -n openshift-marketplace <catalog-source-pod>
```
**Common causes:** wrong `channel` name in Subscription; disconnected `CatalogSource` image
not reachable from the mirror (check IDMS/ITMS applied and MCP rolled out); pull secret missing
mirror auth (`04-pull-secret-patch.sh` not run - see section 11 below if the Subscription itself
is stuck `Pending` rather than failing to pull images).

## 2. Pods stuck Pending

```bash
oc get pods -n <namespace> -o wide | grep Pending
oc describe pod <pod> -n <namespace>   # check Events at bottom
oc get events -n <namespace> --sort-by='.lastTimestamp' | tail -30
oc describe node <node>   # check Allocatable vs Capacity, taints
```
**Common causes:** insufficient CPU/RAM on workers (RHOSO control plane pods are
resource-heavy — recheck `worker_node_spec` sizing); PVC stuck (see storage section below);
a node taint the pod doesn't tolerate; `NetworkAttachmentDefinition` referenced doesn't exist
yet (pod scheduling can succeed but container creation fails with a Multus error instead — check
`oc describe pod` for `AddOnPod` / CNI errors).

## 3. StorageClass / PVC issues

```bash
oc get storageclass
oc get pvc -A | grep -v Bound
oc describe pvc <pvc> -n <namespace>
oc get storagecluster -n openshift-storage -o yaml
oc get cephcluster -n openshift-storage
oc get pods -n openshift-storage | grep -v Running
oc logs -n openshift-storage deploy/rook-ceph-operator
```
**Common causes:** ODF `StorageCluster` still `Progressing` while it connects to the external
Ceph cluster (usually faster than internal-mode's OSD prep, but still a few minutes); the
`rook-ceph-external-cluster-details` secret is stale/wrong (re-run
`manifests/01-storage-odf/02-fetch-and-run-exporter.sh` if the external Ceph cluster's mon IPs or
keys changed); wrong `storageClassName` referenced in `OpenStackControlPlane` (must exactly
match `oc get storageclass` output - external mode, `ocs-external-storagecluster-ceph-rbd`, NOT
`ocs-storagecluster-ceph-rbd` which was the internal-mode name and does not exist in this repo's
current storage architecture).

## 4. MetalLB / LoadBalancer VIP issues

```bash
oc get pods -n metallb-system
oc get ipaddresspool -n metallb-system
oc get l2advertisement -n metallb-system
oc get svc -A -o wide | grep LoadBalancer
oc describe svc <svc> -n <namespace>   # check EXTERNAL-IP stuck <pending>
oc logs -n metallb-system -l app=metallb -l component=speaker
```
**Common causes:** `IPAddressPool` range overlaps existing DHCP/static IPs (address conflict,
check ARP on the network); no `L2Advertisement` referencing the pool; MetalLB speaker pods not
scheduled on the node whose L2 segment the VIP needs to live on (check node selectors/taints).

## 5. DNS issues

```bash
oc get dns.operator/default -o yaml
oc get pods -n openshift-dns
oc run -it --rm dnstest --image=registry.access.redhat.com/ubi9/ubi-minimal -- \
  bash -c "curl -v https://api.<cluster_name>.<base_domain>:6443"
nslookup api.<cluster_name>.<base_domain>
nslookup <keystone-public-vip>
```
**Common causes:** external DNS records for `api.` / `*.apps.` / RHOSO public endpoint VIP
not created (agent-based install does not manage external DNS — you must add A records for
API/Ingress VIPs and the MetalLB VIP pool, matching `terraform/variables.tf` `network` block).

## 6. Nova compute not joining / not appearing in `openstack compute service list`

```bash
oc get openstackdataplanenodeset -n openstack -o yaml
oc get openstackdataplanedeployment -n openstack -o yaml
oc get pods -n openstack -l app=openstackansibleee
oc logs -n openstack <ansibleee-pod>   # the Ansible run log - read from the bottom
oc exec -n openstack <openstackclient-pod> -- openstack compute service list
oc exec -n openstack <openstackclient-pod> -- openstack hypervisor list
```
On the RHEL Compute node itself:
```bash
ssh cloud-admin@<compute-node-ip>          # CHANGE_ME
sudo podman ps | grep nova
sudo podman logs nova_compute
sudo systemctl status edpm-nova-compute 2>/dev/null || sudo podman ps -a | grep nova
```
**Common causes:** SSH key from `01-ssh-and-nova-secrets.sh` not present in
`~cloud-admin/.ssh/authorized_keys` on the node; nested virtualization (VT-x/AMD-V) not enabled
in BIOS on a KVM host; `ansibleHost`/`fixedIP` mismatch between NodeSet and reality; message
queue (RabbitMQ) unreachable from the Compute node (check `internalapi` network reachability
from the RHEL node to the OCP-hosted RabbitMQ VIP).

## 7. Neutron / OVN issues

```bash
oc exec -n openstack <openstackclient-pod> -- openstack network agent list
oc get pods -n openstack -l service=ovn
oc rsh -n openstack <ovn-northd-pod>
ovn-nbctl show      # inside the ovn pod - logical switches/routers
ovn-sbctl show      # southbound - chassis registration (compute nodes should appear here)
oc logs -n openstack <ovn-controller-pod-on-compute>
```
On the Compute node:
```bash
sudo podman logs ovn_controller
sudo ovs-vsctl show
```
**Common causes:** `tenant` NetworkAttachmentDefinition/VLAN not reachable end-to-end between
OCP nodes and the RHEL Compute node (Geneve tunnel needs L3 connectivity on that VLAN); OVN
southbound DB not showing the compute node's chassis = `ovn-controller` on the node can't reach
`ovnDBCluster` service VIP — check `internalapi` connectivity and firewall/security group rules
between subnets.

**Floating IPs / provider network specifically:** `scripts/06-create-provider-network.sh`
creates the Neutron `public` network mapped to physnet `datacentre`, which
`manifests/05-data-plane/02-nodeset-compute.yaml`'s EDPM network config template bridges to a
dedicated VLAN (`bond0.30` → OVS bridge `br-ex`) via `edpm_ovn_bridge_mappings`. This gets you a
working floating-IP allocate/attach/detach path and reachability from anything else already on
that VLAN, which is enough to demonstrate and test the control-plane flow end to end - but it is
NOT the same as real internet egress. If `openstack floating ip create` succeeds but the floating
IP isn't reachable from outside the lab, that's expected unless you've also physically connected
`br-ex`'s uplink to a real router with a route back to that VLAN's CIDR - this repo doesn't (and
generically can't) assume what your real upstream network looks like. Verify the mapping itself
with:
```bash
# on the Compute node:
sudo ovs-vsctl show | grep -A3 br-ex
sudo ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings
```

## 8. Image upload issues (Glance)

```bash
oc exec -n openstack <openstackclient-pod> -- openstack image list
oc get pods -n openstack -l service=glance
oc logs -n openstack <glance-api-pod>
oc exec -n openstack <openstackclient-pod> -- openstack image show <image> -f json
```
**Common causes:** Glance PVC not bound (storage backend issue, see section 3); disk quota
too small for the qcow2 you're uploading; direct-Ceph RBD backend misconfigured - check that
`ceph-conf-files` (`manifests/04-control-plane/03-ceph-conf-secret.sh`) actually mounted into the
glance-api pod at `/etc/ceph/` (`oc exec -n openstack <glance-api-pod> -- cat /etc/ceph/ceph.conf`)
and that `rbd_user`/`rbd_pool` in the CR match the external Ceph cluster's real pool/keyring.

## 9. VM boot failure

```bash
oc exec -n openstack <openstackclient-pod> -- openstack server show <vm> -f json
oc exec -n openstack <openstackclient-pod> -- openstack server event list <vm>
oc exec -n openstack <openstackclient-pod> -- nova instance-action-list <vm> 2>/dev/null || true
```
On the Compute node hosting the instance:
```bash
sudo podman logs nova_compute | tail -100
sudo virsh list --all
sudo virsh dumpxml <instance-id>
sudo journalctl -u libvirtd --since "10 min ago"
```
**Common causes:** flavor requests more resources than the Compute node's `nova.conf`
overcommit allows (check `openstack hypervisor stats show`); image format/disk_format mismatch;
no free IP in the Neutron subnet's allocation pool; nested-virt not enabled (instance stuck in
`BUILD` then `ERROR` with a libvirt "KVM not supported" style message in `nova_compute` logs);
Cinder volume attach failure if booting from volume (check `cinder-volume` pod logs and Ceph
RBD connectivity from the Compute node).

## 10. OpenStackControlPlane stuck, cert-manager related

```bash
oc get pods -n cert-manager
oc get certificate -A
oc describe certificate <name> -n openstack   # look for "issuer not found" or Ready=False
oc get issuer,clusterissuer -A
oc get csv -n cert-manager-operator
```
**Common causes:** `manifests/00-prereqs/00-cert-manager-operator.yaml` not applied before the
control plane (RHOSO 18.0 has TLS-e on by default - every service Route/Certificate needs
cert-manager's webhook and controller running first, or the openstack-operator's own
Issuers/Certificates never reach `Ready` and dependent pods sit `Pending`/`ContainerCreating`
indefinitely with no obvious error at the pod level); cert-manager Subscription's InstallPlan
never approved (see section 11).

## 11. Subscription stuck on `AtLatestKnown` / CSV never appears

```bash
oc get subscription -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.state}{"\n"}{end}'
oc get installplan -n <namespace>
oc get installplan <name> -n <namespace> -o jsonpath='{.spec.approved}'
```
**Cause:** every Subscription in this repo uses `installPlanApproval: Manual` (deliberately - see
the comment in `manifests/03-openstack-operator/03-subscription.yaml` for why, particularly for
openstack-operator's ~20-dependent-operator InstallPlan). OLM creates the InstallPlan but waits
forever for approval. Fix:
```bash
oc patch installplan <name> -n <namespace> --type merge -p '{"spec":{"approved":true}}'
```
Every deploy script in `scripts/` calls `scripts/lib/common.sh`'s `wait_and_approve` helper to do
this automatically - if you're applying manifests by hand instead of via the scripts, you must
do this step yourself for every operator.

## 12. EDPM node fails to register / `redhat` service fails first

```bash
oc get openstackdataplanedeployment -n openstack -o yaml | grep -A5 redhat
oc logs -n openstack <ansibleee-pod> | grep -i "subscription-manager\|rhc "
```
On the Compute node:
```bash
sudo subscription-manager status
sudo subscription-manager repos --list-enabled
```
**Common causes:** `subscription-manager`/`redhat-registry` secrets
(`manifests/05-data-plane/00-subscription-manager-secrets.sh`) have the wrong Satellite
organization/activation-key name (must match `infra-bootstrap/01-satellite-content.sh`'s `ORG`/
`AK_NAME` exactly); Satellite's own repos haven't finished syncing yet
(`hammer task list --search 'Synchronize'` on the Satellite host); the EDPM node has no route to
the Satellite host on whatever network `ansibleHost` uses.

## 13. NNCP/bonding issues - node never gets the isolated-network VLANs

```bash
oc get nncp
oc get nnce   # per-node enactment status - check for Failed, and read .status.conditions[].message
oc get nncp <node>-osp-vlans -o yaml
```
On the node itself (`oc debug node/<node>`):
```bash
chroot /host nmcli con show
chroot /host ip -d link show bond0
chroot /host cat /proc/net/bonding/bond0   # confirms both members are actually Up, LACP negotiated
```
**Common causes:** `bonding.member1_name`/`member2_name` in `terraform/terraform.tfvars` don't
match the REAL interface names the node came up with (very common on unfamiliar hardware/
hypervisors - `chroot /host ip link` on a freshly-installed node to check before assuming);
switch ports not configured for LACP when `bonding.mode = "802.3ad"` (symptom: bond0 comes up but
throughput is poor or only one member passes traffic - switch to `active-backup` as a quick test,
it needs no switch-side config at all); `03-generate-nncp.sh` run before `terraform apply`
produced `terraform/generated/nodes/*.json` (nothing to read node names from - see that script's
fallback `$WORKER_NODES` env var).

## General first commands whenever something looks wrong

```bash
oc get events -A --sort-by='.lastTimestamp' | tail -50
oc get openstackcontrolplane -n openstack -o yaml | grep -A3 conditions
oc adm must-gather --image=registry.redhat.io/rhoso/openstack-must-gather-rhel9:18.0   # CHANGE_ME tag
```
