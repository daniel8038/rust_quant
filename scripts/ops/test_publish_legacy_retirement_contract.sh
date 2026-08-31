#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root="$(CDPATH= cd -- "${script_dir}/../.." && pwd)"
contract_script="${script_dir}/publish_legacy_retirement_contract.sh"
workflow="${repository_root}/.github/workflows/legacy-production-retirement-contract.yml"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

readonly revision="b983a481f915aa9986d1829be2ae689ce856b0d3"
source_root="${DEPLOY_LEGACY_TEST_SOURCE_ROOT:-}"
if [[ -z "${source_root}" ]]; then
  source_root="${test_root}/legacy-source"
  git clone --quiet --no-checkout "${repository_root}" "${source_root}"
  git -C "${source_root}" checkout --quiet --detach "${revision}"
fi
source_root="$(realpath "${source_root}")"
[[ "$(git -C "${source_root}" rev-parse HEAD)" == "${revision}" ]]
source_deploy_dir="${source_root}/scripts/deploy"
readonly config_image="ghcr.io/example/quant-core-worker@sha256:$(printf 'a%.0s' {1..64})"
readonly image_id="sha256:$(printf 'b%.0s' {1..64})"
readonly container_id="$(printf 'c%.0s' {1..64})"

file_mode() {
  local file="$1"
  if stat -c '%a' "${file}" >/dev/null 2>&1; then
    stat -c '%a' "${file}"
  else
    stat -f '%Lp' "${file}"
  fi
}

working_dir="${test_root}/legacy"
fake_bin="${test_root}/bin"
mkdir -p "${working_dir}/.deploy/eth-4h-market-handoff" "${working_dir}/scripts" "${fake_bin}"
working_dir="$(realpath "${working_dir}")"
printf 'image=%s\nrevision=%s\n' "${config_image}" "${revision}" \
  > "${working_dir}/.deploy/eth-4h-market-handoff/current-release.env"
: > "${working_dir}/.deploy/eth-4h-market-handoff/market-ownership-transferred"

cat > "${fake_bin}/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "inspect" && "$2" == "--format" && "$4" == "quant-core-vegas-eth-4h-worker" ]]
case "$3" in
  '{{.Name}}') printf '/quant-core-vegas-eth-4h-worker\n' ;;
  '{{.Config.Image}}') printf '%s\n' "${FAKE_CONFIG_IMAGE}" ;;
  '{{.Image}}') printf '%s\n' "${FAKE_IMAGE_ID}" ;;
  '{{ index .Config.Labels "org.opencontainers.image.revision" }}') printf '%s\n' "${FAKE_REVISION}" ;;
  '{{ index .Config.Labels "com.docker.compose.service" }}') printf 'quant-core-vegas-eth-4h-worker\n' ;;
  '{{.State.Status}}') printf 'running\n' ;;
  '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}') printf '%s\n' "${FAKE_WORKING_DIR}" ;;
  '{{.Id}}') printf '%s\n' "${FAKE_CONTAINER_ID}" ;;
  *) echo "unexpected docker inspect format: $3" >&2; exit 1 ;;
esac
DOCKER
chmod +x "${fake_bin}/docker"

deploy_core_base64="$(base64 < "${source_deploy_dir}/deploy_core.sh" | tr -d '\n')"
runtime_services_base64="$(base64 < "${source_deploy_dir}/runtime-services.txt" | tr -d '\n')"
remote_env=(
  "PATH=${fake_bin}:${PATH}"
  "FAKE_CONFIG_IMAGE=${config_image}"
  "FAKE_IMAGE_ID=${image_id}"
  "FAKE_REVISION=${revision}"
  "FAKE_WORKING_DIR=${working_dir}"
  "FAKE_CONTAINER_ID=${container_id}"
)

for required in \
  "environment:" \
  "name: production" \
  "path: legacy-source" \
  "publish-exact-b983-retirement-contract" \
  "verify-exact-b983-retirement-contract" \
  "SSH_KNOWN_HOSTS" \
  "94d0eec915df3c0011f3c975539428e8582b4019" \
  "787062ab3868ab2d08830d9522b3811ac5d1155a" \
  "f6ab63f8d360609f0823e773627098f19825f70887d5c4d61b98d8f046f01b4c" \
  "bf2a15599e97b464351d31550b52672689c3b8e5983ed7cf04c50d33aedc6c62"; do
  grep -Fq "${required}" "${workflow}"
done

before_missing_verify="$(find "${working_dir}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort || find "${working_dir}" -type f -printf '%p %s %T@\n' | sort)"
if env "${remote_env[@]}" bash "${contract_script}" __remote verify \
  "${revision}" "${config_image}" "${image_id}" "${revision}" \
  verify-exact-b983-retirement-contract > /dev/null 2>&1; then
  echo "verify accepted a missing scripts/deploy directory" >&2
  exit 1
fi
after_missing_verify="$(find "${working_dir}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort || find "${working_dir}" -type f -printf '%p %s %T@\n' | sort)"
[[ "${before_missing_verify}" == "${after_missing_verify}" ]]
[[ ! -e "${working_dir}/scripts/deploy" ]]

