#!/bin/bash
# ============================================================
#  RHEL LVM Storage Management Script
#  Author  : Your Name
#  Version : 1.0
#  Desc    : Create and manage Physical Volumes, Volume Groups,
#            Logical Volumes, extend/reduce LVM, setup swap,
#            and mount persistently via /etc/fstab on RHEL
# ============================================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Log file ----------
LOGFILE="/var/log/lvm_management.log"

# ---------- Must run as root ----------
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root (sudo).${NC}"
  exit 1
fi

# ---------- Check if lvm2 is installed ----------
if ! command -v lvm &>/dev/null; then
  echo -e "${YELLOW}[WARN] lvm2 not found. Installing...${NC}"
  dnf install lvm2 -y &>/dev/null
  echo -e "${GREEN}[OK] lvm2 installed.${NC}"
fi

# ---------- Logging function ----------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
  echo -e "$1"
}

# ============================================================
#  FUNCTION: Show current LVM status (overview)
# ============================================================
show_lvm_status() {
  echo -e "\n${CYAN}============================================${NC}"
  echo -e "${CYAN}          CURRENT LVM STATUS                ${NC}"
  echo -e "${CYAN}============================================${NC}"

  echo -e "\n${BOLD}--- Physical Volumes (PV) ---${NC}"
  pvs 2>/dev/null || echo "No Physical Volumes found."

  echo -e "\n${BOLD}--- Volume Groups (VG) ---${NC}"
  vgs 2>/dev/null || echo "No Volume Groups found."

  echo -e "\n${BOLD}--- Logical Volumes (LV) ---${NC}"
  lvs 2>/dev/null || echo "No Logical Volumes found."

  echo -e "\n${BOLD}--- Disk & Partition Info ---${NC}"
  lsblk

  echo -e "\n${BOLD}--- Mounted Filesystems ---${NC}"
  df -hT | grep -v tmpfs
}

# ============================================================
#  FUNCTION: Create Physical Volume (PV)
# ============================================================
create_pv() {
  echo -e "\n${CYAN}=== CREATE PHYSICAL VOLUME (PV) ===${NC}"

  echo -e "${YELLOW}Available block devices:${NC}"
  lsblk -d -o NAME,SIZE,TYPE | grep -v loop

  read -rp "Enter device to initialize as PV (e.g. /dev/sdb): " DEVICE

  # Validate device exists
  if [[ ! -b "$DEVICE" ]]; then
    log "${RED}[ERROR] Device '$DEVICE' not found or not a block device.${NC}"
    return
  fi

  # Warn user
  echo -e "${RED}[WARNING] This will DESTROY all data on '$DEVICE'. Are you sure? (yes/no):${NC}"
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    return
  fi

  pvcreate "$DEVICE"
  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Physical Volume created on '$DEVICE'.${NC}"
    pvs "$DEVICE"
  else
    log "${RED}[ERROR] Failed to create Physical Volume on '$DEVICE'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Create Volume Group (VG)
# ============================================================
create_vg() {
  echo -e "\n${CYAN}=== CREATE VOLUME GROUP (VG) ===${NC}"

  echo -e "${YELLOW}Available Physical Volumes:${NC}"
  pvs 2>/dev/null || echo "No PVs found. Create a PV first."

  read -rp "Enter Volume Group name (e.g. vg_data): " VGNAME
  read -rp "Enter PV device(s) to include (space-separated, e.g. /dev/sdb /dev/sdc): " PV_DEVICES

  vgcreate "$VGNAME" $PV_DEVICES
  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Volume Group '$VGNAME' created using: $PV_DEVICES${NC}"
    vgs "$VGNAME"
  else
    log "${RED}[ERROR] Failed to create Volume Group '$VGNAME'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Create Logical Volume (LV)
# ============================================================
create_lv() {
  echo -e "\n${CYAN}=== CREATE LOGICAL VOLUME (LV) ===${NC}"

  echo -e "${YELLOW}Available Volume Groups:${NC}"
  vgs 2>/dev/null || echo "No VGs found. Create a VG first."

  read -rp "Enter Volume Group name to use: " VGNAME

  # Validate VG exists
  if ! vgs "$VGNAME" &>/dev/null; then
    log "${RED}[ERROR] Volume Group '$VGNAME' not found.${NC}"
    return
  fi

  read -rp "Enter Logical Volume name (e.g. lv_data): " LVNAME

  echo "Size options:"
  echo "  1. Fixed size (e.g. 5G, 500M)"
  echo "  2. Use % of VG free space (e.g. 50%FREE)"
  read -rp "Choose (1/2): " SIZE_OPT

  if [[ "$SIZE_OPT" == "1" ]]; then
    read -rp "Enter size (e.g. 5G or 500M): " LV_SIZE
    lvcreate -L "$LV_SIZE" -n "$LVNAME" "$VGNAME"
  else
    read -rp "Enter % of free space to use (e.g. 80 for 80%FREE): " LV_PERCENT
    lvcreate -l "${LV_PERCENT}%FREE" -n "$LVNAME" "$VGNAME"
  fi

  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Logical Volume '$LVNAME' created in VG '$VGNAME'.${NC}"

    # Format filesystem
    echo -e "\n${YELLOW}Choose filesystem to format:${NC}"
    echo "  1. ext4"
    echo "  2. xfs"
    echo "  3. Skip formatting"
    read -rp "Choose (1/2/3): " FS_OPT

    LV_PATH="/dev/$VGNAME/$LVNAME"

    case $FS_OPT in
      1)
        mkfs.ext4 "$LV_PATH"
        log "${GREEN}[OK] Formatted '$LV_PATH' as ext4.${NC}"
        ;;
      2)
        mkfs.xfs "$LV_PATH"
        log "${GREEN}[OK] Formatted '$LV_PATH' as xfs.${NC}"
        ;;
      3)
        echo -e "${YELLOW}Skipping formatting.${NC}"
        ;;
      *)
        echo -e "${RED}Invalid option. Skipping formatting.${NC}"
        ;;
    esac

    # Offer to mount
    read -rp "Mount this LV now? (y/n): " DO_MOUNT
    if [[ "$DO_MOUNT" =~ ^[Yy]$ ]]; then
      mount_lv_manual "$LV_PATH"
    fi

    lvs "$VGNAME"
  else
    log "${RED}[ERROR] Failed to create Logical Volume '$LVNAME'.${NC}"
  fi
}

