#! /bin/sh

# Copyright (c) 2014 Ian White <ian@impressiver.com>
# License: [MIT](http://opensource.org/licenses/MIT)
#
# Create a bootable SD Card (or eMMC rom) containing the latest Arch Linux base.
# Intended to be used *on* a Beaglebone Black, while running either Angstrom or
# Arch Linux (and possibly other distros), it will create an SD card that can
# then be used to boot and flash (using this same script) the eMMC.
# 
# This script is based on several scripts found online, and lots of trial and
# error.

VERSION='0.0.1'

# Define the usage text.
USAGE=$( cat <<EOF
Usage: `basename $0` [-hvezk] [-d <device>]\n
-h|--help\tDisplays this helpful message
-v|--version\tDisplays the installed version of this script

-d|--device\tDevice path of the target disk where Arch Linux will be
\t\tinstalled (/dev/...)

-e|--emmc\tFlash the internal eMMC rom
-z|--wipe\tOverwrite all data on the disk before creating partitions
\t\t(only use this if you know what you are doing)

-k|--keep\tKeep temp files around after successful install
\t\t(useful for reusing previously downloaded tarballs)
EOF
)

MMC_REBOOT=$( cat <<EOF
\nArch Linux has been installed on the eMMC. Follow these reboot instructions:\n
\t* Type 'poweroff' in the terminal and hit enter\n
\t* Wait for all LED lights on the device to stop blinking\n
\t* Remove power (5v and/or USB)\n
\t* Remove the micro SD card\n
\t* Reapply power (do not hold down the user button)
EOF
)

# Path to this script file
SCRIPT_PATH="`dirname \"$0\"`"

# Path to tmp dir
TMP_PATH='/tmp/bone'

# All users with $UID 0 have root privileges.
ROOT_UID=0

# Just one single user is called root.
ROOT_NAME="root"

#
# Functions
#

# Definition of error functions.
function info()
{
   echo -e "$*" >&2
   exit 0
}

function warning()
{
   echo -e "$*" >&2
}

function error()
{
   echo -e "$*" >&2
   exit 1
}

function confirm()
{
   local ans
   local ok=0
   local default
   local t

   while [[ "$1" ]]
   do
      case "$1" in
      --default)
         shift
         default=$1
         if [[ ! "$default" ]]; then 
            error "Missing default value"
         fi

         t=$(tr '[:upper:]' '[:lower:]' <<<$default)

         if [[ "$t" != 'y'  &&  "$t" != 'yes'  &&  "$t" != 'n'  &&  "$t" != 'no' ]]; then
            error "Illegal default answer: $default"
         fi
         default=$t
         shift
         ;;
      -*)
         error "Unrecognized option: $1"
         ;;
      *)
         break
         ;;
      esac
   done

   if [[ ! "$*" ]]; then 
      error "Missing question"
   fi

   while [[ $ok -eq 0 ]]
   do
      read -p "$*" ans
      if [[ ! "$ans" ]]; then
         ans=$default
      else
         ans=$(tr '[:upper:]' '[:lower:]' <<<$ans)
      fi 

      if [[ "$ans" == 'y'  ||  "$ans" == 'yes'  ||  "$ans" == 'n'  ||  "$ans" == 'no' ]]; then
         ok=1
      fi

      if [[ $ok -eq 0 ]]; then 
         warning "Valid answers are: yes/no"
      fi
   done
   
   [[ "$ans" = "y" || "$ans" == "yes" ]]
}

function partition()
{
  echo "Partitioning '$*'..."
  fdisk $* <<EOF
o
p
n
p
1

+16M
n
p
2


a
1
t
1
e
p
w
EOF
  
  sleep 1
}

function cleanUp() 
{
  echo "Cleaning up..."
  rm -r $tmp
}

#
# Config
#

# Check if user has root privileges.
if [[ $EUID -ne $ROOT_UID ]]; then
   error "This script must be run as root!"
fi

# Check if user is root and does not use sudoer privileges.
if [[ "${SUDO_USER:-$(whoami)}" != "$ROOT_NAME" ]]; then
   error "This script must be run as root (not via sudo)"
fi

# Setup script vars.
tmp=$TMP_PATH
devices=$(cat /proc/partitions|awk '/^ / {print "/dev/"$4}')
device=""
mmc=0
zero=0
bootloader=""
rootfs=""
bootlabel="boot"
rootlabel="rootfs"
keep=0

# Fetch command line options.
while [[ "$1" ]]
do
   case "$1" in
      --help|-h)
         info "$USAGE"
         ;;
      --version|-v)
         info "`basename $0` version $VERSION"
         ;;
      --device|-d)
         shift
         device=$1
         
         if [[ ! "$device" ]]; then 
            error "Device path not specified.\n\n$USAGE"
         fi

         device=$(tr '[:upper:]' '[:lower:]' <<< $device)
         
         if [[ ! -b $device ]]; then
            error "Invalid device '$device'.\n\n" \
              "\rThe following devices are available:\n" \
              "\r$devices\n"
         fi
         
         shift
         ;;
      --emmc|--mmc|-m)
         mmc=1
         shift
         ;;
      --wipe|-z)
         zero=1
         shift
         ;;
      --keep|-k)
         keep=1
         shift
         ;;
      -*)
         error "Unrecognized option: $1\n\n$USAGE"
         ;;
      *)
         break
         ;;
   esac
