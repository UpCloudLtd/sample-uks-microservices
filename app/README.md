# UpCloud UKS Orders Demo App

A tiny demo application to showcase the UpCloud UKS blueprint:

- `orders-api` – HTTP service with:
  - simple HTML form at `/`
  - POST `/orders` → publishes messages to RabbitMQ
  - `/healthz`, `/readyz`, `/metrics` (Prometheus)
- `orders-worker` – background worker that:
  - consumes messages from the `orders` queue
  - inserts rows into Postgres `orders` table
  - exposes `/healthz`, `/readyz`, `/metrics`

Both services are instrumented with Prometheus metrics and emit structured logs that end up in Loki.

---

## Architecture

- **UKS cluster** runs:
  - `orders-api` Deployment + Service (NodePort)
  - `orders-worker` Deployment + Service (NodePort for metrics only)
- **RabbitMQ** VM (private IP) for the `orders` queue
- **PostgreSQL** (UpCloud Managed Databases) holding `orders` table
- **Monitoring VM** (NAT host) with:
  - Prometheus (scrapes orders-api, orders-worker, rabbitmq)
  - Grafana (dashboards)
  - Loki + promtail (UKS logs)

---

## Prerequisites

- Working **UKS cluster** with kubectl configured.
- The base **infra blueprint** already deployed (RabbitMQ, Postgres, monitoring stack).
- Access to container registry where you would push the images (i.e.  Docker Hub)
- Environment variables:

  ```bash
  export IMAGE_API="yourdockeruser/orders-api:v1"
  export IMAGE_WORKER="yourdockeruser/orders-worker:v1"

  export RABBITMQ_URL="amqp://app:changeme-rabbitmq@10.10.0.2:5672/"
  export POSTGRES_DSN="postgres://upadmin:<PWD>@uks-mcrsvc-demo-dev-postgres-hddsdtzzbszm.db.upclouddatabases.com:11569/defaultdb?sslmode=require"
  ```
- `envsubst` available (from `gettext`)

---
## Deployment and testing

### Build & push images
From repo root:
  ```bash
  # orders-api
docker build -t "$IMAGE_API" ./orders-api
docker push "$IMAGE_API"

# orders-worker
docker build -t "$IMAGE_WORKER" ./orders-worker
docker push "$IMAGE_WORKER"
  ```

### Deploy to UKS

  ```bash
 envsubst < k8s/app-demo.yaml | kubectl apply -f -
kubectl -n app-demo get pods
kubectl -n app-demo get svc
  ```

Wait for rollouts
 ```bash
kubectl rollout status -n app-demo deploy/orders-api
kubectl rollout status -n app-demo deploy/orders-worker
 ```
  
### Port-forward & use the app
```bash
kubectl port-forward -n app-demo svc/orders-api 8080:8080
 ```
 Then open
- `http://localhost:8080/` submit a few orders
- `http://localhost:8080/metrics` Prometheus metrics (debug)

---
### Verify PostgreSQL
Use the ```psql-debug``` pod from the infra blueprint: 
 ```bash
  kubectl exec -it -n debug psql-debug -- bash

psql "$POSTGRES_DSN" -c '
  SELECT id, order_id, quantity, created_at
  FROM orders
  ORDER BY created_at DESC
  LIMIT 10;
'
  ```
  You should see the orders you just submitted.
 
 ---
 ## Observability
 ### Prometheus jobs
 Prometheus is configured to scrape:
 - ```orders-api``` metrics via  ```job="orders_api"``` (NodePort 31090 on monitoring VM)
 - ```orders-worker``` metrics via  ```job="orders_worker"``` (NodePort 31083)
 - RabbitMQ exporter via ```job="rabbitmq"

 ### Example PromQL
 - RPS:
 ```promql
 sum by (method) (
  rate(orders_http_requests_total{
    job="orders_api",
    handler="orders"
  }[5m])
)
 ```
 - Error rate:
 ```promql
 100 *
sum(rate(orders_http_requests_total{
  job="orders_api",
  handler="orders",
  code=~"5.."
}[5m]))
/
sum(rate(orders_http_requests_total{
  job="orders_api",
  handler="orders"
}[5m]))

 ```
 - Worker throughput:
 ```promql
 sum(rate(orders_worker_messages_total{
  job="orders_worker",
  status="ok"
}[5m]))
 ```

