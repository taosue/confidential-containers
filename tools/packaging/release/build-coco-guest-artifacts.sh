#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_dir="$(cd "${script_dir}/../../../" && pwd)"
source "${repo_root_dir}/tools/scripts/asterinas-coco-defaults.sh"

BUILD_ROOT="${BUILD_ROOT:-${repo_root_dir}/build/asterinas-coco-release}"
KATA_SOURCE_DIR="${KATA_SOURCE_DIR:?KATA_SOURCE_DIR must be set}"
WORK_DIR="${GUEST_ARTIFACTS_WORK_DIR:-${KATA_SOURCE_DIR}/build/asterinas-coco-guest-artifacts}"
OUT_DIR="${WORK_DIR}/out"

GUEST_COMPONENTS_COMMIT="${GUEST_COMPONENTS_COMMIT:-}"

GUEST_COMPONENTS_DIR="${OUT_DIR}/guest-components"
PAUSE_BUNDLE_DIR="${OUT_DIR}/pause/pause_bundle"
GUEST_COMPONENTS_TARBALL="${OUT_DIR}/kata-static-coco-guest-components.tar.zst"
PAUSE_IMAGE_TARBALL="${OUT_DIR}/kata-static-pause-image.tar.zst"

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

build_guest_components_tarball() {
	local kata_coco_build_script="${KATA_SOURCE_DIR}/tools/packaging/static-build/coco-guest-components/build.sh"

	rm -rf "${GUEST_COMPONENTS_DIR}"
	mkdir -p "${GUEST_COMPONENTS_DIR}/usr/local/bin" "${GUEST_COMPONENTS_DIR}/etc"
	sudo chown -R "$(id -u)":"$(id -g)" "${WORK_DIR}" 2>/dev/null || true

	# The Kata static build helper enables SNP, TDX, and NVIDIA attesters on
	# x86_64. This release only needs the TDX attester, so patch the temporary
	# Kata source checkout before invoking the helper.
	sed -i \
		's/ATTESTER="snp-attester,tdx-attester,nvidia-attester"/ATTESTER="tdx-attester"/' \
		"${kata_coco_build_script}"

	pushd "${KATA_SOURCE_DIR}/tools/packaging/static-build/coco-guest-components" >/dev/null
		DESTDIR="${GUEST_COMPONENTS_DIR}" \
		coco_guest_components_repo="${GUEST_COMPONENTS_REPOSITORY}" \
		coco_guest_components_version="${GUEST_COMPONENTS_COMMIT}" \
		./build.sh
	popd >/dev/null

	rm -f "${GUEST_COMPONENTS_TARBALL}"
	tar --zstd -cvf "${GUEST_COMPONENTS_TARBALL}" \
		-C "${GUEST_COMPONENTS_DIR}" \
		usr/local/bin/confidential-data-hub \
		usr/local/bin/attestation-agent \
		usr/local/bin/api-server-rest \
		etc/ocicrypt_config.json
}

build_pause_image_tarball() {
	local pause_dir="${OUT_DIR}/pause"

	rm -rf "${pause_dir}"
	mkdir -p "${pause_dir}"
	sudo chown -R "$(id -u)":"$(id -g)" "${WORK_DIR}" 2>/dev/null || true

	pushd "${KATA_SOURCE_DIR}/tools/packaging/static-build/pause-image" >/dev/null
		DESTDIR="${pause_dir}" \
		pause_image_repo="${PAUSE_IMAGE_REPOSITORY}" \
		pause_image_version="${PAUSE_IMAGE_VERSION}" \
		./build.sh
	popd >/dev/null

	rm -f "${PAUSE_IMAGE_TARBALL}"
	tar --zstd -cvf "${PAUSE_IMAGE_TARBALL}" -C "${pause_dir}" pause_bundle
}

require_cmd docker git install sudo tar

mkdir -p "${OUT_DIR}"
[ -d "${KATA_SOURCE_DIR}" ] || die "KATA_SOURCE_DIR does not exist: ${KATA_SOURCE_DIR}"

if ! command -v yq >/dev/null 2>&1; then
	"${KATA_SOURCE_DIR}/ci/install_yq.sh"
fi

resolve_guest_components_commit
build_guest_components_tarball
build_pause_image_tarball

emit_output "guest_components_commit" "${GUEST_COMPONENTS_COMMIT}"
emit_output "guest_components_tarball" "${GUEST_COMPONENTS_TARBALL}"
emit_output "pause_image_tarball" "${PAUSE_IMAGE_TARBALL}"
