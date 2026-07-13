#!/usr/bin/env python3
"""
scripts/configure.py

WHAT: Interactive wizard that asks for every environment-specific value this repo needs
(domain, org, network, nodes, Satellite, mirror registry, Ceph, provider network, credentials)
ONCE, then:
  1. writes terraform/terraform.tfvars (a complete, ready-to-use file - not the .example)
  2. writes .rhoso-poc-config.json (every non-secret answer, gitignored, so re-running this
     script later offers your previous answers as defaults instead of starting from scratch)
  3. writes .rhoso-poc-secrets.env (the handful of real passwords, gitignored, meant to be
     `source`d before running infra-bootstrap/ scripts that need them - these are deliberately
     NEVER written into any tracked file, see the note in step 4)
  4. replaces every __TOKEN__ placeholder across manifests/, scripts/, and infra-bootstrap/ with
     the matching answer

WHAT THIS DOES NOT DO: a small number of CHANGE_ME comments in the repo are judgment calls, not
blanks (e.g. "confirm the exact OLM channel name for your catalog", "enable Swift? true/false",
replica counts for HA vs POC sizing). Those are printed at the end of this script's run rather
than guessed at - see CHANGELOG.md's "Explicit scope decisions" section for the reasoning.

USAGE:
    cd rhoso-poc          # repo root
    python3 scripts/configure.py

Safe to re-run: it will offer your previous answers (from .rhoso-poc-config.json) as defaults,
and every substitution is idempotent (replacing __TOKEN__ a second time is a no-op since the
token is gone after the first run - see --relaunch below if you need to change values afterward).

VERIFY: grep -rn "CHANGE_ME" . | wc -l    (should shrink to just the judgment-call items)
        grep -rn "__[A-Z_]*__" .          (should be empty - if not, a token had no answer)
"""
import ipaddress
import json
import os
import re
import secrets
import string
import subprocess
import sys
import uuid
from getpass import getpass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / ".rhoso-poc-config.json"
SECRETS_PATH = REPO_ROOT / ".rhoso-poc-secrets.env"
TFVARS_PATH = REPO_ROOT / "terraform" / "terraform.tfvars"

# Directories that may contain __TOKEN__ placeholders. terraform/ is deliberately excluded -
# terraform.tfvars is generated fresh instead of token-substituted (see write_tfvars()).
SUBSTITUTION_DIRS = ["manifests", "scripts", "infra-bootstrap"]
SUBSTITUTION_EXTS = {".sh", ".yaml", ".yml"}


# --------------------------------------------------------------------------------------
# Small prompt helpers
# --------------------------------------------------------------------------------------
def ask(prompt, default=None, validator=None, error_hint=None):
    """Prompt with an optional default (shown, accepted on bare Enter) and optional validator
    (a callable returning True/False; re-prompts with error_hint on failure).
    default=None means "no default, something must be typed"; default="" (or any other string,
    including an intentionally blank one) means "bare Enter accepts this value as-is"."""
    has_default = default is not None
    if has_default and default != "":
        suffix = f" [{default}]"
    elif has_default:
        suffix = " [blank OK]"
    else:
        suffix = ""
    while True:
        raw = input(f"{prompt}{suffix}: ").strip()
        if raw:
            value = raw
        elif has_default:
            value = default
        else:
            print("  (a value is required)")
            continue
        if validator and not validator(value):
            print(f"  ({error_hint or 'invalid value'}) try again")
            continue
        return value


def ask_yesno(prompt, default=True):
    d = "Y/n" if default else "y/N"
    raw = input(f"{prompt} [{d}]: ").strip().lower()
    if not raw:
        return default
    return raw.startswith("y")


def ask_secret(prompt, default_generated=None):
    """Never echoes input. If the person just hits Enter and a generated default is offered,
    uses that (still random per-run, never a fixed literal)."""
    hint = " [Enter to auto-generate a random one]" if default_generated else ""
    val = getpass(f"{prompt}{hint}: ")
    if not val and default_generated:
        return default_generated
    while not val:
        val = getpass(f"{prompt} (required): ")
    return val


