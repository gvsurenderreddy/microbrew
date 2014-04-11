#!/bin/sh

BACKUP_DIR="/mnt/cache/Backup/$(hostname)"

if [ $# -lt 1 ]; then
  path="${BACKUP_DIR}/$(date +%F)"
  echo "No destination provided. Using: $path" >&2
elif [ $# -gt 1 ]; then
  echo "Too many arguments. Usage: $0 destination" >&2
  exit 1
elif [ -d "$1" ]; then
  echo "Path already exists: $1" >&2
  echo "Use '--merge' to update an existing backup (as soon as it's implemented)"
  exit 1
else
  case "$1" in
    "/mnt") ;;
    "/mnt/"*) ;;
    "/media") ;;
    "/media/"*) ;;
    *) echo "Destination not allowed." >&2
       exit 1
       ;;
  esac
  path="$1" 
fi

mkdir -p "$path"

if [ ! -w "$path" ]; then
  echo "Directory not writable: $path" >&2
  exit 1
fi


START=$(date +%s)

echo "rsyncing rootfs..."
rsync -aAXv /* $path/rootfs --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/srv/*,/media/*,/lost+found,/var/lib/pacman/sync/*,/var/log/journal/*}

echo "saving list of installed packages..."
pacman -Qqne > $path/pkg.list

echo "backing up pacman db..."
tar -cjf $path/pacman-local.tar.bz2 /var/lib/pacman/local

FINISH=$(date +%s)
echo "total time: $(( ($FINISH-$START) / 60 )) minutes, $(( ($FINISH-$START) % 60 )) seconds" | tee $path/"Backup from $(date '+%A, %d %B %Y, %T')"

