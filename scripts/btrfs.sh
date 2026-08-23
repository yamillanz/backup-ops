#!/usr/bin/env bash
# backup-ops: btrfs snapshot helper (for distros whose root filesystem is btrfs,
# e.g. Omarchy). Lets the user roll back the whole OS if a migration goes sideways.
# Usage:
#   btrfs.sh status                 # list snapshots on the current system
#   btrfs.sh snapshot <name>        # create a read-only snapshot (may need sudo)
#   btrfs.sh rollback-list <name>   # print the exact commands to roll back

set -uo pipefail

ACTION="${1:-status}"
NAME="${2:-backup-ops-$(date +%Y%m%d-%H%M%S)}"

fstype() { findmnt -n -o FSTYPE -T / 2>/dev/null; }

if [[ "$(fstype)" != "btrfs" ]]; then
  echo "NOTE: root filesystem is '$(fstype || echo unknown)', not btrfs —"
  echo "      no btrfs snapshot support. Drive-level rollback (Timeshift-style"
  echo "      image or reinstall) is out of scope here."
  exit 0
fi

case "$ACTION" in
  status)
    echo "=== btrfs subvolumes (current system) ==="
    btrfs subvolume list / 2>/dev/null || sudo btrfs subvolume list /
    echo
    echo "=== snapshots at or below / (pattern @) ==="
    btrfs subvolume list -o / 2>/dev/null | grep -i "^ID" || true
    ;;

  snapshot)
    echo "creating read-only snapshot: $NAME"
    btrfs subvolume snapshot -r / "@$NAME" 2>/dev/null \
      || sudo btrfs subvolume snapshot -r / "@$NAME"
    ;;

  rollback-list)
    echo "# To roll the system back to '@$NAME' (run from a live USB):"
    echo "  sudo mount /dev/<root-dev> /mnt"
    echo "  sudo mv /mnt/@ /mnt/@.broken"
    echo "  sudo btrfs subvolume snapshot /mnt/@$NAME /mnt/@"
    echo "  sudo umount /mnt && reboot"
    echo
    echo "# Or via the bootloader snapshot picker if your distro exposes one."
    ;;

  *)
    echo "usage: btrfs.sh [status|snapshot <name>|rollback-list <name>]"
    exit 2
    ;;
esac