locals {
  flux_instance        = yamldecode(var.flux_instance_yaml)
  bootstrap_namespace  = var.bootstrap_namespace
  config_map_name      = "flux-operator-bootstrap"
  service_account_name = "flux-operator-bootstrap"
  cluster_role_binding = "flux-operator-bootstrap-${local.bootstrap_namespace}"
  job_name             = "flux-operator-bootstrap"
  image                = "${var.image.repository}:${var.image.tag}"
  ttl_value            = tonumber(trimsuffix(trimsuffix(trimsuffix(var.ttl_after_finished, "s"), "m"), "h"))
  ttl_unit             = substr(var.ttl_after_finished, length(var.ttl_after_finished) - 1, 1)
  ttl_after_finished_seconds = local.ttl_unit == "s" ? local.ttl_value : (
    local.ttl_unit == "m" ? local.ttl_value * 60 : local.ttl_value * 3600
  )
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.bootstrap_namespace
  }
}

resource "kubernetes_service_account_v1" "this" {
  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = local.service_account_name
    namespace = local.bootstrap_namespace
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  metadata {
    name = local.cluster_role_binding
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this.metadata[0].name
    namespace = kubernetes_service_account_v1.this.metadata[0].namespace
  }
}

resource "kubernetes_config_map_v1" "this" {
  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = local.config_map_name
    namespace = local.bootstrap_namespace
  }

  data = {
    "flux-instance.yaml" = var.flux_instance_yaml
  }
}

resource "kubernetes_job_v1" "this" {
  depends_on = [
    kubernetes_cluster_role_binding_v1.this,
    kubernetes_config_map_v1.this,
  ]

  wait_for_completion = var.wait && !var.use_kubectl_watcher

  metadata {
    name      = local.job_name
    namespace = local.bootstrap_namespace
  }

  spec {
    backoff_limit              = 0
    ttl_seconds_after_finished = var.wait && !var.use_kubectl_watcher ? local.ttl_after_finished_seconds : null

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account_v1.this.metadata[0].name
        restart_policy       = "Never"

        container {
          name              = "bootstrap"
          image             = local.image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "FLUX_INSTANCE_FILE"
            value = "/bootstrap/flux-instance.yaml"
          }

          env {
            name  = "WAIT_FOR_INSTANCE"
            value = tostring(var.wait)
          }

          env {
            name  = "TIMEOUT"
            value = var.timeout
          }

          env {
            name  = "BOOTSTRAP_NAMESPACE"
            value = local.bootstrap_namespace
          }

          env {
            name  = "SERVICE_ACCOUNT_NAME"
            value = kubernetes_service_account_v1.this.metadata[0].name
          }

          env {
            name  = "CLUSTER_ROLE_BINDING_NAME"
            value = kubernetes_cluster_role_binding_v1.this.metadata[0].name
          }

          env {
            name  = "DEBUG_FAULT_INJECTION_MESSAGE"
            value = var.debug_fault_injection_message
          }

          volume_mount {
            name       = "bootstrap-manifest"
            mount_path = "/bootstrap"
            read_only  = true
          }
        }

        volume {
          name = "bootstrap-manifest"

          config_map {
            name = kubernetes_config_map_v1.this.metadata[0].name
          }
        }
      }
    }
  }

  timeouts {
    create = var.timeout
    update = var.timeout
  }
}

resource "null_resource" "watch_job" {
  count = var.wait && var.use_kubectl_watcher ? 1 : 0

  depends_on = [kubernetes_job_v1.this]

  triggers = {
    job_name             = kubernetes_job_v1.this.metadata[0].name
    job_namespace        = kubernetes_job_v1.this.metadata[0].namespace
    job_uid              = kubernetes_job_v1.this.metadata[0].uid
    timeout              = var.timeout
    bootstrap_script_sha = filesha256("${path.module}/scripts/watch-job.sh")
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = "bash ${path.module}/scripts/watch-job.sh"

    environment = {
      JOB_NAME                          = kubernetes_job_v1.this.metadata[0].name
      JOB_NAMESPACE                     = kubernetes_job_v1.this.metadata[0].namespace
      TIMEOUT                           = var.timeout
      KUBERNETES_HOST                   = var.kubernetes_host
      KUBERNETES_CLUSTER_CA_CERTIFICATE = var.kubernetes_cluster_ca_certificate
      KUBERNETES_TOKEN                  = var.kubernetes_token
    }
  }

  lifecycle {
    replace_triggered_by = [kubernetes_job_v1.this]
  }
}