def gen_password(length=20):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def valid_ip(v):
    try:
        ipaddress.ip_address(v)
        return True
    except ValueError:
        return False


def valid_cidr(v):
    try:
        ipaddress.ip_network(v, strict=False)
        return True
    except ValueError:
        return False


def valid_mac(v):
    return bool(re.fullmatch(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", v))


def gen_libvirt_mac(index):
    """Locally-administered, QEMU/KVM-conventional MAC for auto-generated libvirt nodes."""
    return f"52:54:00:a{index // 100}:{(index // 10) % 10:01x}{index % 10:01x}:{index:02x}"


def net_prefix(cidr):
    """10.10.10.0/24 -> '10.10.10'. Only meaningful for /24s, which is this repo's assumption
    throughout (see manifests/02-networking/02-netconfig.yaml's header comment)."""
    return ".".join(cidr.split("/")[0].split(".")[:3])


# --------------------------------------------------------------------------------------
# Config load/save (so re-running this script offers previous answers as defaults)
# --------------------------------------------------------------------------------------
def load_previous():
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except Exception:
            return {}
    return {}


def save_config(cfg):
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, sort_keys=True) + "\n")
    print(f"\n-> wrote {CONFIG_PATH.relative_to(REPO_ROOT)} (safe to re-run this script later; not a secret)")


# --------------------------------------------------------------------------------------
# Interactive sections
# --------------------------------------------------------------------------------------
def section_basics(prev):
    print("\n== Basics ==")
    cluster_name = ask("Cluster name", prev.get("cluster_name", "rhoso-poc"))
    base_domain = ask("Base DNS domain (e.g. lab.example.com)", prev.get("base_domain"))
    org_name = ask("Organization name (Satellite org + catalog publisher)", prev.get("org_name", "MyOrg"))
    return {"cluster_name": cluster_name, "base_domain": base_domain, "org_name": org_name}


def section_platform(prev):
    print("\n== Platform ==")
    print("  redfish : real bare metal / a Redfish-capable bare-metal cloud")
    print("  libvirt : KVM VMs on one host, anywhere - works with zero physical hardware")
    print("  vsphere : an existing VMware private cloud")
    platform_mode = ask(
        "platform_mode", prev.get("platform_mode", "libvirt"),
        validator=lambda v: v in ("redfish", "libvirt", "vsphere"),
        error_hint="must be redfish, libvirt, or vsphere",
    )
    out = {"platform_mode": platform_mode}
    if platform_mode == "libvirt":
        out["libvirt_uri"] = ask("libvirt connection URI", prev.get("libvirt_uri", "qemu:///system"))
        out["libvirt_storage_pool"] = ask("libvirt storage pool", prev.get("libvirt_storage_pool", "default"))
        out["libvirt_network_bridge"] = ask(
            "Pre-existing Linux bridge for node NICs", prev.get("libvirt_network_bridge", "br0")
        )
    elif platform_mode == "vsphere":
        out["vsphere_user"] = ask("vSphere username", prev.get("vsphere_user"))
        out["vsphere_password"] = ask_secret("vSphere password")
        out["vsphere_server"] = ask("vSphere server (vCenter host)", prev.get("vsphere_server"))
    else:
        out["boot_iso_http_url"] = ask(
            "HTTP(S) URL where the agent ISO will be hosted (BMC-reachable)",
            prev.get("boot_iso_http_url"),
        )
    return out


def section_bonding(prev):
    print("\n== Bonding (applied to every node's two NICs) ==")
    mode = ask(
        "Bonding mode", prev.get("bonding_mode", "802.3ad"),
        validator=lambda v: v in ("active-backup", "balance-xor", "802.3ad", "balance-tlb", "balance-alb"),
        error_hint="must be one of active-backup/balance-xor/802.3ad/balance-tlb/balance-alb",
    )
    member1 = ask("First bond member interface name", prev.get("bond_member1", "eno1"))
    member2 = ask("Second bond member interface name", prev.get("bond_member2", "eno2"))
    return {"bonding_mode": mode, "bond_member1": member1, "bond_member2": member2}


