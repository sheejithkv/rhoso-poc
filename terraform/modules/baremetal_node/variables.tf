variable "platform_mode" {
  type        = string
  description = "redfish | libvirt | vsphere - selects which resource block below actually runs"
}

variable "name" { type = string }
variable "role" { type = string } # master | worker
variable "ip_address" { type = string }

variable "nic1_mac" { type = string }
variable "nic2_mac" { type = string }

variable "bmc_address" {
  type    = string
  default = ""
}
variable "bmc_username" {
  type    = string
  default = ""
}
variable "bmc_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "boot_iso" { type = string }
variable "boot_iso_url" {
  type        = string
  default     = ""
  description = "HTTP(S) URL to the agent ISO, reachable FROM the BMC's management network - only used when platform_mode = \"redfish\". See main.tf's redfish_virtual_media comment."
}
variable "cpu_cores" { type = number }
variable "ram_gb" { type = number }
variable "disk_gb" { type = number }

variable "libvirt_storage_pool" {
  type    = string
  default = "default"
}
variable "libvirt_network_bridge" {
  type    = string
  default = "br0"
}
