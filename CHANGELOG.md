# Changelog — remediation pass

This documents every change made to the repo in this pass: the 16 issues originally identified,
the 4 new considerations (bonding, image registry, Satellite, portability), and everything else
found along the way. Each entry names the actual file(s) changed.

## The 16 originally identified issues

1. **ODF internal mode unsupported** → `manifests/01-storage-odf/` rebuilt for **external mode**.
   `03-label-storage-nodes.sh` (worker-disk labeling, internal-mode-only) removed. New:
   `02-fetch-and-run-exporter.sh` (pulls and runs the exporter script against the external Ceph
   cluster), `03-storagecluster-external.yaml` (was `02-storagecluster.yaml`, internal mode).
   The external Ceph cluster itself is bootstrapped by the new
   `infra-bootstrap/04-ceph-cluster-bootstrap.sh`.

2. **Missing cert-manager Operator** → new `manifests/00-prereqs/00-cert-manager-operator.yaml`,
   applied and waited-on in `scripts/00-prereqs-check.sh` before anything else.

3. **rendezvousIP = gateway IP** → `terraform/templates/agent-config.yaml.tmpl` now takes
   `rendezvous_ip` from `terraform/main.tf`'s `local.rendezvous_ip` (= the first master's real
   static IP). This also required adding real per-node static IPs to `terraform/variables.tf`'s
   `nodes` list, which didn't exist before (nodes only had MAC addresses).

4. **Hardcoded `/home/claude/` paths** → removed everywhere. Every script now resolves its own
   location via `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` (see
   `scripts/lib/common.sh`) instead of an absolute path baked in at write-time. Specifically:
   `manifests/04-control-plane/01-osp-secret-gen.sh`, and the README's `grep` example.

5. **NNCP only for worker-0** → `manifests/02-networking/02-nncp-worker.yaml` (static, single
   node) replaced by `03-generate-nncp.sh`, which generates one bonded NNCP per actual worker
   node (reading `terraform/generated/nodes/*.json`, or a `$WORKER_NODES` fallback) and applies
   all of them. `scripts/02-deploy-networking.sh` calls the generator instead of applying one file.

6. **`03-pull-secret-patch.sh` never invoked** → renumbered to `04-pull-secret-patch.sh` (to make
   room for cert-manager at 00 and ITMS at 02) and is now called from
   `scripts/00-prereqs-check.sh`, with a preflight check for the mirror-auth file and a clear
   error message if it's missing instead of a raw Python traceback.

7. **No public provider network** → new `scripts/06-create-provider-network.sh`, which creates
   the Neutron `public` network/subnet mapped to the `datacentre` physnet, wired to a dedicated
   OVS bridge (`br-ex`) on the Compute node — see item under "Bonding" below and
   `docs/troubleshooting.md` #7 for what this does and doesn't get you without real upstream
   routing.

8. **Missing RHEL version pinning** → `manifests/05-data-plane/02-nodeset-compute.yaml` now sets
   `rhc_release`, `rhc_repositories` (BaseOS/AppStream/HA EUS + Fast Datapath + RHOSO 18.0 +
   RHCEPH 7 tools channels), and `edpm_bootstrap_release_version_package`, sourced through new
   secrets in `manifests/05-data-plane/00-subscription-manager-secrets.sh` that register against
   **Satellite** via activation key (see "Satellite" below) rather than registry.redhat.io directly.

9. **Barbican section missing from the CR** → added to
   `manifests/04-control-plane/04-openstackcontrolplane.yaml` (`barbican:` block, replicas=1 for
   POC), consuming the `BarbicanDatabasePassword`/`BarbicanSimpleCryptoKEK` fields that
   `01-osp-secret-gen.sh` was already generating but that nothing consumed before.

10. **Telemetry/Ceilometer missing from the CR** → added (`telemetry:` block: metricStorage,
    autoscaling/Aodh disabled by default for POC, Ceilometer enabled), matching RHOSO 18.0's
    documented schema. `01-osp-secret-gen.sh` extended with `AodhDatabasePassword`,
    `AodhPassword`, `CeilometerPassword`.

