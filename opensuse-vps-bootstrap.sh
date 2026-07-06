#!/bin/bash
set -euo pipefail

# Configuration options for devices and paths.
SRV_MOUNT_PATH="/srv"
MOUNT_DEVICE="${1}"

NETBIRD_REPO_ALIAS="netbird"
NETBIRD_REPO="https://pkgs.netbird.io/yum/"
CONTAINER_REPO="https://download.opensuse.org/repositories/Virtualization:containers/16.0/Virtualization:containers.repo"

# Repository and system environment initialization.
# GPG key fingerprint: https://docs.netbird.io/get-started/install/linux#open-suse-zypper
sudo zypper addrepo "$NETBIRD_REPO" "$NETBIRD_REPO_ALIAS" || true
# Add repo to install crun
sudo zypper addrepo "$CONTAINER_REPO" || true

# Download and import package gpg keys, to avoid approval interactive prompt
curl -fsSL https://download.opensuse.org/repositories/Virtualization:/containers/16.0/repodata/repomd.xml.key > /tmp/repo-containers.key
curl -fsSL https://pkgs.netbird.io/yum/repodata/repomd.xml.key > /tmp/repo-netbird.key

rpm --import /tmp/repo-containers.key
rpm --import /tmp/repo-netbird.key

# Clean up previously existing mount and subvolumes safely.
if mountpoint -q "$SRV_MOUNT_PATH"; then
    sudo umount "$SRV_MOUNT_PATH"

    # Get subvolume ID of old srv and delete it
    SUBVOL_ID=$(sudo btrfs subvolume list / | grep "@$SRV_MOUNT_PATH" | awk '{print $2}')
    if [ -n "$SUBVOL_ID" ]; then
        sudo btrfs subvolume delete --subvolid "$SUBVOL_ID" /
    fi
fi

# Storage provisioning and btrfs layout creation.
sudo mkfs.btrfs "$MOUNT_DEVICE"
sudo mount "$MOUNT_DEVICE" "$SRV_MOUNT_PATH"

sudo btrfs subvolume create "$SRV_MOUNT_PATH/@"
sudo btrfs subvolume create "$SRV_MOUNT_PATH/@/containers"
sudo btrfs subvolume create "$SRV_MOUNT_PATH/@/postgres"
sudo btrfs subvolume create "$SRV_MOUNT_PATH/@/postgres_wal"
sudo btrfs subvolume create "$SRV_MOUNT_PATH/@/valkey"

# If srv mount path entry exists in fstab, comment out, uses a GNU sed extension
sudo sed -i "\|^[^#]*${SRV_MOUNT_PATH}|s/^/#/" /etc/fstab
DEVICE_UUID=$(lsblk -no UUID "$MOUNT_DEVICE")

sudo tee -a /etc/fstab << EOF

UUID=${DEVICE_UUID}  ${SRV_MOUNT_PATH}                    btrfs  defaults,subvol=/@,noatime                      0  0
UUID=${DEVICE_UUID}  ${SRV_MOUNT_PATH}/containers         btrfs  subvol=/@/containers,noatime,compress=zstd:1    0  0
UUID=${DEVICE_UUID}  ${SRV_MOUNT_PATH}/postgres           btrfs  subvol=/@/postgres,noatime                      0  0
UUID=${DEVICE_UUID}  ${SRV_MOUNT_PATH}/postgres_wal       btrfs  subvol=/@/postgres_wal,noatime                  0  0
UUID=${DEVICE_UUID}  ${SRV_MOUNT_PATH}/valkey             btrfs  subvol=/@/valkey,noatime                        0  0

EOF

# Create the mount point directories
sudo mkdir -p "$SRV_MOUNT_PATH/containers"
sudo mkdir -p "$SRV_MOUNT_PATH/postgres"
sudo mkdir -p "$SRV_MOUNT_PATH/postgres_wal"
sudo mkdir -p "$SRV_MOUNT_PATH/valkey"

# Mount
sudo mount "$SRV_MOUNT_PATH/containers"
sudo mount "$SRV_MOUNT_PATH/postgres"
sudo mount "$SRV_MOUNT_PATH/postgres_wal"
sudo mount "$SRV_MOUNT_PATH/valkey"

# Disable copy on write, to improve performance
sudo chattr +C "$SRV_MOUNT_PATH/postgres"
sudo chattr +C "$SRV_MOUNT_PATH/postgres_wal"
sudo chattr +C "$SRV_MOUNT_PATH/valkey"

# Make current user own the necesary srv folders
sudo chown -R "$USER:$USER" "$SRV_MOUNT_PATH/containers"
sudo chown -R "$USER:$USER" "$SRV_MOUNT_PATH/postgres"
sudo chown -R "$USER:$USER" "$SRV_MOUNT_PATH/postgres_wal"
sudo chown -R "$USER:$USER" "$SRV_MOUNT_PATH/valkey"

# Install packages
# Have to install crun separately as runc is the defualt for OpenSUSE
sudo zypper --non-interactive install zram-generator crun podman
sudo zypper --non-interactive install qemu-kvm libvirt-daemon libvirt-client bridge-utils

mkdir -p "$SRV_MOUNT_PATH/containers/storage"
mkdir -p "~/.config/containers"
tee ~/.config/containers/storage.conf << EOF
[storage]
driver = "overlay"
graphroot = "$SRV_MOUNT_PATH/containers/storage"

[storage.options.overlay]
# Enable metacopy for faster layer operations
# Requires kernel 4.19+ and overlay module
mountopt = "nodev,metacopy=on"
EOF

sudo tee /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = lz4
swap-priority = 100
EOF

# Make zram units get created
sudo systemctl daemon-reexec

sudo tee /etc/sysctl.d/99-custom-tuning.conf << 'EOF'
# Reuse TIME_WAIT sockets, important for short-lived connections
net.ipv4.tcp_tw_reuse = 1
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
# Required for container networking
net.ipv4.ip_forward = 1

# Reserve huge pages for postgres, check the amount required by postgres
# Using `SHOW shared_memory_size_in_huge_pages;`
vm.nr_hugepages = 80
# Since zram is enabled, a relatively high value is preferred
vm.swappiness=60
# Setting page-cluster to 0 disables page read-ahead to avoid CPU overhead on compressed memory blocks.
vm.page-cluster=0
# Required by Valkey to prevent background save failures
vm.overcommit_memory = 1
EOF

sudo mkdir -p /etc/systemd/system/user@.service.d
cat << 'EOF' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpuset cpu io memory pids
EOF

# Required by valkey to minimize latency
sudo tee /etc/default/grub.d/50-thp.cfg << 'EOF'
GRUB_CMDLINE_LINUX="transparent_hugepage=never"
EOF

# Regenerate grub config because we modified cgroup settings
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

echo "System bootstrap completed successfully. Please reboot."
