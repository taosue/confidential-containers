# SPDX-License-Identifier: Apache-2.0

FROM ubuntu:24.04 AS build-qemu

ARG DEBIAN_FRONTEND=noninteractive
ARG QEMU_VERSION=10.2.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    libgcrypt-dev \
    libglib2.0-dev \
    libnuma-dev \
    libpixman-1-dev \
    libslirp-dev \
    libusb-dev \
    meson \
    ninja-build \
    pkg-config \
    python3 \
    python3-venv \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN wget -O qemu.tar.xz "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    && mkdir qemu-src \
    && tar -xf qemu.tar.xz --strip-components=1 -C qemu-src \
    && rm qemu.tar.xz

WORKDIR /tmp/qemu-src

RUN ./configure \
      --target-list=x86_64-softmmu \
      --prefix=/usr/local/qemu \
      --enable-slirp \
      --enable-numa \
    && make -j"$(nproc)" \
    && make install

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgcrypt20 \
    libglib2.0-0 \
    libnuma1 \
    libpixman-1-0 \
    libslirp0 \
    libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build-qemu /usr/local/qemu /usr/local/qemu
