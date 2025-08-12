#!/usr/bin/env bash
# helper script to setup /dev/zram1 device,
# create ext4 filesystem,
# mount as ramdisk and restore kvm image state
#
# assumes zram0 is already in use (refcnt=2)
# 2023 phk

#set -x

# ansi
OK="\e[1;38;5;36m"
ERR="\e[1;31m"
RST="\e[0m"

# check for root privileges
[[ $EUID -ne 0 ]] && echo -e "$ERR[ERR]$RST must be run as root, exiting" && exit 1

# vars
SIZE="36G"
DEV=0
FS=0
MNT=0
IMG=0

help() {
echo -e "
 interactive zram ramdisk helper script | 2023 phk

 usage: $OK${0##*/}$RST [option]
        -r    unmount and remove zram1 device
        -h    this help
"
}

case "$1" in
  -r)
    [[ ! -e /dev/zram1 ]] && echo -e "$OK[INF]$RST no /dev/zram1 device, exit" && exit 1
    echo -e "$OK[INF]$RST save zram kvm image state\n"
    read -n1 -sp "      save ramdisk changes to /mnt/images/? (Y)" Yy
    echo ""
    case $Yy in
      Y|y)
        if rsync -a --progress /mnt/zram/zram.qcow2 /mnt/images/ 2>/dev/null; then
          IMG=0
          echo -e "\n$OK[INF]$RST kvm image state saved to /mnt/images/zram.qcow2\n"
        else
          echo -e "\n$ERR[ERR]$RST kvm image state could not be saved\n"
        fi
      ;;
    esac
    echo -e "$OK[INF]$RST trying to unmount and remove device"
    if [[ $(mount | grep zram1) ]]; then
      echo -ne "$OK[INF]$RST unmounting"
      echo -ne " "; for i in $(seq 1 5); do echo -ne '*'; sleep 0.5; done
      if umount /mnt/zram; then
        echo -ne "\r$OK[INF]$RST /mnt/zram unmounted\n"
        echo -ne "$OK[INF]$RST removing device"
        # hot-remove device
        echo 1 > /sys/class/zram-control/hot_remove
        echo -ne " "; for i in $(seq 1 5); do echo -ne '*'; sleep 0.5; done
        echo -e "\r$OK[INF]$RST device removed        \n"
        dmesg -T | grep zram1 | tail -2 | awk '{print "      " $0}'; sleep 2
        echo ""
        exit 0
      else
        echo -e "$ERR[ERR]$RST failed to unmount\n"
        exit 1
      fi
    else
      echo -e "$ERR[ERR]$RST not mounted, exit"
      exit 1
    fi
  ;;
  -s)
    echo -e "\n$OK[INF]$RST /dev/zram status\n"
    zramctl | sed -e 's/^/      /g'
    echo ""
    [[ ! $(zramctl | grep zram1 &>/dev/null) ]] && echo -e "$ERR[WRN]$RST /dev/zram1 device not found!"
    exit 0
  ;;
  -h)
    help
    exit 0
  ;;
esac

echo -e "$OK[INF]$RST checking zram conditions"; sleep 2

# check if module is loaded
[[ ! $(lsmod | grep zram) ]] && echo -e "$ERR[ERR]$RST module not loaded, exit 1" && exit 1
echo -e "\n$OK[INF]$RST module loaded"; sleep 1

# check if module is loaded w/ correct num_devices (workaround for missing parameters section in module sysfs)
# module zram doesn't provide sysfs parameters, only way to check is refcnt, which is num_active_devices + 1 (2 if /dev/zram0 exists and is used by swap)
[[ $(cat /sys/module/zram/refcnt) -ne 2 ]] && echo -e "\n$ERR[ERR]$RST refcnt !=2, exit 1" && exit 1
echo -e "\n$OK[INF]$RST module refcnt=2"; sleep 1

# trigger creation of zram1 device by issuing a READ operation on /sys/class/zram-control/hot_add
cat /sys/class/zram-control/hot_add &>/dev/null; sleep 1
echo ""
dmesg -T | grep zram1 | tail -1 | awk '{print "      " $0}'; sleep 2
echo ""

