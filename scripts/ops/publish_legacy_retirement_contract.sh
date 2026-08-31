#!/usr/bin/env bash
set -euo pipefail

readonly CONTRACT_SOURCE_REVISION="b983a481f915aa9986d1829be2ae689ce856b0d3"
readonly DEPLOY_CORE_BLOB="94d0eec915df3c0011f3c975539428e8582b4019"
readonly DEPLOY_CORE_SHA256="f6ab63f8d360609f0823e773627098f19825f70887d5c4d61b98d8f046f01b4c"
readonly RUNTIME_SERVICES_BLOB="787062ab3868ab2d08830d9522b3811ac5d1155a"
readonly RUNTIME_SERVICES_SHA256="bf2a15599e97b464351d31550b52672689c3b8e5983ed7cf04c50d33aedc6c62"
readonly LEGACY_CONTAINER_NAME="quant-core-vegas-eth-4h-worker"

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

single_file_field() {
  local file="$1" key="$2" value
  [[ "$(grep -c "^${key}=" "${file}")" == "1" ]] || return 1
  value="$(sed -n "s/^${key}=//p" "${file}")"
  [[ -n "${value}" && "${value}" != *$'\n'* ]] || return 1
  printf '%s' "${value}"
}

assert_regular_real_directory() {
  local directory="$1"
  [[ "${directory}" =~ ^/[A-Za-z0-9._/-]+$ \
     && "${directory}" != *".."* \
     && -d "${directory}" \
     && ! -L "${directory}" \
     && "$(realpath "${directory}")" == "${directory}" ]]
}

assert_remote_identity() {
  local expected_config_image="$1" expected_image_id="$2" expected_revision="$3"
  local actual_name actual_config_image actual_image_id actual_revision actual_service actual_state
  local working_dir handoff_root release_file ownership_marker release_image release_revision

  actual_name="$(docker inspect --format '{{.Name}}' "${LEGACY_CONTAINER_NAME}")"
  actual_config_image="$(docker inspect --format '{{.Config.Image}}' "${LEGACY_CONTAINER_NAME}")"
  actual_image_id="$(docker inspect --format '{{.Image}}' "${LEGACY_CONTAINER_NAME}")"
  actual_revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "${LEGACY_CONTAINER_NAME}")"
  actual_service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "${LEGACY_CONTAINER_NAME}")"
  actual_state="$(docker inspect --format '{{.State.Status}}' "${LEGACY_CONTAINER_NAME}")"
  working_dir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "${LEGACY_CONTAINER_NAME}")"

  [[ "${actual_name}" == "/${LEGACY_CONTAINER_NAME}" \
     && "${actual_config_image}" == "${expected_config_image}" \
     && "${actual_image_id}" == "${expected_image_id}" \
     && "${actual_revision}" == "${expected_revision}" \
     && "${actual_service}" == "${LEGACY_CONTAINER_NAME}" \
     && "${actual_state}" == "running" ]] \
    || { echo "legacy producer container identity mismatch" >&2; return 1; }
  assert_regular_real_directory "${working_dir}" \
    || { echo "legacy container working directory is not an exact regular realpath" >&2; return 1; }

  handoff_root="${working_dir}/.deploy/eth-4h-market-handoff"
  release_file="${handoff_root}/current-release.env"
  ownership_marker="${handoff_root}/market-ownership-transferred"
  [[ -d "${handoff_root}" && ! -L "${handoff_root}" \
     && "$(realpath "${handoff_root}")" == "${handoff_root}" \
     && -f "${release_file}" && ! -L "${release_file}" \
     && "$(wc -l < "${release_file}" | tr -d ' ')" == "2" \
     && -f "${ownership_marker}" && ! -L "${ownership_marker}" \
     && ! -s "${ownership_marker}" ]] \
    || { echo "legacy Market handoff identity is incomplete" >&2; return 1; }
  release_image="$(single_file_field "${release_file}" image)"
  release_revision="$(single_file_field "${release_file}" revision)"
  [[ "${release_image}" == "${expected_config_image}" \
     && "${release_revision}" == "${expected_revision}" ]] \
    || { echo "legacy Market handoff release identity mismatch" >&2; return 1; }

  printf '%s\n%s\n' "${working_dir}" "$(docker inspect --format '{{.Id}}' "${LEGACY_CONTAINER_NAME}")"
}

