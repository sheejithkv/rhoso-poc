# Phase -1: Infra bootstrap (Satellite + mirror registry)

This directory is **new** in the remediated repo. It runs *before* `terraform/` and before
any OpenShift provisioning, because both later phases depend on it:

- `terraform/` needs the disconnected registry's CA cert and the RHOSO image mirror to already
  exist so `install-config.yaml` can be generated with the right `imageContentSources` /
  `additionalTrustBundle` values (see `manifests/00-prereqs/`).
- `manifests/05-data-plane/` needs Satellite (or another RHEL content source) reachable so the
  RHEL 9.4 Compute node can register and pull EUS/RHOSO packages during the Ansible bootstrap
  run (see `edpm_bootstrap_command` / `rhc_repositories` in `02-nodeset-compute.yaml`).

Two separate systems on purpose - they hold different content types and this matches standard
Red Hat disconnected architecture:

| System | Content type | Consumed by |
|---|---|---|
| **Satellite** (`00`/`01`) | RPMs: RHEL 9.4 BaseOS/AppStream/HA **EUS**, Fast Datapath, RHOSO 18.0 RPM channel, RHCEPH 7 tools | RHEL Compute (EDPM) nodes, and optionally the bastion/Terraform host itself |
| **mirror registry for Red Hat OpenShift** (`02`/`03`) | OCI images: OCP release payload, redhat-operator-index catalog, RHOSO operator + service images | OpenShift itself (cluster install + OLM), via IDMS/ITMS/CatalogSource in `manifests/00-prereqs/` |

If your organization already has a Satellite and/or Quay/Artifactory mirror, skip straight to
`03-oc-mirror-run.sh` (pointed at your existing registry) and reuse your existing Satellite
activation key in `manifests/05-data-plane/00-subscription-manager-secrets.sh`.

## Order

```bash
cd infra-bootstrap
bash 00-satellite-install.sh          # RPM install + satellite-installer on the Satellite VM/host
bash 01-satellite-content.sh          # org, manifest, repos, sync, lifecycle env, CV, activation key
bash 02-mirror-registry-install.sh    # small Quay-based OCI registry for OCP + RHOSO images
bash 03-oc-mirror-run.sh              # oc-mirror v2: OCP release + operator catalog + RHOSO -> registry
```

Everything here is a **one-time, per-environment** setup. It is intentionally separate from
`scripts/deploy-all.sh`, which only orchestrates the OpenShift-side manifests and assumes this
phase is already done (that's why `00-prereqs-check.sh` starts by checking the mirror is
reachable rather than creating it).

All hostnames below are `CHANGE_ME` - search for it:

```bash
grep -rn "CHANGE_ME" .
```
