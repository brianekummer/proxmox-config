#!/bin/bash

# -----------------------------------------------------------------------------
# Proxmox Backup and Sync Script
#
# Usage:
#   ./backup-and-sync-to-gdrive.sh [--dry-run] <targets>
#
#   <targets> is a comma-separated list of container/VM IDs and/or the keyword:
#     - Specific container/VM id's: e.g. 101,105
#     - Special values:
#         all   - backup all known containers/VMs and PVE config
#         pve   - backup only Proxmox system configuration
#   --dry-run: optional flag to simulate actions without performing them
#
# This script performs the following:
#   ✓ Stops necessary containers before backup, and restarts them afterward
#   ✓ Backs up specified containers, VMs, and/or Proxmox configuration
#   ✓ Manages NAS-related dependencies:
#       - Dependent containers are stopped before the NAS container
#       - NAS container is backed up to a local folder, then restarted before 
#         moving the backup to $BACKUP_DIR
#       - Dependent containers are restarted afterward
#   ✓ Prunes local backups, keeping only the 3 most recent per container/VM/PVE
#   ✓ Uses symbolic links in $TMP_DIR to isolate the most recent backup of each
#   ✓ Syncs that temporary folder to Google Drive using rclone (1 backup per target)
#
# Notes:
# - The symbolic links make syncing predictable and prevent duplication
# - The script assumes rclone is configured with a remote named "gdrive"
# - Backup files are stored in $BACKUP_DIR (NAS-mounted)
# - Proxmox config backups include network, hostname, SSH, NUT, rclone config, etc.
#
# Dependencies:
#   - Proxmox `vzdump` utility
#   - `rclone` for syncing to Google Drive
#   - `pct` for managing containers
#
# -----------------------------------------------------------------------------
set -e

# === CONFIGURATION ===
BACKUP_DIR="/mnt/pve/nas-proxmox-backups/dump"
REMOTE_NAME="gdrive:"
REMOTE_DIR="/Proxmox Server Backups"
TMP_DIR="/tmp/latest-backups"
DRY_RUN=false

# Define container/VM relationships
NAS_CTID=103
NAS_DEPENDENT_CTS=(101 102 105)
NAS_INDEPENDENT_CTS=(104)
NAS_INDEPENDENT_VMS=(100)

# Files or directories to include in backup of PVE config
PVE_BACKUP_LIST=(
  "/mnt/pve/nas/Private/Proxmox-Backups/backup-and-sync-to-gdrive.sh"
  "/etc/pve"
  "/etc/network/interfaces"
  "/etc/hostname"
  "/etc/hosts"
  "/etc/fstab"
  "/etc/resolv.conf"
  "/etc/nut"
  "/etc/postfix"
  "/root/.config/rclone/rclone.conf"
)



# === UTILITY FUNCTIONS ===
log() {
  printf "[$(date +"%Y-%m-%d %H:%M:%S")] $1\n"
}

die() {
  log "ERROR: $1"
  exit 1
}

print_usage() {
  echo ""
  echo "Backup Proxmox configuration, containers, and VMs and sync them to Google Drive"
  echo ""
  echo "Usage: $0 [--dry-run] <targets>"
  echo "  --dry-run   Show what would happen without performing any actions"
  echo "  <targets>   Comma-separated list of LXC/VM id's, 'pve' for Proxmox config, or 'all'"
  echo "              Examples:"
  echo "                101,103"
  echo "                100,101,pve"
  echo "                pve"
  echo "                all"
  echo ""
  echo "If backing up the NAS container (CT $NAS_CTID), this script will stop it and all"
  echo "of its dependent containers, back up the requested containers, and then restart them"
  echo "afterwards."
  echo ""
  exit 1
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    print_usage
  fi

  for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
      DRY_RUN=true
    elif [[ "$arg" == "--help" ]]; then
      print_usage
    else
      TARGET_STRING="$arg"
    fi
  done

  [[ -z "$TARGET_STRING" ]] && print_usage

  IFS="," read -ra TARGETS <<< "$TARGET_STRING"
}

