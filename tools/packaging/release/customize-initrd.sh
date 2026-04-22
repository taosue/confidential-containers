#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

INITRD_PATH="${INITRD_PATH:?INITRD_PATH must be set}"
OUTPUT_INITRD_PATH="${OUTPUT_INITRD_PATH:-${INITRD_PATH}}"
COCO_GUEST_COMPONENTS_DIR="${COCO_GUEST_COMPONENTS_DIR:?COCO_GUEST_COMPONENTS_DIR must be set}"
PAUSE_BUNDLE_DIR="${PAUSE_BUNDLE_DIR:?PAUSE_BUNDLE_DIR must be set}"
RESOLV_CONF_NAMESERVER="${RESOLV_CONF_NAMESERVER:-8.8.8.8}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

cleanup() {
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

require_cmd() {
	local cmd

	for cmd in "$@"; do
		command -v "${cmd}" >/dev/null 2>&1 || {
			echo >&2 "ERROR: missing required command: ${cmd}"
			exit 1
		}
	done
}

require_cmd cat cp cpio gzip mv

mkdir -p "${WORK_DIR}/overlay/etc"

cp -a "${COCO_GUEST_COMPONENTS_DIR}/." "${WORK_DIR}/overlay/"
cp -a "${PAUSE_BUNDLE_DIR}" "${WORK_DIR}/overlay/pause_bundle"

printf 'nameserver %s\n' "${RESOLV_CONF_NAMESERVER}" > "${WORK_DIR}/overlay/etc/resolv.conf"

(cd "${WORK_DIR}/overlay" && find . -print0 | sort -z | cpio --null -o -H newc --quiet) > "${WORK_DIR}/overlay.cpio"
gzip -dc "${INITRD_PATH}" > "${WORK_DIR}/base.cpio"
cat "${WORK_DIR}/base.cpio" "${WORK_DIR}/overlay.cpio" | gzip -9 > "${WORK_DIR}/customized-initrd.img"
mv "${WORK_DIR}/customized-initrd.img" "${OUTPUT_INITRD_PATH}"
