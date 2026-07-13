# POC Results — RHOSO on OpenShift (Simulated Run Walkthrough)

This is a narrative walkthrough of what a run through this repo looks like end to end, in
order, using the default `terraform.tfvars.example` (`platform_mode = "libvirt"`, 3 masters + 3
workers, one of which - `compute-0` - is the Compute data-plane node). Every command shown
matches an actual script in this repo; output is illustrative, not a literal transcript.

## 0. infra-bootstrap (one-time, before anything else)

```
$ bash infra-bootstrap/00-satellite-install.sh
== [4/4] Running satellite-installer (POC-sized, self-signed cert) ==
Satellite installed. Log in at https://satellite.CHANGE_ME.example.com

$ bash infra-bootstrap/01-satellite-content.sh
== [6/6] Activation key ==
Activation key ready: rhoso-poc-edpm-key (org: CHANGE_ME_Org)

$ bash infra-bootstrap/02-mirror-registry-install.sh
Install finished. Credentials were printed above (user "init" + generated password) - save them.

$ bash infra-bootstrap/03-oc-mirror-run.sh
oc-mirror finished. Generated resources are in: ./workspace/working-dir/cluster-resources

$ bash infra-bootstrap/04-ceph-cluster-bootstrap.sh
== [5/5] Creating the openstack client keyring RHOSO services will use directly ==
Ceph cluster bootstrapped.
```

## 1. Terraform infra (this repo's actual module - NOT a cloud-VM module)

FIXED: the original version of this document showed `aws_instance.master[0]` /
`aws_instance.worker[0]` here, which never matched what `terraform/` actually contains (a
provider-agnostic `baremetal_node` module with `libvirt`/`redfish`/`vsphere` resource blocks, no
AWS anywhere in this repo). Corrected below to reflect the real module and the default
`platform_mode = "libvirt"`.

```
$ terraform init
Initializing provider plugins...
- Installing dmacvicar/libvirt v0.9.8...
- Installing hashicorp/local v2.5.x...
Terraform has been successfully initialized!

$ terraform apply -auto-approve
module.baremetal_node["master-0"].libvirt_volume.this[0]: Creating...
module.baremetal_node["master-0"].libvirt_domain.this[0]: Creating...
module.baremetal_node["master-1"].libvirt_domain.this[0]: Creating...
module.baremetal_node["master-2"].libvirt_domain.this[0]: Creating...
module.baremetal_node["worker-0"].libvirt_domain.this[0]: Creating...
module.baremetal_node["worker-1"].libvirt_domain.this[0]: Creating...
module.baremetal_node["compute-0"].libvirt_domain.this[0]: Creating...
module.baremetal_node["master-0"].libvirt_domain.this[0]: Creation complete after 4s
...
local_file.install_config: Creation complete
local_file.agent_config: Creation complete
module.baremetal_node["compute-0"].local_file.node_manifest: Creation complete

Apply complete! Resources: 19 added, 0 changed, 0 destroyed.

Outputs:
install_config_path = "./generated/install-config.yaml"
agent_config_path   = "./generated/agent-config.yaml"
next_steps = <<EOT
  0. (should already be done) infra-bootstrap/00-03 - ...
  1. openshift-install agent create image --dir ./generated --log-level=info
  ...
EOT
```

---

## 2. Agent-based OpenShift install

```
$ openshift-install agent create image --dir ./generated
INFO Consuming Install Config from target directory
INFO Consuming Agent Config from target directory
INFO Created image: generated/agent.x86_64.iso

$ openshift-install agent wait-for bootstrap-complete --dir ./generated
INFO The rendezvous host IP (node0 IP) is 10.10.10.11
INFO Bootstrap Kube API Initialized
INFO cluster bootstrap is complete

$ openshift-install agent wait-for install-complete --dir ./generated
INFO Cluster is initialized
INFO Install complete!
INFO To access the cluster: export KUBECONFIG=./generated/auth/kubeconfig
```
Note the rendezvous IP above is `10.10.10.11` (master-0's real static IP, from
`terraform.tfvars.example`) - not the network gateway, which is what the original version of
this repo's `agent-config.yaml.tmpl` would have produced and which the Agent-based Installer
would have rejected/misbehaved on (a rendezvous IP must belong to one of the hosts).

---

## 3. 00-prereqs-check.sh (now also installs cert-manager)

```
$ bash scripts/00-prereqs-check.sh
== Checking cluster reachability ==
kube:admin
NAME      VERSION   AVAILABLE   PROGRESSING
version   4.18.2    True        False
== Applying disconnected registry prereqs (IDMS + ITMS + CatalogSource) ==
imagedigestmirrorset.config.openshift.io/rhoso-mirror created
imagetagmirrorset.config.openshift.io/rhoso-mirror created
catalogsource.operators.coreos.com/rhoso-mirror-catalog created
-> waiting for MachineConfigPools to finish rolling...
NAME     UPDATED   UPDATING   DEGRADED
master   True      False      False
worker   True      False      False
== Patching cluster pull secret with mirror auth ==
Pull secret patched with mirror auth from mirror-auth.json.
== Installing cert-manager operator (hard prerequisite - RHOSO 18.0 TLS-e is on by default) ==
-> approving InstallPlan install-abc12 in cert-manager-operator
-> waiting for CSV matching 'cert-manager-operator' in cert-manager-operator to reach Succeeded...
-> cert-manager-operator Succeeded
```

