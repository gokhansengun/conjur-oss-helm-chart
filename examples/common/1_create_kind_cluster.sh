#!/bin/bash

set -euo pipefail

. utils.sh

check_env_var "KIND_CLUSTER_NAME"
min_kind_version="0.7.0"

# Confirm that 'kind' binary is installed.
if ! command -v kind &> /dev/null; then
  echo "kind binary not found. See https://kind.sigs.k8s.io/docs/user/quick-start/"
  echo "for installation instructions."
  exit 1
fi

# Check version of 'kind' binary.
kind_version="$(kind version -q)"
if ! meets_min_version $kind_version $min_kind_version; then
  echo "kind version $kind_version is invalid. Version must be $min_kind_version or newer"
  exit 1
fi

registry_container_is_running() {
  docker inspect -f '{{.State.Running}}' $DOCKER_LOCAL_REGISTRY_NAME 2>/dev/null
}
 
# Check if KinD cluster has already been created
if [ "$(kind get clusters | grep "^$KIND_CLUSTER_NAME$")" = "$KIND_CLUSTER_NAME" ]; then
  echo "KinD cluster '$KIND_CLUSTER_NAME' already exists. Skipping cluster creation."
  if [[ $USE_DOCKER_LOCAL_REGISTRY == "true" ]]; then
    if ! registry_container_is_running; then 
      echo "KinD cluster '$KIND_CLUSTER_NAME' does not have an internal Docker registry running"
      echo "and 'USE_DOCKER_LOCAL_REGISTRY' is set to 'true'. To use an"
      echo "internal Docker registry, please delete the KinD cluster:"
      echo "    kind delete cluster --name $KIND_CLUSTER_NAME"
      echo "and restart the demo scripts to create a new KinD cluster."
      exit 1
    fi
  fi
elif [[ $USE_DOCKER_LOCAL_REGISTRY == "true" ]]; then 
  announce "Creating KinD Cluster with local registry"
  
  reg_name="$DOCKER_LOCAL_REGISTRY_NAME"
  reg_port="$DOCKER_LOCAL_REGISTRY_PORT"
    
  # create registry container unless it already exists
  if ! registry_container_is_running; then
    echo "Creating a registry container"
    # Create a Docker network named 'kind' if not already created
    docker network inspect kind >/dev/null 2>&1 || \
      docker network create kind
    docker run \
      -d --restart=always -p "${reg_port}:${reg_port}" --name "${reg_name}" --net=kind \
      registry:2
  fi
  reg_ip="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${reg_name}")"
  echo "Registry IP: ${reg_ip}"

  # Create the KinD cluster (no containerd patch needed; we configure it post-creation)
  kind create cluster --name "${KIND_CLUSTER_NAME}"

  # Configure the local registry mirror in containerd inside the node using hosts.d
  # (containerd v2 no longer supports the legacy 'mirrors' TOML patch)
  node_container="${KIND_CLUSTER_NAME}-control-plane"
  hosts_toml="$(mktemp)"
  cat > "${hosts_toml}" <<HOSTSEOF
server = "http://localhost:${reg_port}"

[host."http://${reg_ip}:${reg_port}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
HOSTSEOF

  docker exec "${node_container}" mkdir -p "/etc/containerd/certs.d/localhost:${reg_port}"
  docker cp "${hosts_toml}" "${node_container}:/etc/containerd/certs.d/localhost:${reg_port}/hosts.toml"
  rm -f "${hosts_toml}"
  docker exec "${node_container}" systemctl restart containerd
  echo "Containerd registry mirror configured for localhost:${reg_port}"

else
  kind create cluster --name "$KIND_CLUSTER_NAME"
fi
