#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_dir="$(cd "${script_dir}/../../../" && pwd)"

BUILD_ROOT="${BUILD_ROOT:-${repo_root_dir}/build/asterinas-coco-release}"
WORK_DIR="${BUILD_ROOT}/guest-artifacts"
SRC_DIR="${WORK_DIR}/src"
OUT_DIR="${WORK_DIR}/out"

GUEST_COMPONENTS_REPOSITORY="${GUEST_COMPONENTS_REPOSITORY:-https://github.com/taosue/guest-components}"
GUEST_COMPONENTS_REF="${GUEST_COMPONENTS_REF:-main}"
GUEST_COMPONENTS_COMMIT="${GUEST_COMPONENTS_COMMIT:-}"
GUEST_COMPONENTS_TEE_PLATFORM="${GUEST_COMPONENTS_TEE_PLATFORM:-all}"
PAUSE_IMAGE_REPOSITORY="${PAUSE_IMAGE_REPOSITORY:-docker://registry.k8s.io/pause}"
PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION:-3.10}"

GUEST_COMPONENTS_DIR="${OUT_DIR}/guest-components"
PAUSE_BUNDLE_DIR="${OUT_DIR}/pause/pause_bundle"

die() {
	echo >&2 "ERROR: $*"
	exit 1
}

require_cmd() {
	local cmd

	for cmd in "$@"; do
		command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
	done
}

emit_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
	fi
}

resolve_guest_components_commit() {
	local ls_remote_output

	if [ -n "${GUEST_COMPONENTS_COMMIT}" ]; then
		return 0
	fi

	ls_remote_output="$(git ls-remote "${GUEST_COMPONENTS_REPOSITORY}" "refs/heads/${GUEST_COMPONENTS_REF}")"
	GUEST_COMPONENTS_COMMIT="${ls_remote_output%%$'\t'*}"
	[ -n "${GUEST_COMPONENTS_COMMIT}" ] || die "failed to resolve ${GUEST_COMPONENTS_REPOSITORY}@${GUEST_COMPONENTS_REF}"
}

clone_guest_components() {
	rm -rf "${SRC_DIR}/guest-components"
	git clone --filter=blob:none "${GUEST_COMPONENTS_REPOSITORY}" "${SRC_DIR}/guest-components"
	git -C "${SRC_DIR}/guest-components" checkout "${GUEST_COMPONENTS_COMMIT}"
}

build_guest_components_tarball() {
	rm -rf "${GUEST_COMPONENTS_DIR}"
	mkdir -p "${GUEST_COMPONENTS_DIR}/usr/local/bin" "${GUEST_COMPONENTS_DIR}/etc"

pushd "${SRC_DIR}/guest-components" >/dev/null
	DESTDIR="${GUEST_COMPONENTS_DIR}/usr/local/bin" TEE_PLATFORM="${GUEST_COMPONENTS_TEE_PLATFORM}" LIBC=gnu make build
	DESTDIR="${GUEST_COMPONENTS_DIR}/usr/local/bin" TEE_PLATFORM="${GUEST_COMPONENTS_TEE_PLATFORM}" LIBC=gnu make install
	install -m 0644 confidential-data-hub/hub/src/image/ocicrypt_config.json "${GUEST_COMPONENTS_DIR}/etc/ocicrypt_config.json"
popd >/dev/null
}

build_pause_image_tarball() {
	local pause_dir="${OUT_DIR}/pause"
	local oci_dir="${pause_dir}/oci"

	rm -rf "${pause_dir}"
	mkdir -p "${oci_dir}"

	skopeo copy "${PAUSE_IMAGE_REPOSITORY}:${PAUSE_IMAGE_VERSION}" "oci:${oci_dir}:${PAUSE_IMAGE_VERSION}"
	umoci unpack --rootless --image "${oci_dir}:${PAUSE_IMAGE_VERSION}" "${PAUSE_BUNDLE_DIR}"
	rm -f "${PAUSE_BUNDLE_DIR}/umoci.json"
}

require_cmd git install make skopeo umoci

mkdir -p "${SRC_DIR}" "${OUT_DIR}"

resolve_guest_components_commit
clone_guest_components
build_guest_components_tarball
build_pause_image_tarball

emit_output "guest_components_dir" "${GUEST_COMPONENTS_DIR}"
emit_output "pause_bundle_dir" "${PAUSE_BUNDLE_DIR}"
emit_output "guest_components_commit" "${GUEST_COMPONENTS_COMMIT}"
