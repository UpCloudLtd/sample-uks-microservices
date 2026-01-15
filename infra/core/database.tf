###################################
# Managed PostgreSQL (HA)
###################################

resource "upcloud_managed_database_postgresql" "app" {
  name  = "${local.name_prefix}-postgres"
  plan  = var.db_plan
  zone  = var.upcloud_zone
  title = "postgres"

  # Optional but recommended: keep DB private-only by default.
  # You can expose public access later if needed.
  properties {
    public_access                       = true
    automatic_utility_network_ip_filter = true
  }

  network {
    uuid   = upcloud_network.core_sdn.id
    family = "IPv4"
    name   = "privatenetwork"
    type   = "private"
  }

  labels = {
    project     = var.project_name
    environment = var.environment
    component   = "database"
    managed_by  = "terraform"
  }
}

# Logical database inside the managed PostgreSQL service
resource "upcloud_managed_database_logical_database" "app" {
  service = upcloud_managed_database_postgresql.app.id
  name    = var.db_logical_name
}

