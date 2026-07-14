# RHOSO (Red Hat OpenStack Services on OpenShift) 18.0 — POC Deployment

End-to-end automation: Satellite + mirror registry + external Ceph (`infra-bootstrap/`) →
Terraform infra (bare metal, any bare-metal environment or any cloud) → OpenShift 4.18 →
RHOSO 18.0 control plane + data plane, in a **disconnected** environment, with bonded NICs on
every node.

This is a POC procedure, not a production sizing/HA guide. Where Red Hat requires more nodes
for supportability (e.g. 3 control plane nodes), that minimum is kept even in the POC.

Configuration (one-time, before anything installs)

python3 scripts/configure.py — writes terraform.tfvars, .rhoso-poc-secrets.env, substitutes every __TOKEN__

Phase −1 — Pre-provisioning infra (infra-bootstrap/)

00-satellite-install.sh → Satellite installed
01-satellite-content.sh → org, repos, activation key ready
02-mirror-registry-install.sh → mirror registry installed
03-oc-mirror-run.sh → registry populated, IDMS/ITMS generated
04-ceph-cluster-bootstrap.sh → external Ceph cluster ready

Phase 0 — Nodes + OpenShift install (terraform/)

terraform init && terraform apply → nodes provisioned, bonded NICs up
openshift-install agent create image → boot ISO built
openshift-install agent wait-for bootstrap-complete
openshift-install agent wait-for install-complete → OpenShift cluster is up

Phase 1–7 — RHOSO deployment (scripts/deploy-all.sh, or run individually)

00-prereqs-check.sh → IDMS/ITMS/CatalogSource + pull secret + cert-manager installed
01-deploy-storage.sh → ODF (external mode) connected to Ceph
02-deploy-networking.sh → NetConfig + bonded NNCPs + NAD + MetalLB ready
03-deploy-openstack-operator.sh → openstack-operator + ~20 service operators running
04-deploy-control-plane.sh → RHOSO control plane Ready (Keystone/Nova/Neutron/Cinder/Barbican/Telemetry/...)
05-deploy-data-plane.sh → Compute node registered + deployed (Nova/OVN/libvirt/Ceph client live)
06-create-provider-network.sh → floating-IP network ready
07-smoke-test.sh → VM + floating IP + SSH verified → POC complete

---

## 1. Environment assumptions (edit these first)

| Item | POC default used in this repo | Change in |
|---|---|---|
| OpenShift version | 4.18 | `terraform/variables.tf` (`ocp_version`) |
| RHOSO version | 18.0 (GA channel) | `manifests/03-openstack-operator/03-subscription.yaml` |
| Platform | `libvirt` by default (any cloud/host with nested virt); `redfish` for real bare metal; `vsphere` for a private cloud | `terraform/variables.tf` (`platform_mode`) |
| Control plane nodes | 3 | `terraform/variables.tf` |
| Worker nodes | 3 (2 minimum for RHOSO control plane pods, 1+ dedicated as Compute data-plane node) | `terraform/variables.tf` |
| Node NICs | 2 per node, bonded (`bond0`, LACP 802.3ad by default) | `terraform/variables.tf` (`bonding`) |
| Storage backend (OCP) | ODF, **external mode** against a real external Ceph cluster | `manifests/01-storage-odf/`, `infra-bootstrap/04-ceph-cluster-bootstrap.sh` |
| Cinder/Glance/Nova Ceph access | Direct RBD via `ceph-conf-files` secret, `rbd_user=openstack` | `manifests/04-control-plane/03-ceph-conf-secret.sh` |
| RHEL content source | Red Hat Satellite (activation key), NOT registry.redhat.io directly | `infra-bootstrap/00-01-satellite-*.sh` |
| Container image mirror | mirror registry for Red Hat OpenShift (small Quay), populated via oc-mirror v2 | `infra-bootstrap/02-03-*.sh` |
| TLS | TLS-everywhere (TLS-e), on by default, cert-manager-issued | `manifests/00-prereqs/00-cert-manager-operator.yaml` |
| Key Manager / Telemetry | Barbican + Ceilometer/Aodh, explicitly configured | `manifests/04-control-plane/04-openstackcontrolplane.yaml` |
| Network type | OVN-Kubernetes (OCP) + OVN (Neutron) | fixed |
| DNS domain | `CHANGE_ME.example.com` | everywhere marked `CHANGE_ME` |
| Data plane node OS | RHEL 9.4 EUS, pinned via Satellite | `manifests/05-data-plane/02-nodeset-compute.yaml` |
| Provider/floating-IP network | `public`, VLAN 30 on a dedicated OVS bridge (`br-ex`) | `scripts/06-create-provider-network.sh` |
| Test image | Cirros (fast smoke test) — swap for RHEL qcow2 for real workloads | `scripts/07-smoke-test.sh` |

Every value you must personally set is tagged `CHANGE_ME` in the files, or (for anything with
real cross-file dependencies - the same hostname, UUID, or MAC needing to match in several
places) an `__ALL_CAPS_TOKEN__` placeholder. **Run the configuration wizard instead of hand-editing
these** - see section 2 below.

