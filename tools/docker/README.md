# CoCo Development Docker Image

This directory contains the Docker image and bootstrap scripts for running
`kubeadm + containerd + confidential-containers` inside a development
container.

Layout:

- `tools/docker/config/`: runtime, containerd, nydus, CNI, and kubeadm config
- `tools/docker/manifests/`: test Kubernetes manifests
- `tools/scripts/`: bootstrap and shared helper scripts

## Building The Image

This image is built from:

- the base image is provided through `UPSTREAM_ASTERINAS_BASE_IMAGE`
  and the current CI default is `asterinas/asterinas:<DOCKER_IMAGE_VERSION>`
- the prebuilt Asterinas Kata artifacts come from an `asterinas/kata-containers` release package
- the customized CoCo initrd comes from this repository's release package

The image bakes in:

- `/opt/coco/prebuilt/asterinas-coco/aster-kernel-osdk-bin.qemu_elf`
- `/opt/coco/prebuilt/asterinas-coco/aster-kernel-osdk-bin-tdx`
- `/opt/coco/prebuilt/asterinas-coco/containerd-shim-kata-v2`
- `/opt/coco/prebuilt/asterinas-coco/kata-containers-initrd.img`

From this directory:

```bash
cd tools/docker
DOCKER_BUILDKIT=1 docker build --progress=plain \
    --build-arg UPSTREAM_ASTERINAS_BASE_IMAGE=asterinas/asterinas:<DOCKER_IMAGE_VERSION> \
    --build-arg KATA_RELEASE_PACKAGE_URL=<asterinas-kata-release-package-url> \
    --build-arg COCO_RELEASE_PACKAGE_URL=<confidential-containers-release-package-url> \
    -t asterinas/coco:<DOCKER_IMAGE_VERSION> \
    .
```

## Starting The Container

The outer container must expose KVM/vsock devices, use host cgroups, and keep
nydus on `tmpfs`. `/var/lib/containerd` is intentionally kept inside the image
so the preloaded containerd content store and native snapshots can be reused at
runtime. The image also preloads kubeadm images into `/var/lib/containerd` and
stores OCI archives for kubeadm and `kata-deploy` images under `/opt/coco/cache`.

Recommended command:

```bash
docker run -it --rm \
    --privileged \
    --cgroupns host \
    --device /dev/kvm \
    --device /dev/vhost-vsock \
    --tmpfs /var/lib/containerd-nydus:rw,size=512m \
    asterinas/coco:<DOCKER_IMAGE_VERSION> \
    bash
```

## Bootstrapping CoCo

Inside the container:

```bash
/opt/coco/setup-coco-k8s.sh
```

`setup-coco-k8s.sh` is the one-click entrypoint. It prepares the CoCo
development container services and bootstraps Kubernetes.

After bootstrap, use the bundled manifests directly:

```bash
kubectl apply -f /opt/coco/manifests/alpine-kata-qemu-coco-dev.yaml
kubectl apply -f /opt/coco/manifests/alpine-kata-qemu-tdx.yaml
```

The image already contains:

- Kata runtime config: `/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/configuration-qemu-coco-dev-asterinas.toml`
- Kata runtime config: `/opt/kata/share/defaults/kata-containers/runtimes/qemu-tdx/configuration-qemu-tdx-asterinas.toml`
- Containerd guest-pull config: `/etc/containerd/conf.d/50-coco-guest-pull.toml`
- kubeadm config: `/opt/coco/kubeadm-coco-init.yaml`
- CNI config template: `/opt/coco/10-bridge.conflist`
- nydus config: `/opt/coco/nydus-config-proxy.toml`
- Prebuilt OCI archives for kubeadm images and `kata-deploy` under `/opt/coco/cache/`
- Preloaded kubeadm image records and native snapshots under `/var/lib/containerd`
- Prebuilt Asterinas kernel/shim/initrd artifacts under `/opt/coco/prebuilt/asterinas-coco`
