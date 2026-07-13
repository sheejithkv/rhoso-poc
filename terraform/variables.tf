variable "cluster_name" {
  description = "OpenShift cluster name"
  type        = string
  default     = "rhoso-poc" # CHANGE_ME
}

variable "base_domain" {
  description = "DNS base domain, cluster will be <cluster_name>.<base_domain>"
  type        = string
  default     = "CHANGE_ME.example.com"
}

variable "ocp_version" {
  description = "OpenShift version to install"
  type        = string
  default     = "4.18"
}

variable "pull_secret_path" {
  description = "Path to local file containing your Red Hat pull secret (from console.redhat.com), merged with the disconnected mirror auth by manifests/00-prereqs/04-pull-secret-patch.sh after install"
  type        = string
  default     = "CHANGE_ME/pull-secret.json"
}

variable "ssh_public_key_path" {
  description = "SSH public key injected into core/RHEL nodes"
  type        = string
  default     = "~/.ssh/id_rsa.pub" # CHANGE_ME if different
}

variable "platform_mode" {
  description = <<-EOT
    Selects which provider block in providers.tf actually provisions nodes:
      "redfish" - real bare metal or a bare-metal cloud that exposes a Redfish BMC
                  (on-prem iDRAC/iLO/XCC/CIMC, Equinix Metal, etc.) - this is the
                  "any bare-metal environment" path.
      "libvirt" - KVM/libvirt VMs on a single Linux host, anywhere (a spare server,
                  or a nested-virtualization-enabled VM on any cloud: GCP/Azure/on-prem
                  ESXi with nested HV) - this is the "any cloud" / no-hardware-available path.
                  This is what the RHOSO/Metal3 upstream community itself uses for CI, usually
                  paired with sushy-tools to expose the libvirt VMs over a virtual Redfish
                  endpoint so the SAME agent-config.yaml host.bmc automation works either way.
      "vsphere" - VM-based POC on an existing VMware private cloud.
    Only ONE of these is actually instantiated (see modules/baremetal_node/main.tf's `count`
    guards); the other provider blocks stay declared-but-unused so switching later is a one-line
    change here, not a rewrite.
  EOT
  type        = string
  default     = "libvirt" # CHANGE_ME - "redfish" once real hardware/BMC details are confirmed
  validation {
    condition     = contains(["redfish", "libvirt", "vsphere"], var.platform_mode)
    error_message = "platform_mode must be one of: redfish, libvirt, vsphere."
  }
}

variable "control_plane_count" {
  description = "Number of OpenShift control plane (master) nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of OpenShift worker nodes (2 minimum for RHOSO control plane pods, 1+ dedicated as Compute data-plane node)"
  type        = number
  default     = 3
}

variable "control_plane_node_spec" {
  description = "CPU/RAM/Disk per control plane node (POC minimum per Red Hat sizing guidance)"
  type = object({
    cpu_cores = number
    ram_gb    = number
    disk_gb   = number
  })
  default = {
    cpu_cores = 8
    ram_gb    = 32
    disk_gb   = 120
  }
}

variable "worker_node_spec" {
  description = "CPU/RAM/Disk per worker node. The RHOSO Compute node needs nested virt (VT-x/AMD-V) enabled in BIOS/hypervisor."
  type = object({
    cpu_cores = number
    ram_gb    = number
    disk_gb   = number
  })
  default = {
    cpu_cores = 16
    ram_gb    = 64
    disk_gb   = 250
  }
}

