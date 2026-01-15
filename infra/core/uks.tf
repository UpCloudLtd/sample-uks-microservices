############################################
# UpCloud Kubernetes Service (UKS)
# - Cluster on core_sdn
# - Private node groups behind NAT Gateway
############################################

# Managed Kubernetes cluster
resource "upcloud_kubernetes_cluster" "core" {
  # Allow access to the control plane only from configured IP ranges
  control_plane_ip_filter = var.control_plane_ip_filter

  name    = "${local.name_prefix}-cluster"
  network = upcloud_network.core_sdn.id
  zone    = var.upcloud_zone

  # Nodes have *no* public IPs, all outbound via NAT Gateway on the router.
  private_node_groups = true
}

############################################
# Node group 1: general workloads
#   - 3 nodes, plan CLOUDNATIVE-2xCPU-4GB (Cloud Native)
############################################

resource "upcloud_kubernetes_node_group" "general" {
  cluster    = upcloud_kubernetes_cluster.core.id
  name       = "${local.name_prefix}-ng-general"
  node_count = 3

  # Same format as in UpCloud's own Terraform examples
  # which corresponds to CLOUDNATIVE-8xCPU-16GB in the plan table.
  plan = "CLOUDNATIVE-8xCPU-16GB"
}

############################################
# Node group 2: compute-heavy workloads
#   - 3 nodes, plan 4xCPU-16GB (Cloud Native)
############################################

# resource "upcloud_kubernetes_node_group" "compute" {
#   cluster    = upcloud_kubernetes_cluster.core.id
#   name       = "${local.name_prefix}-ng-compute"
#   node_count = 3

#   # Uses the 4xCPU-16GB Cloud Native plan – see Cloud Native plan matrix.
#   # Terraform uses the form (e.g. "CLOUDNATIVE-4xCPU-16GB") just like "2xCPU-4GB".
#   plan = "CLOUDNATIVE-4xCPU-16GB"
# }

############################################
# Cluster data source for kubeconfig / providers
############################################

data "upcloud_kubernetes_cluster" "core" {
  id = upcloud_kubernetes_cluster.core.id
}

# Optional: write kubeconfig to file for kubectl access
resource "local_file" "kubeconfig_uks" {
  content  = data.upcloud_kubernetes_cluster.core.kubeconfig
  filename = "${abspath(path.module)}/kubeconfig-uks.yml"
  file_permission      = "0600"
  directory_permission = "0700"
}

