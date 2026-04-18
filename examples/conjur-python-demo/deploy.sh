#!/bin/bash
# Build, push, load Conjur policy, and deploy conjur-python-demo to K8s.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-localhost:5000}"
IMAGE="${REGISTRY}/conjur-python-demo:latest"
NAMESPACE="${NAMESPACE:-app-test}"
CONJUR_NAMESPACE="${CONJUR_NAMESPACE:-conjur-oss}"
CONJUR_ACCOUNT="${CONJUR_ACCOUNT:-myConjurAccount}"
CONJUR_ADMIN_PASSWORD="${CONJUR_ADMIN_PASSWORD:-}"

# ── 1. Build & push image ────────────────────────────────────────────────────
echo "==> Building Docker image: ${IMAGE}"
docker build -t "${IMAGE}" "${SCRIPT_DIR}"

echo "==> Pushing to local registry"
docker push "${IMAGE}"

# ── 2. Load Conjur policy ────────────────────────────────────────────────────
echo "==> Loading Conjur policy"

CONJUR_POD=$(kubectl get pod -n "${CONJUR_NAMESPACE}" \
  -l "app=conjur-oss" \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${CONJUR_POD}" ]]; then
  echo "ERROR: Could not find a running Conjur pod in namespace '${CONJUR_NAMESPACE}'"
  exit 1
fi

echo "    Using Conjur pod: ${CONJUR_POD}"

# Locate the conjur-cli pod in the same namespace
CLI_POD=$(kubectl get pod -n "${CONJUR_NAMESPACE}" \
  -l "app=conjur-cli" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${CLI_POD}" ]]; then
  echo "    Using conjur-cli pod: ${CLI_POD}"
  kubectl cp "${SCRIPT_DIR}/conjur-policy.yml" \
    "${CONJUR_NAMESPACE}/${CLI_POD}:/home/cli/conjur-python-demo-policy.yml"

  if [[ -z "${CONJUR_ADMIN_PASSWORD}" ]]; then
    echo "    CONJUR_ADMIN_PASSWORD not set — retrieving admin API key from Conjur pod"
    CONJUR_ADMIN_PASSWORD=$(kubectl exec -n "${CONJUR_NAMESPACE}" "${CONJUR_POD}" \
      --container=conjur-oss \
      -- conjurctl role retrieve-key "${CONJUR_ACCOUNT}:user:admin" | tail -1)
    if [[ -z "${CONJUR_ADMIN_PASSWORD}" ]]; then
      echo "ERROR: Failed to retrieve admin API key from Conjur pod"
      exit 1
    fi
    echo "    Admin API key retrieved successfully"
  fi

  kubectl exec -n "${CONJUR_NAMESPACE}" "${CLI_POD}" -- sh -c "
    echo y | conjur init -u https://conjur-oss.conjur-oss.svc.cluster.local \
      -a ${CONJUR_ACCOUNT} --self-signed --force && \
    conjur login -i admin -p '${CONJUR_ADMIN_PASSWORD}' && \
    conjur policy load -b conjur/authn-k8s/my-authenticator-id/apps \
      -f /home/cli/conjur-python-demo-policy.yml && \
    conjur logout
  "
else
  echo "WARNING: No conjur-cli pod found. Skipping policy load."
  echo "         Load conjur-policy.yml manually:"
  echo "           conjur policy load -b conjur/authn-k8s/my-authenticator-id/apps -f conjur-policy.yml"
fi

echo "==> Cleaning up the existing deployment (if any)"
kubectl delete -f "${SCRIPT_DIR}/k8s/deployment.yaml" --ignore-not-found

# ── 3. Deploy to Kubernetes ──────────────────────────────────────────────────
echo "==> Deploying to Kubernetes namespace '${NAMESPACE}'"
kubectl apply -f "${SCRIPT_DIR}/k8s/service-account.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/deployment.yaml"

echo "==> Waiting for deployment rollout"
kubectl rollout status deployment/conjur-python-demo -n "${NAMESPACE}" --timeout=120s

echo "==> Tailing logs (Ctrl-C to stop)"
POD=$(kubectl get pod -n "${NAMESPACE}" \
  -l "app=conjur-python-demo" \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n "${NAMESPACE}" "${POD}" -f
