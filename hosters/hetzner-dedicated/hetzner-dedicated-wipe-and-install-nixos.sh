#!/usr/bin/env bash

# Installs NixOS on a Hetzner server, wiping the server.
#
# This is for a specific server configuration; adjust where needed.
#
# When the script is done, make sure to boot the server from HD, not rescue mode again.

# Explanations:
#
# * Adapted from https://gist.github.com/nh2/78d1c65e33806e7728622dbe748c2b6a
# * Following largely https://nixos.org/nixos/manual/index.html#sec-installing-from-other-distro.
# * **Important:** We boot in legacy-BIOS mode, not UEFI, because that's what Hetzner uses.
#   * NVMe devices aren't supported for booting (those require EFI boot)
# * We set a custom `configuration.nix` so that we can connect to the machine afterwards,
#   inspired by https://nixos.wiki/wiki/Install_NixOS_on_Hetzner_Online
# * This server has 2 HDDs.
#   We put everything on RAID1.
#   Storage scheme: `partitions -> RAID -> LVM -> ext4`.
# * A root user with empty password is created, so that you can just login
#   as root and press enter when using the Hetzner spider KVM.
#   Of course that empty-password login isn't exposed to the Internet.
#   Change the password afterwards to avoid anyone with physical access
#   being able to login without any authentication.
# * The script reboots at the end.


# Default options
RAIDLEVEL=1
HOSTNAME='hetzner'
NETWORK_BRIDGE=0

# Default SSH key
SSH_PUBKEY="$(xargs < <(find "$HOME/.ssh" -name '*.pub' -exec cat {} \; -quit))"

# Strict mode
set -euo pipefail

# Parameter parsing
while true; do
  case "$1" in
    # Construct RAID in striped mode rather than mirror
    --raid0)
      RAIDLEVEL=0
      shift
      ;;

    # Configure a network bridge and enslave the primary NIC
    --bridge)
      NETWORK_BRIDGE=1
      shift
      ;;

    # Configure a known hostname
    --hostname)
      HOSTNAME="$2"
      shift 2
      ;;

    # Provide the path to an SSH public key file to use for the root user
    --pubkey)
      SSH_PUBKEY="$(xargs < "$2")"
      shift 2
      ;;

    # Print shell statements
    --verbose|-v)
      VERBOSE=1
      shift
      ;;

    # Print usage information
    --help|-h)
      cat <<-EOF
				usage: ssh root@<hostname> bash -s < $0 [options]

				OPTIONS
						--raid0                   Construct the root RAID array in striped mode rather than mirrored mode
						--bridge                  Provision a network bridge and enslave the primary NIC to it
						--hostname HOSTNAME       Set a known hostname, used for both the host and the madm RAID
						--pubkey FILE             Provide the path to a file containing an SSH public key to be provisioned to the root user
						--verbose|-h              Enable shell command tracing
				EOF
      ;;

    # Stop parsing option on first unknown parameter
    *)
      break
  esac
done

[[ -n $VERBOSE ]] && set -x

# Install dependencies
apt-get install -y sudo

# Inspect existing disks
declare -a DISKS
readarray -t DISKS < <(lsblk -Jl | jq -r '.blockdevices[] | select(.type == "disk") | .name')

# Helper function to get the correct partition name given a disk name and partition number
# partname sda 2 => /dev/sda2
# partname nvme0n1 2 => /dev/nvme0n1p2
partname() {
  if [[ $1 == nvme* ]]; then
    echo "/dev/${1}p${2}"
  else
    echo "/dev/${1}${2}"
  fi
}

# Undo existing setups to allow running the script multiple times to iterate on it.
# We allow these operations to fail for the case the script runs the first time.
set +e
umount /mnt
vgchange -an
set -e

# Stop all mdadm arrays that the boot may have activated.
mdadm --stop --scan

# Prevent mdadm from auto-assembling arrays.
# Otherwise, as soon as we create the partition tables below, it will try to
# re-assemple a previous RAID if any remaining RAID signatures are present,
# before we even get the chance to wipe them.
# From:
#     https://unix.stackexchange.com/questions/166688/prevent-debian-from-auto-assembling-raid-at-boot/504035#504035
# We use `>` because the file may already contain some detected RAID arrays,
# which would take precedence over our `<ignore>`.
echo 'AUTO -all
ARRAY <ignore> UUID=00000000:00000000:00000000:00000000' > /etc/mdadm/mdadm.conf

# Create partition tables (--script to not ask)
for disk in "${DISKS[@]}"; do
  parted --script "/dev/$disk" mklabel gpt
done

