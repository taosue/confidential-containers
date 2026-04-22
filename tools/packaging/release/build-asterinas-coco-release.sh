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
KATA_RELEASE_REPOSITORY="${KATA_RELEASE_REPOSITORY:-jjf-dev/kata-containers}"
KATA_RELEASE_TAG="${KATA_RELEASE_TAG:-${KATA_VERSION}-asterinas}"

BUILD_ROOT="${BUILD_ROOT:-${repo_root_dir}/build/asterinas-coco-release}"
DOWNLOAD_DIR="${BUILD_ROOT}/downloads"
DIST_DIR="${BUILD_ROOT}/dist"
STAGING_DIR="${BUILD_ROOT}/staging"
EXTRACT_DIR="${BUILD_ROOT}/extract"
ARTIFACTS_DIR="${BUILD_ROOT}/artifacts"

KATA_RELEASE_URL_BASE="https://github.com/${KATA_RELEASE_REPOSITORY}/releases/download/${KATA_RELEASE_TAG}"
KATA_RELEASE_API_URL="https://api.github.com/repos/${KATA_RELEASE_REPOSITORY}/releases/tags/${KATA_RELEASE_TAG}"
KATA_STATIC_ASSET_NAME="${KATA_STATIC_ASSET_NAME:-}"
KATA_STATIC_URL="${KATA_STATIC_URL:-}"
GUEST_COMPONENTS_REPOSITORY="${GUEST_COMPONENTS_REPOSITORY:-https://github.com/taosue/guest-components}"
GUEST_COMPONENTS_REF="${GUEST_COMPONENTS_REF:-main}"
PAUSE_IMAGE_REPOSITORY="${PAUSE_IMAGE_REPOSITORY:-docker://registry.k8s.io/pause}"
PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION:-3.10}"
RESOLV_CONF_NAMESERVER="${RESOLV_CONF_NAMESERVER:-8.8.8.8}"

RELEASE_BASENAME="${RELEASE_BASENAME:-asterinas-coco-${VERSION}-${ARCHITECTURE}}"
KATA_STATIC_FILE="${DOWNLOAD_DIR}/${KATA_STATIC_ASSET_NAME}"
INITRD_FILE="${DOWNLOAD_DIR}/kata-containers-initrd.img"
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

extract_kata_initrd() {
	local initrd_entry="./opt/kata/share/kata-containers/kata-containers-initrd.img"
	local initrd_target

	rm -rf "${EXTRACT_DIR}"
	mkdir -p "${EXTRACT_DIR}"

	initrd_target="$(
		tar --zstd -tvf "${KATA_STATIC_FILE}" "${initrd_entry}" |
			awk '
				$1 ~ /^l/ {
					for (i = 1; i <= NF; i++) {
						if ($i == "->") {
							print $(i + 1)
							exit
						}
					}
				}
			'
	)"

	if [ -n "${initrd_target}" ]; then
		tar --zstd -xf "${KATA_STATIC_FILE}" -C "${EXTRACT_DIR}" \
			"${initrd_entry}" \
			"./opt/kata/share/kata-containers/${initrd_target}"
	else
		tar --zstd -xf "${KATA_STATIC_FILE}" -C "${EXTRACT_DIR}" \
			"${initrd_entry}"
	fi

	install -m 0644 \
		"${EXTRACT_DIR}/opt/kata/share/kata-containers/kata-containers-initrd.img" \
		"${INITRD_FILE}"
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
	GUEST_COMPONENTS_REPOSITORY="${GUEST_COMPONENTS_REPOSITORY}" \
	GUEST_COMPONENTS_REF="${GUEST_COMPONENTS_REF}" \
	PAUSE_IMAGE_REPOSITORY="${PAUSE_IMAGE_REPOSITORY}" \
	PAUSE_IMAGE_VERSION="${PAUSE_IMAGE_VERSION}" \
	"${script_dir}/build-coco-guest-artifacts.sh"

	GUEST_COMPONENTS_DIR="$(sed -n 's/^guest_components_dir=//p' "${guest_output_file}" | head -n 1)"
	PAUSE_BUNDLE_DIR="$(sed -n 's/^pause_bundle_dir=//p' "${guest_output_file}" | head -n 1)"
	GUEST_COMPONENTS_COMMIT="$(sed -n 's/^guest_components_commit=//p' "${guest_output_file}" | head -n 1)"

	[ -n "${GUEST_COMPONENTS_DIR}" ] || die "failed to capture guest components directory"
	[ -n "${PAUSE_BUNDLE_DIR}" ] || die "failed to capture pause bundle directory"
	[ -n "${GUEST_COMPONENTS_COMMIT}" ] || die "failed to capture guest components commit"
}

customize_initrd() {
	INITRD_PATH="${INITRD_FILE}" \
	OUTPUT_INITRD_PATH="${CUSTOMIZED_INITRD_FILE}" \
	COCO_GUEST_COMPONENTS_DIR="${GUEST_COMPONENTS_DIR}" \
	PAUSE_BUNDLE_DIR="${PAUSE_BUNDLE_DIR}" \
	RESOLV_CONF_NAMESERVER="${RESOLV_CONF_NAMESERVER}" \
	"${script_dir}/customize-initrd.sh"
}

stage_release_tree() {
	rm -rf "${STAGING_DIR}"
	mkdir -p "${STAGING_DIR}/artifacts"

	install -m 0644 "${CUSTOMIZED_INITRD_FILE}" "${STAGING_DIR}/artifacts/kata-containers-initrd.img"
	install -m 0644 "${MANIFEST_FILE}" "${STAGING_DIR}/manifest.json"
}

require_cmd awk cargo cpio curl git gzip python3 sha256sum skopeo tar umoci zstd install

mkdir -p "${DOWNLOAD_DIR}" "${DIST_DIR}"

BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git -C "${repo_root_dir}" rev-parse HEAD)"

resolve_kata_static_asset
KATA_STATIC_FILE="${DOWNLOAD_DIR}/${KATA_STATIC_ASSET_NAME}"
curl --fail --location --silent --show-error "${KATA_STATIC_URL}" --output "${KATA_STATIC_FILE}"
extract_kata_initrd
build_coco_guest_artifacts
customize_initrd
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
emit_output "kata_static_asset" "${KATA_STATIC_FILE}"
