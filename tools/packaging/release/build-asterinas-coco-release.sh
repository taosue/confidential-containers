#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_dir="$(cd "${script_dir}/../../../" && pwd)"

ARCHITECTURE="${ARCHITECTURE:-amd64}"
VERSION="${VERSION:-$(<"${repo_root_dir}/VERSION")}"
KATA_VERSION="${KATA_VERSION:-$(<"${repo_root_dir}/KATA_VERSION")}"
source "${repo_root_dir}/tools/scripts/asterinas-coco-defaults.sh"

BUILD_ROOT="${BUILD_ROOT:-${repo_root_dir}/build/asterinas-coco-release}"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
DIST_DIR="${BUILD_ROOT}/dist"
STAGING_DIR="${BUILD_ROOT}/staging"
ARTIFACTS_DIR="${BUILD_ROOT}/artifacts"

KATA_RELEASE_URL_BASE="https://github.com/${KATA_RELEASE_REPOSITORY}/releases/download/${KATA_RELEASE_TAG}"
KATA_RELEASE_API_URL="https://api.github.com/repos/${KATA_RELEASE_REPOSITORY}/releases/tags/${KATA_RELEASE_TAG}"
KATA_STATIC_ASSET_NAME="${KATA_STATIC_ASSET_NAME:-}"
KATA_STATIC_URL="${KATA_STATIC_URL:-}"
KATA_SOURCE_DIR="${BUILD_ROOT}/src/kata-containers"
KATA_ROOTFS_DIR="${BUILD_ROOT}/kata-rootfs"

RELEASE_BASENAME="${RELEASE_BASENAME:-asterinas-coco-${VERSION}-${ARCHITECTURE}}"
CUSTOMIZED_INITRD_FILE="${DIST_DIR}/kata-containers-initrd.img"
RELEASE_ASSET="${DIST_DIR}/${RELEASE_BASENAME}.tar.gz"
MANIFEST_FILE="${DIST_DIR}/${RELEASE_BASENAME}.manifest.json"
CHECKSUMS_FILE="${DIST_DIR}/${RELEASE_BASENAME}.SHA256SUMS"
RELEASE_NOTES="${DIST_DIR}/${RELEASE_BASENAME}.release-notes.md"

die() {
	echo >&2 "ERROR: $*"
	exit 1
}

download_release_metadata() {
	local metadata_file="$1"
	local -a auth_args=()

	if [ -n "${GITHUB_TOKEN:-}" ]; then
		auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi

	curl --fail --location --silent --show-error \
		-H "Accept: application/vnd.github+json" \
		"${auth_args[@]}" \
		"${KATA_RELEASE_API_URL}" \
		--output "${metadata_file}"
}

resolve_kata_static_asset() {
	local metadata_file="${DOWNLOAD_DIR}/kata-release.json"
	local resolved_asset_name
	local resolved_asset_url

	if [ -n "${KATA_STATIC_URL}" ]; then
		KATA_STATIC_ASSET_NAME="${KATA_STATIC_ASSET_NAME:-$(basename "${KATA_STATIC_URL%%\?*}")}"
		return 0
	fi

	download_release_metadata "${metadata_file}"
	resolved_asset_name="$(
		python3 -c '
import json
import sys

arch = sys.argv[1]
with open(sys.argv[2], "r", encoding="utf-8") as f:
    release = json.load(f)

for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(".tar.zst") and "asterinas" in name and arch in name:
        print(name)
        break
' "${ARCHITECTURE}" "${metadata_file}"
	)"
	[ -n "${resolved_asset_name}" ] || die "failed to resolve Asterinas Kata static asset from ${KATA_RELEASE_API_URL}"

	resolved_asset_url="$(
		python3 -c '
import json
import sys

target = sys.argv[1]
with open(sys.argv[2], "r", encoding="utf-8") as f:
    release = json.load(f)

for asset in release.get("assets", []):
    if asset.get("name") == target:
        print(asset.get("browser_download_url", ""))
        break
' "${resolved_asset_name}" "${metadata_file}"
	)"
	[ -n "${resolved_asset_url}" ] || die "failed to resolve download URL for ${resolved_asset_name}"

	KATA_STATIC_ASSET_NAME="${resolved_asset_name}"
	KATA_STATIC_URL="${resolved_asset_url}"
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

write_manifest() {
	cat > "${MANIFEST_FILE}" <<EOF
{
  "built_at_utc": "${BUILD_TIME_UTC}",
  "coco_version": "${VERSION}",
  "kata_version": "${KATA_VERSION}",
  "kata_release_tag": "${KATA_RELEASE_TAG}",
  "kata_release_repository": "${KATA_RELEASE_REPOSITORY}",
  "kata_release_package_url": "${KATA_STATIC_URL}",
  "kata_static_url": "${KATA_STATIC_URL}",
  "kata_static_asset_name": "${KATA_STATIC_ASSET_NAME}",
  "kata_initrd_path": "opt/kata/share/kata-containers/kata-containers-initrd.img",
  "guest_components_repository": "${GUEST_COMPONENTS_REPOSITORY}",
  "guest_components_ref": "${GUEST_COMPONENTS_REF}",
  "guest_components_commit": "${GUEST_COMPONENTS_COMMIT}",
  "guest_components_paths": [
    "/usr/local/bin/confidential-data-hub",
    "/usr/local/bin/attestation-agent",
    "/usr/local/bin/api-server-rest",
    "/etc/ocicrypt_config.json"
  ],
  "pause_image_repository": "${PAUSE_IMAGE_REPOSITORY}",
  "pause_image_version": "${PAUSE_IMAGE_VERSION}",
  "pause_bundle_path": "/pause_bundle",
  "resolv_conf_nameserver": "${RESOLV_CONF_NAMESERVER}",
  "architecture": "${ARCHITECTURE}",
  "git_commit": "${GIT_COMMIT}"
}
EOF
}