done

if [[ ! "$device" ]]; then 
   error "No device specified\n\n$USAGE"
fi

if ! command -v fdisk >/dev/null 2>&1 ; then
   error "'fdisk' is required, but could not be found. Aborting."
fi

if ! confirm --default no "This will destroy all existing data on '$device'. Are you sure you want to continue? (default no) "; then
   info "Aborting."
fi

#
# Device format
#

# Unmount all mounted partitions belonging to the specified device
echo "Unmounting partitions..."
for partition in $(fdisk -l $device|awk '/^\/dev\// {print $1}')
do
  if [[ $(mount | grep $partition) != "" ]]; then
     echo "Unmounting partition '${device}p${partition}'..."
     umount "${partition}"
  fi
done

# Make eMMC partition labels distinct
if [[ $mmc -eq 1 ]]; then
  bootlabel="mmcboot"
  rootlabel="mmcrootfs"
fi

# Create a temp directory to work with
mkdir -p $tmp

# Reformat if the destination is *not* the eMMC
# (eMMC should already be properly formatted)
if [[ $mmc -ne 1 ]]; then
  # Zero out the disk using ones. Ones (not zeros) are considered free space by
  # NAND controllers
  if [[ $zero -eq 1 ]]; then
    # TODO: (IW) Use device preferred erase block size:
    # `cat /sys/block/mmcblk0/device/preferred_erase_size`
    echo "Wiping the entire disk..."
    tr "\000" "\377" < /dev/zero | dd bs=4M of=$device
  fi

  echo "Wiping first 1M of the disk..."
  tr "\000" "\377" < /dev/zero | dd bs=1024 count=1024 of=$device

  # Make sure the disk is done writing
  sync ; sleep 1 ; sync

  # Repartition the disk
  partition $device
fi

# Identify the newly created partitions
echo "Looking for expected partitions..."
part1=$(fdisk -l $device|grep -m 1 W95|awk '/^\/dev\// {print $1}')
part2=$(fdisk -l $device|grep -m 1 Linux|awk '/^\/dev\// {print $1}')

# Create a fat16 filesystem on the first partition
echo "Creating fat16 boot partition filesystem..."
mkfs.vfat -F 16 -n "$bootlabel" $part1
sleep 1

# Create an ext4 filesystem on the second partition
echo "Creating ext4 root partition filesystem..."
mkfs.ext4 -L "$rootlabel" $part2
sleep 1

# Print out the partition table
echo "New partition table:"
fdisk -l $device

#
# Install Arch Linux
#

echo "Preparing Arch Linux install..."

# Find or download the bootloader tarball
echo "Looking for bootloader..."

# Look for a bootloader archive in the same directory as the script
bootloader="${SCRIPT_PATH}/BeagleBone-bootloader.tar.gz"

if [ ! -f $bootloader ]; then
  # Download the arch-beaglebone bootloader tarball
  echo "Downloading bootloader..."
  wget http://archlinuxarm.org/os/omap/BeagleBone-bootloader.tar.gz --directory-prefix="$tmp"
  sleep 1

  bootloader="${tmp}/BeagleBone-bootloader.tar.gz"
fi

echo "Using bootloader tarball ${bootloader}"

# Find or download the rootfs tarball
echo "Looking for root filesystem..."

# Look for a rootfs archive in the same directory as the script
rootfs="${SCRIPT_PATH}/ArchLinuxARM-am33x-latest.tar.gz"

if [ ! -f $rootfs ]; then
  # Download the latest arch root filesystem tarball
  echo "Downloading latest root filesystem..."
  wget http://archlinuxarm.org/os/ArchLinuxARM-am33x-latest.tar.gz --directory-prefix="$tmp"
  sleep 1
  
  rootfs="${tmp}/ArchLinuxARM-am33x-latest.tar.gz"
fi

echo "Using root filesystem tarball ${rootfs}"

# Create tmp directories to mount "boot" and "rootfs"
mkdir $tmp/{boot,root}

# Mount the partitions to the tmp dirs
mount $part1 "${tmp}/boot"
mount $part2 "${tmp}/root"

# Extract the tarballs directly to the mounted partitions
echo "Extracting files to disk..."
tar -xvf $bootloader --no-same-owner -C "${tmp}/boot"
tar -xf $rootfs -C "${tmp}/root"

# Copy the boot image to the boot partition
echo "Copying Boot Image..."
cp "${tmp}/root/boot/zImage" "${tmp}/boot"

# Make sure the write buffer has been commited to disk
echo "Synching..."
sync ; sleep 1 ; sync

# Unmount the partitions
umount "${tmp}/boot"
umount "${tmp}/root"

# Sweep the floors
if [[ $keep -eq 0 ]]; then
  cleanUp
fi

# Huzzah!
echo "Done!"

# Print reboot instructions after flashing the eMMC
if [[ $mmc -eq 1 ]]; then
  echo "$MMC_REBOOT"
fi
