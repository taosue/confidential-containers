# CoCo Development Docker Image

This directory contains the Docker image and bootstrap scripts for running
`kubeadm + containerd + confidential-containers` inside a development
container.

Layout:

- `tools/docker/config/`: runtime, containerd, nydus, CNI, and Helm values
- `tools/docker/manifests/`: test Kubernetes manifests
- `tools/scripts/`: install, demo, and container launch entrypoints

## Building The Image

This image follows the `kata-jianfeng` publish-image style:

- the base image comes from `asterinas/asterinas:<DOCKER_IMAGE_VERSION>`
- the prebuilt Asterinas Kata artifacts come from a `jjf-dev/kata-containers` release package
- the customized CoCo initrd comes from a `confidential-containers` release package

The image bakes in:

- `/opt/coco/prebuilt/asterinas-coco/aster-kernel-osdk-bin.qemu_elf`
- `/opt/coco/prebuilt/asterinas-coco/aster-kernel-osdk-bin.qemu_elf-tdx`
- `/opt/coco/prebuilt/asterinas-coco/containerd-shim-kata-v2`
- `/opt/coco/prebuilt/asterinas-coco/kata-containers-initrd.img`

From this directory:

```bash
cd tools/docker
DOCKER_BUILDKIT=1 docker build --progress=plain \
    --build-arg UPSTREAM_ASTERINAS_BASE_IMAGE=asterinas/asterinas:<DOCKER_IMAGE_VERSION> \
    --build-arg KATA_RELEASE_PACKAGE_URL=<jjf-dev-kata-release-package-url> \
    --build-arg COCO_RELEASE_PACKAGE_URL=<confidential-containers-release-package-url> \
    -t asterinas/coco:<DOCKER_IMAGE_VERSION> \
    .
```

## Starting The Container

The outer container must expose KVM/vsock devices, use host cgroups, and keep
nydus on `tmpfs`. `/var/lib/containerd` is intentionally kept inside the image
so the preloaded containerd content store and native snapshots can be reused at
runtime.

Recommended:

```bash
tools/scripts/run_coco_dev_container.sh
```

Equivalent raw command:

```bash
docker run -it --rm \
    --name coco-dev \
    --privileged \
    --cgroupns host \
    --device /dev/kvm \
    --device /dev/vhost-vsock \
    --tmpfs /var/lib/containerd-nydus:rw,size=512m \
    -v $(pwd):/workspace/confidential-containers \
    -w /workspace/confidential-containers \
    asterinas/coco:<DOCKER_IMAGE_VERSION> \
    bash
```

## Bootstrapping CoCo

Inside the container:

```bash
/opt/coco/install-coco-cluster.sh
/opt/coco/run-coco-demo.sh
```

`install-coco-cluster.sh` is the one-click install entrypoint.

`run-coco-demo.sh` is the one-click demo entrypoint. It applies the bundled
`kata-qemu-coco-dev` test manifest, waits for the Pod to become ready, and
drops you into `/bin/sh` inside the Pod.

The image already contains:

- Kata runtime override: `/opt/kata/share/defaults/kata-containers/runtimes/qemu-coco-dev/config.d/90-runtime-minimal.toml`
- Containerd guest-pull config: `/etc/containerd/conf.d/50-coco-guest-pull.toml`
- Helm values: `/opt/coco/confidential-containers-values.yaml`
- Prebuilt OCI archives for kubeadm images and `kata-deploy` under `/opt/coco/cache/`
- Preloaded kubeadm image records and native snapshots under `/var/lib/containerd`
- Prebuilt Asterinas kernel/shim/initrd artifacts under `/opt/coco/prebuilt/asterinas-coco`
