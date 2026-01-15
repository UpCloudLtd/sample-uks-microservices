#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$ROOT/infra}"
CORE_DIR="${CORE_DIR:-$INFRA_DIR/core}"
ADDONS_DIR="${ADDONS_DIR:-$INFRA_DIR/addons}"
APP_DIR="${APP_DIR:-$ROOT/app}"

# Images must be reachable by UKS nodes (e.g. GHCR)
: "${IMAGE_API:?Set IMAGE_API (e.g. ghcr.io/praivan/orders-api:tag)}"
: "${IMAGE_WORKER:?Set IMAGE_WORKER (e.g. ghcr.io/praivan/orders-worker:tag)}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need terraform
need kubectl
need envsubst
need curl
need jq
need ssh
need date

SSH_USER="${SSH_USER:-ubuntu}"
APPLY="${SMOKE_APPLY:-1}"
DESTROY="${SMOKE_DESTROY:-0}"

echo "==> Using:"
echo "  INFRA_DIR = $INFRA_DIR"
echo "  APP_DIR   = $APP_DIR"
echo "  CORE_DIR   = $CORE_DIR"
echo "  ADDONS_DIR = $ADDONS_DIR"
echo "  APPLY     = $APPLY"
echo "  DESTROY   = $DESTROY"
echo

cleanup() {
  if [[ "$DESTROY" == "1" ]]; then
    echo
    echo "==> terraform destroy"
    # Destroy addons first (k8s objects), then core (UpCloud)
    (cd "$ADDONS_DIR" && terraform destroy -auto-approve) || true
    (cd "$CORE_DIR" && terraform destroy -auto-approve) || true
  fi
}
trap cleanup EXIT

echo "==> terraform init"
(cd "$CORE_DIR" && terraform init -input=false >/dev/null)
(cd "$ADDONS_DIR" && terraform init -input=false >/dev/null)

if [[ "$APPLY" == "1" ]]; then
  echo "==> terraform apply (core)"
  (cd "$CORE_DIR" && terraform apply -auto-approve)
  echo "==> terraform apply (addons)"
  (cd "$ADDONS_DIR" && terraform apply -auto-approve)

fi

echo "==> Read Terraform outputs"
KUBECONFIG_PATH="$(cd "$CORE_DIR" && terraform output -raw uks_kubeconfig_path)"
MON_PUB="$(cd "$CORE_DIR" && terraform output -raw monitoring_public_ip)"
GRAFANA_URL="$(cd "$CORE_DIR" && terraform output -raw grafana_url)"
RABBIT_PUB="$(cd "$CORE_DIR" && terraform output -raw rabbitmq_public_ip)"
RABBIT_PRIV="$(cd "$CORE_DIR" && terraform output -raw rabbitmq_private_ip)"
RABBIT_URL="$(cd "$CORE_DIR" && terraform output -raw rabbitmq_amqp_url)"
POSTGRES_DSN="$(cd "$CORE_DIR" && terraform output -raw postgres_app_dsn)"


export KUBECONFIG="$KUBECONFIG_PATH"

echo "==> UKS check: nodes"
kubectl get nodes -o wide

echo "==> UKS check: kube-system pods (sanity)"
kubectl -n kube-system get pods -o wide | head -n 30 || true

echo "==> RabbitMQ check: SSH reachable (public) and ports listening"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${RABBIT_PUB}" \
  "cloud-init status --wait >/dev/null 2>&1 || true; \
   sudo systemctl is-active rabbitmq-server; \
   sudo ss -ltnp | egrep ':(5672|15672)\\b'"

echo "==> RabbitMQ check: reachable from monitoring VM (private 5672)"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${MON_PUB}" \
  "nc -vz -w 3 ${RABBIT_PRIV} 5672"

