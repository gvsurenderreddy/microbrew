#! /bin/sh

# Copyright (c) 2014 Ian White <ian@impressiver.com>
# License: [MIT](http://opensource.org/licenses/MIT)

# Define the usage text.
USAGE=$( cat <<EOF
Usage: `basename $0` [-hvm] [-d <device>]\n
-h|--help:
\tDisplays this help.
-v|--version
\tDisplays the current version of this script.
-d|--device
\tSets the name of the device to which Arch Linux 
\tshould be flashed to (/dev/sdXpY).
-m|--mmc
\tParameter should be used to flash Arch Linux 
\tto a Beaglebone Black eMMC rom.
-z|--zero
\tZero out the disk before creating partition map
\t(ignored when flashing eMMC rom).
EOF
)

MMC_REBOOT=$( cat <<EOF
\nYour Beaglebone eMMC is ready to boot Arch. Follow these instructions now:\n
\t* Enter the command 'poweroff' and hit enter\n
\t* Wait for the LED lights on the Beaglebone to stop blinking\n
\t* Remove power (5v or USB) and micro SD card\n
\t* Reapply power (do not hold down the user button)
EOF
)

# Path to this script file
SCRIPT_PATH="`dirname \"$0\"`"

# All users with $UID 0 have root privileges.
ROOT_UID=0

# Just one single user is called root.
ROOT_NAME="root"

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

function yesno()
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

function cleanUp() 
{
  echo "Cleaning up ..."
  rm -r /tmp/bone
}

# Check if user has root privileges.
if [[ $EUID -ne $ROOT_UID ]]; then
   error "This script must be run as root!"
fi

# Check if user is root and does not use sudoer privileges.
if [[ "${SUDO_USER:-$(whoami)}" != "$ROOT_NAME" ]]; then
   error "This script must be run as root, not as sudo user!"
fi

# Setup script vars.
devices=$(cat /proc/partitions|awk '/^ / {print "/dev/"$4}')
device=""
mmc=0
zero=0
bootloader=""
rootfs=""
bootlabel="boot"
rootlabel="rootfs"

# Fetch command line options.
while [[ "$1" ]]
do
   case "$1" in
      --help|-h)
         info "$USAGE"
         ;;
      --version|-v)
         info "`basename $0` version 1.0"
         ;;
      --device|-d)
         shift
         device=$1
         
         if [[ ! "$device" ]]; then 
            error "Missing device name!\n\n$USAGE"
         fi

         device=$(tr '[:upper:]' '[:lower:]' <<< $device)
         
         if [[ ! -b $device ]]; then
            error "Device $device is not a block device!\n\n" \
              "\rThe following devices are available:\n" \
              "\r$devices\n"
         fi
         
         shift
         ;;
      --mmc|-m)
         mmc=1
         shift
         ;;
      --zero|-z)
         zero=1
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
   error "Missing device name!\n\n$USAGE"
fi

if ! command -v fdisk >/dev/null 2>&1 ; then
   error "fdisk required, but not installed. Aborting."
fi

if ! yesno --default no "This will destroy all existing data. Are you sure you want to wipe $device (default no) ? "; then
   info "Aborting."
fi

# Unmount all partitions in /dev/sdXpY.
for partition in $(fdisk -l $device|awk '/^\/dev\// {print $1}')
do
  if [[ $(mount | grep $partition) != "" ]]; then
     echo "Unmounting partition ${device}p${partition} ..."
     umount "${partition}"
  fi
done

# Make eMMC partition labels distinct
if [[ $mmc -eq 1 ]]; then
  bootlabel="mmcboot"
  rootlabel="mmcrootfs"
fi

# Create a temporary directory within /tmp.
mkdir -p /tmp/bone

# Reformat disk if the destination is not eMMC (which should be formatted).
if [[ $mmc -ne 1 ]]; then
  # Zero out the disk. Because of how NAND works, it's better to write a bunch
  # of 1's instead of 0's to wipe the disk.
  if [[ $zero -eq 1 ]]; then
    echo "\"Zeroing\" the entire disk ..."
    # dd if=/dev/zero of=$device
    # tr '\000' '\377' < /dev/zero > $device
    tr "\000" "\377" < /dev/zero | dd bs=16M of=$device
  else
    echo "\"Zeroing\" first 1M of the disk ..."
    # dd if=/dev/zero of=$device bs=1024 count=1024
    tr "\000" "\377" < /dev/zero | dd bs=1024 count=1024 of=$device
  fi

  echo "Partitioning ${device} ..."
  fdisk $device << EOF
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
fi

# Grab the names of the partitions we need.
part1=$(fdisk -l $device|grep -m 1 W95|awk '/^\/dev\// {print $1}')
part2=$(fdisk -l $device|grep -m 1 Linux|awk '/^\/dev\// {print $1}')

# Create the fat16 filesystem at the first partition ...
echo "Creating fat16 boot partition filesystem ..."
mkfs.vfat -F 16 -n "$bootlabel" $part1
sleep 1

# ... and the ext4 filesystem at the second partition.
echo "Creating ext4 root partition filesystem ..."
mkfs.ext4 -L "$rootlabel" $part2
sleep 1

# Print out the partition table.
fdisk -l $device

# Find or download the bootloader tarball
echo "Looking for a bootloader tarball ..."

# Look for a bootloader archive in the same directory as the script
bootloader="${SCRIPT_PATH}/BeagleBone-bootloader.tar.gz"

if [ ! -f $bootloader ]; then
  # Download the arch-beaglebone bootloader tarball
  echo "Downloading bootloader ..."
  wget http://archlinuxarm.org/os/omap/BeagleBone-bootloader.tar.gz --directory-prefix=/tmp/bone
  sleep 1

  bootloader="/tmp/bone/BeagleBone-bootloader.tar.gz"
fi

echo "Using bootloader tarball ${bootloader}"

# Find or download the rootfs tarball
echo "Looking for a root filesystem tarball ..."

# Look for a rootfs archive in the same directory as the script
rootfs="${SCRIPT_PATH}/ArchLinuxARM-am33x-latest.tar.gz"

if [ ! -f $rootfs ]; then
  # Download the latest arch root filesystem tarball
  echo "Downloading latest root filesystem ..."
  wget http://archlinuxarm.org/os/ArchLinuxARM-am33x-latest.tar.gz --directory-prefix=/tmp/bone
  sleep 1
  
  rootfs="/tmp/bone/ArchLinuxARM-am33x-latest.tar.gz"
fi

echo "Using root filesystem tarball ${rootfs}"

# ... create new directories to mount "boot" and "rootfs", ...
mkdir /tmp/bone/{boot,root}

# ... mount the partitions, ...
mount $part1 /tmp/bone/boot
mount $part2 /tmp/bone/root

# ... extract the tarballs to the disk partitions, ...
echo "Extracting files to disk ..."
tar -xvf $bootloader --no-same-owner -C /tmp/bone/boot
tar -xf $rootfs -C /tmp/bone/root

# ... copy the boot image to the boot partition, ...
echo "Copying Boot Image ..."
cp /tmp/bone/root/boot/zImage /tmp/bone/boot

# ... make sure the write buffer has been commited to disk ...
echo "Synching ..."
sync

# ... and then unmount the partitions.
umount /tmp/bone/boot
umount /tmp/bone/root

cleanUp

echo "Done!"

# Make eMMC partition labels distinct
if [[ $mmc -eq 1 ]]; then
  echo "$MMC_REBOOT"
fi