def section_network(prev):
    print("\n== Network ==")
    cidr = ask(
        "Machine network CIDR (a /24 - see note in netconfig.yaml)",
        prev.get("machine_network_cidr", "10.10.10.0/24"),
        validator=valid_cidr, error_hint="not a valid CIDR",
    )
    prefix = net_prefix(cidr)
    gateway = ask("Gateway", prev.get("gateway", f"{prefix}.1"), validator=valid_ip, error_hint="not a valid IP")
    api_vip = ask("API VIP", prev.get("api_vip", f"{prefix}.5"), validator=valid_ip, error_hint="not a valid IP")
    ingress_vip = ask(
        "Ingress VIP", prev.get("ingress_vip", f"{prefix}.6"), validator=valid_ip, error_hint="not a valid IP"
    )
    dns_server = ask("DNS server", prev.get("dns_server", gateway), validator=valid_ip, error_hint="not a valid IP")
    ntp_server = ask("NTP server", prev.get("ntp_server", gateway), validator=valid_ip, error_hint="not a valid IP")
    metallb_range = f"{prefix}.80-{prefix}.90"
    print(f"  -> MetalLB pool auto-set to {metallb_range} (edit manifests/02-networking/06-metallb-ipaddresspool.yaml later if that overlaps something)")
    return {
        "machine_network_cidr": cidr,
        "gateway": gateway,
        "api_vip": api_vip,
        "ingress_vip": ingress_vip,
        "dns_server": dns_server,
        "ntp_server": ntp_server,
        "metallb_pool_range": metallb_range,
    }


def section_nodes(prev, platform_mode, prefix):
    print("\n== Nodes ==")
    print("  3 control-plane (master) nodes is fixed - RHOSO/OCP HA requires it.")
    worker_count = int(
        ask("How many worker nodes (one will be the Compute/data-plane node)?", str(prev.get("worker_count", 3)))
    )
    prev_nodes = {n["name"]: n for n in prev.get("nodes", [])}
    nodes = []

    def node_prompt(name, default_ip, default_role):
        print(f"\n  -- {name} ({default_role}) --")
        p = prev_nodes.get(name, {})
        ip_address = ask(f"    {name} IP", p.get("ip_address", default_ip), validator=valid_ip, error_hint="not a valid IP")
        if platform_mode == "libvirt":
            idx = len(nodes)
            nic1_mac = p.get("nic1_mac") or gen_libvirt_mac(idx * 2 + 1)
            nic2_mac = p.get("nic2_mac") or gen_libvirt_mac(idx * 2 + 2)
            print(f"    (auto-generated MACs: {nic1_mac} / {nic2_mac} - override in terraform.tfvars later if needed)")
        else:
            nic1_mac = ask(f"    {name} NIC1 MAC (bond member 1)", p.get("nic1_mac"), validator=valid_mac, error_hint="not a MAC (aa:bb:cc:dd:ee:ff)")
            nic2_mac = ask(f"    {name} NIC2 MAC (bond member 2)", p.get("nic2_mac"), validator=valid_mac, error_hint="not a MAC")
        node = {"name": name, "role": default_role, "ip_address": ip_address, "nic1_mac": nic1_mac, "nic2_mac": nic2_mac}
        if platform_mode == "redfish":
            node["bmc_address"] = ask(f"    {name} BMC address (redfish-virtualmedia+https://...)", p.get("bmc_address"))
            node["bmc_username"] = ask(f"    {name} BMC username", p.get("bmc_username"))
            node["bmc_password"] = ask_secret(f"    {name} BMC password")
        else:
            node["bmc_address"] = node["bmc_username"] = node["bmc_password"] = ""
        return node

    for i in range(3):
        nodes.append(node_prompt(f"master-{i}", f"{prefix}.{11 + i}", "master"))
    for i in range(worker_count):
        default_name = f"compute-0" if i == worker_count - 1 else f"worker-{i}"
        nodes.append(node_prompt(default_name, f"{prefix}.{21 + i}", "worker"))

    compute_default = nodes[-1]["name"]
    compute_name = ask("Which node name is the Compute/data-plane node?", prev.get("compute_node_name", compute_default))
    compute_node = next((n for n in nodes if n["name"] == compute_name), nodes[-1])
    return {"nodes": nodes, "worker_count": worker_count, "compute_node_name": compute_node["name"], "compute_node": compute_node}


