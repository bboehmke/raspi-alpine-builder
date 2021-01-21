# Raspberry PI Alpine Linux Image Builder

Create minimal Linux images based on [Alpine Linux](https://alpinelinux.org/)
for the [Raspberry PI](https://www.raspberrypi.org/).


## Features

* Alpine base
  * Small image size
  * Fast image build
* A/B partition schema
  * Simple update of whole system
  * Fallback if update failed
* Single image for every Raspberry PI
* Read only root filesystem


## Usage

### Image Creation

> A simple example for a go application can be found in the [example](example/) 
> directory.

To generate an empty image simply run:
```
docker run --rm -it -v $PWD/output:/output bboehmke/raspi-alpine-builder
```

This will create 2 image files in the directory `$PWD/output/`:
* `alpine.img.gz`: complete SD card image for the raspberry
* `alpine_update.img.gz`: image of root partition to update running raspberry

> For each image a *.sha256 file will be generated to validate integrity.

To add custom modifications mount a script to `/input/image.sh`.
The following variables can be useful for the for and `image.sh`:

| Variable    | Description                 |
| ----------- | --------------------------- |
| INPUT_PATH  | Path to input directory     |
| ROOTFS_PATH | Path to new root filesystem |
| BOOTFS_PATH | Path to new boot filesystem |
| DATAFS_PATH | Path to new data filesystem |

There is also a function `chroot_exec` that can be used to run command inside 
the new root filesystem. To enable a service called `example_daemon` simple run:
```
chroot_exec rc-update add example_daemon default
```

#### Config Variables

The following variables can be used to modify the base behaviour of the image 
builder.

| Variable                    | Default Value                        | Description                                                                                       |
| --------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------- |
| ALPINE_BRANCH               | v3.11                                | [Alpine Branch](https://alpinelinux.org/releases) to use for image         |
| ALPINE_MIRROR               | http://dl-cdn.alpinelinux.org/alpine | Mirror used for package download                                                                  |
| CUSTOM_IMAGE_SCRIPT         | image.sh                             | Name of script for image customizations (relative to input dir)                                   |
| DEFAULT_DROPBEAR_ENABLED    | true                                 | True to enable SSH server by default                                                              |
| DEFAULT_HOSTNAME            | alpine                               | Default hostname                                                                                  |
| DEFAULT_KERNEL_MODULES      | ipv6 af_packet                       | Kernel modules to keep in image                                                                   |
| DEFAULT_ROOT_PASSWORD       | alpine                               | Default password for root user                                                                    |
| DEFAULT_TIMEZONE            | Etc/UTC                              | Default [Timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) to use for image |
| IMG_NAME                    | sdcard                               | Base name of created image file                                                                   |
| INPUT_PATH                  | /input                               | Input directory inside container                                                                  |
| OUTPUT_PATH                 | /output                              | Output directory inside container                                                                 |
| SIZE_BOOT                   | 100M                                 | Size of boot partition                                                                            |
| SIZE_DATA                   | 20M                                  | Initial Size of data partition                                                                    |
| SIZE_ROOT_FS                | 200M                                 | Size of root file system                                                                          |
| SIZE_ROOT_PART              | 500M                                 | Size of root partition                                                                            |
| UBOOT_COUNTER_RESET_ENABLED | true                                 | True to enable simple boot counter reset service                                                  |
| RPI_FIRMWARE_BRANCH         | stable                               | [Raspberry Pi Firmware Branch](https://github.com/raspberrypi/firmware/branches) to use for image                                                    |
### Update running system

The system can be updated without a complete flash of the SD card from the 
running system with the following steps:

1. Transfer the update image to the running system
2. (Optional) Validate integrity of image with checksum file
3. Write the image to the actual inactive partition
4. Switch active partition
5. Reboot system

> An example implementation can be found in the helper script 
> [ab_flash](resources/scripts/ab_flash)

## Image structure

### Partition Layout

The image contains 4 partitions:

1. **Boot:** (Size: `SIZE_BOOT`) \
   Contains boot loader and boot configuration
    
2. **Root A:** (Size: `SIZE_ROOT_PART`) \
   Contains complete root filesystem including all required kernels

3. **Root B:** (Size: `SIZE_ROOT_PART`) \
   Same as *Root A*

4. **Data:** (Size: Initial `SIZE_DATA` & increases on first start) \
   Contains persistent data for both root partitions

> With the exception of the data partition every partition is mounted read only

The A/B root partitions enables an easy and reliable way to update the complete 
system. This is done by flashing the inactive partition with a new root 
filesystem and make this partition active. If this new filesystem does not boot
the boot loader will fallback to the old partition.

The root file system should be as small as possible to reduce the update time 
later. To support future increase of the root file system the partition should 
contain some free space.

### Boot loader

To support the A/B partition schema the [U-Boot](https://www.denx.de/wiki/U-Boot)
boot loader is used.

The configuration/script for the boot loader can be found in the 
[boot.cmd](resources/boot.cmd). This will boot the active root partition and 
switch the active partition if the active one will not start.
> This script also select the right kernel for old Raspberry PIs

The image contains a simple tool that resets the boot counter and switch the 
active partition from the running OS. The sources of the script can be found 
in the [uboot.c](resources/uboot.c). 

