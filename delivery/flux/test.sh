#! /usr/bin/env bash

set -e
declare -r this_dir=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
declare -r root_dir=$(cd ${this_dir}/../.. && pwd)
if [[ -f "${root_dir}/.env" ]]; then source "${root_dir}/.env"; fi

github_user=${1:-${GITHUB_USER}}
github_token=${2:-${GITHUB_TOKEN}}

echo "github_user: ${github_user}"

namespace=podtato-flux
kubectl create namespace ${namespace} &> /dev/null || true
kubectl config set-context --current --namespace=${namespace}
if [[ -n "${github_token}" ]]; then
    test=$(kubectl get secret ghcr -oname 2> /dev/null || true)
    if [[ -z "${test}" ]]; then
      kubectl create secret docker-registry ghcr \
          --docker-server 'ghcr.io' \
          --docker-username "${github_user}" \
          --docker-password "${github_token}"
    fi
fi

# install gh
gh_version=2.2.0
curl -sSLO https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_amd64.tar.gz
tar -xzf gh_${gh_version}_linux_amd64.tar.gz \
    gh_${gh_version}_linux_amd64/bin/gh \
    --strip-components=2
mv ./gh ${this_dir}/gh
chmod +x ${this_dir}/gh
alias gh=${this_dir}/gh
rm -rf gh_${gh_version}_linux_amd64.tar.gz
gh version
# /end install gh

# install flux CLI
curl -s https://fluxcd.io/install.sh | bash
flux version --client
flux install --version=latest
# /end install flux CLI

secret_ref_name=podtato-flux-secret
git_source_name=podtato-flux-repo
git_repo_url=https://github.com/${github_user}/podtato-head
# TODO: update to main after merge
git_source_branch=develop
helmrelease_name=podtato-flux-release

if [[ -n "${USE_SSH_GIT_AUTH}" ]]; then
    git_repo_url=ssh://git@github.com/${github_user}/podtato-head
    flux create secret git ${secret_ref_name} --url=${git_repo_url}
    ssh_public_key=$(kubectl get secret ${secret_ref_name} -n flux-system -ojson | jq -r '.data."identity.pub"' | base64 -d)
    # delete existing keys of the same name
    gh api repos/${github_user}/podtato-head/keys | jq -r '.[].url' | sed 's/^https:\/\/api.github.com\///' | xargs -L 1 -r gh api --method DELETE
    gh api repos/${github_user}/podtato-head/keys \
        -F title=${secret_ref_name} \
        -F "key=${ssh_public_key}"
    sleep 3
else
    flux create secret git ${secret_ref_name} \
        --url=${git_repo_url} \
        --username "${github_user}" \
        --password "${github_token}"
fi

flux create source git ${git_source_name} \
    --url=${git_repo_url} \
    --secret-ref ${secret_ref_name} \
    --branch=${git_source_branch}

# flux adds custom values from a YAML file only so create a temp file for this override
tmp_values_file=$(mktemp)
cat <<EOF > ${tmp_values_file} 
entry:
    serviceType: NodePort
EOF

if [[ -z "${RELEASE_BUILD}" ]]; then
cat <<EOF >> ${tmp_values_file} 
images:
    repositoryDirname: ghcr.io/${github_user:+${github_user}/}podtato-head
EOF
fi

flux create helmrelease ${helmrelease_name} \
    --target-namespace=${namespace} \
    --source=GitRepository/${git_source_name}.flux-system \
    --chart=./delivery/chart \
    --values="${tmp_values_file}"

# do this here for when flux creates a new service account for the service
for sa in $(kubectl get serviceaccounts -oname); do
    kubectl patch ${sa} --patch '{ "imagePullSecrets": [{ "name": "ghcr" }]}'
done

echo ""
echo "=== initial deployments state"
kubectl get deployments --namespace=${namespace}

echo ""
echo "=== await readiness of deployments..."
parts=("entry" "hat" "left-leg" "left-arm" "right-leg" "right-arm")
for part in "${parts[@]}"; do
    kubectl wait --for=condition=Available --timeout=30s deployment --namespace ${namespace} podtato-${part}
done

# service tests
${root_dir}/scripts/test_services.sh ${namespace}

echo ""
echo "=== kubectl logs deployment/podtato-entry"
kubectl logs deployment/podtato-entry

echo ""
echo "=== kubectl logs deployment/podtato-hat"
kubectl logs deployment/podtato-hat

if [[ -n "${WAIT_FOR_DELETE}" ]]; then
    echo ""
    read -N 1 -s -p "press a key to delete resources..."
    echo ""
fi

rm ${this_dir}/gh

echo ""
echo "=== delete all"
flux delete helmrelease ${helmrelease_name} --silent
flux delete source git ${git_source_name} --silent
flux uninstall --silent
kubectl delete namespace ${namespace}
