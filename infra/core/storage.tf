###################################
# Managed Object Storage + buckets
###################################

# Managed Object Storage service
resource "upcloud_managed_object_storage" "app" {
  name              = var.object_storage_name
  region            = var.object_storage_region
  configured_status = "started"

  # Public access over the internet
  network {
    family = "IPv4"
    name   = "public-access"
    type   = "public"
  }

  labels = {
    project     = var.project_name
    environment = var.environment
    component   = "object-storage"
    managed_by  = "terraform"
  }
}

# Buckets within the object storage service
resource "upcloud_managed_object_storage_bucket" "app" {
  for_each     = var.object_storage_bucket_names
  service_uuid = upcloud_managed_object_storage.app.id
  name         = each.value
}

resource "upcloud_managed_object_storage_user" "loki" {
  service_uuid = upcloud_managed_object_storage.app.id
  username     = "${local.name_prefix}-loki"
}

resource "upcloud_managed_object_storage_user_policy" "loki_s3" {
  username     = upcloud_managed_object_storage_user.loki.username
  service_uuid = upcloud_managed_object_storage.app.id
  name         = "ECSS3FullAccess"
}

resource "upcloud_managed_object_storage_user_policy" "loki_iam" {
  username     = upcloud_managed_object_storage_user.loki.username
  service_uuid = upcloud_managed_object_storage.app.id
  name         = "IAMFullAccess"
}

resource "upcloud_managed_object_storage_user_access_key" "loki" {
  service_uuid = upcloud_managed_object_storage.app.id
  username     = upcloud_managed_object_storage_user.loki.username
  status       = "Active"
}