should_backup() {
  local id="$1"
  [[ " ${TARGETS[*]} " == *" ${id} "* || " ${TARGETS[*]} " == *" all "* ]]
}

get_latest_file() {
  # Get the latest file matching the given pattern in the backup directory
  #   - Example patterns: "vzdump-lxc-103*.zst"
  #   - This is being done because the filename consistently has the datetime
  #     embedded in it, so we can use that to determine the latest backup.
  #     This has been more consistent than using the file modification time.
  local pattern="$1"
  ls -1 $BACKUP_DIR/$pattern 2>/dev/null | sort -r | head -n 1
}




# === CONTAINER LIFECYCLE HELPER FUNCTIONS ===
stop_container() {
  local id="$1"
  if $DRY_RUN; then
    log "DRY-RUN: Would stop container $id"
  else
    log "Stopping container $id..."
    pct shutdown "$id" --force
    while container_is_running "$id"; do sleep 3; done
    log "  Container $id stopped"
  fi
}

start_container() {
  local id="$1"
  if $DRY_RUN; then
    log "DRY-RUN: Would start container $id"
  else
    log "Starting container $id..."
    pct start "$id"
    log "  Container $id started"
  fi
}

container_is_running() {
  # This avoids assuming container status based on exit codes and works even in race conditions
  local id="$1"
  pct status "$id" | grep -q "running"
}



# === BACKUP FUNCTIONS ===
backup_and_restart_nas_container() {
  # The NAS container is special because
  #   - It has dependent containers that need to be stopped before the NAS container 
  #     is shutdown for backup. These containers will be restarted by the "Containers"
  #     loop in the main logic.
  #   - Because $BACKUP_DIR is a mount point for the NAS container, when we shutdown 
  #     the NAS container, $BACKUP_DIR will be unavailable. So we must backup to a local
  #     temporary directory and then move the backup files to $BACKUP_DIR after the NAS
  #     container is restarted.
  local id="$1"
  log "Backing up NAS (container $id)..."

  if $DRY_RUN; then
    log "  DRY-RUN: Would backup container $id using vzdump, restart it, and copy the backup to $BACKUP_DIR"
    return
  fi

  # Determine temporary and final backup directories
  local tmp_dir="/var/tmp"
  local mount_point="$(dirname "$BACKUP_DIR")"

  # Run backup to local temp storage
  vzdump "$id" --mode stop --compress zstd --quiet 1 --dumpdir "$tmp_dir" || die "vzdump failed for container $id"

  log "  Starting NAS container $id before moving backup..."
  start_container "$id"

  # Give NAS container time to initialize services before checking mount status
  log "  Waiting for NAS mount point $mount_point to become available..."
  sleep 10

  local attempt=0
  local max_attempts=30
  while true; do
    # Check if NAS mount is active before trying to access the backup folder
    if mountpoint -q "$mount_point"; then
      log "  ✅  mountpoint is active — checking if $BACKUP_DIR is accessible..."
      if ls "$BACKUP_DIR" >/dev/null 2>&1; then
        log "  ✅  $BACKUP_DIR is accessible!"
        break
      else
        log "  ❌  $BACKUP_DIR still inaccessible (attempt $((attempt+1))/$max_attempts)"
      fi
    else
      log "  ❌  $mount_point not mounted yet (attempt $((attempt+1))/$max_attempts)"
    fi

    ((attempt++))
    ((attempt >= max_attempts)) && die "NAS storage did not come online after starting container $id"
    sleep 2
  done

  log "  Moving backup files for container $id from $tmp_dir to $BACKUP_DIR"
  mv "$tmp_dir/vzdump-lxc-${id}-"*.{tar.zst,log} "$BACKUP_DIR/" || die "Failed to move backup files for container $id"
  echo ""
}

backup_container() {
  local id="$1"

  if $DRY_RUN; then
    log "DRY-RUN: Would backup container $id with vzdump"
  else
    log "Backing up container $id..."
    vzdump "$id" --mode stop --compress zstd --quiet 1 --dumpdir "$BACKUP_DIR" || die "vzdump failed for container $id"
  fi
}