def section_paths(prev):
    print("\n== Local paths ==")
    return {
        "pull_secret_path": ask("Path to your Red Hat pull secret json", prev.get("pull_secret_path", str(Path.home() / "pull-secret.json"))),
        "ssh_public_key_path": ask("SSH public key path", prev.get("ssh_public_key_path", "~/.ssh/id_rsa.pub")),
    }


def section_registry(prev):
    print("\n== Disconnected mirror registry (infra-bootstrap/02-mirror-registry-install.sh) ==")
    host = ask("Mirror registry hostname (no port)", prev.get("mirror_registry_host", "quay-mirror.example.com"))
    mirror_auth_path = ask("Path to mirror-auth.json (from `podman login --authfile`)", prev.get("mirror_auth_file_path", str(Path.home() / "mirror-auth.json")))
    ca_cert_path = ask(
        "Path to the mirror registry's CA cert (rootCA.pem)",
        prev.get("mirror_ca_cert_path", str(Path.home() / "quay-install/quay-rootCA/rootCA.pem")),
    )
    return {"mirror_registry_host": host, "mirror_auth_file_path": mirror_auth_path, "mirror_ca_cert_path": ca_cert_path}


def section_satellite(prev, base_domain, org_name):
    print("\n== Satellite ==")
    fqdn = ask("Satellite FQDN", prev.get("satellite_fqdn", f"satellite.{base_domain}"))
    manifest_zip = ask("Path to the downloaded Satellite subscription manifest .zip", prev.get("satellite_manifest_zip_path", str(Path.home() / "manifest_rhoso-poc.zip")))
    activation_key = ask("Activation key name", prev.get("satellite_activation_key", "rhoso-poc-edpm-key"))
    return {"satellite_fqdn": fqdn, "satellite_manifest_zip_path": manifest_zip, "satellite_activation_key": activation_key}


def section_ceph(prev):
    print("\n== External Ceph cluster (infra-bootstrap/04-ceph-cluster-bootstrap.sh) ==")
    mon_ip = ask("Ceph mon host IP", prev.get("ceph_mon_ip"), validator=valid_ip, error_hint="not a valid IP")
    cluster_hosts = ask("Additional Ceph hosts (space-separated, blank for single-node POC)", prev.get("ceph_cluster_hosts", ""))
    data_device = ask("Raw block device for OSD (e.g. /dev/sdb)", prev.get("ceph_data_device", "/dev/sdb"))
    rbd_uuid = prev.get("ceph_rbd_secret_uuid") or str(uuid.uuid4())
    print(f"  -> Cinder<->Nova libvirt RBD secret UUID: {rbd_uuid} (auto-generated once, reused everywhere it must match)")
    return {
        "ceph_mon_ip": mon_ip,
        "ceph_cluster_hosts": cluster_hosts,
        "ceph_data_device": data_device,
        "ceph_rbd_secret_uuid": rbd_uuid,
    }


