#!/usr/bin/env bash
set -euo pipefail

COCO_ROOT="${COCO_ROOT:-/opt/coco}"

# CoCo chart release to install:
# https://github.com/confidential-containers/charts/tree/main/charts/confidential-containers
CHART_VERSION="${CHART_VERSION:-0.19.0}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
KATA_DEPLOY_WAIT_TIMEOUT="${KATA_DEPLOY_WAIT_TIMEOUT:-900}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
KUBEADM_IMAGE_LIST_CMD="${KUBEADM_IMAGE_LIST_CMD:-}"

KUBEADM_IMAGES=()
PAUSE_IMAGE="${PAUSE_IMAGE:-}"
CONTAINERD_CONFIG_CHANGED=0
PREBUILT_SHIM="/opt/coco/prebuilt/asterinas-coco/containerd-shim-kata-v2"

log() {
    echo "[install] $*"
}

require_prereqs() {
    for bin in helm kubeadm kubelet kubectl containerd ctr modprobe; do
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
    if ! pgrep -x rsyslogd >/dev/null 2>&1; then
        log "starting rsyslogd"
        rsyslogd
    fi
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

    local kata_deploy_archive="${COCO_ROOT}/cache/kata-deploy/kata-deploy-amd64.tar"
    if [ -f "${kata_deploy_archive}" ] && ! image_exists "quay.io/kata-containers/kata-deploy:3.28.0"; then
        log "importing cached kata-deploy image (this can take several minutes)"
        ctr -n k8s.io images import "${kata_deploy_archive}" >/tmp/ctr-import-kata-deploy.log 2>&1
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

        if grep -q "^cgroupDriver:" /var/lib/kubelet/config.yaml; then
            sed -i "s/^cgroupDriver:.*/cgroupDriver: cgroupfs/" /var/lib/kubelet/config.yaml
        else
            printf "\ncgroupDriver: cgroupfs\n" >> /var/lib/kubelet/config.yaml
        fi

        # This container is not booted by systemd. Pin resolvConf so kubelet
        # does not try to probe systemd-resolved and emit a harmless warning.
        if grep -q "^resolvConf:" /var/lib/kubelet/config.yaml; then
            sed -i "s|^resolvConf:.*|resolvConf: /etc/resolv.conf|" /var/lib/kubelet/config.yaml
        else
            printf "resolvConf: /etc/resolv.conf\n" >> /var/lib/kubelet/config.yaml
        fi

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
    if ! kubeadm init \
        --kubernetes-version="${KUBERNETES_VERSION}" \
        --pod-network-cidr="${POD_CIDR}" \
        --ignore-preflight-errors=all \
        >/tmp/kubeadm-init.log 2>&1; then
        tail -n 160 /tmp/kubeadm-init.log >&2 || true
        exit 1
    fi

    install_kubeconfig

    if ! kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null | grep -qx yes; then
        echo "kubeadm init completed but admin.conf is not cluster-admin" >&2
        exit 1
    fi
}

label_node_for_kata() {
    local node_name

    node_name="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    log "labeling node ${node_name} for kata runtime"
    kubectl label node "${node_name}" katacontainers.io/kata-runtime=true --overwrite
}

kata_artifacts_ready() {
    [ -f /opt/kata/containerd/config.d/kata-deploy.toml ] && \
    [ -x /opt/kata/nydus-snapshotter/containerd-nydus-grpc ] && \
    [ -x /opt/kata/nydus-snapshotter/nydus-overlayfs ]
}

helm_release_ready() {
    helm status coco -n coco-system >/dev/null 2>&1
}

runtimeclass_ready() {
    kubectl get runtimeclass kata-qemu-coco-dev >/dev/null 2>&1 && \
    kubectl get runtimeclass kata-qemu-tdx >/dev/null 2>&1
}

install_confidential_containers() {
    if helm_release_ready && kata_artifacts_ready && runtimeclass_ready; then
        log "confidential-containers already installed, skipping Helm install"
        return
    fi

    log "installing confidential-containers Helm chart"
    helm upgrade --install coco \
        oci://ghcr.io/confidential-containers/charts/confidential-containers \
        --version "${CHART_VERSION}" \
        -n coco-system \
        --create-namespace \
        -f "${COCO_ROOT}/confidential-containers-values.yaml"

    log "waiting for kata-deploy artifacts on host"
    timeout "${KATA_DEPLOY_WAIT_TIMEOUT}" bash -lc '
        while true; do
            if [ -f /opt/kata/containerd/config.d/kata-deploy.toml ] && \
               [ -x /opt/kata/nydus-snapshotter/containerd-nydus-grpc ] && \
               [ -x /opt/kata/nydus-snapshotter/nydus-overlayfs ]; then
                exit 0
            fi
            sleep 2
        done
    '
}

install_asterinas_runtime_dropin() {
    local runtime
    local src
    local dst

    for runtime in qemu-coco-dev qemu-tdx; do
        src="${COCO_ROOT}/${runtime}-runtime-asterinas-dev.toml"
        dst="/opt/kata/share/defaults/kata-containers/runtimes/${runtime}/config.d/95-asterinas-dev.toml"

        if [ -f "${src}" ] && ! cmp -s "${src}" "${dst}" 2>/dev/null; then
            log "installing ${runtime} asterinas-dev Kata runtime drop-in"
            mkdir -p "$(dirname "${dst}")"
            install -m 0644 "${src}" "${dst}"
        fi
    done
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
    install_asterinas_runtime_dropin
    link_nydus_overlayfs

    # kata-deploy creates its containerd drop-in during Helm install. Regenerate
    # imports now so kata-deploy is loaded first and our guest-pull override is
    # loaded last.
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
    label_node_for_kata
    install_confidential_containers
    finalize_runtime_config
}

main "$@"