# ============================================================
#  HELPER: Mount LV to a directory
# ============================================================
mount_lv_manual() {
  local LV_PATH="$1"
  read -rp "Enter mount point (e.g. /mnt/data): " MOUNT_POINT

  # Create mount point if it doesn't exist
  if [[ ! -d "$MOUNT_POINT" ]]; then
    mkdir -p "$MOUNT_POINT"
    log "${GREEN}[OK] Created mount point '$MOUNT_POINT'.${NC}"
  fi

  mount "$LV_PATH" "$MOUNT_POINT"
  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] '$LV_PATH' mounted at '$MOUNT_POINT'.${NC}"

    # Add to /etc/fstab for persistence
    read -rp "Add to /etc/fstab for persistent mount on reboot? (y/n): " ADD_FSTAB
    if [[ "$ADD_FSTAB" =~ ^[Yy]$ ]]; then
      add_to_fstab "$LV_PATH" "$MOUNT_POINT"
    fi
  else
    log "${RED}[ERROR] Failed to mount '$LV_PATH' at '$MOUNT_POINT'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Add entry to /etc/fstab
# ============================================================
add_to_fstab() {
  local LV_PATH="$1"
  local MOUNT_POINT="$2"

  # Detect filesystem type
  FS_TYPE=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null)
  FS_TYPE=${FS_TYPE:-ext4}

  # Get UUID for more reliable fstab entry
  UUID=$(blkid -o value -s UUID "$LV_PATH" 2>/dev/null)

  # Backup fstab first
  cp /etc/fstab /etc/fstab.bak.$(date '+%Y%m%d%H%M%S')
  log "${GREEN}[OK] /etc/fstab backed up.${NC}"

  if [[ -n "$UUID" ]]; then
    FSTAB_ENTRY="UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults  0  0"
  else
    FSTAB_ENTRY="$LV_PATH  $MOUNT_POINT  $FS_TYPE  defaults  0  0"
  fi

  # Check if entry already exists
  if grep -q "$MOUNT_POINT" /etc/fstab; then
    log "${YELLOW}[WARN] Mount point '$MOUNT_POINT' already exists in /etc/fstab. Skipping.${NC}"
    return
  fi

  echo "$FSTAB_ENTRY" >> /etc/fstab
  log "${GREEN}[OK] Added to /etc/fstab: $FSTAB_ENTRY${NC}"

  # Verify fstab is valid
  mount -a 2>/dev/null
  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] /etc/fstab verified — no errors.${NC}"
  else
    log "${RED}[ERROR] /etc/fstab may have errors. Check manually.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Extend a Logical Volume