def section_provider_network(prev):
    print("\n== Neutron provider (floating-IP) network ==")
    physnet = ask("Physical network name", prev.get("external_physnet", "datacentre"))
    vlan_id = ask("VLAN ID (distinct from the ctlplane/internalapi/storage/tenant ones)", str(prev.get("external_vlan_id", 30)))
    subnet_cidr = ask("Subnet CIDR", prev.get("external_subnet_cidr", "10.20.20.0/24"), validator=valid_cidr, error_hint="not a valid CIDR")
    prefix = net_prefix(subnet_cidr)
    alloc_start = ask("Floating-IP allocation start", prev.get("external_allocation_start", f"{prefix}.100"), validator=valid_ip, error_hint="not a valid IP")
    alloc_end = ask("Floating-IP allocation end", prev.get("external_allocation_end", f"{prefix}.200"), validator=valid_ip, error_hint="not a valid IP")
    gateway = ask(
        "Upstream gateway for this VLAN (leave as a placeholder if none - see docs/troubleshooting.md #7)",
        prev.get("external_gateway", f"{prefix}.1"), validator=valid_ip, error_hint="not a valid IP",
    )
    return {
        "external_physnet": physnet, "external_vlan_id": vlan_id, "external_subnet_cidr": subnet_cidr,
        "external_allocation_start": alloc_start, "external_allocation_end": alloc_end, "external_gateway": gateway,
    }


def section_misc(prev):
    print("\n== Misc ==")
    ansible_user = ask("SSH user the operator uses to configure the Compute node", prev.get("ansible_user", "cloud-admin"))
    return {"ansible_user": ansible_user}


def section_secrets():
    print("\n== Credentials (never echoed, never written into any tracked file) ==")
    gen_sat = gen_password()
    gen_ceph = gen_password()
    gen_reg = gen_password()
    return {
        "SATELLITE_ADMIN_PASSWORD": ask_secret("Satellite admin password", gen_sat),
        "CEPH_DASHBOARD_PASSWORD": ask_secret("Ceph dashboard password", gen_ceph),
        "MIRROR_REGISTRY_PASSWORD": ask_secret(
            "Mirror registry password (leave blank + Enter if you don't have it yet - "
            "02-mirror-registry-install.sh prints the real one at install time)",
            gen_reg,
        ),
    }


# --------------------------------------------------------------------------------------
# File writers
# --------------------------------------------------------------------------------------
def hcl_str(v):
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_tfvars(cfg):
    n = cfg["nodes"]
    node_lines = []
    for node in n:
        fields = (
            f'name = {hcl_str(node["name"])}, role = {hcl_str(node["role"])}, '
            f'ip_address = {hcl_str(node["ip_address"])}, nic1_mac = {hcl_str(node["nic1_mac"])}, '
            f'nic2_mac = {hcl_str(node["nic2_mac"])}, bmc_address = {hcl_str(node["bmc_address"])}, '
            f'bmc_username = {hcl_str(node["bmc_username"])}, bmc_password = {hcl_str(node["bmc_password"])}'
        )
        node_lines.append(f"  {{ {fields} }},")

    lines = [
        "# Generated by scripts/configure.py - re-run that script to regenerate, don't hand-edit",
        "# the node list (everything else below is fair game to tweak by hand).",
        "",
        f"cluster_name        = {hcl_str(cfg['cluster_name'])}",
        f"base_domain         = {hcl_str(cfg['base_domain'])}",
        f"pull_secret_path    = {hcl_str(cfg['pull_secret_path'])}",
        f"ssh_public_key_path = {hcl_str(cfg['ssh_public_key_path'])}",
        "",
        f"platform_mode = {hcl_str(cfg['platform_mode'])}",
        "",
        "control_plane_count = 3",
        f"worker_count         = {cfg['worker_count']}",
        "",
        "bonding = {",
        f"  interface_name = \"bond0\"",
        f"  member1_name   = {hcl_str(cfg['bond_member1'])}",
        f"  member2_name   = {hcl_str(cfg['bond_member2'])}",
        f"  mode           = {hcl_str(cfg['bonding_mode'])}",
        "  miimon_ms      = 140",
        "}",
        "",
        "nodes = [",
        *node_lines,
        "]",
        "",
        "network = {",
        f"  machine_network_cidr = {hcl_str(cfg['machine_network_cidr'])}",
        f"  api_vip              = {hcl_str(cfg['api_vip'])}",
        f"  ingress_vip          = {hcl_str(cfg['ingress_vip'])}",
        f"  dns_servers          = [{hcl_str(cfg['dns_server'])}]",
        f"  ntp_servers          = [{hcl_str(cfg['ntp_server'])}]",
        f"  gateway              = {hcl_str(cfg['gateway'])}",
        "}",
        "",
        "disconnected_registry = {",
        f"  host         = {hcl_str(cfg['mirror_registry_host'])}",
        "  port         = 8443",
        f"  ca_cert_path = {hcl_str(cfg['mirror_ca_cert_path'])}",
        "}",
    ]

    if cfg["platform_mode"] == "libvirt":
        lines += [
            "",
            f"libvirt_uri            = {hcl_str(cfg['libvirt_uri'])}",
            f"libvirt_storage_pool   = {hcl_str(cfg['libvirt_storage_pool'])}",
            f"libvirt_network_bridge = {hcl_str(cfg['libvirt_network_bridge'])}",
        ]
    elif cfg["platform_mode"] == "vsphere":
        lines += [
            "",
            f"vsphere_user     = {hcl_str(cfg['vsphere_user'])}",
            f"vsphere_password = {hcl_str(cfg['vsphere_password'])}",
            f"vsphere_server   = {hcl_str(cfg['vsphere_server'])}",
        ]
    else:
        lines += ["", f"boot_iso_http_url = {hcl_str(cfg['boot_iso_http_url'])}"]

    TFVARS_PATH.write_text("\n".join(lines) + "\n")
    print(f"-> wrote {TFVARS_PATH.relative_to(REPO_ROOT)}")


