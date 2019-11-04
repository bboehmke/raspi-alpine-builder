 #!/bin/bash
set -e

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# User config
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
: ${ALPINE_BRANCH:="3.10"}
: ${ALPINE_MIRROR:="http://dl-cdn.alpinelinux.org/alpine"}

: ${DEFAULT_TIMEZONE:="Etc/UTC"}
: ${DEFAULT_HOSTNAME:="alpine"}
: ${DEFAULT_ROOT_PASSWORD:="alpine"}

: ${SIZE_BOOT:="100M"}
: ${SIZE_ROOT_FS:="150M"}
: ${SIZE_ROOT_PART:="250M"}
: ${SIZE_DATA:="20M"}
: ${IMG_NAME:="alpine-${ALPINE_BRANCH}-sdcard"}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# static config
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
RES_PATH=/resources/
BASE_PACKAGES="alpine-base tzdata parted ifupdown e2fsprogs-extra util-linux coreutils linux-rpi2 uboot-tools openntpd"

WORK_PATH="/work"
OUTPUT_PATH="/output"
ROOTFS_PATH="${WORK_PATH}/root_fs"
BOOTFS_PATH="${WORK_PATH}/boot_fs"
DATAFS_PATH="${WORK_PATH}/data_fs"
IMAGE_PATH="${WORK_PATH}/img"