```bash
grep -rn "CHANGE_ME" . | wc -l
grep -rln "CHANGE_ME" .
```

---

## 2. Configure once: `scripts/configure.py`

```bash
python3 scripts/configure.py
```

Asks for every environment-specific value this repo needs (domain, org, network, one prompt per
node, Satellite, mirror registry, Ceph, provider network, credentials) and then:

- writes a complete `terraform/terraform.tfvars` (not just filling in the `.example`)
- replaces every `__TOKEN__` placeholder across `manifests/`, `scripts/`, and `infra-bootstrap/`
  with the matching answer - so the Compute node's NIC MACs, the Ceph RBD secret UUID, the
  mirror registry hostname, and everything else that has to match across multiple files only
  gets entered once and can't drift out of sync
- writes `.rhoso-poc-secrets.env` (gitignored, `chmod 600`) for the handful of real passwords
  (Satellite admin, Ceph dashboard, mirror registry) - these are **never** written into any
  tracked file, even by this wizard; `source` that file before running the scripts that need them
- writes `.rhoso-poc-config.json` (gitignored) so re-running the wizard later offers your
  previous answers as defaults instead of starting over

Safe to re-run any time - answers are remembered, and every substitution is idempotent. What it
does *not* do: a small number of remaining `CHANGE_ME` comments are judgment calls, not blanks
(confirm an OLM channel name, enable Swift or not, HA vs. POC replica counts) - the wizard prints
these at the end of its run rather than guessing.

---

## 3. Repository layout

```
rhoso-poc/
├── README.md                     <- you are here
├── CHANGELOG.md                  <- what changed vs. the previous version of this repo, and why
├── infra-bootstrap/              <- Phase -1: Satellite + mirror registry + Ceph (before Terraform)
│   ├── 00-satellite-install.sh     satellite-installer on a dedicated RHEL host
│   ├── 01-satellite-content.sh     org/manifest/repos/content-view/activation-key
│   ├── 02-mirror-registry-install.sh   small Quay instance for OCP+RHOSO images
│   ├── 03-oc-mirror-run.sh         oc-mirror v2: populate the registry, emit IDMS/ITMS
│   ├── 04-ceph-cluster-bootstrap.sh   minimal external Ceph cluster via cephadm
│   └── imageset-config.yaml        oc-mirror v2 input (OCP release + operator catalog + RHOSO)
├── terraform/                    <- Phase 0: node infra provisioning, provider-agnostic
│   ├── providers.tf              <- redfish / libvirt / vsphere, selected by platform_mode
│   ├── variables.tf              <- node counts, bonded NIC pairs, BMC creds, network CIDRs
│   ├── main.tf                   <- calls modules/baremetal_node per node; computes rendezvousIP
│   ├── outputs.tf                <- emits install-config.yaml + agent-config.yaml
│   └── modules/baremetal_node/   <- redfish (real BMC) or libvirt (KVM, any cloud/host) resources
├── manifests/                    <- Phase 1-5: OpenShift + RHOSO YAML, apply in numeric order
│   ├── 00-prereqs/                 cert-manager, IDMS/ITMS, disconnected CatalogSource, pull-secret patch
│   ├── 01-storage-odf/             ODF operator in EXTERNAL mode + external-cluster exporter wrapper
│   ├── 02-networking/              openstack namespace, NMState, NetConfig, per-worker bonded NNCPs, NAD, MetalLB
│   ├── 03-openstack-operator/      openstack-operator namespace/subscription
│   ├── 04-control-plane/           osp-secret + ceph-conf-files secret + OpenStackControlPlane CR
│   └── 05-data-plane/              subscription secrets + OpenStackDataPlaneNodeSet + Deployment
├── scripts/                      <- orchestration wrapper (idempotent, validates each step)
│   ├── configure.py               <- run this FIRST: interactive config wizard (see section 2)
│   ├── deploy-all.sh              <- runs everything in order end to end, or --teardown
│   ├── lib/common.sh              <- shared helpers (Manual InstallPlan approval, CSV waits)
│   ├── 00-prereqs-check.sh
│   ├── 01-deploy-storage.sh
│   ├── 02-deploy-networking.sh
│   ├── 03-deploy-openstack-operator.sh
│   ├── 04-deploy-control-plane.sh
│   ├── 05-deploy-data-plane.sh
│   ├── 06-create-provider-network.sh
│   └── 07-smoke-test.sh
├── docs/
│   └── troubleshooting.md        <- symptom -> command -> likely fix, 13 failure classes
└── POC-Results-DOC.md            <- narrative walkthrough of a full run, phase by phase
```

---

## 4. Before Terraform: infra-bootstrap

Satellite (RPM content for the RHEL Compute node) and the mirror registry (OCI images for OCP +
RHOSO) both need to exist *before* you provision anything else — the disconnected OpenShift
install needs the registry's CA and mirror mappings, and the data-plane Ansible run needs
Satellite reachable. See `infra-bootstrap/README.md` for the full rationale and order:

```bash
cd infra-bootstrap
bash 00-satellite-install.sh
bash 01-satellite-content.sh
bash 02-mirror-registry-install.sh
bash 03-oc-mirror-run.sh
bash 04-ceph-cluster-bootstrap.sh
```

