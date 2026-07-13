# WHAT: Child modules that use provider-specific resource types must declare their OWN
#       required_providers with matching source addresses - it is not enough for only the root
#       module's providers.tf to declare `dell/redfish` / `dmacvicar/libvirt`. Without this file,
#       `tofu init` (confirmed against a real OpenTofu 1.12.3 binary, not just eyeballed) resolves
#       the redfish_* / libvirt_* resource types used in main.tf to the DEFAULT hashicorp/
#       namespace (hashicorp/redfish, hashicorp/libvirt) instead of the real providers, which do
#       not exist there and fail to resolve.
terraform {
  required_providers {
    redfish = {
      source = "dell/redfish"
    }
    libvirt = {
      source = "dmacvicar/libvirt"
    }
    local = {
      source = "hashicorp/local"
    }
  }
}
