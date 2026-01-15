#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH" >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (install gettext, e.g. 'brew install gettext')" >&2
  exit 1
fi

: "${IMAGE_API:?Set IMAGE_API, e.g. youruser/orders-api:v2}"
: "${IMAGE_WORKER:?Set IMAGE_WORKER, e.g. youruser/orders-worker:v1}"
: "${RABBITMQ_URL:?Set RABBITMQ_URL, e.g. amqp://app:changeme-rabbitmq@10.10.0.2:5672/}"
: "${POSTGRES_DSN:?Set POSTGRES_DSN, e.g. postgres://upadmin:PW@HOST:11569/defaultdb?sslmode=require}"

+echo "==> Apply base manifests (namespace/config/deployments/services)"
+envsubst < k8s/app-demo.yaml | kubectl apply -f -
 
if [[ -f k8s/orders-api-metrics-nodeport.yaml ]]; then
  echo "==> Apply orders-api metrics NodePort service"
  kubectl apply -f k8s/orders-api-metrics-nodeport.yaml
fi

echo "Using:"
echo "  IMAGE_API    = ${IMAGE_API}"
echo "  IMAGE_WORKER = ${IMAGE_WORKER}"
echo "  RABBITMQ_URL = ${RABBITMQ_URL}"
echo "  POSTGRES_DSN = ${POSTGRES_DSN}"



envsubst < k8s/app-demo.yaml | kubectl apply -f -
if [[ -f k8s/orders-migrate-job.yaml ]]; then
  echo "==> Run DB migration job (idempotent: delete+recreate)"
  kubectl -n app-demo delete job/orders-migrate --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f k8s/orders-migrate-job.yaml

  echo "==> Wait for migration job to complete"
  if ! kubectl -n app-demo wait --for=condition=complete job/orders-migrate --timeout=180s; then
    echo "orders-migrate did not complete. Diagnostics:"
    kubectl -n app-demo get pods -l job-name=orders-migrate -o wide || true
    POD="$(kubectl -n app-demo get pod -l job-name=orders-migrate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${POD}" ]]; then
      kubectl -n app-demo describe pod "${POD}" || true
      kubectl -n app-demo logs "${POD}" || true
    fi
    exit 1
  fi
fi

echo "==> Deploy complete"