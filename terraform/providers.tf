## Provider block - now driven by var.platform_mode instead of a single hardcoded choice.
##
## All three providers are declared so `terraform init` always works the same way regardless
## of platform_mode; only the one selected by platform_mode actually gets resources created
## against it (see modules/baremetal_node/main.tf's `count = var.platform_mode == "..." ? 1 : 0`
## guards). Switching platforms later means changing platform_mode in variables.tf, not
## rewriting this file.
##
## IMPORTANT: this sandbox cannot reach registry.terraform.io to run `terraform init`/`validate`
## against these providers, so the resource schemas below (attribute names in
## modules/baremetal_node/main.tf) are written from each provider's documented examples but are
## NOT executed here. Before your first real `terraform apply`, run:
##   terraform init && terraform providers schema -json | jq '.provider_schemas'
## and diff the actual installed schema against what's used here - provider APIs do change
## between major versions.

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    # --- redfish: real bare metal, any vendor's Redfish-conformant BMC (Dell iDRAC9+,
    #     HPE iLO5+, Lenovo XCC, Cisco CIMC, Supermicro X12+, or a bare-metal cloud like
    #     Equinix Metal that exposes Redfish) - the "any bare-metal environment" path.
    redfish = {
      source  = "dell/redfish"
      version = "~> 1.4"
    }

    # --- libvirt: KVM VMs on a single Linux host with nested virtualization - works on a spare
    #     server OR a nested-virt-enabled VM on any cloud (GCP n2/c2 with nested virt, Azure
    #     Ddsv5/Edsv5, on-prem ESXi with "Expose hardware assisted virtualization" checked) -
    #     the "any cloud, no physical hardware available" path.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }

    # --- vsphere: VM-based POC on an existing VMware private cloud.
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "redfish" {}

provider "libvirt" {
  uri = var.libvirt_uri
}

provider "vsphere" {
  user                 = var.vsphere_user     # CHANGE_ME
  password             = var.vsphere_password # CHANGE_ME
  vsphere_server       = var.vsphere_server   # CHANGE_ME
  allow_unverified_ssl = true
}

# Declared here (rather than variables.tf) because they're only meaningful for platform_mode =
# "vsphere" and default to empty so `terraform plan` doesn't fail on unrelated platform_modes.
variable "vsphere_user" {
  type    = string
  default = ""
}
variable "vsphere_password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "vsphere_server" {
  type    = string
  default = ""
}
