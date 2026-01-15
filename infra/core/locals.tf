locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Example tags/labels you might want to propagate via labels or metadata
  common_tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
  # S3 endpoint for UpCloud Object Storage (first/only endpoint entry)
  object_storage_s3_endpoint = "https://${one(upcloud_managed_object_storage.app.endpoint).domain_name}"

  # Dedicated bucket for Loki logs
  loki_bucket_name = upcloud_managed_object_storage_bucket.app["loki-logs"].name

   # Use provided creds if set; otherwise use the generated Object Storage user access key.
  object_storage_access_key_id     = coalesce(var.object_storage_access_key_id, upcloud_managed_object_storage_user_access_key.loki.access_key_id)
  object_storage_secret_access_key = coalesce(var.object_storage_secret_access_key, upcloud_managed_object_storage_user_access_key.loki.secret_access_key)

  # Extract IPs from created servers
  rabbitmq_private_ip   = try([for ni in upcloud_server.rabbitmq.network_interface : ni.ip_address if lower(ni.type) == "private"][0], null)
  rabbitmq_public_ip    = try([for ni in upcloud_server.rabbitmq.network_interface : ni.ip_address if lower(ni.type) == "public"][0], null)
  monitoring_private_ip = try([for ni in upcloud_server.monitoring.network_interface : ni.ip_address if lower(ni.type) == "private"][0], null)
  monitoring_public_ip  = try([for ni in upcloud_server.monitoring.network_interface : ni.ip_address if lower(ni.type) == "public"][0], null)

  # Fail-fast checks (to avoid null IPs in other locals/outputs)
  _require_rabbitmq_private   = local.rabbitmq_private_ip   != null ? true : tobool("missing rabbitmq private ip")
  _require_monitoring_private = local.monitoring_private_ip != null ? true : tobool("missing monitoring private ip")
  _require_monitoring_public  = local.monitoring_public_ip  != null ? true : tobool("missing monitoring public ip")
}
