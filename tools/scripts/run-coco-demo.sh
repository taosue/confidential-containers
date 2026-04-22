#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_COCO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${SCRIPT_COCO_ROOT}/manifests/alpine-kata-qemu-coco-dev.yaml" ]; then
    COCO_ROOT="${COCO_ROOT:-${SCRIPT_COCO_ROOT}}"
    MANIFEST="${COCO_ROOT}/manifests/alpine-kata-qemu-coco-dev.yaml"
else
    COCO_ROOT="${COCO_ROOT:-/opt/coco}"
    MANIFEST="${COCO_ROOT}/manifests/alpine-kata-qemu-coco-dev.yaml"
fi
POD_NAME="${POD_NAME:-alpine-kata-qemu-coco-dev}"

kubectl apply -f "${MANIFEST}"
kubectl wait --for=condition=Ready "pod/${POD_NAME}" --timeout="${POD_WAIT_TIMEOUT:-5m}"
exec kubectl exec -it "${POD_NAME}" -- /bin/sh
