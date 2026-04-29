#!/usr/bin/env bash
set -euo pipefail

COCO_ROOT="${COCO_ROOT:-/opt/coco}"

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
KUBEADM_IMAGE_LIST_CMD="${KUBEADM_IMAGE_LIST_CMD:-}"
UNPACK_KUBEADM_IMAGES="${UNPACK_KUBEADM_IMAGES:-false}"

KUBEADM_IMAGES=()
PAUSE_IMAGE="${PAUSE_IMAGE:-}"
CONTAINERD_CONFIG_CHANGED=0
PREBUILT_SHIM="/opt/coco/prebuilt/asterinas-coco/containerd-shim-kata-v2"
DEV_LOG_PID_FILE="/tmp/dev-log.pid"

log() {
    echo "[install] $*"
}

require_prereqs() {
    for bin in kubeadm kubelet kubectl containerd ctr modprobe socat; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            echo "missing required binary: ${bin}" >&2
            exit 1
        fi
    done

    if [ ! -x /opt/cni/bin/bridge ]; then
        echo "missing CNI plugin: /opt/cni/bin/bridge" >&2
        exit 1
    fi
}

load_kubeadm_images() {
    local image_list_cmd
    local images_list_err

    if [ -z "${KUBERNETES_VERSION}" ]; then
        KUBERNETES_VERSION="$(kubeadm version -o short)"
    fi
    image_list_cmd="${KUBEADM_IMAGE_LIST_CMD:-kubeadm config images list --kubernetes-version ${KUBERNETES_VERSION}}"

    images_list_err="$(mktemp)"
    if ! mapfile -t KUBEADM_IMAGES < <(eval "${image_list_cmd}" 2>"${images_list_err}"); then
        cat "${images_list_err}" >&2
        rm -f "${images_list_err}"
        exit 1
    fi
    rm -f "${images_list_err}"

    if [ -z "${PAUSE_IMAGE}" ]; then
        PAUSE_IMAGE="$(printf '%s\n' "${KUBEADM_IMAGES[@]}" | grep '/pause:' | head -n 1)"
    fi
}

mount_tmpfs_once() {
    local path="$1"
    local size="$2"

    mkdir -p "${path}"
    if ! mountpoint -q "${path}"; then
        log "mounting tmpfs for ${path}"
        mount -t tmpfs -o "rw,size=${size}" tmpfs "${path}"
    fi
}

write_containerd_config() {
    local imports='"/etc/containerd/conf.d/*.toml"'
    local tmp_config

    # kata-deploy creates this file during Helm install. Import it first so our
    # /etc/containerd/conf.d/50-coco-guest-pull.toml override wins afterwards.
    if [ -f /opt/kata/containerd/config.d/kata-deploy.toml ]; then
        imports='"/opt/kata/containerd/config.d/kata-deploy.toml", "/etc/containerd/conf.d/*.toml"'
    fi

    tmp_config="$(mktemp)"
    cat > "${tmp_config}" <<EOF
version = 3
root = "/var/lib/containerd"
state = "/run/containerd"
imports = [${imports}]
EOF

    if ! cmp -s "${tmp_config}" /etc/containerd/config.toml 2>/dev/null; then
        install -m 0644 "${tmp_config}" /etc/containerd/config.toml
        CONTAINERD_CONFIG_CHANGED=1
    fi
    rm -f "${tmp_config}"
}

prepare_host_config() {
    log "preparing directories and config"

    mkdir -p \
        /etc/containerd/conf.d \
        /etc/nydus \
        /etc/cni/net.d \
        /run/containerd-nydus \
        /opt/cni/bin

    mount_tmpfs_once /var/lib/containerd/tmpmounts 512m
    mount_tmpfs_once /var/lib/containerd-nydus 512m

    install -m 0644 "${COCO_ROOT}/nydus-config-proxy.toml" /etc/nydus/config-proxy.toml
    install -m 0644 "${COCO_ROOT}/10-bridge.conflist" /etc/cni/net.d/10-bridge.conflist
    write_containerd_config
}