# Create partitions (--script to not ask)
#
# We create the 1MB BIOS boot partition at the front.
#
# Note we use "MB" instead of "MiB" because otherwise `--align optimal` has no effect;
# as per documentation https://www.gnu.org/software/parted/manual/html_node/unit.html#unit:
# > Note that as of parted-2.4, when you specify start and/or end values using IEC
# > binary units like "MiB", "GiB", "TiB", etc., parted treats those values as exact
#
# Note: When using `mkpart` on GPT, as per
#   https://www.gnu.org/software/parted/manual/html_node/mkpart.html#mkpart
# the first argument to `mkpart` is not a `part-type`, but the GPT partition name:
#   ... part-type is one of 'primary', 'extended' or 'logical', and may be specified only with 'msdos' or 'dvh' partition tables.
#   A name must be specified for a 'gpt' partition table.
# GPT partition names are limited to 36 UTF-16 chars, see https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_entries_(LBA_2-33).
for disk in "${DISKS[@]}"; do
  parted --script --align optimal "/dev/$disk" -- \
         mklabel gpt \
         mkpart 'BIOS-boot-partition' 1MB 2MB \
         set 1 bios_grub on \
         mkpart 'data-partition' 2MB '100%'
done

# Relaod partitions
partprobe

for disk in "${DISKS[@]}"; do
  # Wait for all devices to exist
  udevadm settle --timeout=5 --exit-if-exists="$(partname "$disk" 1)"
  udevadm settle --timeout=5 --exit-if-exists="$(partname "$disk" 2)"

  # Wipe any previous RAID signatures
  mdadm --zero-superblock --force "$(partname "$disk" 2)"
done


# Create RAIDs
# Note that during creating and boot-time assembly, mdadm cares about the
# host name, and the existence and contents of `mdadm.conf`!
# This also affects the names appearing in /dev/md/ being different
# before and after reboot in general (but we take extra care here
# to pass explicit names, and set HOMEHOST for the rebooting system further
# down, so that the names appear the same).
# Almost all details of this are explained in
#   https://bugzilla.redhat.com/show_bug.cgi?id=606481#c14
# and the followup comments by Doug Ledford.

# An array of all partitions in the RAID
declare -a RAIDPARTS
for disk in "${DISKS[@]}"; do
  RAIDPARTS+=( "$(partname "$disk" 2)" )
done

# shellcheck disable=SC2046
mdadm --create --run --verbose /dev/md0 --level="$RAIDLEVEL" --raid-devices="${#DISKS[@]}" \
      --homehost="$HOSTNAME" --name=root0 "${RAIDPARTS[@]}"

# Assembling the RAID can result in auto-activation of previously-existing LVM
# groups, preventing the RAID block device wiping below with
# `Device or resource busy`. So disable all VGs first.
vgchange -an

# Wipe filesystem signatures that might be on the RAID from some
# possibly existing older use of the disks (RAID creation does not do that).
# See https://serverfault.com/questions/911370/why-does-mdadm-zero-superblock-preserve-file-system-information
wipefs -a /dev/md0

# Disable RAID recovery. We don't want this to slow down machine provisioning
# in the rescue mode. It can run in normal operation after reboot.
echo 0 > /proc/sys/dev/raid/speed_limit_max

# LVM
# PVs
pvcreate /dev/md0
# VGs
vgcreate vg0 /dev/md0
# LVs (--yes to automatically wipe detected file system signatures)
lvcreate --yes --extents 95%FREE -n root0 vg0  # 5% slack space

# Filesystems (-F to not ask on preexisting FS)
mkfs.ext4 -F -L root /dev/mapper/vg0-root0

# Creating file systems changes their UUIDs.
# Trigger udev so that the entries in /dev/disk/by-uuid get refreshed.
# `nixos-generate-config` depends on those being up-to-date.
# See https://github.com/NixOS/nixpkgs/issues/62444
udevadm trigger

# Wait for FS labels to appear
udevadm settle --timeout=5 --exit-if-exists=/dev/disk/by-label/root

# NixOS pre-installation mounts

# Mount target root partition
mount /dev/disk/by-label/root /mnt

# Installing nix

# Allow installing nix as root, see
#   https://github.com/NixOS/nix/issues/936#issuecomment-475795730
mkdir -p /etc/nix
echo "build-users-group =" > /etc/nix/nix.conf

curl -L https://nixos.org/nix/install | sh
set +u +x # sourcing this may refer to unset variables that we have no control over
  # shellcheck disable=SC1090
. "$HOME"/.nix-profile/etc/profile.d/nix.sh
set -u -x

# Keep in sync with `system.stateVersion` set below!
# nix-channel --add https://nixos.org/channels/nixos-20.03 nixpkgs
nix-channel --add https://nixos.org/channels/nixos-20.03 nixpkgs
nix-channel --update

# Getting NixOS installation tools
nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; with config.system.build; [ nixos-generate-config nixos-install nixos-enter manual.manpages ]"

nixos-generate-config --root /mnt

# Find the name of the network interface that connects us to the Internet.
# Inspired by https://unix.stackexchange.com/questions/14961/how-to-find-out-which-interface-am-i-using-for-connecting-to-the-internet/302613#302613
RESCUE_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)')

# Find what its name will be under NixOS, which uses stable interface names.
# See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
# NICs for most Hetzner servers are not onboard, which is why we use
# `ID_NET_NAME_PATH`otherwise it would be `ID_NET_NAME_ONBOARD`.
INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*${RESCUE_INTERFACE})")
UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
NIXOS_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_PATH=\w+' | cut -d= -f2)
echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'"