---

## 4. 01-deploy-storage.sh (ODF EXTERNAL mode - not internal)

FIXED: internal-mode ODF (building a Ceph cluster out of worker local disks, which the original
version of this document showed via `03-label-storage-nodes.sh`) is not a supported RHOSO 18.0
configuration. This phase now connects to the already-bootstrapped external Ceph cluster instead.

```
$ bash scripts/01-deploy-storage.sh
== Installing ODF operator ==
namespace/openshift-storage created
subscription.operators.coreos.com/odf-operator created
-> approving InstallPlan ... / waiting for CSV ... Succeeded
== Fetching the external-cluster exporter script ==
-> wrote ./ceph-external-cluster-details-exporter.py

STOPPING HERE - manual step required.
[... run exporter.py against the Ceph cluster, create the secret, re-run ...]

$ bash scripts/01-deploy-storage.sh
[picks up from here since the secret now exists]
== Applying external StorageCluster ==
storagecluster.ocs.openshift.io/ocs-external-storagecluster created
  ...still Progressing
NAME                          PHASE   EXTERNAL
ocs-external-storagecluster   Ready   true

$ oc get storageclass | grep ocs-external
ocs-external-storagecluster-ceph-rbd    openshift-storage.rbd.csi.ceph.com
ocs-external-storagecluster-cephfs      openshift-storage.cephfs.csi.ceph.com
```

---

## 5. 02-deploy-networking.sh (NetConfig + one bonded NNCP per worker)

FIXED: the original version of this document (and the repo it described) showed exactly ONE
`worker-0-osp-vlans` NNCP. On a 3-worker cluster the other two workers - including whichever one
is the Compute data-plane node - never got the isolated-network VLANs at all. Below shows all
three, generated by `03-generate-nncp.sh`, each with the bonded pair underneath.

```
$ bash scripts/02-deploy-networking.sh
== Creating openstack namespace early (fixes ordering bug) ==
namespace/openstack created
== Installing NMState operator ==
namespace/openshift-nmstate created
nmstate.nmstate.io/nmstate created
== Applying NetConfig (IPAM for ctlplane/internalapi/storage/tenant) ==
netconfig.network.openstack.org/netconfig created
== Generating and applying per-worker bonded NNCPs ==
-> 3 node JSON file(s) found in terraform/generated/nodes/
nodenetworkconfigurationpolicy.nmstate.io/worker-0-osp-vlans created
nodenetworkconfigurationpolicy.nmstate.io/worker-1-osp-vlans created
nodenetworkconfigurationpolicy.nmstate.io/compute-0-osp-vlans created
NAME                        STATUS
worker-0.bond0              Available
worker-0.bond0.20           Available
worker-1.bond0              Available
compute-0.bond0             Available
...
== Applying NetworkAttachmentDefinitions ==
networkattachmentdefinition.k8s.cni.cncf.io/ctlplane created
networkattachmentdefinition.k8s.cni.cncf.io/internalapi created
networkattachmentdefinition.k8s.cni.cncf.io/storage created
networkattachmentdefinition.k8s.cni.cncf.io/tenant created
== Installing MetalLB ==
metallb.metallb.io/metallb created
ipaddresspool.metallb.io/osp-public-pool created
```

---

## 6. 03-deploy-openstack-operator.sh

```
$ bash scripts/03-deploy-openstack-operator.sh
namespace/openstack-operators created
namespace/openstack created
subscription.operators.coreos.com/openstack-operator created
-> approving InstallPlan install-xyz89 in openstack-operators
-> waiting for CSV matching 'openstack-operator' ... Succeeded
NAME                                              READY   STATUS
keystone-operator-controller-manager-6c4f8        2/2     Running
nova-operator-controller-manager-9b7d6            2/2     Running
neutron-operator-controller-manager-5f8c9         2/2     Running
cinder-operator-controller-manager-7d9f4          2/2     Running
barbican-operator-controller-manager-3a1e2        2/2     Running
telemetry-operator-controller-manager-9f4c1       2/2     Running
openstack-operator-controller-manager-8c6d7       2/2     Running
... (≈18 more operator pods, all Running)
```

---

## 7. 04-deploy-control-plane.sh (now includes the Ceph secret + Barbican + Telemetry)