link_nydus_overlayfs() {
    if [ -x /opt/kata/nydus-snapshotter/nydus-overlayfs ]; then
        log "linking nydus-overlayfs into PATH"
        ln -sf /opt/kata/nydus-snapshotter/nydus-overlayfs /usr/local/bin/nydus-overlayfs
        ln -sf /opt/kata/nydus-snapshotter/nydus-overlayfs /usr/bin/nydus-overlayfs
    fi
}

start_rsyslog() {
    local dev_log_pid=""

    if [ -f "${DEV_LOG_PID_FILE}" ]; then
        dev_log_pid="$(cat "${DEV_LOG_PID_FILE}" 2>/dev/null || true)"
        if [ -n "${dev_log_pid}" ] && kill -0 "${dev_log_pid}" 2>/dev/null; then
            kill "${dev_log_pid}" >/dev/null 2>&1 || true
        fi
        rm -f "${DEV_LOG_PID_FILE}"
    fi

    rm -f /dev/log /tmp/dev-log.log /tmp/dev-log.stdout /tmp/logger-smoke.log

    log "starting /dev/log sink"
    nohup socat \
        UNIX-RECVFROM:/dev/log,fork,mode=666 \
        OPEN:/tmp/dev-log.log,creat,append \
        >/tmp/dev-log.stdout 2>&1 &
    dev_log_pid="$!"
    echo "${dev_log_pid}" > "${DEV_LOG_PID_FILE}"

    if timeout 5 bash -c '
        socket_path="$1"
        process_id="$2"

        while kill -0 "${process_id}" 2>/dev/null; do
            if [ -S "${socket_path}" ]; then
                exit 0
            fi
            sleep 0.05
        done

        exit 1
    ' bash /dev/log "${dev_log_pid}" && \
       kill -0 "${dev_log_pid}" 2>/dev/null; then
        logger -t coco-syslog-smoke "syslog ready $(date +%s)" >/tmp/logger-smoke.log 2>&1 || true
        return
    fi

    echo "syslog readiness check failed" >&2
    echo "===== ls -l /dev/log =====" >&2
    ls -l /dev/log >&2 2>/dev/null || true
    echo "===== ss -xl | grep /dev/log =====" >&2
    ss -xl >&2 2>/dev/null | grep -F '/dev/log' || true
    echo "===== dev-log pid =====" >&2
    cat "${DEV_LOG_PID_FILE}" >&2 2>/dev/null || true
    echo "===== logger smoke test =====" >&2
    logger -t coco-syslog-smoke "syslog failed $(date +%s)" >/tmp/logger-smoke.log 2>&1 || true
    tail -n 240 /tmp/logger-smoke.log >&2 2>/dev/null || true
    echo "===== dev-log.stdout =====" >&2
    tail -n 240 /tmp/dev-log.stdout >&2 2>/dev/null || true
    echo "===== dev-log.log =====" >&2
    tail -n 240 /tmp/dev-log.log >&2 2>/dev/null || true
    echo "===== ps -ef | grep socat =====" >&2
    ps -ef | grep socat | grep -v grep >&2 || true
    exit 1
}

start_containerd() {
    if ! pgrep -x containerd >/dev/null 2>&1; then
        log "starting containerd"
        nohup containerd >/tmp/containerd.log 2>&1 &
    fi

    for _ in $(seq 1 30); do
        if [ -S /run/containerd/containerd.sock ]; then
            return
        fi
        sleep 1
    done

    echo "containerd socket did not become ready" >&2
    exit 1
}

start_nydus_snapshotter() {
    if [ -x /opt/kata/nydus-snapshotter/containerd-nydus-grpc ] && \
       ! pgrep -f '/opt/kata/nydus-snapshotter/containerd-nydus-grpc' >/dev/null 2>&1; then
        log "starting nydus snapshotter"
        nohup /opt/kata/nydus-snapshotter/containerd-nydus-grpc \
            --config /etc/nydus/config-proxy.toml \
            --log-to-stdout \
            >/tmp/nydus.log 2>&1 &
        sleep 2
    fi
}

start_base_services() {
    start_rsyslog
    start_containerd
    start_nydus_snapshotter
}

image_exists() {
    ctr -n k8s.io images ls -q | grep -Fx "$1" >/dev/null 2>&1
}

image_archive_name() {
    echo "$1" | sed 's|/|_|g; s|:|_|g'
}

