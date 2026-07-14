# FAQ

Common questions about this repo — what it does, why it's built this way, and what to check
before you rely on it. Click a question to expand it. For step-by-step failures, see
`docs/troubleshooting.md` instead — this file is design rationale and usage questions, not a
symptom → fix reference.

> [!IMPORTANT]
> This is a personal proof-of-concept repo, **not official Red Hat documentation or a supported
> product**. It follows Red Hat's documented architecture and was checked against current Red Hat
> docs throughout, but there's no support channel here beyond the repo itself.

### Jump to a section
[About this repo](#about-this-repo) ·
[Before you start](#before-you-start) ·
[Configuring the repo](#configuring-the-repo) ·
[Installation method](#installation-method) ·
[Running the deployment](#running-the-deployment) ·
[Architecture decisions](#architecture-decisions) ·
[RHOSO services](#rhoso-services) ·
[Day 2 / ongoing operations](#day-2--ongoing-operations) ·
[Extending this repo](#extending-this-repo)

---

## About this repo

<details>
<summary><b>Is this official Red Hat documentation or a supported product?</b></summary><br>

No. See the callout at the top — this is a personal POC repo, checked against current Red Hat
docs but not Red Hat content, with no support channel beyond this repo. For production
deployments, work from Red Hat's official documentation and support/consulting.
</details>

<details>
<summary><b>What does this actually deploy?</b></summary><br>

A disconnected (air-gapped) RHOSO 18.0 environment: OpenShift 4.18 cluster, external Ceph
storage, the RHOSO control plane (~20 OpenStack services), and one external RHEL 9.4 Compute
node — plus the pre-provisioning infrastructure (Satellite, mirror registry, Ceph cluster) it
depends on. `docs/architecture.svg` is the visual overview.
</details>

<details>
<summary><b>Who is this for?</b></summary><br>

Anyone standing up a RHOSO POC/lab who wants a working, bonded-networking, disconnected-capable
reference rather than starting from a blank `install-config.yaml`. Assumes familiarity with
OpenShift and OpenStack fundamentals — it's not a from-scratch tutorial.
</details>

---

## Before you start

<details>
<summary><b>What are the hardware requirements?</b></summary><br>

| Component | Count | vCPU | RAM | Disk |
|---|---|---|---|---|
| Control plane (master) | 3 | 8 | 32 GB | 120 GB |
| Worker | 3 | 16 | 64 GB | 250 GB |
| Satellite | 1 | 4 | 32 GB | 300 GB |
| Mirror registry | 1 | 2 | 8 GB | 300–500 GB |
| External Ceph | 1+ | 8 | 32 GB | 200 GB+ (raw block device) |

If testing everything as nested VMs on one host (`platform_mode = libvirt`): ~72 vCPU / 288 GB
RAM / ~1.1 TB disk, cumulative.

> [!NOTE]
> Whichever worker you designate as the Compute node needs nested virtualization (VT-x/AMD-V)
> exposed to it, or Nova won't start.
</details>

<details>
<summary><b>Do I have to use Satellite / this exact mirror registry / cephadm for external Ceph?</b></summary><br>

No — reference path, not a hard dependency. Already have a RHEL content source, an image mirror,
or a Ceph cluster? Skip the matching `infra-bootstrap/` script and point `scripts/configure.py` /
`terraform.tfvars` at your existing infrastructure instead.
</details>

<details>
<summary><b>What are the preparation steps?</b></summary><br>

Pull secret, SSH key, 2 DNS records (`api.<cluster>.<domain>`, `*.apps.<cluster>.<domain>`), a
network plan (machine CIDR/VIPs/gateway/DNS/NTP), per-node static IPs and bonded-NIC MAC
addresses, and — since this is disconnected — a populated mirror registry with its CA cert ready
to merge into the cluster pull secret.
</details>

---

## Configuring the repo

<details>
<summary><b>How do I configure this for my own environment?</b></summary><br>

```bash
python3 scripts/configure.py
```
One interactive pass asks for every environment-specific value and writes
`terraform/terraform.tfvars`, substitutes every `__TOKEN__` placeholder across
`manifests/`/`scripts/`/`infra-bootstrap/`, and writes `.rhoso-poc-secrets.env` for the handful
of real passwords (never baked into a tracked file).
</details>

<details>
<summary><b>I re-ran <code>configure.py</code> — did it overwrite my previous answers?</b></summary><br>

No — it offers your previous answers (from `.rhoso-poc-config.json`) as defaults on every
prompt. Hit Enter to keep any of them, or type a new value to change just that one.
</details>

<details>
<summary><b>Some <code>CHANGE_ME</code> comments are still there after running the wizard — is that a bug?</b></summary><br>

No — those are judgment calls the wizard deliberately doesn't guess at: confirming an exact OLM
channel name, whether to enable Swift, HA vs. POC replica counts. The wizard prints the full
list of what's left at the end of its run.
</details>

---

## Installation method

<details>
<summary><b>Why Agent-based Installer instead of UPI or IPI?</b></summary><br>

IPI needs a discrete provisioner node (with nested virt, running libvirt to host the bootstrap
VM) plus a separate PXE provisioning network. UPI needs you to hand-build ignition delivery,
your own load balancer, and more DNS records. Agent-based needs none of that — one ISO, no
provisioner, in-place bootstrap.

| Aspect | UPI | IPI (baremetal) | Agent-based (this repo) |
|---|---|---|---|
| Provisioner node | Not needed | Required | Not needed |
| Bootstrap | Separate VM you create/destroy | Separate VM, automatic | In-place, no separate machine |
| DNS needed | api, api-int, *.apps, etcd SRV | api, *.apps | api, *.apps |
| DHCP | Your responsibility | Required on provisioning network | Not required (static IPs) |
| Load balancer | You build it | Automatic | Automatic |
</details>

<details>
<summary><b>Why don't I see DNS/DHCP/load-balancer setup steps?</b></summary><br>

DHCP and PXE aren't used at all — every node gets a static IP via `agent-config.yaml`, booting
from an ISO. The load balancer is automatic: `platform: baremetal` makes OpenShift run its own
keepalived + haproxy as static pods on the masters.

> [!NOTE]
> DNS is the one real exception — you still need to create 2 external records yourself
> (`api.<cluster>.<domain>`, `*.apps.<cluster>.<domain>`). No install method automates that part.
</details>

<details>
<summary><b>What platforms does this repo support?</b></summary><br>

Repo's own `platform_mode`: `redfish` (real bare metal / a Redfish-capable bare-metal cloud),
`libvirt` (KVM VMs on one host, the default — works with zero physical hardware), `vsphere`
(VMware private cloud). Separately, OpenShift's own `platform:` setting only accepts
`baremetal`, `vsphere`, or `none` for Agent-based installs — this repo uses `baremetal`.
</details>

---

## Running the deployment

<details>
<summary><b>What's the installation sequence?</b></summary><br>

1. `python3 scripts/configure.py`
2. `infra-bootstrap/00`–`04` — Satellite, mirror registry, oc-mirror, external Ceph
3. `terraform init && terraform apply` — nodes provisioned
4. `openshift-install agent create image` → `wait-for bootstrap-complete` → `wait-for
   install-complete`
5. `scripts/00`–`07` (or `deploy-all.sh`) — prereqs/cert-manager → storage → networking →
   openstack-operator → control plane → data plane → provider network → smoke test

`CHECKLIST.md` has this as literal checkboxes with a verification command for each step.
</details>

<details>
<summary><b>Can I dry-run any of this with <code>terraform plan</code>?</b></summary><br>

Partially. `main.tf` reads the pull secret, SSH key, and mirror CA cert with `file()` at plan
time, so `plan` fails if those don't exist yet — the CA cert specifically doesn't exist until
the mirror registry script has actually run. `platform_mode = libvirt` also needs the libvirt
daemon reachable, and `redfish` needs the BMCs reachable.

> [!TIP]
> There's no version of `plan` here with zero external dependencies — that's expected, not a bug.
</details>

<details>
<summary><b>A step failed partway through — do I have to start over?</b></summary><br>

No — every script in `scripts/` and `infra-bootstrap/` is written to be re-runnable on its own,
not just as part of the full chain. Check `docs/troubleshooting.md` for the specific symptom
first.
</details>

---
## what are the operators we installed, and why we need it
Five operators, installed in this order:

1. **cert-manager** — RHOSO 18 ships TLS-everywhere by default; needed to issue/rotate certs for every service endpoint
2. **NMState** — manages the NNCPs (bonding + VLANs) at the OS level, post-install
3. **MetalLB** — bare metal has no cloud load balancer; provides the VIP pool for RHOSO service endpoints (Keystone public URL, Horizon, etc.)
4. **ODF** (external mode) — provides the StorageClass for OpenShift-internal PVCs (Galera, RabbitMQ, OVN DB), backed by the external Ceph cluster
5. **openstack-operator** — the meta-operator; deploys and manages all ~20 RHOSO services (Keystone, Nova, Neutron+OVN, Cinder, Barbican, Telemetry, etc.)

Each is a hard dependency for something specific — skip cert-manager and the control plane CR never goes Ready; skip MetalLB and no service gets a reachable IP; skip NMState and the bonding we just discussed doesn't apply.

---

## Architecture decisions

<details>
<summary><b>Why is Ceph external instead of using ODF internal mode?</b></summary><br>

ODF internal mode (Ceph running as pods inside OpenShift on worker local disks) isn't a
supported RHOSO 18.0 configuration per Red Hat's storage docs. External mode connects to a real,
separately-managed Ceph cluster instead.
</details>

<details>
<summary><b>How is NIC bonding enforced?</b></summary><br>

At three points that all have to agree: install-time (`agent-config.yaml`'s embedded NMState
config), ongoing (a generated NodeNetworkConfigurationPolicy per node), and the EDPM Compute
node's own network config. Intentional redundancy across lifecycle stages, not duplication.
</details>

<details>
<summary><b>How does the floating-IP/provider network work, and what's the catch?</b></summary><br>

A dedicated VLAN on the bonded pair, bridged via OVS on the Compute node, mapped to a Neutron
provider network.

> [!WARNING]
> Floating IPs allocate/attach/detach correctly, proving the control-plane path — but without a
> real upstream router physically connected to that VLAN, they won't reach the actual internet.
> Inherent to a self-contained POC, not something this repo can fix generically.
</details>

<details>
<summary><b>Why is every operator Subscription set to <code>installPlanApproval: Manual</code>?</b></summary><br>

Deliberate. Particularly for `openstack-operator`'s InstallPlan — worth reviewing what actually
resolved through the disconnected mirror once, rather than blanket-approving it. Every deploy
script approves it automatically for you either way (`scripts/lib/common.sh`).
</details>

---

## RHOSO services

<details>
<summary><b>How many services does RHOSO actually run?</b></summary><br>

Exactly 20 operators across 19 documented services (Bare Metal Provisioning uses two:
`ironic-operator` and `openstack-baremetal-operator`) — verified against Red Hat's current
service-operators table, not an approximation.
</details>

<details>
<summary><b>Does this deployment use every service's default on/off setting?</b></summary><br>

No, four deliberate deviations from Red Hat's documented defaults:

| Service | RHOSO default | This repo |
|---|---|---|
| Horizon | Disabled | Enabled |
| Octavia | Disabled | Enabled |
| Heat | Disabled | Enabled |
| Swift | Enabled | Disabled |
</details>

<details>
<summary><b>Do I need to manage ~20 separate operators?</b></summary><br>

Not on current RHOSO 18.0 (18.0.6+) — it's a single `openstack-operator` managing all ~20
services internally via an `OpenStackVersion` CR. Earlier 18.0.x releases used one operator per
service; on one of those, expect ~20 separate CSVs instead of one.
</details>

---

## Day 2 / ongoing operations

<details>
<summary><b>What does this repo cover after the initial deployment?</b></summary><br>

`scripts/deploy-all.sh --teardown` for full rollback, and `docs/troubleshooting.md` for 13
failure classes with diagnostic commands.
</details>

<details>
<summary><b>What's NOT covered that I'd need for a real deployment?</b></summary><br>

Scaling (adding masters/workers/Compute nodes), OCP/RHOSO version upgrades, RHEL EUS patch
cadence via Satellite content-view promotion, Ceph capacity expansion, tenant/quota management,
and backup/DR. This repo is deliberately Day 1-scoped.
</details>

---

## Extending this repo

<details>
<summary><b>Is there a Red Hat GitOps option instead of these shell scripts?</b></summary><br>

`openstack-k8s-operators/gitops` exists (ArgoCD-based) but is explicitly Developer Preview, not
production-ready, and doesn't yet manage MetalLB/NMState/cert-manager the way this repo does.
This repo's numbered-phase structure (`00-prereqs` → ... → `05-data-plane`) would map cleanly
onto ArgoCD sync-waves if extended in that direction later.
</details>

<details>
<summary><b>Something's wrong and none of this explains it — now what?</b></summary><br>

`docs/troubleshooting.md` first (symptom → command → likely cause, 13 sections). If it's a gap
in that doc rather than something covered, that's worth opening as an issue against the repo.
</details>
