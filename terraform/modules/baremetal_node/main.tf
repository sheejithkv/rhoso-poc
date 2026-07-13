# Generic bare-metal/VM node module, now with two concrete implementations instead of a
# placeholder. Both wire up TWO NICs per node (nic1_mac/nic2_mac) so every node - master or
# worker - boots with its primary interface already bonded (var.bonding in the root module),
# matching the "bonding enabled on node NICs" requirement end to end, not just on the RHOSO
# isolated-network VLANs applied later by manifests/02-networking/.
#
# Only the block matching var.platform_mode actually creates anything (count = 0/1 guards).
# See providers.tf for the "why two implementations" rationale and the schema-verification
# caveat - these are written from each provider's documented examples, not executed here.

# ---------------------------------------------------------------------------
# Option A: real bare metal (or a bare-metal cloud) via Redfish virtual media boot.
# Schema verified against dell/terraform-provider-redfish v1.6.1's own published examples
# (github.com/dell/terraform-provider-redfish, examples/resources/redfish_virtual_media and
# .../redfish_power) - two fields in an earlier draft of this module did not actually exist in
# the real provider (image cannot be a local file:// path - the BMC fetches it itself over
# HTTP/HTTPS/NFS/etc, so it must already be hosted somewhere network-reachable FROM the BMC's
# management network; and the power resource's field is desired_power_action, not
# desired_power_state) - fixed here after checking against the provider's actual source.
# Only the primary/PXE-capable NIC's MAC needs to be known to the installer beforehand
# (nic1_mac, matched against agent-config.yaml's hosts[].interfaces[].macAddress); the bond's
# second member (nic2_mac) is wired up by the OS itself from the agent-config.yaml network
# config once it boots - Redfish doesn't need to know about it.
# ---------------------------------------------------------------------------
resource "redfish_virtual_media" "this" {
  count = var.platform_mode == "redfish" ? 1 : 0
  redfish_server {
    user     = var.bmc_username
    password = var.bmc_password
    endpoint = var.bmc_address
  }
  # CHANGE_ME: must be an HTTP(S)/NFS/CIFS URL the BMC itself can reach - NOT a local path on
  # the machine running terraform. Simplest option: serve terraform/generated/agent.x86_64.iso
  # from the same host as infra-bootstrap's mirror registry (or any small HTTP server) and point
  # this at it, e.g. "http://quay-mirror.CHANGE_ME.example.com/agent-isos/agent.x86_64.iso".
  image                  = var.boot_iso_url
  transfer_method        = "Stream"
  transfer_protocol_type = "HTTP"
  write_protected        = true
}

resource "redfish_power" "this" {
  count = var.platform_mode == "redfish" ? 1 : 0
  redfish_server {
    user     = var.bmc_username
    password = var.bmc_password
    endpoint = var.bmc_address
  }
  desired_power_action = "ForceOn"
  maximum_wait_time    = 120
  check_interval       = 10
  depends_on           = [redfish_virtual_media.this]
}

# ---------------------------------------------------------------------------
# Option B: libvirt/KVM VM with two NICs on the same bridge (simulating two physical uplinks
# for the in-guest bond0) - this is what makes the repo actually runnable on "any cloud": spin
# up one nested-virt-capable VM anywhere, install libvirt+bridge-utils on it, point
# libvirt_uri/libvirt_network_bridge at it, and every node in var.nodes becomes a KVM guest.
# ---------------------------------------------------------------------------
resource "libvirt_volume" "this" {
  count  = var.platform_mode == "libvirt" ? 1 : 0
  name   = "${var.name}.qcow2"
  pool   = var.libvirt_storage_pool
  size   = var.disk_gb * 1024 * 1024 * 1024
  format = "qcow2"
}

resource "libvirt_domain" "this" {
  count  = var.platform_mode == "libvirt" ? 1 : 0
  name   = var.name
  memory = var.ram_gb * 1024
  vcpu   = var.cpu_cores

  disk {
    volume_id = libvirt_volume.this[0].id
  }
  disk {
    file = var.boot_iso # agent.x86_64.iso, attached as a CDROM
  }

  # Two interfaces on the SAME bridge, distinct MACs -> in-guest NetworkManager/nmstate bonds
  # them into bond0 per templates/agent-config.yaml.tmpl's per-host networkConfig.
  network_interface {
    bridge = var.libvirt_network_bridge
    mac    = var.nic1_mac
  }
  network_interface {
    bridge = var.libvirt_network_bridge
    mac    = var.nic2_mac
  }

  boot_device {
    dev = ["cdrom", "hd"]
  }

  console {
    type        = "pty"
    target_port = "0"
  }

  cpu {
    mode = "host-passthrough" # required: Nova/libvirt nested guests on the eventual Compute node need VT-x/AMD-V visible
  }
}

# ---------------------------------------------------------------------------
# Always written regardless of platform_mode - a flat audit record of what this run intended to
# provision, useful for `grep`-ing node/MAC/role mappings without parsing .tfstate.
# ---------------------------------------------------------------------------
resource "local_file" "node_manifest" {
  filename = "${path.root}/generated/nodes/${var.name}.json"
  content = jsonencode({
    name          = var.name
    role          = var.role
    ip_address    = var.ip_address
    nic1_mac      = var.nic1_mac
    nic2_mac      = var.nic2_mac
    bmc_address   = var.bmc_address
    platform_mode = var.platform_mode
    cpu_cores     = var.cpu_cores
    ram_gb        = var.ram_gb
    disk_gb       = var.disk_gb
  })
}