backup_vm() {
  local id="$1"
  if $DRY_RUN; then
    log "DRY-RUN: Would backup VM $id with vzdump"
  else
    log "Backing up VM $id..."
    vzdump "$id" --mode stop --compress zstd --quiet 1 --dumpdir "$BACKUP_DIR" || die "vzdump failed for VM $id"
  fi
}

backup_pve_config() {
  timestamp=$(date +%Y_%m_%d-%H_%M_%S)
  archive="proxmox-pve-${timestamp}.tar.zst"
  work_dir="/tmp/proxmox-backup-$timestamp"
  
  mkdir -p "$work_dir"

  for path in "${PVE_BACKUP_LIST[@]}"; do
    [ -e "$path" ] && cp --parents --recursive "$path" "$work_dir"
  done
  
  if $DRY_RUN; then
    # Setting archive to a dummy path when dry-running
    archive="$BACKUP_DIR/proxmox-pve-$(date '+%Y_%m_%d-%H_%M_%S').tar.zst"
    log "DRY-RUN: Would create Proxmox config backup archive: $(basename "$archive")"
  else
    (cd "$work_dir" && tar --zstd -cf "$BACKUP_DIR/$archive" .)
    rm -rf "$work_dir"
    log "Proxmox config backup created: $archive"
  fi
}



# === PRUNING AND SYNC FUNCTIONS ===
process_latest_backup() {
  # We assume one backup file per ID prefix — always link the latest only
  local prefix="$1"
  link_backup_and_log "$(get_latest_file "${prefix}*.zst")"
  prune_local_backups "$prefix"
}

link_backup_and_log() {
  local file="$1"
  [ -z "$file" ] && return

  if [ ! -f "$file" ]; then
    if $DRY_RUN; then
      log "DRY-RUN: Would link missing backup file: $file"
    else
      log "❌  ERROR: Backup file not found: $file"
    fi
    return
  fi

  # Always link the backup file (whether in dry-run or not)
  ln -sf "$file" "$TMP_DIR/"
  log "Linked backup file: $file"

  # Now derive the matching log file
  local base
  base=$(basename "$file" | sed -E 's/\.(tar|vma)\.zst$//')
  local log_file="$BACKUP_DIR/${base}.log"

  if [ -f "$log_file" ]; then
    ln -sf "$log_file" "$TMP_DIR/"
    log "Linked log file:    $log_file"
  else
    log "No matching log file found for $file — skipping log link"
  fi
}