11. **39 `Zone.Identifier` files** → deleted; `.gitignore` now excludes `*:Zone.Identifier`
    globally so they can't be re-committed by accident.

12. **`POC-Results-DOC.md` showed `aws_instance`** → rewritten to match the actual bare-metal/
    libvirt Terraform module (no cloud VM resources anywhere in this repo), and updated end to
    end to reflect every other change in this list (external Ceph, cert-manager, bonded NNCPs,
    Barbican/Telemetry, Satellite registration, provider network).

13. **Empty `03-nncp-controlplane-ns.yaml`** → deleted outright. Its stated purpose (NNCP
    coverage for control-plane-adjacent nodes) is now handled properly by
    `manifests/02-networking/03-generate-nncp.sh` generating a policy per node that needs one.

14. **Teardown incomplete** → `scripts/deploy-all.sh --teardown` rewritten to reverse every
    phase this repo now has: data-plane secrets, control-plane secrets, openstack-operator +
    its InstallPlans, NMState/MetalLB instances and NNCPs, the `openstack` namespace, external
    StorageCluster, and cert-manager — all previously left in place or simply never installed
    (so never torn down) in the first place.

15. **`installPlanApproval: Automatic`** → changed to `Manual` on every Subscription in the repo
    (cert-manager, ODF, NMState, MetalLB, openstack-operator) — deliberately, not just for
    consistency; see `docs/troubleshooting.md` #11. `scripts/lib/common.sh`'s `wait_and_approve`
    helper approves the resulting InstallPlan automatically from every deploy script.

16. **ITMS alongside IDMS** → new `manifests/00-prereqs/02-itms.yaml`, for the tag-referenced
    images (must-gather, RHCEPH tools image) that an IDMS alone doesn't cover. Both are generated
    together by `infra-bootstrap/03-oc-mirror-run.sh` in a real run.

## The 4 new considerations