```
$ bash scripts/04-deploy-control-plane.sh
Wrote 02-osp-secret.yaml.
secret/osp-secret created
ceph-conf-files secret ready. FSID: fsid = 6454b2b8-2cb4-495f-942c-1f1767b222ff
openstackcontrolplane.core.openstack.org/openstack-control-plane created
-> waiting for OpenStackControlPlane to reach Ready...
  ...still deploying
NAME                       READY
galera-openstack-0         1/1     Running
rabbitmq-server-0          1/1     Running
keystone-6f9d8-x2n4v       1/1     Running
glance-default-single-0    1/1     Running
neutron-6b9c7              1/1     Running
nova-api-0                 1/1     Running
cinder-volume-ceph-0       1/1     Running
barbican-api-7c9d1         1/1     Running
ceilometer-central-9b2f0   1/1     Running
horizon-7d9f4              1/1     Running

NAME                       STATUS
openstack-control-plane    Ready   True
```

---

## 8. 05-deploy-data-plane.sh (now registers RHEL via Satellite first)

```
$ bash scripts/05-deploy-data-plane.sh
secret/subscription-manager created
secret/redhat-registry created
secret/dataplane-ansible-ssh-private-key-secret created
openstackdataplanenodeset.dataplane.openstack.org/compute-nodeset created
openstackdataplanedeployment.dataplane.openstack.org/compute-deploy created
NAME                                    READY   STATUS
openstackansibleee-compute-nodeset-x7   1/1     Running

PLAY [Bootstrap EDPM nodes] ***********************************
TASK [redhat : register with Satellite] *** changed: [compute-0]
TASK [Gathering Facts] ***** ok: [compute-0]
TASK [edpm_bootstrap : install packages] *** ok: [compute-0]
TASK [ceph_client : distribute ceph.conf + keyring] *** changed: [compute-0]
TASK [edpm_network_config : configure bond0 + VLANs + br-ex] *** changed: [compute-0]
TASK [edpm_nova : configure nova-compute] *** changed: [compute-0]
TASK [edpm_ovn : start ovn-controller, set bridge-mappings] *** changed: [compute-0]
PLAY RECAP ***** compute-0 : ok=45  changed=21  unreachable=0  failed=0

NAME                     STATUS
compute-deploy           Ready   True
```

---

## 9. 06-create-provider-network.sh (previously entirely missing)

```
$ bash scripts/06-create-provider-network.sh
+---------------+--------------------------------------+
| name          | public                                |
| provider:physical_network | datacentre                |
| provider:segmentation_id  | 30                         |
+---------------+--------------------------------------+
+---------------+--------------------------------------+
| name          | public-subnet                        |
| cidr          | 10.20.20.0/24                          |
| allocation_pools | 10.20.20.100-10.20.20.200            |
+---------------+--------------------------------------+
Provider network 'public' ready. Next: bash 07-smoke-test.sh
```

---

## 10. 07-smoke-test.sh

```
$ bash scripts/07-smoke-test.sh
+ openstack project create poc-project        -> created
+ openstack user create poc-user              -> created
+ openstack flavor create m1.tiny.poc          -> created
+ openstack keypair create poc-keypair          -> created
+ openstack security group create poc-secgroup -> created
-- image upload (Cirros) --
+---------------+--------------------------------------+
| status        | active                                |
+---------------+--------------------------------------+
-- network/subnet/router --
+ network poc-net       -> created
+ subnet poc-subnet     -> created
+ router poc-router     -> created, external gateway set (public)
-- boot VM --
  status=BUILD, waiting...
  status=ACTIVE
Floating IP: 10.20.20.150
-- SSH test --
SSH_OK
```

If everything ends here with `SSH_OK`, the POC is functionally complete: control plane up
(including Barbican and Telemetry), storage backed by an external Ceph cluster, one bonded
Compute node registered via Satellite, a provider network that didn't exist before this
remediation pass, and a VM booted and reachable over a floating IP.

---

## Most likely real-world time-consuming points (in rough order of probability)

1. **External Ceph connection (ODF external mode)** — a stale or mistyped
   `rook-ceph-external-cluster-details` secret is the single most common reason this phase
   sits `Progressing` far longer than shown above; re-run the exporter script rather than
   guessing.
2. **Bonding/NIC naming** — `bonding.member1_name`/`member2_name` not matching what the actual
   hardware/hypervisor names its interfaces is the most common reason a node comes up with no
   isolated-network connectivity at all (see docs/troubleshooting.md #13).
3. **Data-plane Ansible run** — Satellite activation-key mismatch, or nested-virt (VT-x) not
   actually exposed on the chosen hypervisor/BIOS setting.
4. **OVN chassis registration for the Compute node** — network reachability on the tenant
   VLAN between the Compute node and the OCP-hosted OVN southbound DB.
5. **Manual InstallPlan approval** — every Subscription in this repo is `installPlanApproval:
   Manual`; forgetting to approve one (or not noticing `wait_and_approve` timed out) looks like
   a hung operator install with no error anywhere.

These are exactly the sections to escalate to someone experienced rather than retry blindly —
see `docs/troubleshooting.md` for the diagnostic commands for each.
