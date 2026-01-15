# You can generate kubeconfig for UKS via UpCloud Hub or via the upcloud_kubernetes_cluster resource.
# Here we assume you store it on disk and pass its path in a variable.

provider "kubernetes" {
  config_path = data.terraform_remote_state.core.outputs.uks_kubeconfig_path
}

provider "helm" {
  kubernetes={
    config_path = data.terraform_remote_state.core.outputs.uks_kubeconfig_path
  }
}


########################################
# Namespace for logging
########################################

resource "kubernetes_namespace" "logging" {
  metadata {
    name = "logging"
  }
}

########################################
# ServiceAccount for promtail
########################################

resource "kubernetes_service_account" "promtail" {
  metadata {
    name      = "promtail"
    namespace = kubernetes_namespace.logging.metadata[0].name
  }
}

########################################
# RBAC for promtail (new unique names)
########################################

resource "kubernetes_cluster_role" "promtail_logs" {
  metadata {
    name = "promtail-logs" # <— NEW, avoids conflict with existing "promtail"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "nodes", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "promtail_logs" {
  metadata {
    name = "promtail-logs-binding" # <— NEW name, also avoid clashes
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.promtail_logs.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.promtail.metadata[0].name
    namespace = kubernetes_namespace.logging.metadata[0].name
  }
}