echo "==> Monitoring check: Prometheus healthy + Loki ready (with retries)"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${MON_PUB}" '
  set -e
  cloud-init status --wait >/dev/null 2>&1 || true

  for i in {1..60}; do
    if curl -fsS http://127.0.0.1:9090/-/healthy >/dev/null 2>&1 && \
       curl -fsS http://127.0.0.1:3100/ready >/dev/null 2>&1; then
      exit 0
    fi
    sleep 5
  done

  echo "Prometheus/Loki not healthy/ready after retries"
  echo "--- Prometheus ready endpoint ---"
  curl -sS -i http://127.0.0.1:9090/-/ready | head -n 30 || true
  echo "--- Prometheus logs ---"
  sudo docker logs prometheus --tail 120 || true
  echo "--- Loki logs ---"
  sudo docker logs loki --tail 120 || true
  exit 1
'

echo "==> Deploy app via app/deploy.sh"
export IMAGE_API IMAGE_WORKER
export RABBITMQ_URL="$RABBIT_URL"
export POSTGRES_DSN="$POSTGRES_DSN"
(cd "$APP_DIR" && ./deploy.sh)

echo "==> Wait for app rollouts"
kubectl -n app-demo rollout status deploy/orders-api --timeout=240s
kubectl -n app-demo rollout status deploy/orders-worker --timeout=240s
kubectl -n app-demo get pods -o wide

echo "==> App check: in-cluster POST /orders (debuggable curl pod)"
kubectl -n app-demo delete pod curl-demo --ignore-not-found >/dev/null 2>&1 || true

kubectl -n app-demo run curl-demo \
  --restart=Never \
  --image=curlimages/curl:latest \
  --command -- sleep 300

if ! kubectl -n app-demo wait --for=condition=Ready pod/curl-demo --timeout=120s; then
  echo "curl-demo did not become Ready. Diagnostics:"
  kubectl -n app-demo get pod curl-demo -o wide || true
  kubectl -n app-demo describe pod curl-demo || true
  kubectl -n app-demo get events --sort-by=.lastTimestamp | tail -n 50 || true
  exit 1
fi

API_PORT="$(kubectl -n app-demo get svc orders-api -o jsonpath='{.spec.ports[0].port}')"
ORDER_ID="smoke-$(date +%s)"

kubectl -n app-demo exec curl-demo -- \
  curl -fsS -X POST "http://orders-api:${API_PORT}/orders" \
    -H 'Content-Type: application/json' \
    -d "{\"order_id\":\"${ORDER_ID}\",\"quantity\":1}" >/dev/null

kubectl -n app-demo delete pod curl-demo --wait=false >/dev/null 2>&1 || true


echo "==> App check: API root returns HTML (port-forward quick check)"
# Use a short-lived port-forward and curl locally (no browser needed)
kubectl -n app-demo port-forward svc/orders-api 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
sleep 1
curl -fsS "http://127.0.0.1:18080/" >/dev/null || { kill $PF_PID || true; echo "API UI check failed"; exit 1; }
kill $PF_PID || true

echo "==> Prometheus check: key targets are UP (via monitoring VM)"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${MON_PUB}" \
  "curl -fsS http://localhost:9090/api/v1/targets \
   | jq -r '.data.activeTargets[] | select(.labels.job == \"orders_api\" or .labels.job == \"orders_worker\" or .labels.job == \"kube-state-metrics\" or .labels.job == \"rabbitmq\" or .labels.job == \"postgres_exporter\") | [.labels.job,.health,.scrapeUrl] | @tsv'"

echo "==> Loki check: query_range sees app-demo logs (via monitoring VM)"
# Query last 15 minutes for any app-demo logs
START_NS="$(python3 - <<'PY'
import time
print(int((time.time()-15*60)*1e9))
PY
)"
END_NS="$(python3 - <<'PY'
import time
print(int(time.time()*1e9))
PY
)"

ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${SSH_USER}@${MON_PUB}" \
  "curl -G -fsS http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode 'query={job=\"kubernetes-pods\",namespace=\"app-demo\"}' \
    --data-urlencode 'start=${START_NS}' \
    --data-urlencode 'end=${END_NS}' \
    --data-urlencode 'limit=5' \
   | jq -e '.data.result | length > 0' >/dev/null"

echo
echo "Smoke test complete"
echo "Grafana: ${GRAFANA_URL}"
