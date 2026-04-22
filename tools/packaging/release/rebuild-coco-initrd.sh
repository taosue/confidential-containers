#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail

KATA_SOURCE_DIR="${KATA_SOURCE_DIR:?KATA_SOURCE_DIR must be set}"
ROOTFS_DIR="${ROOTFS_DIR:?ROOTFS_DIR must be set}"
OUTPUT_INITRD_PATH="${OUTPUT_INITRD_PATH:?OUTPUT_INITRD_PATH must be set}"
COCO_GUEST_COMPONENTS_TARBALL="${COCO_GUEST_COMPONENTS_TARBALL:?COCO_GUEST_COMPONENTS_TARBALL must be set}"
PAUSE_IMAGE_TARBALL="${PAUSE_IMAGE_TARBALL:?PAUSE_IMAGE_TARBALL must be set}"
RESOLV_CONF_NAMESERVER="${RESOLV_CONF_NAMESERVER:-8.8.8.8}"
DISTRO="${DISTRO:-ubuntu}"
OS_VERSION="${OS_VERSION:-noble}"

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

require_cmd install mkdir printf rm script sudo tee

[ -d "${KATA_SOURCE_DIR}" ] || die "KATA_SOURCE_DIR does not exist: ${KATA_SOURCE_DIR}"
[ -f "${COCO_GUEST_COMPONENTS_TARBALL}" ] || die "COCO_GUEST_COMPONENTS_TARBALL does not exist: ${COCO_GUEST_COMPONENTS_TARBALL}"
[ -f "${PAUSE_IMAGE_TARBALL}" ] || die "PAUSE_IMAGE_TARBALL does not exist: ${PAUSE_IMAGE_TARBALL}"

export ROOTFS_DIR
export COCO_GUEST_COMPONENTS_TARBALL
export PAUSE_IMAGE_TARBALL
export distro="${DISTRO}"

sudo rm -rf "${ROOTFS_DIR}"
mkdir -p "$(dirname "${OUTPUT_INITRD_PATH}")"

pushd "${KATA_SOURCE_DIR}/tools/osbuilder/rootfs-builder" >/dev/null
script -q -e -c 'sudo -E AGENT_INIT=yes USE_DOCKER=true SECCOMP=no OS_VERSION='"${OS_VERSION}"' INIT_DATA=no CONFIDENTIAL_GUEST=yes ./rootfs.sh "'"${DISTRO}"'"' /dev/null
popd >/dev/null

printf 'nameserver %s\n' "${RESOLV_CONF_NAMESERVER}" | sudo tee "${ROOTFS_DIR}/etc/resolv.conf" >/dev/null

pushd "${KATA_SOURCE_DIR}/tools/osbuilder/initrd-builder" >/dev/null
script -q -e -c 'sudo -E AGENT_INIT=yes USE_DOCKER=true SECCOMP=no INIT_DATA=no ./initrd_builder.sh "'"${ROOTFS_DIR}"'"' /dev/null
popd >/dev/null

install -m 0644 "${KATA_SOURCE_DIR}/tools/osbuilder/initrd-builder/kata-containers-initrd.img" "${OUTPUT_INITRD_PATH}"
