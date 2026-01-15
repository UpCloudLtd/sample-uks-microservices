########################################
# promtail configuration (ConfigMap)
########################################

locals {
  loki_url = "http://${data.terraform_remote_state.core.outputs.monitoring_private_ip}:3100/loki/api/v1/push"
}


resource "kubernetes_config_map" "promtail" {
  metadata {
    name      = "promtail-config"
    namespace = kubernetes_namespace.logging.metadata[0].name
  }

  data = {
    "promtail.yml" = <<-YAML
      server:
        http_listen_port: 9080
        grpc_listen_port: 0

      positions:
        filename: /run/promtail/positions.yaml

      clients:
        - url: ${local.loki_url}

      scrape_configs:
        - job_name: kubernetes-pods

          # Tail all container logs from the node
          static_configs:
            - targets:
                - localhost
              labels:
                job: kubernetes-pods
                __path__: /var/log/containers/*.log

          # Extract namespace, pod, container from the filename
          #
          # Example filename:
          #   /var/log/containers/
          #     coredns-54f559dc9-nht8q_kube-system_coredns-<hash>.log
          #
          # Regex groups:
          #   pod        = coredns-54f559dc9-nht8q
          #   namespace  = kube-system
          #   container  = coredns
          pipeline_stages:
            - regex:
                expression: "/var/log/containers/(?P<pod>[^_]+)_(?P<namespace>[^_]+)_(?P<container>[^-]+)-.*\\.log"
                source: filename

            # Turn extracted fields into labels
            - labels:
                namespace:
                pod:
                container:
    YAML
  }
}

########################################
# promtail DaemonSet
########################################

resource "kubernetes_daemonset" "promtail" {
  metadata {
    name      = "promtail"
    namespace = kubernetes_namespace.logging.metadata[0].name
    labels = {
      app = "promtail"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "promtail"
      }
    }

    template {
      metadata {
        labels = {
          app = "promtail"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.promtail.metadata[0].name

        container {
          name  = "promtail"
          image = "grafana/promtail:latest"

          args = [
            "-config.file=/etc/promtail/promtail.yml",
          ]

          resources {
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          # Config file
          volume_mount {
            name       = "config"
            mount_path = "/etc/promtail"
          }

          # Host logs (/var/log, /var/log/pods, /var/log/containers)
          volume_mount {
            name       = "varlog"
            mount_path = "/var/log"
          }

          # Positions directory
          volume_mount {
            name       = "positions"
            mount_path = "/run/promtail"
          }

          # Docker container logs (if needed by your runtime)
          volume_mount {
            name       = "varlibdockercontainers"
            mount_path = "/var/lib/docker/containers"
            read_only  = true
          }
        }

        # --- volumes ---

        # Promtail config
        volume {
          name = "config"

          config_map {
            name = kubernetes_config_map.promtail.metadata[0].name

            items {
              key  = "promtail.yml"
              path = "promtail.yml"
            }
          }
        }

        # Positions file (in-memory per-node)
        volume {
          name = "positions"

          empty_dir {}
        }

        # /var/log from host
        volume {
          name = "varlog"

          host_path {
            path = "/var/log"
          }
        }

        # /var/lib/docker/containers from host (if you need it)
        volume {
          name = "varlibdockercontainers"

          host_path {
            path = "/var/lib/docker/containers"
          }
        }
      }
    }
  }
}
