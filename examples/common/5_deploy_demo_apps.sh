#!/bin/bash

set -euo pipefail

. utils.sh

conjur_demo_scripts_path="temp/kubernetes-conjur-demo"

# Clone the conjurdemos/kubernetes-conjur-demo repo
rm -rf "$conjur_demo_scripts_path"
announce "Cloning Kubernetes Conjur Demo scripts to $conjur_demo_scripts_path"
mkdir -p temp
git clone https://github.com/conjurdemos/kubernetes-conjur-demo "$conjur_demo_scripts_path"

# Because the kubernetes-conjur-demo scripts use a different naming convention
# for the Conjur namespace env variable, some translation is required.
export CONJUR_NAMESPACE_NAME="$CONJUR_NAMESPACE"

announce "Running the Kubernetes Conjur Demo scripts"
cd "$conjur_demo_scripts_path"

# The conjur-cli container image runs as non-root user 'cli', so /policy is not
# writable. Patch policy scripts to use /home/cli/policy instead.
sed -i \
  -e 's|$conjur_cli_pod:/policy|$conjur_cli_pod:/home/cli/policy|g' \
  -e 's|rm -rf /policy|rm -rf /home/cli/policy|g' \
  -e 's|/policy/load_policies.sh|/home/cli/policy/load_policies.sh|g' \
  2_admin_load_conjur_policies.sh
sed -i 's|POLICY_DIR="/policy"|POLICY_DIR="/home/cli/policy"|g' policy/load_policies.sh

# Use 'bundle exec rake' to avoid Gem version conflicts in the Conjur container
sed -i 's|CONJUR_ACCOUNT=$CONJUR_ACCOUNT rake |CONJUR_ACCOUNT=$CONJUR_ACCOUNT bundle exec rake |g' \
  3_admin_init_conjur_cert_authority.sh

# radial/busyboxplus:curl uses deprecated Docker manifest v1, unsupported in containerd v2.1+
# curlimages/curl uses named user 'curl_user' (non-numeric); add runAsUser: 100 for k8s compat
for f in kubernetes/test-curl.yml openshift/test-curl.yml; do
  [ -f "$f" ] || continue
  sed -i 's|image: radial/busyboxplus:curl|image: curlimages/curl:latest|g' "$f"
  sed -i 's|runAsNonRoot: true|runAsUser: 100\n      runAsNonRoot: true|g' "$f"
done

./start

announce "Cleaning up test/validation deployments and pods"
# The 'test-app-with-host-outside-apps-branch-summon-init' deployment
# is used to test that authentication works with the Conjur host defined
# anywhere in the policy branch. It can be deleted now.
kubectl delete deployment -n "$TEST_APP_NAMESPACE_NAME" \
        test-app-with-host-outside-apps-branch-summon-init --ignore-not-found
if [[ "$TEST_APP_LOADBALANCER_SVCS" == "false" ]]; then
    kubectl delete pod -n "$TEST_APP_NAMESPACE_NAME" test-curl
fi

announce "Deployment of Conjur and demo applications is complete!"