write_release_notes() {
	local release_sha

	release_sha="$(sha256sum "${RELEASE_ASSET}" | awk '{print $1}')"

	cat > "${RELEASE_NOTES}" <<EOF
# Asterinas CoCo ${VERSION}

- CoCo version: \`${VERSION}\`
- Kata release tag: [\`${KATA_RELEASE_TAG}\`](https://github.com/${KATA_RELEASE_REPOSITORY}/tree/${KATA_RELEASE_TAG})
- Kata release package: [\`${KATA_STATIC_ASSET_NAME}\`](${KATA_STATIC_URL})
- Kata initrd path: \`artifacts/kata-containers-initrd.img\`
- Guest Components commit: [\`${GUEST_COMPONENTS_COMMIT}\`](${GUEST_COMPONENTS_REPOSITORY}/commit/${GUEST_COMPONENTS_COMMIT})
- Guest components paths inside initrd: \`/usr/local/bin/{confidential-data-hub, attestation-agent, api-server-rest}\`
- Pause image: \`${PAUSE_IMAGE_REPOSITORY}:${PAUSE_IMAGE_VERSION}\`
- Asset SHA256: \`${release_sha}\`
EOF
}

build_coco_guest_artifacts() {
	local guest_output_file="${ARTIFACTS_DIR}/guest-artifacts.outputs"

	rm -rf "${ARTIFACTS_DIR}"
	mkdir -p "${ARTIFACTS_DIR}"

	GITHUB_OUTPUT="${guest_output_file}" \
	BUILD_ROOT="${BUILD_ROOT}" \
	KATA_SOURCE_DIR="${KATA_SOURCE_DIR}" \
	GUEST_COMPONENTS_REPOSITORY="${GUEST_COMPONENTS_REPOSITORY}" \
	GUEST_COMPONENTS_REF="${GUEST_COMPONENTS_REF}" \
	PAUSE_IMAGE_REPOSITORY="${PAUSE_IMAGE_REPOSITORY}" \
	PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION}" \
	"${script_dir}/build-coco-guest-artifacts.sh"

	GUEST_COMPONENTS_COMMIT="$(sed -n 's/^guest_components_commit=//p' "${guest_output_file}" | head -n 1)"
	COCO_GUEST_COMPONENTS_TARBALL="$(sed -n 's/^guest_components_tarball=//p' "${guest_output_file}" | head -n 1)"
	PAUSE_IMAGE_TARBALL="$(sed -n 's/^pause_image_tarball=//p' "${guest_output_file}" | head -n 1)"

	[ -n "${GUEST_COMPONENTS_COMMIT}" ] || die "failed to capture guest components commit"
	[ -n "${COCO_GUEST_COMPONENTS_TARBALL}" ] || die "failed to capture guest components tarball"
	[ -n "${PAUSE_IMAGE_TARBALL}" ] || die "failed to capture pause image tarball"
}

prepare_kata_source_tree() {
	rm -rf "${KATA_SOURCE_DIR}"
	mkdir -p "$(dirname "${KATA_SOURCE_DIR}")"
	git clone --branch "${KATA_RELEASE_TAG}" --depth 1 "https://github.com/${KATA_RELEASE_REPOSITORY}.git" "${KATA_SOURCE_DIR}"
}

rebuild_initrd() {
	KATA_SOURCE_DIR="${KATA_SOURCE_DIR}" \
	ROOTFS_DIR="${KATA_ROOTFS_DIR}" \
	OUTPUT_INITRD_PATH="${CUSTOMIZED_INITRD_FILE}" \
	COCO_GUEST_COMPONENTS_TARBALL="${COCO_GUEST_COMPONENTS_TARBALL}" \
	PAUSE_IMAGE_TARBALL="${PAUSE_IMAGE_TARBALL}" \
	RESOLV_CONF_NAMESERVER="${RESOLV_CONF_NAMESERVER}" \
	"${script_dir}/rebuild-coco-initrd.sh"
}

stage_release_tree() {
	rm -rf "${STAGING_DIR}"
	mkdir -p "${STAGING_DIR}/artifacts"

	install -m 0644 "${CUSTOMIZED_INITRD_FILE}" "${STAGING_DIR}/artifacts/kata-containers-initrd.img"
	install -m 0644 "${MANIFEST_FILE}" "${STAGING_DIR}/manifest.json"
}

require_cmd awk cargo curl docker git gzip python3 script sha256sum sudo tar zstd install

mkdir -p "${DOWNLOAD_DIR}" "${DIST_DIR}"
sudo chown -R "$(id -u)":"$(id -g)" "${BUILD_ROOT}" 2>/dev/null || true

BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git -C "${repo_root_dir}" rev-parse HEAD)"

resolve_kata_static_asset
prepare_kata_source_tree
build_coco_guest_artifacts
rebuild_initrd
write_manifest
stage_release_tree

tar \
	--sort=name \
	--owner=0 \
	--group=0 \
	--numeric-owner \
	-C "${STAGING_DIR}" \
	-czf "${RELEASE_ASSET}" \
	.

write_release_notes
sha256sum \
	"${RELEASE_ASSET}" \
	"${MANIFEST_FILE}" \
	> "${CHECKSUMS_FILE}"

emit_output "release_asset" "${RELEASE_ASSET}"
emit_output "manifest_file" "${MANIFEST_FILE}"
emit_output "checksums_file" "${CHECKSUMS_FILE}"
emit_output "release_notes" "${RELEASE_NOTES}"
emit_output "kata_initrd" "${CUSTOMIZED_INITRD_FILE}"