# ============================================================
extend_lv() {
  echo -e "\n${CYAN}=== EXTEND LOGICAL VOLUME ===${NC}"

  echo -e "${YELLOW}Current Logical Volumes:${NC}"
  lvs

  read -rp "Enter full LV path to extend (e.g. /dev/vg_data/lv_data): " LV_PATH

  if [[ ! -e "$LV_PATH" ]]; then
    log "${RED}[ERROR] Logical Volume '$LV_PATH' not found.${NC}"
    return
  fi

  echo "Extend by:"
  echo "  1. Fixed size (e.g. +2G)"
  echo "  2. Use all remaining free space"
  read -rp "Choose (1/2): " EXT_OPT

  if [[ "$EXT_OPT" == "1" ]]; then
    read -rp "Enter size to add (e.g. 2G or 500M): " EXT_SIZE
    lvextend -L +"$EXT_SIZE" "$LV_PATH"
  else
    lvextend -l +100%FREE "$LV_PATH"
  fi

  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Logical Volume '$LV_PATH' extended.${NC}"

    # Resize filesystem
    FS_TYPE=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null)
    echo -e "${YELLOW}Detected filesystem: $FS_TYPE${NC}"

    if [[ "$FS_TYPE" == "ext4" ]]; then
      resize2fs "$LV_PATH"
      log "${GREEN}[OK] ext4 filesystem resized on '$LV_PATH'.${NC}"
    elif [[ "$FS_TYPE" == "xfs" ]]; then
      MOUNT_PT=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null)
      if [[ -n "$MOUNT_PT" ]]; then
        xfs_growfs "$MOUNT_PT"
        log "${GREEN}[OK] xfs filesystem grown at '$MOUNT_PT'.${NC}"
      else
        log "${YELLOW}[WARN] XFS LV not mounted. Mount it first, then run xfs_growfs.${NC}"
      fi
    fi

    lvs "$LV_PATH"
  else
    log "${RED}[ERROR] Failed to extend '$LV_PATH'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Reduce a Logical Volume (ext4 only — xfs cannot shrink)
# ============================================================
reduce_lv() {
  echo -e "\n${CYAN}=== REDUCE LOGICAL VOLUME ===${NC}"
  echo -e "${RED}[WARNING] Reducing a Logical Volume can cause DATA LOSS if done incorrectly.${NC}"
  echo -e "${RED}          Only ext4 supports shrinking. XFS CANNOT be shrunk.${NC}"

  echo -e "${YELLOW}Current Logical Volumes:${NC}"
  lvs

  read -rp "Enter full LV path to reduce (e.g. /dev/vg_data/lv_data): " LV_PATH

  if [[ ! -e "$LV_PATH" ]]; then
    log "${RED}[ERROR] Logical Volume '$LV_PATH' not found.${NC}"
    return
  fi

  FS_TYPE=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null)
  if [[ "$FS_TYPE" == "xfs" ]]; then
    log "${RED}[ERROR] XFS filesystem cannot be shrunk. Operation aborted.${NC}"
    return
  fi

  read -rp "Enter new size to reduce TO (e.g. 3G): " NEW_SIZE

  echo -e "${RED}Are you sure you want to reduce '$LV_PATH' to $NEW_SIZE? (yes/no):${NC}"
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    return
  fi

  # Unmount first
  MOUNT_PT=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null)
  if [[ -n "$MOUNT_PT" ]]; then
    umount "$LV_PATH"
    log "${GREEN}[OK] Unmounted '$LV_PATH' from '$MOUNT_PT'.${NC}"
  fi

  # Check and resize filesystem first
  e2fsck -f "$LV_PATH"
  resize2fs "$LV_PATH" "$NEW_SIZE"

  # Then reduce the LV
  lvreduce -L "$NEW_SIZE" "$LV_PATH"

  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Logical Volume '$LV_PATH' reduced to $NEW_SIZE.${NC}"

    # Remount if it was mounted
    if [[ -n "$MOUNT_PT" ]]; then
      mount "$LV_PATH" "$MOUNT_PT"
      log "${GREEN}[OK] Remounted '$LV_PATH' at '$MOUNT_PT'.${NC}"
    fi
    lvs "$LV_PATH"
  else
    log "${RED}[ERROR] Failed to reduce '$LV_PATH'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Setup Swap on LV
