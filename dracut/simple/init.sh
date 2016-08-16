#!/bin/sh
echo "Qubes initramfs script here:"

mkdir -p /proc /sys /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

if [ -e /dev/mapper/dmroot ] ; then
    echo "Qubes: FATAL error: /dev/mapper/dmroot already exists?!"
fi

set -e

modprobe xenblk || modprobe xen-blkfront || echo "Qubes: Cannot load Xen Block Frontend..."
modprobe dm-thin-pool

initialize_pool() {
    if [ -n "$pool_dev" ]; then
        return
    fi
    while ! [ -e /dev/xvdc ]; do sleep 0.1; done
    VOLATILE_SIZE=$(cat /sys/block/xvdc/size) # sectors
    meta_size=$(( $VOLATILE_SIZE / 512 ))
    data_size=$(( $VOLATILE_SIZE - $meta_size ))
    dmsetup create volatile-tmeta \
        --table "0 $meta_size linear /dev/xvdc 0"
    dmsetup create volatile-tdata \
        --table "0 $data_size linear /dev/xvdc $meta_size"
    meta_dev=$(dmsetup info -c --noheadings volatile-tmeta | cut -d : -f 2,3)
    data_dev=$(dmsetup info -c --noheadings volatile-tdata | cut -d : -f 2,3)
    dmsetup create volatile --addnodeoncreate --table \
        "0 $data_size thin-pool $meta_dev $data_dev 256 0"
    pool_dev=$(dmsetup info -c --noheadings volatile | cut -d : -f 2,3)
}

echo "Waiting for /dev/xvda* devices..."
while ! [ -e /dev/xvda ]; do sleep 0.1; done

SWAP_SIZE=$(( 1024 * 1024 * 2 )) # sectors, 1GB

initialize_pool

ROOT_SIZE=$(cat /sys/block/xvda/size) # sectors
if [ `cat /sys/block/xvda/ro` = 1 ] ; then
    echo "Qubes: Doing COW setup for AppVM..."

    dmsetup message volatile 0 "create_thin 0"
    dmsetup create dmroot \
        --table "0 $ROOT_SIZE thin $pool_dev 0 /dev/xvda"
else
    echo "Qubes: Doing R/W setup for TemplateVM..."
    dmsetup create dmroot \
        --table "0 $ROOT_SIZE linear /dev/xvda 0"
fi
dmsetup message volatile 0 "create_thin 16"
dmsetup create dmswap \
    --table "0 $SWAP_SIZE thin $pool_dev 16"
dmsetup mknodes dmroot dmswap
mkswap /dev/mapper/dmswap

echo Qubes: done.

modprobe ext4 || :

mkdir -p /sysroot
mount /dev/mapper/dmroot /sysroot -o ro
NEWROOT=/sysroot

kver="`uname -r`"
if ! [ -d "$NEWROOT/lib/modules/$kver/kernel" ]; then
    echo "Waiting for /dev/xvdd device..."
    while ! [ -e /dev/xvdd ]; do sleep 0.1; done

    # Mount only `uname -r` subdirectory, to leave the rest of /lib/modules writable
    mkdir -p /tmp/modules
    mount -n -t ext3 /dev/xvdd /tmp/modules
    if ! [ -d "$NEWROOT/lib/modules/$kver" ]; then
        mount "$NEWROOT" -o remount,rw
        mkdir -p "$NEWROOT/lib/modules/$kver"
        mount "$NEWROOT" -o remount,ro
    fi
    mount --bind "/tmp/modules/$kver" "$NEWROOT/lib/modules/$kver"
    umount /tmp/modules
    rmdir /tmp/modules
fi


umount /dev /sys /proc

exec switch_root $NEWROOT /sbin/init
