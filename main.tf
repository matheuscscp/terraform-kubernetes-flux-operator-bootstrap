locals {
  flux_instance_yaml = file(abspath(var.gitops_resources.flux_instance_path))
  flux_instance      = yamldecode(local.flux_instance_yaml)
  has_secrets_yaml   = trimspace(var.managed_resources.secrets_yaml) != ""
  prerequisite_files = { for idx, path in var.gitops_resources.prerequisites_paths : format("prerequisite-%03d.yaml", idx) => file(abspath(path)) }
  timeout_value      = tonumber(trimsuffix(trimsuffix(trimsuffix(var.timeout, "s"), "m"), "h"))
  timeout_unit       = substr(var.timeout, length(var.timeout) - 1, 1)
  timeout_seconds = local.timeout_unit == "s" ? local.timeout_value : (
    local.timeout_unit == "m" ? local.timeout_value * 60 : local.timeout_value * 3600
  )
}

resource "helm_release" "this" {
  name             = "flux-operator-bootstrap"
  namespace        = var.bootstrap_namespace
  chart            = "${path.module}/charts/flux-operator-bootstrap"
  create_namespace = true
  upgrade_install  = true
  wait             = true
  timeout          = local.timeout_seconds
  max_history      = 5

  values = [yamlencode({
    image = merge(var.image, {
      tag = coalesce(var.image.tag, local.module_version)
    })
    gitopsResources = {
      fluxInstance  = local.flux_instance_yaml
      prerequisites = local.prerequisite_files
    }
    timeout                    = var.timeout
    debugFaultInjectionMessage = var.debug_fault_injection_message
    applyTimestamp             = plantimestamp()
  })]

  set_wo = local.has_secrets_yaml ? [{
    name  = "managedResources.secretsYAML"
    value = var.managed_resources.secrets_yaml
    type  = "string"
  }] : []
  set_wo_revision = local.has_secrets_yaml ? parseint(formatdate("YYYYMMDDhhmmss", plantimestamp()), 10) : 0
}
