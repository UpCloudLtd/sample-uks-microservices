###################################
# Firewall rules for monitoring VM
# - Allow SSH (22/tcp) from anywhere (you can tighten later)
# - Allow Grafana (3000/tcp) from anywhere
# - Drop everything else inbound (IPv4)
###################################
resource "upcloud_firewall_rules" "monitoring" {
  server_id = upcloud_server.monitoring.id

  # SSH
  firewall_rule {
    action                 = "accept"
    comment                = "ssh"
    destination_port_start = 22
    destination_port_end   = 22
    direction              = "in"
    protocol               = "tcp"
    family                 = "IPv4"
  }

  # Grafana
  firewall_rule {
    action                 = "accept"
    comment                = "grafana"
    destination_port_start = 3000
    destination_port_end   = 3000
    direction              = "in"
    protocol               = "tcp"
    family                 = "IPv4"
  }

  # Default deny inbound IPv4
  firewall_rule {
    action    = "drop"
    direction = "in"
    family    = "IPv4"
  }
}
###################################
# Firewall rules for RabbitMQ VM
# - Allow SSH (22/tcp) from anywhere (tighten later)
# - Drop everything else inbound (IPv4)
###################################
resource "upcloud_firewall_rules" "rabbitmq" {
  server_id = upcloud_server.rabbitmq.id

  # SSH
  firewall_rule {
    action                 = "accept"
    comment                = "ssh"
    destination_port_start = 22
    destination_port_end   = 22
    direction              = "in"
    protocol               = "tcp"
    family                 = "IPv4"
  }

  # Default deny inbound IPv4
  firewall_rule {
    action    = "drop"
    direction = "in"
    family    = "IPv4"
  }
}