ensure_preloaded_images() {
    local imported_kubeadm=0
    local unpack_marker

    for image in "${KUBEADM_IMAGES[@]}"; do
        local archive="${COCO_ROOT}/cache/kubeadm-images/$(image_archive_name "${image}").tar"
        if [ -f "${archive}" ] && ! image_exists "${image}"; then
            if [ "${imported_kubeadm}" = "0" ]; then
                log "importing cached kubeadm images"
                imported_kubeadm=1
            fi
            ctr -n k8s.io images import --all-platforms "${archive}" >/tmp/ctr-import.log 2>&1
        fi
    done

    unpack_marker="/var/lib/containerd/.coco-kubeadm-native-unpack.$(printf '%s\n' "${KUBEADM_IMAGES[@]}" | sha256sum | awk '{print $1}')"
    if [ "${UNPACK_KUBEADM_IMAGES}" = "true" ]; then
        if [ -f "${unpack_marker}" ]; then
            log "kubeadm images already unpacked with native snapshotter"
        else
            log "ensuring kubeadm images are unpacked with native snapshotter"
            for image in "${KUBEADM_IMAGES[@]}"; do
                if image_exists "${image}"; then
                    local digest
                    digest="$(ctr -n k8s.io images ls | awk -v ref="${image}" '$1 == ref {print $3; exit}')"
                    if [ -n "${digest}" ]; then
                        ctr -n k8s.io snapshots unpack --snapshotter native "${digest}" >/tmp/ctr-unpack.log 2>&1 || true
                    fi
                fi
            done
            touch "${unpack_marker}"
        fi
    else
        log "skipping kubeadm image native unpack"
    fi
}

start_kubelet() {
    if pgrep -x kubelet >/dev/null 2>&1; then
        return
    fi

    nohup bash -lc '
        set -euo pipefail

        while [ ! -f /var/lib/kubelet/kubeadm-flags.env ] || \
              [ ! -f /var/lib/kubelet/config.yaml ] || \
              [ ! -f /etc/kubernetes/kubelet.conf ]; do
            sleep 1
        done

        mkdir -p /var/lib/containerd/tmpmounts
        if ! mountpoint -q /var/lib/containerd/tmpmounts; then
            mount -t tmpfs -o rw,size=512m tmpfs /var/lib/containerd/tmpmounts
        fi

        # shellcheck disable=SC1091
        source /var/lib/kubelet/kubeadm-flags.env
        exec kubelet \
            --kubeconfig=/etc/kubernetes/kubelet.conf \
            --config=/var/lib/kubelet/config.yaml \
            ${KUBELET_KUBEADM_ARGS}
    ' >/tmp/kubelet.log 2>&1 &
}

write_kubeadm_config() {
    local template="${COCO_ROOT}/kubeadm-coco-init.yaml"

    if [ ! -f "${template}" ]; then
        echo "missing kubeadm config template: ${template}" >&2
        exit 1
    fi

    mkdir -p /etc/kubeadm
    sed \
        -e 's|${KUBERNETES_VERSION}|'"${KUBERNETES_VERSION}"'|g' \
        -e 's|${POD_CIDR}|'"${POD_CIDR}"'|g' \
        "${template}" > /etc/kubeadm/coco-init.yaml
}

install_kubeconfig() {
    mkdir -p /root/.kube
    ln -sf /etc/kubernetes/admin.conf /root/.kube/config
}

init_kubernetes() {
    start_kubelet

    if [ -f /etc/kubernetes/admin.conf ]; then
        install_kubeconfig
        if kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null | grep -qx yes; then
            log "kubeadm already initialized, skipping"
            return
        fi

        echo "kubeadm state is incomplete: /etc/kubernetes/admin.conf exists but is not cluster-admin" >&2
        echo "create a fresh container or run kubeadm reset before reinstalling" >&2
        exit 1
    fi

    log "running kubeadm init"
    write_kubeadm_config
    if ! kubeadm init \
        --config=/etc/kubeadm/coco-init.yaml \
        --ignore-preflight-errors=all \
        >/tmp/kubeadm-init.log 2>&1; then
        tail -n 240 /tmp/kubeadm-init.log >&2 2>/dev/null || true
        tail -n 240 /tmp/kubelet.log >&2 2>/dev/null || true
        tail -n 240 /tmp/containerd.log >&2 2>/dev/null || true
        exit 1
    fi

    install_kubeconfig

    if ! kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null | grep -qx yes; then
        echo "kubeadm init completed but admin.conf is not cluster-admin" >&2
        exit 1
    fi
}

