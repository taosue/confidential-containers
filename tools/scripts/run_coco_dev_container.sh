#!/usr/bin/env bash
set -euo pipefail

NAME="${NAME:-coco-dev}"

resolve_default_image() {
    local image

    image="$(
        docker image ls --format '{{.Repository}}:{{.Tag}}' |
            grep -E '(^|.*/)asterinas/coco:' |
            grep -v ':<none>$' |
            head -n 1 || true
    )"

    [ -n "${image}" ] || {
        echo "ERROR: no local asterinas/coco image found; set IMAGE=<repo:tag>" >&2
        exit 1
    }

    printf '%s\n' "${image}"
}

IMAGE="${IMAGE:-$(resolve_default_image)}"

docker rm -f "${NAME}" >/dev/null 2>&1 || true

exec docker run -it --rm \
    --name "${NAME}" \
    --privileged \
    --cgroupns host \
    --device /dev/kvm \
    --device /dev/vhost-vsock \
    --tmpfs /var/lib/containerd-nydus:rw,size=512m \
    "${IMAGE}" \
    bash
