############################################
# Core SDN router
############################################

resource "upcloud_router" "core" {
  name = "${local.name_prefix}-router"
}

############################################
# NAT Gateway on core router
#
# This is the critical piece for private UKS node groups:
# - features = ["nat"] enables the NAT behaviour
# - router block attaches gateway to upcloud_router.core
############################################

resource "upcloud_gateway" "core_nat" {
  name = "${local.name_prefix}-nat-gateway"
  zone = var.upcloud_zone

  # For NAT Gateway, features must include "nat"
  features = ["nat"]

  router {
    id = upcloud_router.core.id
  }
}

############################################
# Core SDN network for UKS + VMs
#
# Requirements for private node groups + NAT:
# - SDN network in the same zone as the cluster
# - Attached to router that has a NAT Gateway
# - ip_network.dhcp = true
# - ip_network.dhcp_default_route = true so default route points at the gateway
############################################

resource "upcloud_network" "core_sdn" {
  name = "${local.name_prefix}-sdn"
  zone = var.upcloud_zone

  ip_network {
    address            = var.core_sdn_cidr
    dhcp               = true
    family             = "IPv4"
    dhcp_default_route = true
    # Optional extras if you ever want to customize:
    # dhcp_dns   = ["1.1.1.1", "8.8.8.8"]
    # gateway    = "10.10.0.1"
  }

  # Attach to the router that has the NAT Gateway
  router = upcloud_router.core.id
}
