#!/bin/bash
# shellcheck disable=SC2034
set -e

function osd_activate {
  if [[ -z "${OSD_DEVICE}" ]] || [[ ! -b "${OSD_DEVICE}" ]]; then
    log "ERROR: you either provided a non-existing device or no device at all."
    log "You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  CEPH_DISK_OPTIONS=()

  if [[ ${OSD_FILESTORE} -eq 1 ]] && [[ ${OSD_DMCRYPT} -eq 0 ]]; then
    if [[ -n "${OSD_JOURNAL}" ]]; then
      CLI+=("${OSD_JOURNAL}")
    else
      CLI+=("${OSD_DEVICE}")
    fi
    JOURNAL_PART=$(ceph-disk list "${CLI[@]}" | awk '/ceph journal/ {print $1}') # This is a privileged container so 'ceph-disk list' works
    JOURNAL_UUID=$(get_part_uuid "${JOURNAL_PART}" || true)
  fi

  # watch the udev event queue, and exit if all current events are handled
  udevadm settle --timeout=600

  DATA_PART=$(dev_part "${OSD_DEVICE}" 1)
  MOUNTED_PART=${DATA_PART}

  if [[ ${OSD_DMCRYPT} -eq 1 ]] && [[ ${OSD_FILESTORE} -eq 1 ]] && [[ ${OSD_BLUESTORE} -eq 0 ]]; then
    DATA_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 1)")
    LOCKBOX_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 5)")
    JOURNAL_PART=$(ceph-disk list "${OSD_DEVICE}" | awk '/ceph journal/ {print $1}') # This is a privileged container so 'ceph-disk list' works
    JOURNAL_UUID=$(get_part_uuid "${JOURNAL_PART}")

    mount_lockbox "$DATA_UUID" "$LOCKBOX_UUID"

    CEPH_DISK_OPTIONS+=('--dmcrypt')
    MOUNTED_PART="/dev/mapper/${DATA_UUID}"

    # Open LUKS device(s) if necessary
    if [[ ! -e /dev/mapper/"${DATA_UUID}" ]]; then
      open_encrypted_part "${DATA_UUID}" "${DATA_PART}" "${DATA_UUID}"
    fi
    if [[ ! -e /dev/mapper/"${JOURNAL_UUID}" ]]; then
      open_encrypted_part "${JOURNAL_UUID}" "${JOURNAL_PART}" "${DATA_UUID}"
    fi
  elif [[ ${OSD_DMCRYPT} -eq 1 ]] && [[ ${OSD_FILESTORE} -eq 0 ]] && [[ ${OSD_BLUESTORE} -eq 1 ]]; then
    DATA_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 1)")
    BLOCK_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 2)")
    LOCKBOX_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 5)")
    BLOCK_DB_PART=$(ceph-disk list "${OSD_BLUESTORE_BLOCK_DB}" | awk '/ceph block.db/ {print $1}') # This is a privileged container so 'ceph-disk list' works
    BLOCK_DB_UUID=$(get_part_uuid "${BLOCK_DB_PART}")
    BLOCK_WAL_PART=$(ceph-disk list "${OSD_BLUESTORE_BLOCK_WAL}" | awk '/ceph block.wal/ {print $1}') # This is a privileged container so 'ceph-disk list' works
    BLOCK_WAL_UUID=$(get_part_uuid "${BLOCK_WAL_PART}")

    mount_lockbox "$DATA_UUID" "$LOCKBOX_UUID"

    CEPH_DISK_OPTIONS+=('--dmcrypt')
    MOUNTED_PART="/dev/mapper/${DATA_UUID}"

    # Open LUKS device(s) if necessary
    if [[ ! -e /dev/mapper/"${DATA_UUID}" ]]; then
      open_encrypted_part "${BLOCK_UUID}" "${DATA_PART}" "${DATA_UUID}"
    fi
    if [[ ! -e /dev/mapper/"${BLOCK_DB_UUID}" ]]; then
      open_encrypted_part "${BLOCK_DB_UUID}" "${BLOCK_DB_PART}" "${DATA_UUID}"
    fi
    if [[ ! -e /dev/mapper/"${BLOCK_WAL_UUID}" ]]; then
      open_encrypted_part "${BLOCK_WAL_UUID}" "${BLOCK_WAL_PART}" "${DATA_UUID}"
    fi
  fi

  if [[ -z "${CEPH_DISK_OPTIONS[*]}" ]]; then
    ceph-disk -v --setuser ceph --setgroup disk activate --no-start-daemon "${DATA_PART}"
  else
    ceph-disk -v --setuser ceph --setgroup disk activate "${CEPH_DISK_OPTIONS[@]}" --no-start-daemon "${DATA_PART}"
  fi

  OSD_ID=$(grep "${MOUNTED_PART}" /proc/mounts | awk '{print $2}' | sed -r 's/^.*-([0-9]+)$/\1/')

  if [[ ${OSD_BLUESTORE} -eq 1 ]]; then
    # Get the device used for block db and wal otherwise apply_ceph_ownership_to_disks will fail
    OSD_BLUESTORE_BLOCK_DB_TMP=$(resolve_symlink "${OSD_PATH}block.db")
# shellcheck disable=SC2034
    OSD_BLUESTORE_BLOCK_DB=${OSD_BLUESTORE_BLOCK_DB_TMP%?}
# shellcheck disable=SC2034
    OSD_BLUESTORE_BLOCK_WAL_TMP=$(resolve_symlink "${OSD_PATH}block.wal")
# shellcheck disable=SC2034
    OSD_BLUESTORE_BLOCK_WAL=${OSD_BLUESTORE_BLOCK_WAL_TMP%?}
  fi
  apply_ceph_ownership_to_disks

  log "SUCCESS"

  # HLEE
  exec /usr/bin/ceph-osd -f -i "${OSD_ID}" --setuser ceph --setgroup disk
  #exec /usr/bin/ceph-osd "${CLI_OPTS[@]}" -f -i "${OSD_ID}" --setuser ceph --setgroup disk
}