wait_for_cluster_basics() {
    log "waiting for cluster basic resources"

    timeout 60 bash -lc '
        while true; do
            if kubectl get serviceaccount default -n default >/dev/null 2>&1; then
                exit 0
            fi
            sleep 1
        done
    '
}

label_node_for_kata() {
    local node_name

    node_name="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    log "labeling node ${node_name} for kata runtime"
    kubectl label node "${node_name}" katacontainers.io/kata-runtime=true --overwrite
}

untaint_control_plane_node() {
    local node_name

    node_name="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    log "removing control-plane NoSchedule taint from ${node_name}"
    kubectl taint nodes "${node_name}" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
}

kata_artifacts_ready() {
    [ -x /opt/kata/nydus-snapshotter/containerd-nydus-grpc ] && \
    [ -x /opt/kata/nydus-snapshotter/nydus-overlayfs ]
}

runtimeclass_ready() {
    kubectl get runtimeclass kata-qemu-coco-dev-asterinas >/dev/null 2>&1 && \
    kubectl get runtimeclass kata-qemu-tdx-asterinas >/dev/null 2>&1
}

install_runtimeclasses() {
    if runtimeclass_ready; then
        log "kata runtimeclasses already installed, skipping"
        return
    fi

    log "installing kata runtimeclasses"
    kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu-coco-dev-asterinas
handler: kata-qemu-coco-dev
overhead:
  podFixed:
    memory: "160Mi"
    cpu: "250m"
scheduling:
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-qemu-tdx-asterinas
handler: kata-qemu-tdx
overhead:
  podFixed:
    memory: "2048Mi"
    cpu: "1.0"
scheduling:
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
EOF

    timeout 30 bash -lc '
        while true; do
            if kubectl get runtimeclass kata-qemu-coco-dev-asterinas >/dev/null 2>&1 && \
               kubectl get runtimeclass kata-qemu-tdx-asterinas >/dev/null 2>&1; then
                exit 0
            fi
            sleep 1
        done
    '
}

restart_containerd_stack() {
    log "restarting containerd stack"

    pkill -f '/opt/kata/nydus-snapshotter/containerd-nydus-grpc' >/dev/null 2>&1 || true
    pkill -x containerd >/dev/null 2>&1 || true

    for _ in $(seq 1 30); do
        if [ ! -S /run/containerd/containerd.sock ]; then
            break
        fi
        sleep 1
    done

    nohup containerd >/tmp/containerd.log 2>&1 &
    start_containerd
    mount_tmpfs_once /var/lib/containerd/tmpmounts 512m
    start_nydus_snapshotter
}

containerd_uses_prebuilt_shim() {
    grep -F '"runtimePath":"'"${PREBUILT_SHIM}"'"' /tmp/containerd.log >/dev/null 2>&1
}

runtime_restart_needed() {
    if [ "${CONTAINERD_CONFIG_CHANGED}" = "1" ]; then
        return 0
    fi
    if ! pgrep -x containerd >/dev/null 2>&1; then
        return 0
    fi
    if ! containerd_uses_prebuilt_shim; then
        return 0
    fi
    if [ -x /opt/kata/nydus-snapshotter/containerd-nydus-grpc ] && \
       ! pgrep -f '/opt/kata/nydus-snapshotter/containerd-nydus-grpc' >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

finalize_runtime_config() {
    link_nydus_overlayfs

    write_containerd_config

    if runtime_restart_needed; then
        restart_containerd_stack
    else
        log "containerd already uses prebuilt shim, skipping restart"
        mount_tmpfs_once /var/lib/containerd/tmpmounts 512m
    fi
}

main() {
    require_prereqs
    load_kubeadm_images

    prepare_host_config
    start_base_services
    ensure_preloaded_images

    init_kubernetes
    wait_for_cluster_basics
    untaint_control_plane_node
    label_node_for_kata
    install_runtimeclasses
    finalize_runtime_config
}

main "$@"
