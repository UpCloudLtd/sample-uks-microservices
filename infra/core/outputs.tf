########################################
# Managed Network outputs
########################################

output "core_router_id" {
  description = "UUID of the core SDN router."
  value       = upcloud_router.core.id
}

output "core_nat_gateway_id" {
  description = "UUID of the NAT Gateway attached to the core router."
  value       = upcloud_gateway.core_nat.id
}

output "core_sdn_network_id" {
  description = "UUID of the core SDN network used for UKS and VMs."
  value       = upcloud_network.core_sdn.id
}

output "core_sdn_cidr" {
  description = "CIDR range of the core SDN network."
  value       = var.core_sdn_cidr
}

############################################
# Outputs UKS cluster info
############################################

output "uks_cluster_id" {
  description = "ID of the UpCloud Kubernetes cluster"
  value       = upcloud_kubernetes_cluster.core.id
}

output "uks_cluster_name" {
  description = "Name of the UpCloud Kubernetes cluster"
  value       = upcloud_kubernetes_cluster.core.name
}

output "uks_node_groups" {
  description = "Names and plans of the UKS node groups"
  value = {
    general = {
      name = upcloud_kubernetes_node_group.general.name
      plan = upcloud_kubernetes_node_group.general.plan
      size = upcloud_kubernetes_node_group.general.node_count
    }
    # compute = {
    #   name = upcloud_kubernetes_node_group.compute.name
    #   plan = upcloud_kubernetes_node_group.compute.plan
    #   size = upcloud_kubernetes_node_group.compute.node_count
    # }
  }
}

output "uks_kubeconfig_path" {
  description = "Path to the generated kubeconfig file for this cluster"
  value       = abspath(local_file.kubeconfig_uks.filename)
}


########################################
# Managed PostgreSQL outputs
########################################

output "postgres_connection" {
  description = "Connection details for the managed PostgreSQL instance."
  sensitive   = true

  value = {
    host     = upcloud_managed_database_postgresql.app.service_host
    port     = upcloud_managed_database_postgresql.app.service_port
    database = upcloud_managed_database_postgresql.app.primary_database
    username = upcloud_managed_database_postgresql.app.service_username
    password = upcloud_managed_database_postgresql.app.service_password
    sslmode  = "require"
  }
}

output "postgres_connection_uri" {
  description = "PostgreSQL connection URI for the managed database (primary service user)."
  sensitive   = true
  value       = upcloud_managed_database_postgresql.app.service_uri
}

# APP focused DSN option URL
output "postgres_app_dsn" {
  description = "PostgreSQL DSN for application workloads."
  sensitive   = true

  value = "postgresql://${upcloud_managed_database_postgresql.app.service_username}:${upcloud_managed_database_postgresql.app.service_password}@${upcloud_managed_database_postgresql.app.service_host}:${upcloud_managed_database_postgresql.app.service_port}/${upcloud_managed_database_postgresql.app.primary_database}?sslmode=require"
}


########################################
# Managed Object Storage outputs
########################################

output "object_storage_endpoint" {
  description = "Public S3-compatible endpoint for the Managed Object Storage service."
  value       = upcloud_managed_object_storage.app.endpoint
}

# Since buckets use for_each, we need a `for` expression
# to collect their attributes into a single value.
output "object_storage_buckets" {
  description = "Buckets created in the Managed Object Storage service."
  value = {
    for bucket_name, bucket in upcloud_managed_object_storage_bucket.app :
    bucket_name => {
      name = bucket.name
      id   = bucket.id
    }
  }
}

output "object_storage_access_credentials" {
  sensitive = true
  value = {
    access_key_id     = upcloud_managed_object_storage_user_access_key.loki.access_key_id
    secret_access_key = upcloud_managed_object_storage_user_access_key.loki.secret_access_key
  }
}


########################################
# Self Managed Rabbit MQ outputs       #
########################################
output "rabbitmq_username" {
  description = "RabbitMQ application username for UKS workloads."
  value       = var.rabbitmq_username
}

output "rabbitmq_password" {
  description = "RabbitMQ application password for UKS workloads."
  value       = var.rabbitmq_password
  sensitive   = true
}

output "rabbitmq_private_ip" {
  description = "Private IP of the RabbitMQ VM on core SDN."
  value       = local.rabbitmq_private_ip
}

output "rabbitmq_public_ip" {
  value = local.rabbitmq_public_ip
}

output "rabbitmq_amqp_url" {
  description = "AMQP URL for UKS workloads to connect to RabbitMQ."
  sensitive   = true

  value = "amqp://${var.rabbitmq_username}:${var.rabbitmq_password}@${local.rabbitmq_private_ip}:5672/"
}

########################################
# Self Managed Monitoting/Logs outputs #
########################################


output "grafana_url" {
  description = "Grafana URL (HTTP) on the monitoring VM."
  value       = "http://${local.monitoring_public_ip}:3000"
}

output "postgres_prometheus_dsn" {
  description = "DSN used by postgres-exporter to scrape Managed PostgreSQL."
  value       = "postgresql://${upcloud_managed_database_postgresql.app.service_username}:${upcloud_managed_database_postgresql.app.service_password}@${upcloud_managed_database_postgresql.app.service_host}:${upcloud_managed_database_postgresql.app.service_port}/${upcloud_managed_database_postgresql.app.primary_database}?sslmode=require"
  sensitive   = true
}
output "grafana_admin_password" {
  description = "Grafana admin password."
  value       = var.grafana_admin_password
  sensitive   = true
}

output "monitoring_private_ip" {
  description = "Private IP of monitoring VM in the core SDN network."
  value       = local.monitoring_private_ip
}

output "monitoring_public_ip" {
  description = "Public IP of monitoring VM (internet-facing)."
  value       = local.monitoring_public_ip
}
