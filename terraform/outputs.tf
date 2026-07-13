output "install_config_path" {
  value = local_file.install_config.filename
}
output "agent_config_path" {
  value = local_file.agent_config.filename
}
output "next_steps" {
  value = <<-EOT
    0. (should already be done) infra-bootstrap/00-03 - Satellite + mirror registry populated,
       additionalTrustBundle/imageContentSources above filled in from their output.
    1. openshift-install agent create image --dir ${path.module}/generated --log-level=info
    2. platform_mode=${var.platform_mode}: `terraform apply` already booted every node from
       generated/agent.x86_64.iso via that provider. If you switched to a provider this repo
       doesn't wire up yet, attach the ISO to each BMC/VM manually instead.
    3. openshift-install agent wait-for bootstrap-complete --dir ${path.module}/generated --log-level=info
    4. openshift-install agent wait-for install-complete   --dir ${path.module}/generated --log-level=info
    5. export KUBECONFIG=${path.module}/generated/auth/kubeconfig
    6. cd .. && bash scripts/deploy-all.sh
  EOT
}