Already have a Satellite, registry, or Ceph cluster? Skip straight to wiring their real
hostnames/credentials into `terraform.tfvars` and `manifests/05-data-plane/00-subscription-manager-secrets.sh`.

---

## 5. How Terraform feeds OpenShift install

`terraform apply` provisions every node (3x master + N x worker, each with **two bonded NICs**)
and writes two files via `local_file` resources:

```
terraform/generated/install-config.yaml
terraform/generated/agent-config.yaml
terraform/generated/nodes/*.json     <- one per node; manifests/02-networking/03-generate-nncp.sh reads these
```

These are consumed directly by the **Agent-based Installer** (recommended for disconnected
bare-metal in 4.18) to boot the cluster with zero manual re-typing of IPs/MACs:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill in every CHANGE_ME
terraform init
terraform apply -auto-approve

openshift-install agent create image --dir ./generated --log-level=info
# -> generated/agent.x86_64.iso
#    platform_mode=redfish: attached to each BMC automatically via redfish_virtual_media
#    platform_mode=libvirt: attached automatically as each VM's virtual CDROM
#    platform_mode=vsphere or anything else: attach manually

openshift-install agent wait-for bootstrap-complete --dir ./generated --log-level=info
openshift-install agent wait-for install-complete   --dir ./generated --log-level=info
```

**Which `platform_mode` should you use?**
- You have real servers with iDRAC/iLO/XCC/CIMC (or a bare-metal cloud like Equinix Metal that
  exposes Redfish): `platform_mode = "redfish"`.
- You don't have physical hardware handy, but you have (or can spin up) one reasonably large
  Linux host or cloud VM with nested virtualization enabled: `platform_mode = "libvirt"`
  (the default) — this is the same technique the upstream OpenShift Metal3/dev-scripts community
  uses to test bare-metal-style installs without real hardware.
- You have an existing VMware private cloud: `platform_mode = "vsphere"`.

The Terraform code for `redfish`/`libvirt` resource attributes was checked against each
provider's own published examples (not just written from memory) — see the comments at the top
of `terraform/providers.tf` for what that does and doesn't guarantee, since this sandbox has no
network path to actually run `terraform init`/`apply` against real infrastructure.

---

## 6. Order of execution (after the cluster is up)

```bash
export KUBECONFIG=$(pwd)/terraform/generated/auth/kubeconfig   # run from repo root
bash scripts/deploy-all.sh
```

`deploy-all.sh` runs, in order, with a wait + verification gate after each stage:

1. `00-prereqs-check.sh` — disconnected registry mirror (IDMS+ITMS) + pull secret + **cert-manager**
2. `01-deploy-storage.sh` — ODF operator in **external mode**, connected to the Ceph cluster from `infra-bootstrap/`
3. `02-deploy-networking.sh` — NMState, NetConfig, **bonded NNCP per worker**, NetworkAttachmentDefinitions, MetalLB
4. `03-deploy-openstack-operator.sh` — openstack-operator subscription
5. `04-deploy-control-plane.sh` — osp-secret + ceph-conf-files + OpenStackControlPlane (Barbican + Telemetry included)
6. `05-deploy-data-plane.sh` — Satellite registration + OpenStackDataPlaneNodeSet + Deployment
7. `06-create-provider-network.sh` — the Neutron `public` network the smoke test needs
8. `07-smoke-test.sh` — full openstack CLI smoke test (project/network/VM/floating IP/SSH)

Every Subscription in this repo uses `installPlanApproval: Manual` (see `docs/troubleshooting.md`
#11 for why); every script calls `scripts/lib/common.sh`'s `wait_and_approve` helper so this
happens automatically when using the scripts. Each script can also be run standalone if you're
re-entering the procedure midway.

---

## 7. Rollback

Every manifest folder has a matching delete command in its own comments, and
`scripts/deploy-all.sh --teardown` runs all of them in reverse order — this now actually reaches
everything (NMState/openstack-operators namespace/operatorgroup/cert-manager were previously left
behind). Terraform:

```bash
cd terraform && terraform destroy -auto-approve
```

`infra-bootstrap/` (Satellite, mirror registry, external Ceph) is deliberately **not** touched by
either teardown path — it's shared, persistent, per-environment infrastructure, not part of any
one cluster's lifecycle. Decommission it manually per `infra-bootstrap/README.md` only if you
actually mean to.

---

## 8. Full written procedure

See the numbered manifests and scripts themselves — each file is preceded by a comment block in
this format:

```
# WHAT: <description, and what changed here vs. the previous version of this repo, if anything>
# VERIFY: <command to run after apply>
# ROLLBACK: <command to delete safely>
```

Troubleshooting for every failure class this repo has hit — operator install, pods pending,
storage class, MetalLB/LB, DNS, cert-manager/TLS, Manual InstallPlan approval, Nova compute not
joining, Neutron/OVN + provider network, image upload, VM boot failure, Satellite registration,
and bonding/NNCP — is in `docs/troubleshooting.md` (13 sections).
