########################################
# Monitoring VM (Prometheus / Grafana / Loki)
########################################

resource "upcloud_server" "monitoring" {
  hostname = "${local.name_prefix}-monitoring"
  zone     = var.upcloud_zone
  plan     = var.monitoring_plan

  metadata = true

  login {
    user = var.vm_admin_username
    keys = [
      var.vm_admin_ssh_public_key,
    ]

    create_password   = false
    password_delivery = "none"
  }

  template {
    storage = var.supporting_vm_os_template
    size    = var.supporting_vm_root_disk_size_gb
  }

  # Public NIC for Grafana access from the internet , default route
  network_interface {
    type = "public"
  }

  # Private SDN NIC (for RabbitMQ & UKS & private stuff)
  network_interface {
    type       = "private"
    network    = upcloud_network.core_sdn.id
    ip_address = "10.10.0.17"
  }


  # Actual Prometheus, Grafana and Loki setup along with exporters - all via cloud-init. 
  # Everything runs in Docker containers for simplicity.


  user_data = <<-CLOUDINIT
    #cloud-config
    package_update: true
    package_upgrade: true
    packages:
      - docker.io
      - docker-compose
      - curl

    groups:
      - docker

    # Make sure the admin user can run docker
    system_info:
      default_user:
        groups: [docker]

    write_files:
      # Netplan config to use both NICs with default route via public NIC
      - path: /etc/netplan/99-dual-nic.yaml
        owner: root:root
        permissions: "0644"
        content: |
          network:
            version: 2
            renderer: networkd
            ethernets:
              ens3:         # public NIC
                dhcp4: true
                dhcp4-overrides:
                  route-metric: 100
              ens4:         # private SDN NIC
                dhcp4: true
                dhcp4-overrides:
                  route-metric: 200
                routes:
                  - to: 10.10.0.0/24
                    via: 10.10.0.1
      # Prometheus config
      - path: /opt/monitoring/prometheus/prometheus.yml
        owner: root:root
        permissions: "0644"
        content: |
          global:
            scrape_interval: 15s
            evaluation_interval: 15s

          scrape_configs:
            # Prometheus self
            - job_name: "prometheus"
              static_configs:
                - targets: ["prometheus:9090"]

            # Host metrics via node_exporter
            - job_name: "node_exporter"
              static_configs:
                - targets: ["node-exporter:9100"]

            # Managed PostgreSQL via postgres-exporter
            - job_name: "postgres_exporter"
              static_configs:
                - targets: ["postgres-exporter:9187"]

            # RabbitMQ via rabbitmq-exporter
            - job_name: "rabbitmq"
              static_configs:
                - targets: ["rabbitmq-exporter:9419"]

      # Loki config (single-node, filesystem storage)
      - path: /opt/monitoring/loki/loki-config.yml
        owner: root:root
        permissions: "0644"
        content: |
          auth_enabled: false

          server:
            http_listen_port: 3100
            grpc_listen_port: 9096

          common:
            path_prefix: /var/lib/loki
            ring:
              instance_addr: 127.0.0.1
              kvstore:
                store: inmemory
            replication_factor: 1

          schema_config:
            configs:
              - from: 2024-01-01
                store: tsdb
                object_store: aws
                schema: v13
                index:
                  prefix: index_
                  period: 24h

          storage_config:
            aws:
              endpoint: "${local.object_storage_s3_endpoint}"
              region: "${var.object_storage_region}"
              bucketnames: "${local.loki_bucket_name}"
              access_key_id: "${local.object_storage_access_key_id}"
              secret_access_key: "${local.object_storage_secret_access_key}"
              s3forcepathstyle: true
              insecure: false
            
            tsdb_shipper:
              active_index_directory: /var/lib/loki/index
              cache_location: /var/lib/loki/index_cache
              resync_interval: 5m

          limits_config:
            reject_old_samples: true
            reject_old_samples_max_age: 168h


      # Promtail config: ship system logs to Loki
      - path: /opt/monitoring/promtail/promtail-config.yml
        owner: root:root
        permissions: "0644"
        content: |
          server:
            http_listen_port: 9080
            grpc_listen_port: 0

          positions:
            filename: /var/log/promtail-positions.yaml

          clients:
            - url: http://loki:3100/loki/api/v1/push

          scrape_configs:
            - job_name: "varlogs"
              static_configs:
                - targets: ["localhost"]
                  labels:
                    job: "varlogs"
                    __path__: /var/log/*.log

      # Docker Compose stack for Prometheus + Grafana + Loki + Promtail + Node Exporter + Postgres Exporter
      - path: /opt/monitoring/docker-compose.yml
        owner: root:root
        permissions: "0644"
        content: |
          version: "3.9"

          services:
            prometheus:
              image: prom/prometheus:latest
              container_name: prometheus
              volumes:
                - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
              command:
                - "--config.file=/etc/prometheus/prometheus.yml"
              ports:
                - "9090:9090"
              restart: unless-stopped

            grafana:
              image: grafana/grafana-oss:latest
              container_name: grafana
              depends_on:
                - prometheus
                - loki
              ports:
                - "3000:3000"
              environment:
                GF_SECURITY_ADMIN_USER: "admin"
                GF_SECURITY_ADMIN_PASSWORD: "${var.grafana_admin_password}"
                GF_SERVER_DOMAIN: ""
                GF_SERVER_ROOT_URL: "%(protocol)s://%(domain)s:%(http_port)s/"
              restart: unless-stopped

            loki:
              image: grafana/loki:latest
              container_name: loki
              user: "0:0"
              command: -config.file=/etc/loki/loki-config.yml
              volumes:
                - ./loki/loki-config.yml:/etc/loki/loki-config.yml:ro
                - loki-data:/var/lib/loki
              ports:
                - "3100:3100"
              restart: unless-stopped


            promtail:
              image: grafana/promtail:latest
              container_name: promtail
              command: -config.file=/etc/promtail/promtail-config.yml
              volumes:
                - ./promtail/promtail-config.yml:/etc/promtail/promtail-config.yml:ro
                - /var/log:/var/log
              restart: unless-stopped

            node-exporter:
              image: prom/node-exporter:latest
              container_name: node-exporter
              ports:
                - "9100:9100"
              restart: unless-stopped

            postgres-exporter:
              image: prometheuscommunity/postgres-exporter:latest
              container_name: postgres-exporter
              command:
              - '--no-collector.wal'

              environment:
                DATA_SOURCE_NAME: "postgresql://${upcloud_managed_database_postgresql.app.service_username}:${upcloud_managed_database_postgresql.app.service_password}@${upcloud_managed_database_postgresql.app.service_host}:${upcloud_managed_database_postgresql.app.service_port}/${upcloud_managed_database_postgresql.app.primary_database}?sslmode=require"
              ports:
                - "9187:9187"
              restart: unless-stopped
            
            rabbitmq-exporter:
              image: kbudde/rabbitmq-exporter:1.0.0
              container_name: rabbitmq-exporter
              environment:
                RABBIT_URL: "http://${local.rabbitmq_private_ip}:15672"
                RABBIT_USER: "${var.rabbitmq_username}"
                RABBIT_PASSWORD: "${var.rabbitmq_password}"
              ports:
                - "9419:9419"
              restart: unless-stopped

          volumes:
            loki-data:

    runcmd:
      - netplan apply
      - systemctl restart systemd-networkd systemd-resolved || true
      - bash -lc 'for i in {1..30}; do resolvectl query registry-1.docker.io && break; sleep 2; done'
      - systemctl enable docker
      - systemctl start docker
      - mkdir -p /opt/monitoring/prometheus /opt/monitoring/loki /opt/monitoring/promtail
      - cd /opt/monitoring && docker-compose pull
      - cd /opt/monitoring && docker-compose up -d
  CLOUDINIT
  firewall  = true
}


resource "upcloud_server" "monitoring_minimal" {
  hostname = "${local.name_prefix}-monitoring-minimal"
  zone     = var.upcloud_zone
  plan     = "1xCPU-1GB"

  metadata = true

  login {
    user              = var.vm_admin_username # still "ubuntu"
    keys              = [var.vm_admin_ssh_public_key]
    create_password   = false
    password_delivery = "none"
  }

  template {
    storage = var.supporting_vm_os_template
    size    = 25
  }

  network_interface {
    type = "public"
  }

  network_interface {
    type    = "private"
    network = upcloud_network.core_sdn.id
  }

  firewall = false

  # NO user_data here on purpose
}