def write_secrets_env(secret_values):
    lines = [
        "# Generated by scripts/configure.py - gitignored, never commit this file.",
        "# source this before running infra-bootstrap/00-satellite-install.sh,",
        "# infra-bootstrap/04-ceph-cluster-bootstrap.sh, and",
        "# manifests/05-data-plane/00-subscription-manager-secrets.sh",
    ]
    for k, v in secret_values.items():
        escaped = v.replace("'", "'\\''")
        lines.append(f"export {k}='{escaped}'")
    SECRETS_PATH.write_text("\n".join(lines) + "\n")
    os.chmod(SECRETS_PATH, 0o600)
    print(f"-> wrote {SECRETS_PATH.relative_to(REPO_ROOT)} (chmod 600, gitignored)")


TOKEN_MAP_KEYS = {
    "__BASE_DOMAIN__": "base_domain",
    "__ORG_NAME__": "org_name",
    "__BONDING_MODE__": "bonding_mode",
    "__GATEWAY__": "gateway",
    "__MACHINE_NETWORK_CIDR__": "machine_network_cidr",
    "__METALLB_POOL_RANGE__": "metallb_pool_range",
    "__MIRROR_REGISTRY_HOST__": "mirror_registry_host",
    "__MIRROR_AUTH_FILE_PATH__": "mirror_auth_file_path",
    "__SATELLITE_FQDN__": "satellite_fqdn",
    "__SATELLITE_MANIFEST_ZIP_PATH__": "satellite_manifest_zip_path",
    "__SATELLITE_ACTIVATION_KEY__": "satellite_activation_key",
    "__CEPH_MON_IP__": "ceph_mon_ip",
    "__CEPH_CLUSTER_HOSTS__": "ceph_cluster_hosts",
    "__CEPH_DATA_DEVICE__": "ceph_data_device",
    "__CEPH_RBD_SECRET_UUID__": "ceph_rbd_secret_uuid",
    "__EXTERNAL_PHYSNET__": "external_physnet",
    "__EXTERNAL_VLAN_ID__": "external_vlan_id",
    "__EXTERNAL_SUBNET_CIDR__": "external_subnet_cidr",
    "__EXTERNAL_ALLOCATION_START__": "external_allocation_start",
    "__EXTERNAL_ALLOCATION_END__": "external_allocation_end",
    "__EXTERNAL_GATEWAY__": "external_gateway",
    "__ANSIBLE_USER__": "ansible_user",
    "__COMPUTE_NODE_NAME__": ("compute_node", "name"),
    "__COMPUTE_NODE_NIC1_MAC__": ("compute_node", "nic1_mac"),
    "__COMPUTE_NODE_NIC2_MAC__": ("compute_node", "nic2_mac"),
}


