#########################################
### kube state metrics node port service#
##########################################

resource "kubernetes_service" "kube_state_metrics_nodeport" {
  metadata {
    name      = "kube-state-metrics-nodeport"
    namespace = "kube-system"
    labels = {
      app = "kube-state-metrics"
    }
  }

  spec {
    type = "NodePort"

    selector = {
      "app.kubernetes.io/name" = "kube-state-metrics"
    }

    port {
      name        = "http-metrics"
      port        = 8080
      target_port = 8080
      node_port   = 31081
    }
  }
}