prune_local_backups() {
  local prefix="$1"
  local keep=3

  log "Starting prune_local_backups with prefix $prefix"

  # Step 1: Prune .zst and their matching .log files
  local backup_files=()
  while IFS= read -r line; do
    backup_files+=("$line")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${prefix}*.zst" | sort -r)

  local count=${#backup_files[@]}
  if (( count <= keep )); then
    log "  Nothing to prune for $prefix (found $count, keeping $keep)"
  else
    for (( i = keep; i < count; i++ )); do
      local old_file="${backup_files[i]}"
      local log_file="${old_file%.zst}.log"

      log "  Pruning local: $old_file"
      if [[ "$DRY_RUN" == "true" ]]; then
        log "    [DRY RUN] Would delete: $old_file"
        log "    [DRY RUN] Would delete: $log_file"
      else
        rm -f "$old_file"
        [[ -f "$log_file" ]] && rm -f "$log_file"
      fi
    done
  fi

  # Step 2: Prune orphaned .log files (that don't have a matching .zst)
  if ! $DRY_RUN; then
    while IFS= read -r log_file; do
      local zst_file="${log_file%.log}.zst"
      if [[ ! -f "$zst_file" ]]; then
        log "  Deleting orphaned log: $log_file"
        rm -f "$log_file"
      fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${prefix}*.log")
  fi

  log "  Finished prune_local_backups with prefix $prefix"
  echo
}

sync_to_remote() {
  if ! $DRY_RUN; then
    log "Emptying Google Drive trash..."
    rclone cleanup $REMOTE_NAME
    sleep 30
  fi

  log "Syncing backups to Google Drive..."
  $DRY_RUN && dry="--dry-run" || dry=""

  # rclone flags used
  #   --copy-links               Follow symlinks in the source directory
  #   --local-no-check-updated   Skips checking modification timestamps on symlink targets,
  #                              necessary for reliable sync
  #   --progress                 Show progress during transfer
  #   --delete-during            Delete files from the destination while checking and uploading
  #                              files. Is considered the fastest option and uses the least 
  #                              memory. This is important to me because I don't have enough space
  #                              on my Google Drive to keep multiple backups of the largest 
  #                              containers and VMs until the unneeded files are deleted at 
  #                              the end of the sync. Sync's default behavior is --delete-after.
  #   --drive-use-trash=false    Permanently delete files instead of moving them to the trash
  #   --bwlimit 0:2.5M           Limit bandwidth to 2.5 MB/s, which is 50% of my current 
  #                              5 MB/s (40 Mbps) upload speed
  rclone sync "$TMP_DIR/" "$REMOTE_NAME$REMOTE_DIR" --copy-links $dry --local-no-check-updated --delete-during --drive-use-trash=false --progress --bwlimit 0:2.5M
}

verify_remote_sync() {
  if $DRY_RUN; then
    log "DRY-RUN: Skipping verification of remote sync"
    return
  fi

  log "Verifying that all files in $TMP_DIR exist on Google Drive..."

  local remote_files
  mapfile -t remote_files < <(rclone ls "$REMOTE_NAME$REMOTE_DIR" | awk '{print $2}')

  local missing_files=0

  for file in "$TMP_DIR"/*; do
    local filename
    filename=$(basename "$file")
    if [[ ! " ${remote_files[*]} " =~ " ${filename} " ]]; then
      log "  ❌  File missing from remote: $filename"
      ((missing_files++))
    fi
  done

  if ((missing_files > 0)); then
    log "❌  $missing_files file(s) were not found on Google Drive"
    return 1  # Failure
  else
    log "✅  All files successfully synced to Google Drive"
    return 0  # Success
  fi
}



# === MAIN LOGIC ===
parse_args "$@"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR"/*

echo ""
log "Starting backup...\n"

# NAS container Backup
if should_backup "$NAS_CTID"; then
  for ctid in "${NAS_DEPENDENT_CTS[@]}"; do
    if container_is_running "$ctid"; then
      stop_container "$ctid"
    fi
  done

  stop_container "$NAS_CTID"
  backup_and_restart_nas_container "$NAS_CTID"

  process_latest_backup "vzdump-lxc-${NAS_CTID}"
fi

# Containers
#
# Do the dependent containers first because, if we just did a NAS backup, those
# containers are still shut down, and we want to get those backed up and restarted
# before backing up the independent containers.
for ctid in "${NAS_DEPENDENT_CTS[@]}" "${NAS_INDEPENDENT_CTS[@]}"; do
  if should_backup "$ctid"; then
    backup_container "$ctid"
  fi
  if ! container_is_running "$ctid"; then
    start_container "$ctid"
  fi

  process_latest_backup "vzdump-lxc-${ctid}"
done

# VMs
for vmid in "${NAS_INDEPENDENT_VMS[@]}"; do
  if should_backup "$vmid"; then
    backup_vm "$vmid"
  fi
  process_latest_backup "vzdump-qemu-${vmid}"
done

# Proxmox config (PVE)
if should_backup "pve"; then
  backup_pve_config
fi
process_latest_backup "proxmox-pve"

# Sync to Google Drive
sync_to_remote
if ! verify_remote_sync; then
  log "❌  ERROR: Backup verification failed, skipping cleanup"
  echo ""
  exit 1
fi

# Cleanup
rm -f "$TMP_DIR"/*

echo ""
log "✅  Backup process complete"