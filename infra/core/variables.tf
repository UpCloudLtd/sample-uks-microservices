########################################
# General variables                    #
########################################
variable "project_name" {
  description = "Logical name/prefix for all resources."
  type        = string
  default     = "uks-mcrsvc-demo"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "upcloud_zone" {
  description = "UpCloud zone to deploy into, e.g. fi-hel1, de-fra1."
  type        = string
  default     = "de-fra1"
}

variable "core_sdn_cidr" {
  description = "CIDR for the core SDN network used by UKS, VMs, NAT."
  type        = string
  default     = "10.10.0.0/24"
}

variable "control_plane_ip_filter" {
  description = "IPv4 addresses or CIDR ranges that are allowed to access the Kubernetes control plane API.For production, restrict this to your office/VPN IP ranges."
  type        = list(string)

  # For a lab / demo you can start with this and tighten later.
  default = ["0.0.0.0/0"]
}

########################################
# Supporting infrastructure variables  #
########################################

variable "vm_admin_username" {
  type        = string
  description = "Admin user to create on supporting VMs (RabbitMQ / monitoring)."
  default     = "ubuntu"
}

variable "vm_admin_ssh_public_key" {
  type        = string
  description = "SSH public key allowed on supporting VMs."
}

variable "rabbitmq_plan" {
  type        = string
  description = "Cloud Server plan for RabbitMQ VM."
  # General Purpose 2xCPU / 4GB RAM plan name
  default = "2xCPU-4GB"
}

variable "monitoring_plan" {
  type        = string
  description = "Cloud Server plan for Prometheus/Grafana/Loki VM."
  # General Purpose 4xCPU / 8GB RAM plan name
  default = "4xCPU-8GB"
}

variable "supporting_vm_os_template" {
  type        = string
  description = "OS template name for supporting VMs (must match UpCloud public template)."
  default     = "Ubuntu Server 24.04 LTS (Noble Numbat)"
}

variable "supporting_vm_root_disk_size_gb" {
  type        = number
  description = "Root disk size (GB) for supporting VMs."
  default     = 80
}

variable "rabbitmq_username" {
  description = "Application user to create in RabbitMQ."
  type        = string
  default     = "app"
}

variable "rabbitmq_password" {
  description = "Password for the RabbitMQ application user."
  type        = string
  sensitive   = true
  default     = "changeme-rabbitmq"
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password."
  type        = string
  sensitive   = true
  default     = "changeme-grafana"
}
########################################
# Managed PostgreSQL setup variables   #
########################################
variable "db_plan" {
  type        = string
  description = "Managed PostgreSQL plan identifier (2-node HA by default)"
  # Lowest 2-node HA plan from UpCloud Managed PostgreSQL configurations
  # (4 GB RAM, 2 cores, 50 GB storage, 2 nodes)
  default = "2x2xCPU-4GB-50GB"
}

variable "db_logical_name" {
  type        = string
  description = "Logical database name inside the managed PostgreSQL service"
  default     = "app_db"
}

# Managed Object Storage
variable "object_storage_region" {
  type        = string
  description = "Region for Managed Object Storage (see UpCloud docs for valid values: apac-1, europe-1, europe-2, us-1)"
  default     = "europe-2"
}

variable "object_storage_name" {
  type        = string
  description = "Name of the Managed Object Storage service"
  default     = "uks-microservices-artifacts"
}

variable "object_storage_bucket_names" {
  type        = set(string)
  description = "Bucket names to create within Managed Object Storage"
  default = [
    "artifacts",
    "loki-logs", # bucket for Loki logs
  ]
}

variable "object_storage_access_key_id" {
  description = "S3 access key for the Managed Object Storage service used by Loki."
  type        = string
  sensitive   = true
  default = null
}

variable "object_storage_secret_access_key" {
  description = "S3 secret key for the Managed Object Storage service used by Loki."
  type        = string
  sensitive   = true
  default = null
}


