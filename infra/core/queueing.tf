########################################
# RabbitMQ VM (Ubuntu + RabbitMQ + Mgmt)
########################################

resource "upcloud_server" "rabbitmq" {
  hostname = "${local.name_prefix}-rabbitmq"
  title    = "${local.name_prefix}-rabbitmq (managed by terraform)"
  zone     = var.upcloud_zone
  plan     = var.rabbitmq_plan

  metadata = true

  login {
    user              = var.vm_admin_username
    keys              = [var.vm_admin_ssh_public_key]
    create_password   = false
    password_delivery = "none"
  }

  template {
    # IMPORTANT:
    # Make sure var.supporting_vm_os_template is set to:
    # "Ubuntu Server 24.04 LTS (Noble Numbat)"
    storage = var.supporting_vm_os_template
    size    = var.supporting_vm_root_disk_size_gb
  }

  # Public NIC for direct SSH access
  network_interface {
    type = "public"
  }
  
  # Put the PRIVATE NIC FIRST so index [0] = 10.10.0.x
  network_interface {
    type              = "private"
    ip_address_family = "IPv4"
    network           = upcloud_network.core_sdn.id
  }



  # We keep UpCloud firewall disabled and rely on OS-level firewall if needed.
  firewall = false

  # Cloud-init: install RabbitMQ, enable management plugin, create "app" user.
  user_data = <<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - rabbitmq-server

    write_files:
      # Dual NIC netplan, same as monitoring VM
      - path: /etc/netplan/99-dual-nic.yaml
        owner: root:root
        permissions: '0644'
        content: |
          network:
            version: 2
            renderer: networkd
            ethernets:
              ens3: # public
                dhcp4: true
                dhcp4-overrides:
                  route-metric: 100
              ens4: # private
                dhcp4: true
                dhcp4-overrides:
                  route-metric: 200
                routes:
                  - to: ${var.core_sdn_cidr}
                    via: 10.10.0.1 
      - path: /etc/rabbitmq/rabbitmq.conf
        owner: root:root
        permissions: "0644"
        content: |
          ## Main AMQP listener (all interfaces, default 5672)
          listeners.tcp.default = 5672

          ## Allow remote connections for non-guest users
          loopback_users.guest = false

          ## Management plugin HTTP listener (UI + API)
          management.listener.port = 15672
          management.listener.ip   = 0.0.0.0

    runcmd:
      # Apply the netplan config so routing is deterministic
      - netplan apply
      # Make sure RabbitMQ service is enabled and running
      - systemctl enable --now rabbitmq-server
      - timeout 180 bash -lc 'until rabbitmq-diagnostics -q check_running; do sleep 2; done'
       # Enable the management plugin (this may restart RabbitMQ)
      - rabbitmq-plugins enable rabbitmq_management
      - systemctl restart rabbitmq-server
      - timeout 180 bash -lc 'until rabbitmq-diagnostics -q check_running; do sleep 2; done'
     

      # Create dedicated application user for your workloads
      - rabbitmqctl add_user "${var.rabbitmq_username}" "${var.rabbitmq_password}" || true
      - rabbitmqctl set_user_tags "${var.rabbitmq_username}" administrator
      - rabbitmqctl set_permissions -p / "${var.rabbitmq_username}" ".*" ".*" ".*"
      - ss -ltnp | grep -E ":(5672|15672)\\b" || true

      # Disable the default 'guest' user for safety (optional but recommended)
      - rabbitmqctl delete_user guest || true
  CLOUDINIT
}