- **Bonding enabled on node NICs**: every node gets two NICs bonded into `bond0` (LACP 802.3ad by
  default, `active-backup` as a documented fallback for switches without LACP) at THREE layers
  that all now agree with each other:
  - OpenShift install time: `terraform/templates/agent-config.yaml.tmpl` (real interface names +
    MACs from `terraform/variables.tf`'s new `bonding`/`nodes` schema).
  - OpenShift post-install: `manifests/02-networking/03-generate-nncp.sh` (NMState now owns
    `bond0` going forward, plus the InternalAPI/Storage/Tenant VLANs on top of it).
  - The RHOSO Compute node: `manifests/05-data-plane/02-nodeset-compute.yaml`'s
    `edpm_network_config_template` (`linux_bond` + VLANs + a dedicated `br-ex` OVS bridge for the
    provider network).
- **Image registry creation**: `infra-bootstrap/02-mirror-registry-install.sh` (mirror registry
  for Red Hat OpenShift) + `03-oc-mirror-run.sh` (oc-mirror v2, populates it and emits IDMS/ITMS/
  CatalogSource).
- **Satellite server creation before provisioning OpenShift**: `infra-bootstrap/00-satellite-install.sh`
  + `01-satellite-content.sh`, sequenced explicitly before `terraform/` in the README, and
  consumed by the data-plane's subscription secrets (item 8 above).
- **Works across any bare-metal environment or any cloud**: `terraform/providers.tf` now supports
  `redfish` (any Redfish-conformant BMC — Dell/HPE/Lenovo/Cisco/Supermicro/Equinix Metal, not one
  vendor), `libvirt` (KVM VMs on any single host or nested-virt cloud VM — the default, since it's
  the only mode runnable with zero physical hardware on hand), and `vsphere`. Interface naming and
  BMC/MAC details are all variables, not hardcoded values.

## Additional bugs found during this pass (not on the original list)

- **Namespace-ordering bug**: `scripts/02-deploy-networking.sh` applied
  NetworkAttachmentDefinitions into the `openstack` namespace before that namespace existed
  anywhere (it was only created two phases later). Fixed with new
  `manifests/02-networking/00-openstack-namespace.yaml`, applied first.
- **Missing NetConfig CR**: `manifests/05-data-plane/02-nodeset-compute.yaml` referenced
  `managementNetwork: ctlplane` and named networks/subnets that were never defined anywhere —
  the CRD that defines them (`NetConfig`) didn't exist in the repo at all. Added as
  `manifests/02-networking/02-netconfig.yaml`.
- **Fictitious "bootstrap" node role**: `terraform/variables.tf`'s node list included a node with
  `role = "bootstrap"`, which doesn't exist in the Agent-based Installer's model (there is no
  separate bootstrap VM — a master temporarily coordinates bootstrap, see item 3 above). Removed;
  `nodes` now validates that every role is `master` or `worker`.
- **MetalLB/NMState operators installed but never instantiated**: the original scripts installed
  the Subscriptions for both operators but never created the `NMState`/`MetalLB` singleton CRs
  that actually start their controller pods. Added to `scripts/02-deploy-networking.sh`.
- **A real Jinja2 bug caught by actually rendering the template**: an early draft of
  `edpm_network_config_template` used `{{ mtu_list.append(...) }}` — since `list.append()`
  returns `None`, this prints the literal string `"None"` into the rendered YAML, corrupting it.
  Fixed to `{% set _ = mtu_list.append(...) %}`, and verified by actually rendering the template
  with Jinja2 and parsing the result as YAML (not just eyeballing it).
- **Two incorrect Terraform provider resource fields**: an early draft of the `redfish` module
  used `image = "file://..."` + `inserted = true` on `redfish_virtual_media`, and
  `desired_power_state` on `redfish_power`. Checked against `dell/terraform-provider-redfish`
  v1.6.1's own published examples: the image must be an HTTP(S)/NFS/etc URL the BMC itself can
  fetch (not a local path — added `boot_iso_http_url` to carry this), and the power field is
  `desired_power_action`. Both fixed; the `libvirt` module's resource schema was checked the same
  way and needed no changes.
- **Child module missing its own `required_providers`**: confirmed via a real `tofu init` (using
  a locally-fetched OpenTofu binary, since this environment has no registry access) that without
  a `required_providers` block in `modules/baremetal_node`, Terraform defaulted the `redfish`/
  `libvirt` resource types to the nonexistent `hashicorp/` namespace instead of `dell/` and
  `dmacvicar/`. Fixed with a new `modules/baremetal_node/versions.tf`.

## Explicit scope decisions (not bugs — deliberate POC simplifications)

- **RHOSO's full default network set is 6 networks** (Ctlplane, InternalApi, Storage,
  StorageMgmt, Tenant, External); this repo implements 5 (adds External, skips StorageMgmt,
  which is specifically for Ceph-cluster-internal management traffic and adds little for a POC
  already using an already-bootstrapped external Ceph cluster).
- **Ctlplane shares an L2 segment with the OpenShift machine network** in this POC's IP plan,
  rather than being a fully separate dedicated network as most production reference
  architectures use. Documented in `manifests/02-networking/02-netconfig.yaml`'s header.
- **The `public` provider network has no real upstream router by default** — floating IPs
  allocate/attach/detach correctly (enough to prove the control-plane path end to end) but won't
  reach the real internet until you point `br-ex`'s uplink at an actual router. This is
  inherent to any self-contained POC and can't be hardcoded generically — see
  `docs/troubleshooting.md` #7.
- **Redfish/libvirt Terraform resource blocks are schema-checked but not executed** — this
  sandbox has no network path to real BMCs, hypervisors, or the Terraform/OpenTofu registry, so
  `terraform plan`/`apply` was never run against real infrastructure. What *was* done: full HCL
  syntax validation (`tofu fmt`), confirming both provider source addresses resolve to real,
  actively maintained providers, and diffing the exact resource attributes used here against
  each provider's own published examples (catching and fixing the two real bugs listed above).