# ============================================================
setup_swap() {
  echo -e "\n${CYAN}=== SETUP SWAP SPACE ON LV ===${NC}"

  echo -e "${YELLOW}Existing Logical Volumes:${NC}"
  lvs

  echo ""
  echo "  1. Create a new LV for swap"
  echo "  2. Use an existing LV as swap"
  read -rp "Choose (1/2): " SWAP_OPT

  if [[ "$SWAP_OPT" == "1" ]]; then
    echo -e "${YELLOW}Available Volume Groups:${NC}"
    vgs
    read -rp "Enter VG name: " VGNAME
    read -rp "Enter swap LV name (e.g. lv_swap): " LVNAME
    read -rp "Enter swap size (e.g. 2G): " SWAP_SIZE

    lvcreate -L "$SWAP_SIZE" -n "$LVNAME" "$VGNAME"
    if [[ $? -ne 0 ]]; then
      log "${RED}[ERROR] Failed to create swap LV.${NC}"
      return
    fi
    LV_PATH="/dev/$VGNAME/$LVNAME"
  else
    read -rp "Enter full LV path to use as swap (e.g. /dev/vg_data/lv_swap): " LV_PATH
    if [[ ! -e "$LV_PATH" ]]; then
      log "${RED}[ERROR] LV '$LV_PATH' not found.${NC}"
      return
    fi
  fi

  # Format as swap
  mkswap "$LV_PATH"
  swapon "$LV_PATH"

  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] Swap enabled on '$LV_PATH'.${NC}"
    echo -e "${GREEN}Current swap usage:${NC}"
    swapon --show
    free -h

    # Add to fstab
    read -rp "Add swap to /etc/fstab for persistence? (y/n): " ADD_SWAP_FSTAB
    if [[ "$ADD_SWAP_FSTAB" =~ ^[Yy]$ ]]; then
      UUID=$(blkid -o value -s UUID "$LV_PATH" 2>/dev/null)
      cp /etc/fstab /etc/fstab.bak.$(date '+%Y%m%d%H%M%S')

      if [[ -n "$UUID" ]]; then
        echo "UUID=$UUID  swap  swap  defaults  0  0" >> /etc/fstab
      else
        echo "$LV_PATH  swap  swap  defaults  0  0" >> /etc/fstab
      fi
      log "${GREEN}[OK] Swap added to /etc/fstab.${NC}"
    fi
  else
    log "${RED}[ERROR] Failed to enable swap on '$LV_PATH'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: Remove LV, VG, or PV
# ============================================================
remove_lvm_component() {
  echo -e "\n${CYAN}=== REMOVE LVM COMPONENT ===${NC}"
  echo "  1. Remove Logical Volume (LV)"
  echo "  2. Remove Volume Group (VG)"
  echo "  3. Remove Physical Volume (PV)"
  read -rp "Choose (1/2/3): " RM_OPT

  case $RM_OPT in
    1)
      lvs
      read -rp "Enter full LV path to remove (e.g. /dev/vg_data/lv_data): " LV_PATH
      echo -e "${RED}WARNING: This will DELETE '$LV_PATH' and ALL its data! (yes/no):${NC}"
      read -r CONFIRM
      if [[ "$CONFIRM" != "yes" ]]; then echo -e "${YELLOW}Cancelled.${NC}"; return; fi

      # Unmount if mounted
      MOUNT_PT=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null)
      [[ -n "$MOUNT_PT" ]] && umount "$LV_PATH"

      lvremove -f "$LV_PATH"
      [[ $? -eq 0 ]] && log "${GREEN}[OK] LV '$LV_PATH' removed.${NC}" || log "${RED}[ERROR] Failed.${NC}"
      ;;
    2)
      vgs
      read -rp "Enter VG name to remove: " VGNAME
      echo -e "${RED}WARNING: This will DELETE VG '$VGNAME' and ALL LVs inside! (yes/no):${NC}"
      read -r CONFIRM
      if [[ "$CONFIRM" != "yes" ]]; then echo -e "${YELLOW}Cancelled.${NC}"; return; fi

      vgremove -f "$VGNAME"
      [[ $? -eq 0 ]] && log "${GREEN}[OK] VG '$VGNAME' removed.${NC}" || log "${RED}[ERROR] Failed.${NC}"
      ;;
    3)
      pvs
      read -rp "Enter PV device to remove (e.g. /dev/sdb): " DEVICE
      pvremove "$DEVICE"
      [[ $? -eq 0 ]] && log "${GREEN}[OK] PV '$DEVICE' removed.${NC}" || log "${RED}[ERROR] Failed.${NC}"
      ;;
    *)
      echo -e "${RED}Invalid option.${NC}"
      ;;
  esac
}

