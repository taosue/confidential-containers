#!/usr/bin/env bash

defaults_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
defaults_repo_root="$(cd "${defaults_script_dir}/../.." && pwd)"

DEFAULT_IMAGE_REPOSITORY="asterinas/coco"
DEFAULT_ASTERINAS_BASE_IMAGE="asterinas/kernel-dev:0.19.0-20261012"

VERSION="${VERSION:-$(<"${defaults_repo_root}/VERSION")}"

IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-${DEFAULT_IMAGE_REPOSITORY}}"
ASTERINAS_BASE_IMAGE="${ASTERINAS_BASE_IMAGE:-${DEFAULT_ASTERINAS_BASE_IMAGE}}"
COCO_RELEASE_TAG="${COCO_RELEASE_TAG:-v${VERSION}}"

source "${defaults_repo_root}/tools/packaging/asterinas-coco-packaging-defaults.sh"