variable "bonding" {
  description = <<-EOT
    CHANGE_ME: bonding config applied to every node's primary NIC pair (nic1+nic2), both at
    OpenShift install time (terraform/templates/agent-config.yaml.tmpl -> bond0) and again on
    top of it for the RHOSO isolated-network VLANs (manifests/02-networking/, vlan base-iface
    becomes bond0 instead of a single physical NIC). Supported modes match what OpenShift's
    NMState/kernel bonding driver supports: active-backup, balance-xor, 802.3ad, balance-tlb,
    balance-alb. 802.3ad (LACP) needs matching switch-side port-channel/LACP config; if your
    switches don't do LACP, use active-backup instead - it needs zero switch config.

    member1_name/member2_name must be the REAL kernel/udev interface names nmstate will see at
    boot (e.g. "eno1"/"eno2" on typical Dell/HPE rack servers, "ens1f0"/"ens1f1" on some NIC
    firmware, "enp1s0"/"enp2s0" on most libvirt/KVM guests) - NOT the abstract nic1/nic2 aliases
    used later for the RHOSO Compute node's os-net-config template
    (manifests/05-data-plane/02-nodeset-compute.yaml), which is a different tool that DOES
    support that numbered-alias abstraction. Boot one node manually first (or check your
    hypervisor's default NIC naming) if unsure, then set this once - it's assumed identical
    across all nodes, which holds for homogeneous POC hardware/hypervisor images.
  EOT
  type = object({
    interface_name = string
    member1_name   = string
    member2_name   = string
    mode           = string
    miimon_ms      = number
  })
  default = {
    interface_name = "bond0"
    member1_name   = "eno1"    # CHANGE_ME - see note above
    member2_name   = "eno2"    # CHANGE_ME
    mode           = "802.3ad" # CHANGE_ME to "active-backup" if switches don't support LACP
    miimon_ms      = 140
  }
  validation {
    condition     = contains(["active-backup", "balance-xor", "802.3ad", "balance-tlb", "balance-alb"], var.bonding.mode)
    error_message = "bonding.mode must be one of: active-backup, balance-xor, 802.3ad, balance-tlb, balance-alb."
  }
}

variable "nodes" {
  description = <<-EOT
    CHANGE_ME: one entry per OpenShift node - masters and workers only.
    role must be one of: master, worker  (NOT "bootstrap" - the Agent-based Installer has no
    discrete bootstrap node/VM; one master temporarily acts as the rendezvous/bootstrap host and
    then rejoins as a normal master, see main.tf's rendezvous_ip local and
    templates/agent-config.yaml.tmpl).
    nic1_mac/nic2_mac: two NICs per node, bonded into `bond0` (see var.bonding) for redundancy on
    every node's primary/machine-network traffic, not just the RHOSO isolated networks.
    ip_address: static IP on bond0, must be inside var.network.machine_network_cidr.
  EOT
  type = list(object({
    name         = string
    role         = string # master | worker
    ip_address   = string # CHANGE_ME - static IP on the bonded primary interface
    nic1_mac     = string # CHANGE_ME - first bond member
    nic2_mac     = string # CHANGE_ME - second bond member
    bmc_address  = string # CHANGE_ME - e.g. redfish-virtualmedia+https://10.0.0.10/redfish/v1/Systems/1 (redfish mode only)
    bmc_username = string # CHANGE_ME (redfish mode only)
    bmc_password = string # CHANGE_ME (redfish mode only; use TF_VAR_ or a secrets backend, do not commit)
  }))
  default = [
    { name = "master-0", role = "master", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
    { name = "master-1", role = "master", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
    { name = "master-2", role = "master", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
    { name = "worker-0", role = "worker", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
    { name = "worker-1", role = "worker", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
    { name = "compute-0", role = "worker", ip_address = "CHANGE_ME", nic1_mac = "CHANGE_ME", nic2_mac = "CHANGE_ME", bmc_address = "CHANGE_ME", bmc_username = "CHANGE_ME", bmc_password = "CHANGE_ME" },
  ]
  validation {
    condition     = alltrue([for n in var.nodes : contains(["master", "worker"], n.role)])
    error_message = "Every node role must be \"master\" or \"worker\" - the Agent-based Installer has no separate bootstrap role."
  }
}

variable "network" {
  description = "CHANGE_ME: cluster networking"
  type = object({
    machine_network_cidr = string
    api_vip              = string
    ingress_vip          = string
    dns_servers          = list(string)
    ntp_servers          = list(string)
    gateway              = string
  })
  default = {
    machine_network_cidr = "10.10.10.0/24" # CHANGE_ME
    api_vip              = "10.10.10.5"    # CHANGE_ME
    ingress_vip          = "10.10.10.6"    # CHANGE_ME
    dns_servers          = ["10.10.10.1"]  # CHANGE_ME
    ntp_servers          = ["10.10.10.1"]  # CHANGE_ME
    gateway              = "10.10.10.1"    # CHANGE_ME
  }
}

variable "disconnected_registry" {
  description = "CHANGE_ME: mirror registry details from infra-bootstrap/02-mirror-registry-install.sh"
  type = object({
    host         = string
    port         = number
    ca_cert_path = string
  })
  default = {
    host         = "quay-mirror.CHANGE_ME.example.com"
    port         = 8443
    ca_cert_path = "CHANGE_ME/mirror-ca.crt" # e.g. ~/quay-install/quay-rootCA/rootCA.pem from 02-mirror-registry-install.sh
  }
}

variable "boot_iso_http_url" {
  description = "CHANGE_ME: HTTP(S) URL where generated/agent.x86_64.iso is hosted, reachable FROM every node's BMC management network - only used when platform_mode = \"redfish\" (a BMC fetches virtual media over the network, it cannot read a local path on the machine running terraform). E.g. host it alongside infra-bootstrap's mirror registry, or any small HTTP server on the same management network as the BMCs."
  type        = string
  default     = "http://CHANGE_ME.example.com/agent-isos/agent.x86_64.iso"
}

variable "libvirt_uri" {
  description = "libvirt connection URI, only used when platform_mode = \"libvirt\". qemu:///system for local, qemu+ssh://user@host/system for remote."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_storage_pool" {
  description = "libvirt storage pool name for node disks, only used when platform_mode = \"libvirt\""
  type        = string
  default     = "default"
}

variable "libvirt_network_bridge" {
  description = "Pre-existing Linux bridge on the libvirt host that both bond0 member NICs attach to, only used when platform_mode = \"libvirt\". Two libvirt_domain network_interface blocks against the same bridge simulate two physical NICs for the in-guest bond."
  type        = string
  default     = "br0" # CHANGE_ME
}
