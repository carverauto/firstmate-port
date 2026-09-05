#!/usr/bin/env bash
# Vendored from serviceradar scripts/install-bazelisk.sh (captain directive:
# copy the working publish/Bazel bootstrap; ghcr only, no Harbor here).
# Installs the bazelisk shim; the Bazel distribution itself lands in
# BAZELISK_HOME, which publish-oci.yml persists with actions/cache.

set -euo pipefail

version="${BAZELISK_VERSION:-v1.28.1}"
install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-download-integrity.sh"
base_url="${BAZELISK_BASE_URL:-https://github.com/bazelbuild/bazelisk/releases/download}"
retries="${BAZELISK_DOWNLOAD_RETRIES:-5}"

case "$(uname -m)" in
  x86_64|amd64)
    asset="bazelisk-linux-amd64"
    expected_sha256="${BAZELISK_SHA256:-22e7d3a188699982f661cf4687137ee52d1f24fec1ec893d91a6c4d791a75de8}"
    ;;
  aarch64|arm64)
    asset="bazelisk-linux-arm64"
    expected_sha256="${BAZELISK_SHA256:-8ded44b58a0d9425a4178af26cf17693feac3b87bdcfef0a2a0898fcd1afc9f2}"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$version" != "v1.28.1" && -z "${BAZELISK_SHA256:-}" ]]; then
  expected_sha256=""
fi

# Prefer a preinstalled bazelisk (ARC image / cache) when the pinned SHA
# matches — matches serviceradar. Only curl GitHub releases on miss/mismatch.
# (Forced download hung on arc-runner-set when egress to github.com stalled.)
mkdir -p "${install_root}"
install_path="${install_root}/bazelisk"
if command -v bazelisk >/dev/null 2>&1; then
  existing_bazelisk="$(command -v bazelisk)"
  if [[ "${existing_bazelisk}" != "${install_path}" ]]; then
    cp "${existing_bazelisk}" "${install_path}"
  fi
  if sr_verify_sha256 "${install_path}" "$expected_sha256" "bazelisk ${version} ${asset}" 2>/dev/null; then
    echo "reusing existing bazelisk at ${install_path}"
  else
    echo "existing bazelisk SHA mismatch; downloading ${version}"
    command -v bazelisk >/dev/null 2>&1 && rm -f "${install_path}"
    need_download=1
  fi
else
  need_download=1
fi

if [[ "${need_download:-0}" == 1 ]]; then
  tmp_download="${tmpdir}/bazelisk"
  rm -f "${tmp_download}"
  curl_args=(
    --fail
    --show-error
    --location
    --connect-timeout 20
    --max-time 120
    --retry "${retries}"
    --retry-delay 2
    --retry-max-time 180
  )
  if curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"; then
    curl_args+=(--retry-all-errors)
  fi
  curl "${curl_args[@]}" \
    "${base_url}/${version}/${asset}" \
    -o "${tmp_download}"
  sr_verify_sha256 "${tmp_download}" "$expected_sha256" "bazelisk ${version} ${asset}"
  install -m 0755 "${tmp_download}" "${install_path}"
fi
chmod +x "${install_path}"
ln -sf bazelisk "${install_root}/bazel"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
else
  export PATH="${install_root}:${PATH}"
fi

"${install_root}/bazelisk" --version