def build_token_values(cfg):
    values = {}
    for token, key in TOKEN_MAP_KEYS.items():
        if isinstance(key, tuple):
            values[token] = str(cfg[key[0]][key[1]])
        else:
            values[token] = str(cfg[key])
    # compute-node-derived network addresses, following the same convention
    # manifests/02-networking/02-netconfig.yaml documents (.100-.250 range, offset by index)
    compute_index = next((i for i, n in enumerate(cfg["nodes"]) if n["role"] == "worker"), 0)
    values["__COMPUTE_NODE_CTLPLANE_IP__"] = cfg["compute_node"]["ip_address"]
    values["__COMPUTE_NODE_INTERNALAPI_IP__"] = f"172.17.0.{100 + compute_index}"
    values["__COMPUTE_NODE_STORAGE_IP__"] = f"172.18.0.{100 + compute_index}"
    values["__COMPUTE_NODE_TENANT_IP__"] = f"172.19.0.{100 + compute_index}"
    return values


def substitute_tokens(values):
    changed_files = []
    remaining_tokens = set()
    for d in SUBSTITUTION_DIRS:
        base = REPO_ROOT / d
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix not in SUBSTITUTION_EXTS:
                continue
            text = path.read_text()
            if "__" not in text:
                continue
            original = text
            for token, value in values.items():
                if token in text:
                    text = text.replace(token, value)
            if text != original:
                path.write_text(text)
                changed_files.append(str(path.relative_to(REPO_ROOT)))
            for m in re.findall(r"__[A-Z0-9_]+__", text):
                remaining_tokens.add((str(path.relative_to(REPO_ROOT)), m))
    return changed_files, remaining_tokens


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
def main():
    print(__doc__.split("USAGE:")[0])
    prev = load_previous()
    if prev:
        print(f"Found previous answers in {CONFIG_PATH.name} - press Enter to keep any of them.\n")

    cfg = {}
    cfg.update(section_basics(prev))
    cfg.update(section_platform(prev))
    cfg.update(section_bonding(prev))
    cfg.update(section_network(prev))
    prefix = net_prefix(cfg["machine_network_cidr"])
    cfg.update(section_nodes(prev, cfg["platform_mode"], prefix))
    cfg.update(section_paths(prev))
    cfg.update(section_registry(prev))
    cfg.update(section_satellite(prev, cfg["base_domain"], cfg["org_name"]))
    cfg.update(section_ceph(prev))
    cfg.update(section_provider_network(prev))
    cfg.update(section_misc(prev))
    secret_values = section_secrets()

    print("\n== Writing files ==")
    save_config(cfg)  # non-secret only
    write_tfvars(cfg)
    write_secrets_env(secret_values)

    token_values = build_token_values(cfg)
    changed, remaining = substitute_tokens(token_values)
    print(f"-> substituted {len(token_values)} distinct values across {len(changed)} file(s):")
    for f in sorted(changed):
        print(f"     {f}")

    if remaining:
        print("\n!! Some __TOKEN__ placeholders had no answer and were left as-is - report this,")
        print("   it means scripts/configure.py's TOKEN_MAP_KEYS is missing an entry:")
        for f, t in sorted(remaining):
            print(f"     {f}: {t}")

    print("\n== Remaining manual judgment calls (not blanks - read and decide) ==")
    subprocess.run(
        ["grep", "-rn", "CHANGE_ME", *SUBSTITUTION_DIRS, "terraform/variables.tf", "terraform/providers.tf"],
        cwd=REPO_ROOT,
    )

    print(f"""
Done. Next steps:
  1. source {SECRETS_PATH.relative_to(REPO_ROOT)}
  2. bash infra-bootstrap/00-satellite-install.sh   (and 01-04, in order)
  3. cd terraform && terraform init && terraform apply
  4. ... continue per README.md section 6 (Order of execution)
""")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted - nothing was written past this point.")
        sys.exit(1)