# ensure work directory is clean
rm -rf ${WORK_PATH}/*

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# functions
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

chroot_exec() {
    chroot "${ROOTFS_PATH}" "$@" 1>&2
}

make_image() {
    [ -d /tmp/genimage ] && rm -rf /tmp/genimage
    genimage --rootpath $1 \
      --tmppath /tmp/genimage \
      --inputpath ${IMAGE_PATH} \
      --outputpath ${IMAGE_PATH} \
      --config $2
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# create root FS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo ">> Prepare root FS"

# update local repositories to destination ones to ensure the right packages where installed
cat >/etc/apk/repositories <<EOF
${ALPINE_MIRROR}/v${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/v${ALPINE_BRANCH}/community
EOF

# copy apk keys to new root (required for initial apk add run)
mkdir -p ${ROOTFS_PATH}/etc/apk/keys/
cp /usr/share/apk/keys/*.rsa.pub ${ROOTFS_PATH}/etc/apk/keys/

# copy repositories to new root
cp /etc/apk/repositories ${ROOTFS_PATH}/etc/apk/repositories

# initial package installation
apk --root ${ROOTFS_PATH} --update-cache --initdb --arch armhf add $BASE_PACKAGES

# add google DNS to enable network access inside chroot
echo "nameserver 8.8.8.8" > ${ROOTFS_PATH}/etc/resolv.conf

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
echo ">> Configure root FS"

# Set time zone
ln -fs /data/etc/timezone ${ROOTFS_PATH}/etc/timezone
ln -fs /data/etc/localtime ${ROOTFS_PATH}/etc/localtime

# Set host name
chroot_exec rc-update add hostname default
ln -fs /data/etc/hostname ${ROOTFS_PATH}/etc/hostname

# enable local startup files (stored in /etc/local.d/)
chroot_exec rc-update add local default
cat >${ROOTFS_PATH}/etc/conf.d/local <<EOF
rc_verbose=yes
EOF

# prepare network
chroot_exec rc-update add networking default
ln -fs /data/etc/interfaces ${ROOTFS_PATH}/etc/network/interfaces

# run local before network -> local brings up the interface
sed -i '/^\tneed/ s/$/ local/' ${ROOTFS_PATH}/etc/init.d/networking

# bring up eth0 on startup
cat >${ROOTFS_PATH}/etc/local.d/11-up_eth0.start <<EOF
#!/bin/sh
ifconfig eth0 up
EOF
chmod +x ${ROOTFS_PATH}/etc/local.d/11-up_eth0.start

# add script to resize data partition 
cp ${RES_PATH}/resizedata.sh ${ROOTFS_PATH}/etc/local.d/90-resizedata.start
chmod +x ${ROOTFS_PATH}/etc/local.d/90-resizedata.start

# mount data and boot partition (root is already mounted)
cat >${ROOTFS_PATH}/etc/fstab <<EOF
none             /       ext4    defaults,ro    0       0
/dev/mmcblk0p1   /uboot  vfat    defaults,ro    0       2
/dev/mmcblk0p4   /data   ext4    defaults       0       1

proc           /proc        proc   defaults        0     0
sysfs          /sys         sysfs  defaults        0     0
devpts         /dev/pts     devpts gid=4,mode=620  0     0
tmpfs          /dev/shm     tmpfs  defaults        0     0
tmpfs          /tmp         tmpfs  defaults        0     0
tmpfs          /run         tmpfs  defaults        0     0
tmpfs          /var/lock    tmpfs  defaults        0     0
EOF

# prepare mount points
mkdir -p ${ROOTFS_PATH}/uboot
mkdir -p ${ROOTFS_PATH}/data
mkdir -p ${ROOTFS_PATH}/proc
mkdir -p ${ROOTFS_PATH}/sys
mkdir -p ${ROOTFS_PATH}/tmp
mkdir -p ${ROOTFS_PATH}/run
mkdir -p ${ROOTFS_PATH}/dev/pts
mkdir -p ${ROOTFS_PATH}/dev/shm
mkdir -p ${ROOTFS_PATH}/var/lock

# time
chroot_exec rc-update add openntpd default
cat >${ROOTFS_PATH}/etc/conf.d/openntpd <<EOF
NTPD_OPTS="-s"
EOF
cat >${ROOTFS_PATH}/etc/ntpd.conf <<EOF
servers pool.ntp.org
EOF

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# uboot tools config
cat >${ROOTFS_PATH}/etc/fw_env.config <<EOF
/uboot/uboot.env  0x0000          0x4000
EOF

# TODO REMOVE THIS
# mark system as booted (should be moved to application)
cat >${ROOTFS_PATH}/etc/local.d/99-uboot.start <<EOF
#!/bin/sh
mount -o remount,rw /uboot

fw_setenv boot_count 1

sync
mount -o remount,ro /uboot
EOF
chmod +x ${ROOTFS_PATH}/etc/local.d/99-uboot.start

# copy helper scripts
cp ${RES_PATH}/scripts/* ${ROOTFS_PATH}/sbin/


# TODO configurable
# dropbear
chroot_exec apk add dropbear
chroot_exec rc-update add dropbear
ln -s /data/etc/dropbear/ ${ROOTFS_PATH}/etc/dropbear

mv ${ROOTFS_PATH}/etc/conf.d/dropbear ${ROOTFS_PATH}/etc/conf.d/dropbear_org
ln -s /data/etc/dropbear/dropbear.conf ${ROOTFS_PATH}/etc/conf.d/dropbear

# cleanup
rm -rf ${ROOTFS_PATH}/var/cache/apk/*

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
echo ">> Move persistent data to /data"

# prepare /data
cat >${ROOTFS_PATH}/etc/local.d/20-data_prepare.start <<EOF
#!/bin/sh
mkdir -p /data/etc/
touch /data/etc/resolv.conf

# Set time zone
if [ ! -f /data/etc/timezone ]; then
  echo "${DEFAULT_TIMEZONE}" > /data/etc/timezone
  ln -fs /usr/share/zoneinfo/${DEFAULT_TIMEZONE} /data/etc/localtime
fi

# set host name
if [ ! -f /data/etc/hostname ]; then
  echo "${DEFAULT_HOSTNAME}" > /data/etc/hostname
fi

# root password
root_pw=\$(mkpasswd -m sha-512 -s "${DEFAULT_ROOT_PASSWORD}")
echo "root:\${root_pw}:0:0:::::" > /data/etc/shadow

# interface
if [ ! -f /data/etc/interfaces ]; then
cat > /data/etc/interfaces <<EOF2
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF2
fi

# dropbear
mkdir -p /data/etc/dropbear/
if [ ! -f /data/etc/dropbear/dropbear.conf ]; then
  cp /etc/conf.d/dropbear_org /data/etc/dropbear/dropbear.conf
fi

mkdir -p /data/root/

EOF
chmod +x ${ROOTFS_PATH}/etc/local.d/20-data_prepare.start

# link root dir
rmdir ${ROOTFS_PATH}/root
ln -s /data/root ${ROOTFS_PATH}/root

# resolv.conf & udhcpc
mkdir -p ${ROOTFS_PATH}/etc/udhcpc
cat >${ROOTFS_PATH}/etc/udhcpc/udhcpc.conf <<EOF
RESOLV_CONF=/data/etc/resolv.conf

EOF
ln -fs /data/etc/resolv.conf ${ROOTFS_PATH}/etc/resolv.conf

# root password
ln -fs /data/etc/shadow ${ROOTFS_PATH}/etc/shadow

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
echo ">> Prepare kernel for uboot"

# build uImage
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 -n "Linux kernel" -d ${ROOTFS_PATH}/boot/vmlinuz-rpi2 ${ROOTFS_PATH}/boot/uImage 


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# create boot FS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo ">> Configure boot FS"

# download base firmware
mkdir -p ${BOOTFS_PATH}
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/bootcode.bin
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup_cd.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup_db.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup_x.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup4.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup4cd.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup4db.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/fixup4x.dat
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start_cd.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start_db.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start_x.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start4.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start4cd.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start4db.elf
wget -P ${BOOTFS_PATH} https://github.com/raspberrypi/firmware/raw/master/boot/start4x.elf

# copy linux kernel and overlays to boot
cp ${ROOTFS_PATH}/usr/lib/linux-*-rpi2/*.dtb ${BOOTFS_PATH}/
cp -r ${ROOTFS_PATH}/usr/lib/linux-*-rpi2/overlays ${BOOTFS_PATH}/

# copy u-boot
cp /uboot/* ${BOOTFS_PATH}/

# generate boot script
mkimage -A arm -T script -C none -n "Boot script" -d ${RES_PATH}/boot.cmd ${BOOTFS_PATH}/boot.scr


# write boot config
cat >${BOOTFS_PATH}/config.txt <<EOF
disable_splash=1
boot_delay=0

gpu_mem=256
gpu_mem_256=64

hdmi_drive=1
hdmi_group=2
hdmi_mode=1
hdmi_mode=87
hdmi_cvt 800 480 60 6 0 0 0

kernel=u-boot_rpi1.bin

[pi0w]
kernel=u-boot_rpi0_w.bin

[pi2]
kernel=u-boot_rpi2.bin

[pi3]
kernel=u-boot_rpi3.bin

[pi4]
kernel=u-boot_rpi4.bin

[all]
enable_uart=1

EOF

cat >${BOOTFS_PATH}/cmdline.txt <<EOF
console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 fsck.repair=yes ro rootwait quiet
EOF

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# create data FS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo ">> Configure data FS"
mkdir -p ${DATAFS_PATH}


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# create image
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo ">> Create SD card image"

# boot partition
cat >${WORK_PATH}/genimage_boot.cfg <<EOF
image boot.vfat {
  vfat {
    label = "boot"
  }
  size = ${SIZE_BOOT}
}
EOF
make_image ${BOOTFS_PATH} ${WORK_PATH}/genimage_boot.cfg

# root partition
cat >${WORK_PATH}/genimage_root.cfg <<EOF
image rootfs.ext4 {
  ext4 {
    label = "rootfs"
  }
  size = ${SIZE_ROOT_FS}
}
EOF
make_image ${ROOTFS_PATH} ${WORK_PATH}/genimage_root.cfg

# data partition
cat >${WORK_PATH}/genimage_data.cfg <<EOF
image datafs.ext4 {
  ext4 {
    label = "data"
  }
  size = ${SIZE_DATA}
}
EOF
make_image ${DATAFS_PATH} ${WORK_PATH}/genimage_data.cfg

# sd card image
cat >${WORK_PATH}/genimage_sdcard.cfg <<EOF
image sdcard.img {
  hdimage {
  }

  partition boot {
    partition-type = 0xC
    bootable = "true"
    image = "boot.vfat"
  }

  partition rootfs_a {
    partition-type = 0x83
    image = "rootfs.ext4"
    size = ${SIZE_ROOT_PART}
  }
  partition rootfs_b {
    partition-type = 0x83
    image = "rootfs.ext4"
    size = ${SIZE_ROOT_PART}
  }

  partition datafs {
    partition-type = 0x83
    image = "datafs.ext4"
  }
}
EOF
make_image ${IMAGE_PATH} ${WORK_PATH}/genimage_sdcard.cfg

echo ">> Compress images"
# copy final image
gzip -c ${IMAGE_PATH}/sdcard.img > ${OUTPUT_PATH}/${IMG_NAME}.img.gz
gzip -c ${IMAGE_PATH}/rootfs.ext4 > ${OUTPUT_PATH}/${IMG_NAME}_update.img.gz

# create checksums
cd ${OUTPUT_PATH}/
sha256sum ${IMG_NAME}.img.gz > ${IMG_NAME}.img.gz.sha256
sha256sum ${IMG_NAME}_update.img.gz > ${IMG_NAME}_update.img.gz.sha256