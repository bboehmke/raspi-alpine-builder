FROM debian:buster AS build_base

RUN apt-get update && \
    apt-get install -y build-essential git wget bison flex gcc-arm-linux-gnueabi device-tree-compiler bc

FROM build_base AS uboot

RUN mkdir /uboot_build/ && \
    mkdir /uboot/

WORKDIR /uboot_build/

ENV UBOOT_VERSION=2020.01

RUN wget http://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2 && \
    tar -xjf u-boot-${UBOOT_VERSION}.tar.bz2

WORKDIR /uboot_build/u-boot-${UBOOT_VERSION}/

# model a/b/zero
RUN make CROSS_COMPILE=arm-linux-gnueabi- distclean && \
    make CROSS_COMPILE=arm-linux-gnueabi- rpi_defconfig && \
    make CROSS_COMPILE=arm-linux-gnueabi- -j8 u-boot.bin && \
    cp u-boot.bin /uboot/u-boot_rpi1.bin

# model zero w
RUN make CROSS_COMPILE=arm-linux-gnueabi- distclean && \
    make CROSS_COMPILE=arm-linux-gnueabi- rpi_0_w_defconfig && \
    make CROSS_COMPILE=arm-linux-gnueabi- -j8 u-boot.bin && \
    cp u-boot.bin /uboot/u-boot_rpi0_w.bin

# model 2 b
RUN make CROSS_COMPILE=arm-linux-gnueabi- distclean && \
    make CROSS_COMPILE=arm-linux-gnueabi- rpi_2_defconfig && \
    make CROSS_COMPILE=arm-linux-gnueabi- -j8 u-boot.bin && \
    cp u-boot.bin /uboot/u-boot_rpi2.bin

# model 3 (32 bit)
RUN make CROSS_COMPILE=arm-linux-gnueabi- distclean && \
    make CROSS_COMPILE=arm-linux-gnueabi- rpi_3_32b_defconfig && \
    make CROSS_COMPILE=arm-linux-gnueabi- -j8 u-boot.bin && \
    cp u-boot.bin /uboot/u-boot_rpi3.bin

# model 4 (32 bit)
RUN make CROSS_COMPILE=arm-linux-gnueabi- distclean && \
    make CROSS_COMPILE=arm-linux-gnueabi- rpi_4_32b_defconfig && \
    make CROSS_COMPILE=arm-linux-gnueabi- -j8 u-boot.bin && \
    cp u-boot.bin /uboot/u-boot_rpi4.bin

FROM build_base AS uboot_tool

ADD ./resources/uboot.c /uboot.c

RUN arm-linux-gnueabi-gcc -Wall -static -static-libgcc -o /uboot_tool /uboot.c


FROM alpine:3.11

RUN apk add --no-cache \
        automake build-base git \
        autoconf confuse-dev \
        linux-headers findutils \
        mtools e2fsprogs-extra \
        alpine-sdk dosfstools \
        uboot-tools

RUN git clone https://github.com/pengutronix/genimage.git /tmp/genimage && \
    cd /tmp/genimage && \
    ./autogen.sh && \
    ./configure CFLAGS='-g -O0' --prefix=/usr && \
    make install && \
    cd && \
    rm -rf /tmp/genimage


ADD ./resources/genext2fs /genext2fs

RUN cd /genext2fs && \
    abuild-keygen -a -i -q && \
    abuild -F -P /tmp/pkg && \
    apk add /tmp/pkg/x86_64/genext2fs-1*.apk && \
    rm -rf /tmp/pkg/

ADD ./resources /resources
COPY --from=uboot /uboot/ /uboot/
COPY --from=uboot_tool /uboot_tool /uboot_tool

WORKDIR /work

CMD ["/bin/sh", "/resources/build.sh"]