# check if device is present, should list DISKSIZE 0B
zramctl /dev/zram1 | awk '{print "      " $0}'; sleep 2

echo -e "\n$OK[INF]$RST device_node /dev/zram1 created\n"; sleep 1

# setup size
if zramctl /dev/zram1 --size="$SIZE"; then
  sleep 1
  DEV=1
  dmesg -T | grep zram1 | tail -1 | awk '{print "      " $0}'; sleep 2
  # verify if device is present, should list DISKSIZE 32G
  echo -e "\n$OK[INF]$RST size $SIZE successfully set\n"
  zramctl /dev/zram1 | grep --color=auto -B1 "$SIZE" | awk '{print "      " $0}'; sleep 1
  echo ""
fi

# fallback check
[[ ! $DEV -eq 1 ]] && echo -e "$ERR[ERR]$RST no suitable device found\n" && exit 1

# create filesystem
read -n1 -sp "      create ext4 fs on /dev/zram1? (Y)" Yy
echo -e "\n"
case $Yy in
  Y|y)
    if mkfs.ext4 -m0 /dev/zram1 | awk '{print "      " $0}'; then
      FS=1
      echo -e "$OK[INF]$RST filesystem created\n"
    else
      echo -e "$ERR[ERR]$RST creating filesystem failed\n"
    fi
  ;;
  *)
    echo -e "$OK[INF]$RST skipping filesystem\n"
  ;;
esac

if [[ $FS -eq 0 ]]; then
  echo -e "$OK[INF]$RST skipping mount\n"
  # hot-remove /dev/zram1 device (requires root context)
  echo ""
  read -n1 -sp "      hot-remove /dev/zram1 device? (Y)" Yy
  echo -e "$OK[INF]$RST to hot-remove /dev/zram1 device,\n$OK[INF]$RST run 'echo 1 > /sys/class/zram-control/hot_remove' as root"
  case $Yy in
    Y|y)
      echo 1 > /sys/class/zram-control/hot_remove
      echo ""
      dmesg -T | grep zram1 | tail -2 | awk '{print "      " $0}'; sleep 2
      DEV=0
      FS=0
      MNT=0
      echo -e "\n$OK[INF]$RST device removed\n"
      exit 0
    ;;
    *)
      echo -e "$OK[INF]$RST leaving device /dev/zram1 active\n"
    ;;
  esac
else
  read -n1 -sp "      mount /dev/zram1 device? (Y)" Yy
  echo ""
  case $Yy in
    Y|y)
      echo -e "\n$OK[INF]$RST mounting /dev/zram1 on /mnt/zram\n"
      if mount /dev/zram1 /mnt/zram; then
        MNT=1
        sleep 1
        mount | grep '/dev/zram1' | awk '{print "      " $0}'
        echo -e "\n$OK[INF]$RST mounted\n"
        dmesg -T | grep zram1 | tail -1 | awk '{print "      " $0}'; sleep 2
        echo ""
      fi
    ;;
    *)
      echo -e "$ERR[ERR]$RST not mounted\n"
    ;;
  esac
fi

if [[ $IMG -eq 0 ]] ; then
  if [[ $DEV -eq 1 && $FS -eq 1 && $MNT -eq 1 ]]; then
    echo -e "$OK[INF]$RST restore kvm image\n"
    read -n1 -sp "      restore kvm image on /mnt/zram/? (Y)" Yy
    echo ""
    case $Yy in
      Y|y)
        if mount | grep -q /mnt/images; then
          if rsync -a --progress /mnt/images/zram.qcow2 /mnt/zram/; then
            IMG=1
            echo -e "\n$OK[INF]$RST kvm image restored to /mnt/zram/zram.qcow2\n"
          else
            echo -e "\n$ERR[ERR]$RST kvm image could not be restored\n"
          fi
        else
          echo -e "\n$ERR[ERR]$RST image repository not mounted\n"
          exit 1
        fi
      ;;
      *)
        echo -e "\n$OK[INF]$RST leaving device /dev/zram1 active\n"
      ;;
    esac
  fi
else
  echo -e "\n$OK[INF]$RST kvm image already restored\n"
  exit 0
fi