env "${remote_env[@]}" bash "${contract_script}" __remote publish \
  "${revision}" "${config_image}" "${image_id}" "${revision}" \
  publish-exact-b983-retirement-contract "${deploy_core_base64}" "${runtime_services_base64}"

deploy_target="${working_dir}/scripts/deploy/deploy_core.sh"
runtime_target="${working_dir}/scripts/deploy/runtime-services.txt"
receipt="${working_dir}/.deploy/eth-4h-market-handoff/retirement-contract-receipt.env"
cmp "${source_deploy_dir}/deploy_core.sh" "${deploy_target}"
cmp "${source_deploy_dir}/runtime-services.txt" "${runtime_target}"
[[ "$(file_mode "${deploy_target}")" == "644" ]]
[[ "$(file_mode "${runtime_target}")" == "644" ]]
[[ "$(file_mode "${receipt}")" == "600" ]]
grep -Fxq "legacy_config_image=${config_image}" "${receipt}"
grep -Fxq "legacy_image_id=${image_id}" "${receipt}"
grep -Fxq "legacy_image_revision=${revision}" "${receipt}"
grep -Fxq "legacy_container_id=${container_id}" "${receipt}"
grep -Fxq "working_dir=${working_dir}" "${receipt}"

before_verify="$(find "${working_dir}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort || find "${working_dir}" -type f -printf '%p %s %T@\n' | sort)"
env "${remote_env[@]}" bash "${contract_script}" __remote verify \
  "${revision}" "${config_image}" "${image_id}" "${revision}" \
  verify-exact-b983-retirement-contract
after_verify="$(find "${working_dir}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort || find "${working_dir}" -type f -printf '%p %s %T@\n' | sort)"
[[ "${before_verify}" == "${after_verify}" ]]

before_publish="${after_verify}"
env "${remote_env[@]}" bash "${contract_script}" __remote publish \
  "${revision}" "${config_image}" "${image_id}" "${revision}" \
  publish-exact-b983-retirement-contract "${deploy_core_base64}" "${runtime_services_base64}"
after_publish="$(find "${working_dir}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort || find "${working_dir}" -type f -printf '%p %s %T@\n' | sort)"
[[ "${before_publish}" == "${after_publish}" ]]

cat > "${fake_bin}/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FAKE_SSH_CALLED_FILE:-}" ]] || touch "${FAKE_SSH_CALLED_FILE}"
while [[ "${1:-}" == "-o" || "${1:-}" == "-p" ]]; do
  shift 2
done
[[ "${1:-}" == "contract-user@contract.invalid" ]]
shift
exec "$@"
SSH
chmod +x "${fake_bin}/ssh"
env "${remote_env[@]}" \
  DEPLOY_SSH_USER=contract-user \
  DEPLOY_SSH_HOST=contract.invalid \
  DEPLOY_LEGACY_CONTRACT_ACTION=verify \
  DEPLOY_LEGACY_CONTRACT_CONFIRM=verify-exact-b983-retirement-contract \
  DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION="${revision}" \
  DEPLOY_LEGACY_CONFIG_IMAGE="${config_image}" \
  DEPLOY_LEGACY_IMAGE_ID="${image_id}" \
  DEPLOY_LEGACY_IMAGE_REVISION="${revision}" \
  DEPLOY_LEGACY_SOURCE_ROOT="${source_root}" \
  bash "${contract_script}"

printf 'different bytes\n' > "${runtime_target}"
if env "${remote_env[@]}" bash "${contract_script}" __remote publish \
  "${revision}" "${config_image}" "${image_id}" "${revision}" \
  publish-exact-b983-retirement-contract "${deploy_core_base64}" "${runtime_services_base64}" \
  > /dev/null 2>&1; then
  echo "publish accepted a conflicting existing target" >&2
  exit 1
fi
[[ "$(cat "${runtime_target}")" == "different bytes" ]]

if grep -En 'docker (stop|start|restart|rm|compose)' "${contract_script}" >/dev/null; then
  echo "retirement contract helper contains a forbidden Docker mutation" >&2
  exit 1
fi

ssh_called="${test_root}/ssh-called"
if env "PATH=${fake_bin}:${PATH}" \
  FAKE_SSH_CALLED_FILE="${ssh_called}" \
  DEPLOY_SSH_USER=contract-user \
  DEPLOY_SSH_HOST=contract.invalid \
  DEPLOY_LEGACY_CONTRACT_ACTION=publish \
  DEPLOY_LEGACY_CONTRACT_CONFIRM=wrong \
  DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION="${revision}" \
  DEPLOY_LEGACY_CONFIG_IMAGE="${config_image}" \
  DEPLOY_LEGACY_IMAGE_ID="${image_id}" \
  DEPLOY_LEGACY_IMAGE_REVISION="${revision}" \
  bash "${contract_script}" > /dev/null 2>&1; then
  echo "local helper accepted an invalid confirmation" >&2
  exit 1
fi
[[ ! -e "${ssh_called}" ]]

echo "legacy retirement contract shell tests passed"