IP_V4=$(ip route get 8.8.8.8 | grep -Po '(?<=src )(\S+)')
echo "Determined IP_V4 as $IP_V4"

# Determine Internet IPv6 by checking route, and using ::1
# (because Hetzner rescue mode uses ::2 by default).
# The `ip -6 route get` output on Hetzner looks like:
#   # ip -6 route get 2001:4860:4860:0:0:0:0:8888
#   2001:4860:4860::8888 via fe80::1 dev eth0 src 2a01:4f8:151:62aa::2 metric 1024  pref medium
IP_V6="$(ip route get 2001:4860:4860:0:0:0:0:8888 | head -1 | cut -d' ' -f7 | cut -d: -f1-4)::1"
echo "Determined IP_V6 as $IP_V6"

# Determine the MAC of our primary interface so we can assign it to the bridge
read -r MAC <"/sys/class/net/$RESCUE_INTERFACE/address"
echo "Determined MAC as $MAC"

# From https://stackoverflow.com/questions/1204629/how-do-i-get-the-default-gateway-in-linux-given-the-destination/15973156#15973156
read -r _ _ DEFAULT_GATEWAY _ < <(ip route list match 0/0); echo "$DEFAULT_GATEWAY"
echo "Determined DEFAULT_GATEWAY as $DEFAULT_GATEWAY"

NET_IFACE="$NIXOS_INTERFACE"
if [[ $NETWORK_BRIDGE == "1" ]]; then
  NET_IFACE="br0"
  NET_SLAVE="bridges.br0.interfaces = [ \"$NET_IFACE\" ];"
  NET_SYSCTL='boot.kernel.sysctl = {
    "net.ipv6.conf.all.forwarding" = "1";
    "net.ipv4.ip_forward" = "1";

    # Disable netfilter for bridges, for performance and security
    # Note that this means bridge-routed frames do not go through iptables
    # https://bugzilla.redhat.com/show_bug.cgi?id=512206#c0
    "net.bridge.bridge-nf-call-ip6tables" = "0";
    "net.bridge.bridge-nf-call-iptables" = "0";
    "net.bridge.bridge-nf-call-arptables" = "0";
  };'
fi

# Generate `configuration.nix`. Note that we splice in shell variables.
cat >| /mnt/etc/nixos/configuration.nix <<EOF
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use GRUB2 as the boot loader.
  # We don't use systemd-boot because Hetzner uses BIOS legacy boot.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    devices = [ $(printf '"/dev/%s"' "${DISKS[@]}") ];
  };

  # The madm RAID was created with a certain hostname, which madm will consider
  # the "home hostname". Changing the system hostname will result in the array
  # being considered "foregin" as opposed to "local", and showing it as
  # '/dev/md/<hostname>:root0' instead of '/dev/md/root0'.

  # This is mdadm's protection against accidentally putting a RAID disk
  # into the wrong machine and corrupting data by accidental sync, see
  # https://bugzilla.redhat.com/show_bug.cgi?id=606481#c14 and onward.
  # We set the HOMEHOST manually go get the short '/dev/md' names,
  # and so that things look and are configured the same on all such
  # machines irrespective of host names.
  # We do not worry about plugging disks into the wrong machine because
  # we will never exchange disks between machines.
  environment.etc."mdadm.conf".text = ''
    HOMEHOST $HOSTNAME
  '';

  # The RAIDs are assembled in stage1, so we need to make the config
  # available there.
  boot.initrd.mdadmConf = config.environment.etc."mdadm.conf".text;

  # Network (Hetzner uses static IP assignments, and we don't use DHCP here)
  networking.useDHCP = false;

  networking.interfaces."$NET_IFACE" = {
    ipv4 = {
      addresses = [{
        # Server main IPv4 address
        address = "$IP_V4";
        prefixLength = 24;
      }];

      routes = [
        # Default IPv4 gateway route
        {
          address = "0.0.0.0";
          prefixLength = 0;
          via = "$DEFAULT_GATEWAY";
        }
      ];
    };

    ipv6 = {
      addresses = [{
        address = "$IP_V6";
        prefixLength = 64;
      }];

      # Default IPv6 route
      routes = [{
        address = "::";
        prefixLength = 0;
        via = "fe80::1";
      }];
    };
  }

  networking = {
    nameservers = [ "8.8.8.8" "8.8.4.4" ];
    hostName = "$HOSTNAME";
    ${NET_SLAVE:-}
  };

  ${NET_SYSCTL:-}

  # Initial empty root password for easy login:
  users.users.root.initialHashedPassword = "";
  services.openssh.permitRootLogin = "prohibit-password";
  services.openssh.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    "$(echo "$SSH_PUBKEY" | xargs)"
  ];

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "20.03"; # Did you read the comment?
}
EOF

# Install NixOS
PATH="$PATH" NIX_PATH="$NIX_PATH" "$(command -v nixos-install)" --no-root-passwd --root /mnt --max-jobs "$(nproc)"

umount /mnt

reboot