assert_contract_file() {
  local file="$1" expected_sha256="$2"
  [[ -f "${file}" && ! -L "${file}" \
     && "$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}")" == "644" \
     && "$(sha256_file "${file}")" == "${expected_sha256}" ]]
}

assert_receipt() {
  local receipt="$1" source_revision="$2" config_image="$3" image_id="$4"
  local image_revision="$5" container_id="$6" working_dir="$7"
  [[ -f "${receipt}" && ! -L "${receipt}" \
     && "$(wc -l < "${receipt}" | tr -d ' ')" == "10" \
     && "$(stat -c '%a' "${receipt}" 2>/dev/null || stat -f '%Lp' "${receipt}")" == "600" ]] \
    || return 1
  grep -Fxq "source_revision=${source_revision}" "${receipt}" \
    && grep -Fxq "deploy_core_blob=${DEPLOY_CORE_BLOB}" "${receipt}" \
    && grep -Fxq "deploy_core_sha256=${DEPLOY_CORE_SHA256}" "${receipt}" \
    && grep -Fxq "runtime_services_blob=${RUNTIME_SERVICES_BLOB}" "${receipt}" \
    && grep -Fxq "runtime_services_sha256=${RUNTIME_SERVICES_SHA256}" "${receipt}" \
    && grep -Fxq "legacy_config_image=${config_image}" "${receipt}" \
    && grep -Fxq "legacy_image_id=${image_id}" "${receipt}" \
    && grep -Fxq "legacy_image_revision=${image_revision}" "${receipt}" \
    && grep -Fxq "legacy_container_id=${container_id}" "${receipt}" \
    && grep -Fxq "working_dir=${working_dir}" "${receipt}"
}

decode_file() {
  local encoded="$1" destination="$2"
  if printf '%s' "${encoded}" | base64 --decode > "${destination}" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${encoded}" | base64 -D > "${destination}"
}

write_receipt() {
  local receipt="$1" source_revision="$2" config_image="$3" image_id="$4"
  local image_revision="$5" container_id="$6" working_dir="$7" handoff_root="$8"
  local temporary_receipt
  temporary_receipt="$(mktemp "${handoff_root}/.retirement-contract-receipt.XXXXXX")"
  chmod 600 "${temporary_receipt}"
  {
    printf 'source_revision=%s\n' "${source_revision}"
    printf 'deploy_core_blob=%s\n' "${DEPLOY_CORE_BLOB}"
    printf 'deploy_core_sha256=%s\n' "${DEPLOY_CORE_SHA256}"
    printf 'runtime_services_blob=%s\n' "${RUNTIME_SERVICES_BLOB}"
    printf 'runtime_services_sha256=%s\n' "${RUNTIME_SERVICES_SHA256}"
    printf 'legacy_config_image=%s\n' "${config_image}"
    printf 'legacy_image_id=%s\n' "${image_id}"
    printf 'legacy_image_revision=%s\n' "${image_revision}"
    printf 'legacy_container_id=%s\n' "${container_id}"
    printf 'working_dir=%s\n' "${working_dir}"
  } > "${temporary_receipt}"
  mv "${temporary_receipt}" "${receipt}"
}

publish_remote() {
  local source_revision="$1" config_image="$2" image_id="$3" image_revision="$4"
  local deploy_core_base64="$5" runtime_services_base64="$6"
  local identity=() working_dir container_id deploy_dir handoff_root receipt staging_dir
  local deploy_target runtime_target deploy_temporary="" runtime_temporary=""
  local created_deploy_dir=0 created_deploy=0 created_runtime=0 created_receipt=0 completed=0
  local final_identity=()

  mapfile -t identity < <(assert_remote_identity "${config_image}" "${image_id}" "${image_revision}")
  [[ "${#identity[@]}" == "2" && "${identity[1]}" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "legacy producer container ID is invalid" >&2; return 1; }
  working_dir="${identity[0]}"
  container_id="${identity[1]}"
  deploy_dir="${working_dir}/scripts/deploy"
  handoff_root="${working_dir}/.deploy/eth-4h-market-handoff"
  receipt="${handoff_root}/retirement-contract-receipt.env"
  assert_regular_real_directory "${working_dir}/scripts" \
    || { echo "legacy scripts target is not an exact regular realpath" >&2; return 1; }
  if [[ -e "${deploy_dir}" || -L "${deploy_dir}" ]]; then
    assert_regular_real_directory "${deploy_dir}" \
      || { echo "legacy scripts/deploy target is not an exact regular realpath" >&2; return 1; }
  else
    mkdir "${deploy_dir}"
    created_deploy_dir=1
    assert_regular_real_directory "${deploy_dir}" \
      || { echo "created legacy scripts/deploy target is not an exact regular realpath" >&2; return 1; }
  fi

  staging_dir="$(mktemp -d "${working_dir}/.legacy-retirement-contract.XXXXXX")"
  cleanup_publish() {
    local status="$?"
    [[ -z "${deploy_temporary}" ]] || rm -f "${deploy_temporary}"
    [[ -z "${runtime_temporary}" ]] || rm -f "${runtime_temporary}"
    rm -f "${staging_dir}/deploy_core.sh" "${staging_dir}/runtime-services.txt"
    rmdir "${staging_dir}" 2>/dev/null || true
    if [[ "${completed}" != "1" && "${created_deploy}" == "1" ]]; then
      rm -f "${deploy_dir}/deploy_core.sh"
    fi
    if [[ "${completed}" != "1" && "${created_runtime}" == "1" ]]; then
      rm -f "${deploy_dir}/runtime-services.txt"
    fi
    if [[ "${completed}" != "1" && "${created_receipt}" == "1" ]]; then
      rm -f "${receipt}"
    fi
    if [[ "${completed}" != "1" && "${created_deploy_dir}" == "1" ]]; then
      rmdir "${deploy_dir}" 2>/dev/null || true
    fi
    return "${status}"
  }
  trap cleanup_publish EXIT

  decode_file "${deploy_core_base64}" "${staging_dir}/deploy_core.sh"
  decode_file "${runtime_services_base64}" "${staging_dir}/runtime-services.txt"
  chmod 644 "${staging_dir}/deploy_core.sh"
  chmod 644 "${staging_dir}/runtime-services.txt"
  assert_contract_file "${staging_dir}/deploy_core.sh" "${DEPLOY_CORE_SHA256}" \
    && assert_contract_file "${staging_dir}/runtime-services.txt" "${RUNTIME_SERVICES_SHA256}" \
    || { echo "uploaded retirement contract bytes do not match b983" >&2; return 1; }

  deploy_target="${deploy_dir}/deploy_core.sh"
  runtime_target="${deploy_dir}/runtime-services.txt"
  if [[ -e "${deploy_target}" || -L "${deploy_target}" ]]; then
    assert_contract_file "${deploy_target}" "${DEPLOY_CORE_SHA256}" \
      || { echo "existing deploy_core.sh is not the exact retirement contract" >&2; return 1; }
  fi
  if [[ -e "${runtime_target}" || -L "${runtime_target}" ]]; then
    assert_contract_file "${runtime_target}" "${RUNTIME_SERVICES_SHA256}" \
      || { echo "existing runtime-services.txt is not the exact retirement contract" >&2; return 1; }
  fi
  if [[ -e "${receipt}" || -L "${receipt}" ]]; then
    assert_receipt "${receipt}" "${source_revision}" "${config_image}" "${image_id}" \
      "${image_revision}" "${container_id}" "${working_dir}" \
      || { echo "existing retirement contract receipt identity mismatch" >&2; return 1; }
  fi

  if [[ ! -e "${deploy_target}" ]]; then
    deploy_temporary="$(mktemp "${deploy_dir}/.deploy_core.sh.XXXXXX")"
    install -m 0644 "${staging_dir}/deploy_core.sh" "${deploy_temporary}"
    mv "${deploy_temporary}" "${deploy_target}"
    deploy_temporary=""
    created_deploy=1
  fi
  if [[ ! -e "${runtime_target}" ]]; then
    runtime_temporary="$(mktemp "${deploy_dir}/.runtime-services.txt.XXXXXX")"
    install -m 0644 "${staging_dir}/runtime-services.txt" "${runtime_temporary}"
    mv "${runtime_temporary}" "${runtime_target}"
    runtime_temporary=""
    created_runtime=1
  fi
  if [[ ! -e "${receipt}" ]]; then
    write_receipt "${receipt}" "${source_revision}" "${config_image}" "${image_id}" \
      "${image_revision}" "${container_id}" "${working_dir}" "${handoff_root}"
    created_receipt=1
  fi
  assert_contract_file "${deploy_target}" "${DEPLOY_CORE_SHA256}"
  assert_contract_file "${runtime_target}" "${RUNTIME_SERVICES_SHA256}"
  assert_receipt "${receipt}" "${source_revision}" "${config_image}" "${image_id}" \
    "${image_revision}" "${container_id}" "${working_dir}"
  mapfile -t final_identity < <(assert_remote_identity "${config_image}" "${image_id}" "${image_revision}")
  [[ "${final_identity[0]:-}" == "${working_dir}" && "${final_identity[1]:-}" == "${container_id}" ]] \
    || { echo "legacy producer identity changed during retirement contract publication" >&2; return 1; }
  completed=1
  trap - EXIT
  cleanup_publish
  echo "legacy retirement contract published for ${source_revision}"
}

verify_remote() {
  local source_revision="$1" config_image="$2" image_id="$3" image_revision="$4"
  local identity=() working_dir container_id handoff_root
  mapfile -t identity < <(assert_remote_identity "${config_image}" "${image_id}" "${image_revision}")
  [[ "${#identity[@]}" == "2" && "${identity[1]}" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "legacy producer container ID is invalid" >&2; return 1; }
  working_dir="${identity[0]}"
  container_id="${identity[1]}"
  handoff_root="${working_dir}/.deploy/eth-4h-market-handoff"
  assert_regular_real_directory "${working_dir}/scripts" \
    && assert_regular_real_directory "${working_dir}/scripts/deploy" \
    || { echo "legacy scripts/deploy target is not an exact regular realpath" >&2; return 1; }
  assert_contract_file "${working_dir}/scripts/deploy/deploy_core.sh" "${DEPLOY_CORE_SHA256}"
  assert_contract_file "${working_dir}/scripts/deploy/runtime-services.txt" "${RUNTIME_SERVICES_SHA256}"
  assert_receipt "${handoff_root}/retirement-contract-receipt.env" "${source_revision}" \
    "${config_image}" "${image_id}" "${image_revision}" "${container_id}" "${working_dir}"
  echo "legacy retirement contract verified for ${source_revision}"
}

remote_main() {
  local action="$1" source_revision="$2" config_image="$3" image_id="$4" image_revision="$5"
  local confirmation="$6" deploy_core_base64="${7:-}" runtime_services_base64="${8:-}"
  local expected_confirmation
  case "${action}" in
    publish) expected_confirmation="publish-exact-b983-retirement-contract" ;;
    verify) expected_confirmation="verify-exact-b983-retirement-contract" ;;
    *) echo "invalid legacy retirement contract action" >&2; return 2 ;;
  esac
  [[ "${confirmation}" == "${expected_confirmation}" \
     && "${source_revision}" == "${CONTRACT_SOURCE_REVISION}" \
     && "${image_revision}" == "${CONTRACT_SOURCE_REVISION}" \
     && "${config_image}" =~ ^[A-Za-z0-9._/:@-]+$ \
     && "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { echo "invalid legacy retirement contract identity or confirmation" >&2; return 1; }
  if [[ "${action}" == "publish" ]]; then
    [[ -n "${deploy_core_base64}" && -n "${runtime_services_base64}" ]] \
      || { echo "publish requires exact contract bytes" >&2; return 1; }
    publish_remote "${source_revision}" "${config_image}" "${image_id}" "${image_revision}" \
      "${deploy_core_base64}" "${runtime_services_base64}"
  else
    [[ -z "${deploy_core_base64}" && -z "${runtime_services_base64}" ]] \
      || { echo "verify accepts no contract payload" >&2; return 1; }
    verify_remote "${source_revision}" "${config_image}" "${image_id}" "${image_revision}"
  fi
}

local_main() {
  : "${DEPLOY_SSH_USER:?DEPLOY_SSH_USER is required}"
  : "${DEPLOY_SSH_HOST:?DEPLOY_SSH_HOST is required}"
  : "${DEPLOY_LEGACY_CONTRACT_ACTION:?DEPLOY_LEGACY_CONTRACT_ACTION is required}"
  : "${DEPLOY_LEGACY_CONTRACT_CONFIRM:?DEPLOY_LEGACY_CONTRACT_CONFIRM is required}"
  : "${DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION:?DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION is required}"
  : "${DEPLOY_LEGACY_CONFIG_IMAGE:?DEPLOY_LEGACY_CONFIG_IMAGE is required}"
  : "${DEPLOY_LEGACY_IMAGE_ID:?DEPLOY_LEGACY_IMAGE_ID is required}"
  : "${DEPLOY_LEGACY_IMAGE_REVISION:?DEPLOY_LEGACY_IMAGE_REVISION is required}"
  local expected_confirmation script_dir controller_root source_root deploy_core runtime_services
  local deploy_core_base64="" runtime_services_base64="" ssh_port ssh_target

  case "${DEPLOY_LEGACY_CONTRACT_ACTION}" in
    publish) expected_confirmation="publish-exact-b983-retirement-contract" ;;
    verify) expected_confirmation="verify-exact-b983-retirement-contract" ;;
    *) echo "invalid DEPLOY_LEGACY_CONTRACT_ACTION" >&2; return 2 ;;
  esac
  [[ "${DEPLOY_LEGACY_CONTRACT_CONFIRM}" == "${expected_confirmation}" \
     && "${DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION}" == "${CONTRACT_SOURCE_REVISION}" \
     && "${DEPLOY_LEGACY_IMAGE_REVISION}" == "${CONTRACT_SOURCE_REVISION}" \
     && "${DEPLOY_SSH_USER}" =~ ^[A-Za-z0-9._-]+$ \
     && "${DEPLOY_SSH_HOST}" =~ ^[A-Za-z0-9.:-]+$ \
     && "${DEPLOY_LEGACY_CONFIG_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ \
     && "${DEPLOY_LEGACY_IMAGE_ID}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { echo "invalid legacy retirement contract request" >&2; return 1; }

  script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  controller_root="$(CDPATH= cd -- "${script_dir}/../.." && pwd)"
  source_root="${DEPLOY_LEGACY_SOURCE_ROOT:-${controller_root}}"
  [[ "${source_root}" =~ ^/[A-Za-z0-9._/-]+$ \
     && "${source_root}" != *".."* \
     && -d "${source_root}" \
     && ! -L "${source_root}" \
     && "$(realpath "${source_root}")" == "${source_root}" \
     && "$(git -C "${source_root}" rev-parse HEAD)" == "${CONTRACT_SOURCE_REVISION}" \
     && "$(git -C "${source_root}" rev-parse "HEAD:scripts/deploy/deploy_core.sh")" == "${DEPLOY_CORE_BLOB}" \
     && "$(git -C "${source_root}" rev-parse "HEAD:scripts/deploy/runtime-services.txt")" == "${RUNTIME_SERVICES_BLOB}" ]] \
    || { echo "checked-out legacy source identity mismatch" >&2; return 1; }
  deploy_core="${source_root}/scripts/deploy/deploy_core.sh"
  runtime_services="${source_root}/scripts/deploy/runtime-services.txt"
  assert_contract_file "${deploy_core}" "${DEPLOY_CORE_SHA256}" \
    && assert_contract_file "${runtime_services}" "${RUNTIME_SERVICES_SHA256}" \
    || { echo "checked-out legacy retirement contract bytes mismatch" >&2; return 1; }
  if [[ "${DEPLOY_LEGACY_CONTRACT_ACTION}" == "publish" ]]; then
    deploy_core_base64="$(base64 < "${deploy_core}" | tr -d '\n')"
    runtime_services_base64="$(base64 < "${runtime_services}" | tr -d '\n')"
  fi

  ssh_port="${DEPLOY_SSH_PORT:-22}"
  [[ "${ssh_port}" =~ ^[0-9]{1,5}$ ]] || { echo "invalid DEPLOY_SSH_PORT" >&2; return 1; }
  ssh_target="${DEPLOY_SSH_USER}@${DEPLOY_SSH_HOST}"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -p "${ssh_port}" "${ssh_target}" \
    bash -s -- __remote \
    "${DEPLOY_LEGACY_CONTRACT_ACTION}" \
    "${DEPLOY_LEGACY_CONTRACT_SOURCE_REVISION}" \
    "${DEPLOY_LEGACY_CONFIG_IMAGE}" \
    "${DEPLOY_LEGACY_IMAGE_ID}" \
    "${DEPLOY_LEGACY_IMAGE_REVISION}" \
    "${DEPLOY_LEGACY_CONTRACT_CONFIRM}" \
    "${deploy_core_base64}" \
    "${runtime_services_base64}" < "${BASH_SOURCE[0]}"
}

if [[ "${1:-}" == "__remote" ]]; then
  shift
  remote_main "$@"
else
  local_main "$@"
fi