# ============================================================
#  FUNCTION: Add new PV to existing VG (extend VG)
# ============================================================
extend_vg() {
  echo -e "\n${CYAN}=== EXTEND VOLUME GROUP (Add new disk) ===${NC}"

  echo -e "${YELLOW}Current Volume Groups:${NC}"
  vgs

  read -rp "Enter VG name to extend: " VGNAME

  if ! vgs "$VGNAME" &>/dev/null; then
    log "${RED}[ERROR] VG '$VGNAME' not found.${NC}"
    return
  fi

  echo -e "${YELLOW}Available block devices:${NC}"
  lsblk -d -o NAME,SIZE,TYPE | grep -v loop

  read -rp "Enter new device to add (e.g. /dev/sdc): " NEW_DEVICE

  if [[ ! -b "$NEW_DEVICE" ]]; then
    log "${RED}[ERROR] Device '$NEW_DEVICE' not found.${NC}"
    return
  fi

  # Initialize as PV first
  pvcreate "$NEW_DEVICE"
  vgextend "$VGNAME" "$NEW_DEVICE"

  if [[ $? -eq 0 ]]; then
    log "${GREEN}[OK] VG '$VGNAME' extended with '$NEW_DEVICE'.${NC}"
    vgs "$VGNAME"
  else
    log "${RED}[ERROR] Failed to extend VG '$VGNAME'.${NC}"
  fi
}

# ============================================================
#  FUNCTION: View fstab
# ============================================================
view_fstab() {
  echo -e "\n${CYAN}=== /etc/fstab CONTENTS ===${NC}"
  echo -e "${YELLOW}Format: device  mountpoint  fstype  options  dump  pass${NC}\n"
  cat -n /etc/fstab
}

# ============================================================
#  MAIN MENU
# ============================================================
main_menu() {
  while true; do
    echo -e "\n${CYAN}============================================${NC}"
    echo -e "${CYAN}     RHEL LVM Storage Management Script     ${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo "  1.  Show LVM Status (Overview)"
    echo "  2.  Create Physical Volume (PV)"
    echo "  3.  Create Volume Group (VG)"
    echo "  4.  Create Logical Volume (LV) + Format + Mount"
    echo "  5.  Extend Logical Volume"
    echo "  6.  Reduce Logical Volume (ext4 only)"
    echo "  7.  Setup Swap Space on LV"
    echo "  8.  Extend Volume Group (add new disk)"
    echo "  9.  Remove LV / VG / PV"
    echo "  10. View /etc/fstab"
    echo "  11. Exit"
    echo -e "${CYAN}============================================${NC}"
    read -rp "Choose an option (1-11): " CHOICE

    case $CHOICE in
      1)  show_lvm_status ;;
      2)  create_pv ;;
      3)  create_vg ;;
      4)  create_lv ;;
      5)  extend_lv ;;
      6)  reduce_lv ;;
      7)  setup_swap ;;
      8)  extend_vg ;;
      9)  remove_lvm_component ;;
      10) view_fstab ;;
      11)
        echo -e "${GREEN}Exiting. Logs saved to $LOGFILE${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option. Please choose 1-11.${NC}"
        ;;
    esac
  done
}

# ---------- Entry Point ----------
main_menu
