#!/bin/bash
# Quick setup for testing without physical disks
echo "Creating test disk images..."
dd if=/dev/zero of=/tmp/disk1.img bs=1M count=500 2>/dev/null
dd if=/dev/zero of=/tmo/disk2.img bs=1M count=500 2>/dev/null
sudo losetup /dev/loop10 /tmp/disk1.img
sudo losetup /dev/loop11 /tmp/disk2.img
echo "Done! Use /dev/loop10 and /dev/loop11 as test devices."
lsblk | grep loop
