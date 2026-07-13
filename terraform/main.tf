locals {
  masters = [for n in var.nodes : n if n.role == "master"]
  workers = [for n in var.nodes : n if n.role == "worker"]

  # The Agent-based Installer has no separate bootstrap node: one master temporarily runs the
  # assisted-service and coordinates bootstrap, then reboots and joins as a normal master.
  # rendezvousIP must be that master's own IP (see docs referenced in
  # templates/agent-config.yaml.tmpl) - previously this pointed at var.network.gateway, which is
  # not a node at all and would have failed cluster bring-up.
  rendezvous_ip = local.masters[0].ip_address
}

module "baremetal_node" {
  source   = "./modules/baremetal_node"
  for_each = { for n in var.nodes : n.name => n }

  platform_mode = var.platform_mode
  name          = each.value.name
  role          = each.value.role
  ip_address    = each.value.ip_address
  nic1_mac      = each.value.nic1_mac
  nic2_mac      = each.value.nic2_mac
  bmc_address   = each.value.bmc_address
  bmc_username  = each.value.bmc_username
  bmc_password  = each.value.bmc_password
  boot_iso      = "${path.module}/generated/agent.x86_64.iso" # produced by openshift-install agent create image
  boot_iso_url  = var.boot_iso_http_url                       # only read when platform_mode = "redfish"
  cpu_cores     = each.value.role == "master" ? var.control_plane_node_spec.cpu_cores : var.worker_node_spec.cpu_cores
  ram_gb        = each.value.role == "master" ? var.control_plane_node_spec.ram_gb : var.worker_node_spec.ram_gb
  disk_gb       = each.value.role == "master" ? var.control_plane_node_spec.disk_gb : var.worker_node_spec.disk_gb

  libvirt_storage_pool   = var.libvirt_storage_pool
  libvirt_network_bridge = var.libvirt_network_bridge
}

resource "local_file" "install_config" {
  filename = "${path.module}/generated/install-config.yaml"
  content = templatefile("${path.module}/templates/install-config.yaml.tmpl", {
    cluster_name   = var.cluster_name
    base_domain    = var.base_domain
    pull_secret    = file(var.pull_secret_path)
    ssh_key        = file(var.ssh_public_key_path)
    api_vip        = var.network.api_vip
    ingress_vip    = var.network.ingress_vip
    machine_cidr   = var.network.machine_network_cidr
    registry_host  = var.disconnected_registry.host
    registry_port  = var.disconnected_registry.port
    mirror_ca_cert = file(var.disconnected_registry.ca_cert_path)
  })
}

resource "local_file" "agent_config" {
  filename = "${path.module}/generated/agent-config.yaml"
  content = templatefile("${path.module}/templates/agent-config.yaml.tmpl", {
    cluster_name  = var.cluster_name
    gateway       = var.network.gateway
    dns_servers   = var.network.dns_servers
    rendezvous_ip = local.rendezvous_ip
    nodes         = var.nodes
    bonding       = var.bonding
    prefix_length = split("/", var.network.machine_network_cidr)[1]
  })
}
