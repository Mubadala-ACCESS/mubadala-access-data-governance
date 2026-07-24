#!/usr/bin/env bash
set -Eeuo pipefail

# Namerefs and dynamic file descriptors require Bash 4.3 or newer.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  printf 'ERROR: Bash 4.3 or newer is required; found %s.\n' "${BASH_VERSION}" >&2
  exit 1
fi

###############################################################################
# migrate_storagenas1_to_storagenas2_unified_v2.sh
# Version 2.1.1
#
# Linux/NFS-side NAS2 administration and NAS1-to-NAS2 migration.
#
# This script deliberately DOES NOT create Synology DSM users/groups or modify
# Synology Windows ACL entries. Without LDAP/AD, DSM local accounts/groups are
# the SMB identity authority. Create DSM groups first, record their DSM-assigned
# numeric GIDs, and use those exact GIDs on A2, C1, and every trusted NFS client.
#
# Safety properties:
#   * no default operation;
#   * exact-GID checks and collision detection;
#   * no recursive chmod/chown;
#   * no setfacl dependency;
#   * no real migration from a read-write NAS1 mount unless explicitly allowed;
#   * no deletion during copy;
#   * destination remains private while migration is incomplete;
#   * post-copy rsync comparison and optional SHA-256 comparison;
#   * DataAPIs ownership preserved unless explicitly adopted.
###############################################################################

readonly SCRIPT_VERSION="2.1.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_SRC="/storagenas1"
readonly DEFAULT_DST_ROOT="/storagenas2"
readonly DEFAULT_ADMIN_GROUP="storage-admin"
readonly DEFAULT_USERS_GROUP="nas2users"
readonly DEFAULT_DATAAPIS_GROUP="dataapis"
readonly PROJECT_PREFIX="nas2-prj-"

export LC_ALL=C
umask 0027

SRC="${DEFAULT_SRC}"
DST_ROOT="${DEFAULT_DST_ROOT}"
MODE=""
MODE_ARG1=""
MODE_ARG2=""

ADMIN_USER="${SUDO_USER:-}"
ADMIN_GROUP="${DEFAULT_ADMIN_GROUP}"
USERS_GROUP="${DEFAULT_USERS_GROUP}"
DATAAPIS_GROUP="${DEFAULT_DATAAPIS_GROUP}"
ADMIN_GID=""
USERS_GID=""
DATAAPIS_GID=""
DATAAPIS_SERVICE_USER=""

PROJECT_GROUP=""
PROJECT_GID=""
PROJECT_OWNER=""
PROJECT_MEMBERS=""
PROJECT_SMB_MEMBERS=""
PROJECT_RESTRICTED=0
PRIVATE_USER=0

APPLY_PERMISSIONS=1
REPAIR_PERMISSIONS=0
HARDEN_ROOT_POSIX=0
ALLOW_INSECURE_ROOT=0
ADOPT_DATAAPIS=0
DATAAPIS_GROUP_WRITE=0

COPY_RECYCLE=1
MAKE_CHECKSUMS=0
VERIFY_CHECKSUM=0
PRESERVE_XATTRS=0
PRESERVE_POSIX_ACLS=0
ALLOW_RW_SOURCE=0
SPACE_HEADROOM_PERCENT=5

NAS2_TEST_MODE="${NAS2_TEST_MODE:-0}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
BOOT_LOG="$(mktemp "/tmp/nas2-v2.${RUN_ID}.XXXXXX.log")"
LOG_FILE="${BOOT_LOG}"
NAS_LOG_INITIALIZED=0
PROBE_DIR=""
LOCK_FILE="/var/lock/nas2-v2.lock"
LOCK_FD=9
AUDIT_WARNINGS=0
AUDIT_ERRORS=0
ESTIMATED_TRANSFER_BYTES=0

# Derived paths, assigned by derive_paths().
ADMIN_DIR=""
POLICY_DIR=""
IDENTITY_DIR=""
OPERATIONS_DIR=""
AUDIT_DIR=""
SMB_PLAN_DIR=""
MIGRATION_ROOT=""
PROJECTS_DIR=""
DATASETS_DIR=""
USERS_DIR=""
SHARED_DIR=""
USERS_OPEN_DIR=""
ARCHIVE_DIR=""
LEGACY_TOP_DIR=""
LEGACY_ROOT=""
DST=""
PERMISSION_MARKER=""
GID_REGISTRY=""
PROJECT_REGISTRY=""
USER_REGISTRY=""
OP_RUN_DIR=""
OP_LOG_DIR=""
OP_REPORT_DIR=""
OP_MANIFEST_DIR=""
TOP_LEVEL_LIST=""
PROTECTED_DIRS=()

###############################################################################
# Logging and cleanup
###############################################################################

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
  printf '[%s] %s\n' "$(now_utc)" "$*" | tee -a "${LOG_FILE}"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(now_utc)" "$*" | tee -a "${LOG_FILE}" >&2
}

error() {
  printf '[%s] ERROR: %s\n' "$(now_utc)" "$*" | tee -a "${LOG_FILE}" >&2
}

die() { error "$*"; exit 1; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ -n ${PROBE_DIR} && -e ${PROBE_DIR} ]]; then
    rm -rf -- "${PROBE_DIR}" 2>/dev/null || true
  fi

  if [[ ${rc} -ne 0 ]]; then
    error "Operation failed with exit code ${rc}."
    if [[ ${NAS_LOG_INITIALIZED} -eq 1 ]]; then
      error "Review: ${LOG_FILE}"
      rm -f -- "${BOOT_LOG}" 2>/dev/null || true
    else
      error "Temporary log retained: ${BOOT_LOG}"
    fi
  else
    rm -f -- "${BOOT_LOG}" 2>/dev/null || true
  fi

  exit "${rc}"
}
trap cleanup EXIT

on_err() {
  local rc=$?
  local line=$1
  local command_text=$2
  error "Failure at line ${line}: ${command_text} (exit ${rc})"
  return "${rc}"
}
trap 'on_err ${LINENO} "$BASH_COMMAND"' ERR

###############################################################################
# Usage
###############################################################################

usage() {
  cat <<EOF_USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}

Select exactly one operation. Running with no arguments changes nothing.

Core operations:
  --preflight
      Non-destructive validation. It may create and remove a temporary probe.
      It does not create groups or retain NAS files.

  --setup-only
      Synchronize core Linux groups, create the NAS2 structure, write policy and
      runbook files, and apply the initial coarse POSIX permission layer.

  --sync-groups-only
      Create/verify the three core Linux groups on this workstation only.
      Use this on C1 after setup on A2.

  --audit
      Audit mounts, GID consistency, managed paths, projects, and risky modes.

Provisioning operations:
  --add-nas-user USER
  --remove-nas-user USER
  --create-user USER [--private-user]
  --create-project PROJECT --owner OWNER --project-gid GID [options]
  --sync-project-group PROJECT --project-gid GID [--members u1,u2]
  --add-project-member PROJECT USER
  --remove-project-member PROJECT USER

Migration operations:
  --dry-run
  --run
  --verify-only [--verify-checksum]

Core identity options:
  --admin-user USER             Default: sudo caller, if available
  --admin-group GROUP           Default: ${DEFAULT_ADMIN_GROUP}
  --admin-gid GID               DSM-assigned GID
  --users-group GROUP           Default: ${DEFAULT_USERS_GROUP}
  --users-gid GID               DSM-assigned GID
  --dataapis-group GROUP        Default: ${DEFAULT_DATAAPIS_GROUP}
  --dataapis-gid GID            DSM-assigned GID

Project options:
  --owner OWNER                 Required for --create-project
  --members u1,u2               Existing local/NFS workstation users
  --smb-members u1,u2           Recorded in DSM ACL plan only
  --project-gid GID             DSM-assigned project-group GID
  --project-group GROUP         Override ${PROJECT_PREFIX}<project>
  --restricted-project         Members only (2770); default open-read (2775)

DataAPIs options:
  --dataapis-service-user USER  Verified service account, such as ajd11
  --adopt-dataapis              Change only top-level owner/group to
                                USER:${DATAAPIS_GROUP}; never recursive
  --dataapis-group-write        Use 2770 with adoption; default 2750

Migration options:
  --checksums                   Generate and compare source/destination SHA-256
  --verify-checksum             Rsync checksum verify plus SHA-256 manifests
  --skip-recycle               Exclude top-level /storagenas1/#recycle
  --preserve-xattrs            Preserve xattrs after capability probe
  --preserve-posix-acls         Preserve POSIX ACLs after capability probe;
                                expected to fail on the current NFS mount
  --allow-rw-source             Emergency override for a read-write NAS1 mount
  --space-headroom-percent N    Default: 5; minimum extra reserve is 1 GiB

Permission safety options:
  --repair-permissions          Reapply coarse POSIX modes to existing managed
                                directories. Do not use after DSM ACL rollout
                                without reviewing the effect.
  --no-permissions              Skip managed directory chmod/chown. Generated
                                admin files still receive safe owner/modes.
  --harden-root-posix           Explicitly chmod the NAS2 mount root to 0755;
                                use only when Unix permissions are authoritative
  --allow-insecure-root         Emergency override for a writable mount root

Path options:
  --source PATH                 Default: ${DEFAULT_SRC}
  --destination-root PATH       Default: ${DEFAULT_DST_ROOT}

Examples:
  sudo ./${SCRIPT_NAME} --preflight \
    --admin-user ptr226 --admin-gid 42000 --users-gid 42001 --dataapis-gid 42002

  sudo ./${SCRIPT_NAME} --setup-only \
    --admin-user ptr226 --admin-gid 42000 --users-gid 42001 --dataapis-gid 42002

  sudo ./${SCRIPT_NAME} --sync-groups-only \
    --admin-user ptr226 --admin-gid 42000 --users-gid 42001 --dataapis-gid 42002

  sudo ./${SCRIPT_NAME} --create-project regclim-wrf \
    --owner ptr226 --members mk7641,ak11283 \
    --smb-members external-collaborator --project-gid 42100

  sudo ./${SCRIPT_NAME} --audit
  sudo ./${SCRIPT_NAME} --dry-run
  sudo ./${SCRIPT_NAME} --run --checksums
  sudo ./${SCRIPT_NAME} --verify-only --verify-checksum

Exit codes:
  0 success
  1 operation failure
  2 audit completed with critical findings
EOF_USAGE
}

###############################################################################
# General helpers
###############################################################################

set_mode() {
  local requested=$1
  local arg1=${2:-}
  local arg2=${3:-}
  [[ -z ${MODE} ]] || die "Only one operation may be selected (already ${MODE}, also ${requested})."
  MODE="${requested}"
  MODE_ARG1="${arg1}"
  MODE_ARG2="${arg2}"
}

require_value() {
  local opt=$1 value=${2:-}
  [[ -n ${value} ]] || die "${opt} requires a value."
}

require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ ${EUID} -eq 0 ]] || die "Run this operation as root with sudo."; }

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

validate_gid() {
  local label=$1 gid=$2 decimal
  is_uint "${gid}" || die "${label} must be a non-negative integer: ${gid}"
  decimal=$((10#${gid}))
  (( decimal <= 2147483647 )) || die "${label} is outside the supported range: ${gid}"
}

validate_percent() {
  local decimal
  is_uint "$1" || die "--space-headroom-percent must be an integer."
  decimal=$((10#$1))
  (( decimal >= 0 && decimal <= 100 )) || die "--space-headroom-percent must be 0-100."
}

validate_group_name() {
  local name=$1
  [[ ${name} =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "Invalid Linux group name: ${name}"
  (( ${#name} <= 32 )) || die "Linux group name exceeds 32 characters: ${name}"
}

validate_core_identity_separation() {
  [[ ${ADMIN_GROUP} != "${USERS_GROUP}" && ${ADMIN_GROUP} != "${DATAAPIS_GROUP}" && ${USERS_GROUP} != "${DATAAPIS_GROUP}" ]]     || die "Core groups must be distinct: admin=${ADMIN_GROUP}, users=${USERS_GROUP}, dataapis=${DATAAPIS_GROUP}."

  if [[ -n ${ADMIN_GID} && -n ${USERS_GID} && ${ADMIN_GID} == "${USERS_GID}" ]]; then
    die "--admin-gid and --users-gid must be different."
  fi
  if [[ -n ${ADMIN_GID} && -n ${DATAAPIS_GID} && ${ADMIN_GID} == "${DATAAPIS_GID}" ]]; then
    die "--admin-gid and --dataapis-gid must be different."
  fi
  if [[ -n ${USERS_GID} && -n ${DATAAPIS_GID} && ${USERS_GID} == "${DATAAPIS_GID}" ]]; then
    die "--users-gid and --dataapis-gid must be different."
  fi
}

reject_core_project_group() {
  local group=$1
  [[ ${group} != "${ADMIN_GROUP}" && ${group} != "${USERS_GROUP}" && ${group} != "${DATAAPIS_GROUP}" ]]     || die "Project group ${group} conflicts with a core NAS2 group."
}

validate_account_token() {
  [[ $1 =~ ^[A-Za-z0-9_.@-]+$ ]] || die "Invalid account token: $1"
}

validate_project_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Project names must use lowercase letters, digits, and hyphens: $1"
  [[ $1 != *--* ]] || die "Project names may not contain consecutive hyphens: $1"
}

validate_absolute_path() {
  local label=$1 path=$2
  [[ ${path} == /* ]] || die "${label} must be absolute: ${path}"
  [[ ${path} != / ]] || die "${label} may not be the filesystem root."
  [[ ${path} != *$'\n'* ]] || die "${label} may not contain a newline."
}

require_local_user() {
  validate_account_token "$1"
  getent passwd "$1" >/dev/null 2>&1 || die "User does not exist on ${HOST_SHORT}: $1"
}

csv_each() {
  local csv=$1 callback=$2 item
  local -a items=()
  [[ -n ${csv} ]] || return 0
  IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    [[ -n ${item} ]] || continue
    "${callback}" "${item}"
  done
}

derive_paths() {
  validate_absolute_path "--source" "${SRC}"
  validate_absolute_path "--destination-root" "${DST_ROOT}"

  ADMIN_DIR="${DST_ROOT}/00_ADMIN"
  POLICY_DIR="${ADMIN_DIR}/policies"
  IDENTITY_DIR="${ADMIN_DIR}/identity"
  OPERATIONS_DIR="${ADMIN_DIR}/operations"
  AUDIT_DIR="${ADMIN_DIR}/audits"
  SMB_PLAN_DIR="${ADMIN_DIR}/smb-acl-plans"
  MIGRATION_ROOT="${ADMIN_DIR}/migrations/storagenas1"
  PROJECTS_DIR="${DST_ROOT}/10_PROJECTS"
  DATASETS_DIR="${DST_ROOT}/20_DATASETS"
  USERS_DIR="${DST_ROOT}/30_USERS"
  SHARED_DIR="${DST_ROOT}/40_SHARED"
  USERS_OPEN_DIR="${SHARED_DIR}/users-open"
  ARCHIVE_DIR="${DST_ROOT}/50_ARCHIVE"
  LEGACY_TOP_DIR="${DST_ROOT}/90_LEGACY"
  LEGACY_ROOT="${LEGACY_TOP_DIR}/storagenas1"
  DST="${LEGACY_ROOT}/raw"
  PERMISSION_MARKER="${ADMIN_DIR}/.nas2-v2-permissions-initialized"
  GID_REGISTRY="${IDENTITY_DIR}/gid-registry.tsv"
  PROJECT_REGISTRY="${IDENTITY_DIR}/projects.tsv"
  USER_REGISTRY="${IDENTITY_DIR}/users.tsv"
  case "${MODE}" in
    dry-run|run|verify) OP_RUN_DIR="${MIGRATION_ROOT}/${RUN_ID}" ;;
    *)                  OP_RUN_DIR="${OPERATIONS_DIR}/${RUN_ID}" ;;
  esac
  OP_LOG_DIR="${OP_RUN_DIR}/logs"
  OP_REPORT_DIR="${OP_RUN_DIR}/reports"
  OP_MANIFEST_DIR="${OP_RUN_DIR}/manifests"
  TOP_LEVEL_LIST="${OP_MANIFEST_DIR}/source-top-level.nul"
  PROTECTED_DIRS=("${DST_ROOT}/dataapis-backups" "${DST_ROOT}/dataapis-live")

  if [[ ${NAS2_TEST_MODE} == 1 ]]; then
    [[ ${SRC} == /tmp/nas2-v2-test.* || ${SRC} == /tmp/nas2-v2-test.*/* ]] \
      || die "NAS2_TEST_MODE source must be below /tmp/nas2-v2-test.*"
    [[ ${DST_ROOT} == /tmp/nas2-v2-test.* || ${DST_ROOT} == /tmp/nas2-v2-test.*/* ]] \
      || die "NAS2_TEST_MODE destination must be below /tmp/nas2-v2-test.*"
    LOCK_FILE="${DST_ROOT}.lock"
  fi
}

init_nas_logging() {
  mkdir -p -- "${OP_LOG_DIR}" "${OP_REPORT_DIR}" "${OP_MANIFEST_DIR}"
  chown root:"${ADMIN_GROUP}" -- "${OP_RUN_DIR}" "${OP_LOG_DIR}" "${OP_REPORT_DIR}" "${OP_MANIFEST_DIR}"     || die "Cannot assign the storage-admin group to operation directories."
  chmod 2770 -- "${OP_RUN_DIR}" "${OP_LOG_DIR}" "${OP_REPORT_DIR}" "${OP_MANIFEST_DIR}"     || die "Cannot secure operation directories."
  local target="${OP_LOG_DIR}/operation.log"
  cat -- "${BOOT_LOG}" > "${target}"
  chown root:"${ADMIN_GROUP}" -- "${target}" || die "Cannot assign operation-log ownership."
  chmod 0660 -- "${target}" || die "Cannot secure the operation log."
  LOG_FILE="${target}"
  NAS_LOG_INITIALIZED=1
  log "Operation log: ${LOG_FILE}"
}

acquire_lock() {
  require_command flock
  mkdir -p -- "$(dirname "${LOCK_FILE}")"
  exec {LOCK_FD}>"${LOCK_FILE}"
  flock -n "${LOCK_FD}" || die "Another NAS2 operation holds ${LOCK_FILE}."
  log "Acquired lock: ${LOCK_FILE}"
}

is_mountpoint_path() {
  [[ ${NAS2_TEST_MODE} == 1 ]] && return 0
  mountpoint -q -- "$1"
}

require_mountpoint_path() {
  local label=$1 path=$2
  [[ -d ${path} ]] || die "${label} is missing or not a directory: ${path}"
  is_mountpoint_path "${path}" || die "${label} is not a mountpoint: ${path}"
}

mount_description() {
  if [[ ${NAS2_TEST_MODE} == 1 ]]; then
    printf 'TEST-MODE path=%s' "$1"
  else
    findmnt -T "$1" -n -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
  fi
}

mount_options() {
  if [[ ${NAS2_TEST_MODE} == 1 ]]; then
    printf 'rw,test-mode\n'
  else
    findmnt -T "$1" -n -o OPTIONS
  fi
}

mount_is_readonly() {
  local options
  options=",$(mount_options "$1"),"
  [[ ${options} == *,ro,* ]]
}

check_paths_not_nested() {
  local s d
  s="$(readlink -f -- "${SRC}")"
  d="$(readlink -f -- "${DST_ROOT}")"
  [[ ${s} != "${d}" ]] || die "Source and destination are the same path."
  case "${d}" in "${s}"/*) die "Destination is inside the source.";; esac
  case "${s}" in "${d}"/*) die "Source is inside the destination.";; esac
}

mode_has_group_or_other_write() {
  (( (8#$1 & 0022) != 0 ))
}

check_mount_root_security() {
  local behavior=${1:-enforce} mode
  mode="$(stat -c '%a' -- "${DST_ROOT}")"
  if ! mode_has_group_or_other_write "${mode}"; then
    log "NAS2 root mode is not group/world writable: ${mode} ${DST_ROOT}"
    return 0
  fi

  if [[ ${HARDEN_ROOT_POSIX} -eq 1 ]]; then
    log "Explicitly chmodding NAS2 root to 0755: ${DST_ROOT}"
    chmod 0755 -- "${DST_ROOT}"
    mode="$(stat -c '%a' -- "${DST_ROOT}")"
    mode_has_group_or_other_write "${mode}" && die "NAS2 root remains writable after chmod: ${mode}"
    return 0
  fi

  if [[ ${ALLOW_INSECURE_ROOT} -eq 1 ]]; then
    warn "Emergency override: NAS2 root mode ${mode} permits group/other writes."
    return 0
  fi

  if [[ ${behavior} == warn ]]; then
    warn "NAS2 root mode ${mode} permits group/other writes. Verify DSM ACLs and test an ordinary account."
    return 1
  fi

  die "NAS2 root mode ${mode} permits unauthorized top-level creation. Fix DSM permissions, or use --harden-root-posix only for a Unix-permission share."
}

check_source_readonly_for_run() {
  if mount_is_readonly "${SRC}"; then
    log "Source is mounted read-only: ${SRC}"
  elif [[ ${ALLOW_RW_SOURCE} -eq 1 || ${NAS2_TEST_MODE} == 1 ]]; then
    warn "Source is read-write; explicit override/test mode accepted. Freeze writes during migration."
  else
    die "Source is read-write. Remount NAS1 read-only before --run or use --allow-rw-source only in a controlled maintenance window."
  fi
}

write_probe() {
  local p="${DST_ROOT}/.nas2-v2-write-probe.${RUN_ID}"
  (umask 0077; : > "${p}") || die "Cannot write to destination root."
  rm -f -- "${p}" || die "Cannot remove destination write probe."
  log "Destination write probe passed."
}

###############################################################################
# Exact GID management
###############################################################################

group_gid() { getent group "$1" | awk -F: '{print $3; exit}'; }
group_for_gid() { getent group "$1" 2>/dev/null | awk -F: '{print $1; exit}'; }

preflight_group() {
  local name=$1 desired=${2:-} purpose=$3 actual collision
  validate_group_name "${name}"
  [[ -z ${desired} ]] || validate_gid "GID for ${name}" "${desired}"

  if getent group "${name}" >/dev/null 2>&1; then
    actual="$(group_gid "${name}")"
    [[ -z ${desired} || ${actual} == "${desired}" ]] \
      || die "${name} exists as GID ${actual}, but ${desired} was requested."
    log "Preflight: group ${name}:${actual} exists (${purpose})."
  else
    [[ -n ${desired} ]] || die "Group ${name} is absent; supply its DSM-assigned GID."
    collision="$(group_for_gid "${desired}" || true)"
    [[ -z ${collision} ]] || die "GID ${desired} is already used by ${collision}."
    log "Preflight: group ${name}:${desired} can be created (${purpose})."
  fi
}

ensure_group_exact() {
  local name=$1 desired=${2:-} purpose=$3 actual collision
  preflight_group "${name}" "${desired}" "${purpose}"
  if getent group "${name}" >/dev/null 2>&1; then
    return 0
  fi
  groupadd --gid "${desired}" -- "${name}"
  actual="$(group_gid "${name}")"
  [[ ${actual} == "${desired}" ]] || die "Failed to create ${name} with exact GID ${desired}."
  log "Created group ${name}:${actual} (${purpose})."
}

ensure_user_in_group() {
  local user=$1 group=$2
  require_local_user "${user}"
  getent group "${group}" >/dev/null 2>&1 || die "Missing group: ${group}"
  if id -nG "${user}" | tr ' ' '\n' | grep -Fqx -- "${group}"; then
    log "${user} is already in ${group}."
  else
    usermod -aG "${group}" -- "${user}"
    log "Added ${user} to ${group}; a new login session is required."
  fi
}

remove_user_from_group() {
  local user=$1 group=$2
  require_local_user "${user}"
  getent group "${group}" >/dev/null 2>&1 || die "Missing group: ${group}"
  if id -nG "${user}" | tr ' ' '\n' | grep -Fqx -- "${group}"; then
    gpasswd -d "${user}" "${group}" >/dev/null
    log "Removed ${user} from ${group}; existing sessions may retain old groups."
  else
    log "${user} is not in ${group}; no change."
  fi
}

preflight_core_groups() {
  preflight_group "${ADMIN_GROUP}" "${ADMIN_GID}" "NAS2 administration"
  preflight_group "${USERS_GROUP}" "${USERS_GID}" "approved NAS2 users"
  preflight_group "${DATAAPIS_GROUP}" "${DATAAPIS_GID}" "DataAPIs"
  if [[ -n ${ADMIN_USER} ]]; then
    require_local_user "${ADMIN_USER}"
  fi
  if [[ -n ${DATAAPIS_SERVICE_USER} ]]; then
    require_local_user "${DATAAPIS_SERVICE_USER}"
  fi
}

sync_core_groups() {
  ensure_group_exact "${ADMIN_GROUP}" "${ADMIN_GID}" "NAS2 administration"
  ensure_group_exact "${USERS_GROUP}" "${USERS_GID}" "approved NAS2 users"
  ensure_group_exact "${DATAAPIS_GROUP}" "${DATAAPIS_GID}" "DataAPIs"
  ADMIN_GID="$(group_gid "${ADMIN_GROUP}")"
  USERS_GID="$(group_gid "${USERS_GROUP}")"
  DATAAPIS_GID="$(group_gid "${DATAAPIS_GROUP}")"

  if [[ -n ${ADMIN_USER} ]]; then
    ensure_user_in_group "${ADMIN_USER}" "${ADMIN_GROUP}"
    ensure_user_in_group "${ADMIN_USER}" "${USERS_GROUP}"
    ensure_user_in_group "${ADMIN_USER}" "${DATAAPIS_GROUP}"
  else
    warn "No human --admin-user was supplied."
  fi
  if [[ -n ${DATAAPIS_SERVICE_USER} ]]; then
    ensure_user_in_group "${DATAAPIS_SERVICE_USER}" "${DATAAPIS_GROUP}"
  fi
}

###############################################################################
# Atomic files and registries
###############################################################################

atomic_write() {
  local target=$1 owner=$2 group=$3 mode=$4 tmp
  mkdir -p -- "$(dirname "${target}")"
  tmp="$(mktemp "$(dirname "${target}")/.nas2-tmp.XXXXXX")"
  cat > "${tmp}"
  chown "${owner}:${group}" -- "${tmp}"
  chmod "${mode}" -- "${tmp}"
  mv -f -- "${tmp}" "${target}"
}

ensure_registry_headers() {
  [[ -e ${GID_REGISTRY} ]] || printf 'group_name\tgid\tscope\tsource\tupdated_utc\n' \
    | atomic_write "${GID_REGISTRY}" root "${ADMIN_GROUP}" 0660
  [[ -e ${PROJECT_REGISTRY} ]] || printf 'project\tgroup_name\tgid\tclassification\towner\tlocal_members\tsmb_members\tupdated_utc\n' \
    | atomic_write "${PROJECT_REGISTRY}" root "${ADMIN_GROUP}" 0660
  [[ -e ${USER_REGISTRY} ]] || printf 'username\tclassification\tgroup_name\tpath\tupdated_utc\n' \
    | atomic_write "${USER_REGISTRY}" root "${ADMIN_GROUP}" 0660
}

upsert_gid_registry() {
  local name=$1 gid=$2 scope=$3 source=${4:-dsm-local-static} tmp old_name old_gid
  ensure_registry_headers
  old_gid="$(awk -F '\t' -v n="${name}" 'NR>1 && $1==n {print $2; exit}' "${GID_REGISTRY}")"
  [[ -z ${old_gid} || ${old_gid} == "${gid}" ]] || die "Registry conflict: ${name}=${old_gid}, not ${gid}."
  old_name="$(awk -F '\t' -v g="${gid}" 'NR>1 && $2==g {print $1; exit}' "${GID_REGISTRY}")"
  [[ -z ${old_name} || ${old_name} == "${name}" ]] || die "Registry conflict: GID ${gid} belongs to ${old_name}."
  tmp="$(mktemp "${IDENTITY_DIR}/.gid.XXXXXX")"
  awk -F '\t' -v OFS='\t' -v n="${name}" -v g="${gid}" 'NR==1{print;next}$1!=n&&$2!=g{print}' "${GID_REGISTRY}" > "${tmp}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${gid}" "${scope}" "${source}" "$(now_utc)" >> "${tmp}"
  chown root:"${ADMIN_GROUP}" -- "${tmp}"; chmod 0660 -- "${tmp}"; mv -f -- "${tmp}" "${GID_REGISTRY}"
}

upsert_project_registry() {
  local project=$1 group=$2 gid=$3 classification=$4 owner=$5 locals=$6 smbs=$7 tmp
  ensure_registry_headers
  tmp="$(mktemp "${IDENTITY_DIR}/.project.XXXXXX")"
  awk -F '\t' -v OFS='\t' -v p="${project}" 'NR==1{print;next}$1!=p{print}' "${PROJECT_REGISTRY}" > "${tmp}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${project}" "${group}" "${gid}" "${classification}" "${owner}" "${locals}" "${smbs}" "$(now_utc)" >> "${tmp}"
  chown root:"${ADMIN_GROUP}" -- "${tmp}"; chmod 0660 -- "${tmp}"; mv -f -- "${tmp}" "${PROJECT_REGISTRY}"
}

upsert_user_registry() {
  local username=$1 classification=$2 group=$3 path=$4 tmp
  ensure_registry_headers
  tmp="$(mktemp "${IDENTITY_DIR}/.user.XXXXXX")"
  awk -F '\t' -v OFS='\t' -v u="${username}" 'NR==1{print;next}$1!=u{print}' "${USER_REGISTRY}" > "${tmp}"
  printf '%s\t%s\t%s\t%s\t%s\n' "${username}" "${classification}" "${group}" "${path}" "$(now_utc)" >> "${tmp}"
  chown root:"${ADMIN_GROUP}" -- "${tmp}"; chmod 0660 -- "${tmp}"; mv -f -- "${tmp}" "${USER_REGISTRY}"
}

registry_gid() {
  [[ -r ${GID_REGISTRY} ]] || return 1
  awk -F '\t' -v n="$1" 'NR>1 && $1==n {print $2; exit}' "${GID_REGISTRY}"
}

project_field() {
  [[ -r ${PROJECT_REGISTRY} ]] || return 1
  awk -F '\t' -v p="$1" -v f="$2" 'NR>1 && $1==p {print $f; exit}' "${PROJECT_REGISTRY}"
}

###############################################################################
# Base structure and policy files
###############################################################################

apply_dir_state() {
  local path=$1 owner=$2 group=$3 mode=$4 enforce_existing=$5 existed=0
  if [[ -e ${path} ]]; then
    [[ -d ${path} ]] || die "Expected directory, found another type: ${path}"
    existed=1
  else
    mkdir -p -- "${path}"
  fi

  if [[ ${APPLY_PERMISSIONS} -ne 1 ]]; then
    log "Ensured path without chmod/chown: ${path}"
    return 0
  fi
  if [[ ${existed} -eq 1 && ${enforce_existing} -ne 1 ]]; then
    log "Existing path left unchanged by idempotent setup: ${path}"
    return 0
  fi

  chown "${owner}:${group}" -- "${path}" || die "chown failed on ${path}; check NFS squash/DSM permissions."
  chmod "${mode}" -- "${path}" || die "chmod failed on ${path}; check DSM permission mode."

  local expected_uid expected_gid actual_uid actual_gid actual_mode
  expected_uid="$(id -u "${owner}" 2>/dev/null || printf '%s' "${owner}")"
  expected_gid="$(group_gid "${group}")"
  actual_uid="$(stat -c '%u' -- "${path}")"
  actual_gid="$(stat -c '%g' -- "${path}")"
  actual_mode="$(stat -c '%a' -- "${path}")"
  [[ ${actual_uid} == "${expected_uid}" ]] || die "Owner verification failed for ${path}."
  [[ ${actual_gid} == "${expected_gid}" ]] || die "Group verification failed for ${path}."
  [[ ${actual_mode} == "${mode#0}" ]] || die "Mode verification failed for ${path}: expected ${mode}, got ${actual_mode}."
  log "Applied ${owner}:${group} ${mode} to ${path}."
}

capture_prechange_state() {
  local out="${OP_REPORT_DIR}/prechange-path-state.tsv" path
  printf 'path\ttype\tmode\tuid\tgid\towner\tgroup\n' > "${out}"
  for path in "${DST_ROOT}" "${ADMIN_DIR}" "${PROJECTS_DIR}" "${DATASETS_DIR}" "${USERS_DIR}" \
    "${SHARED_DIR}" "${USERS_OPEN_DIR}" "${ARCHIVE_DIR}" "${LEGACY_TOP_DIR}" "${LEGACY_ROOT}" "${DST}" "${PROTECTED_DIRS[@]}"; do
    if [[ -e ${path} || -L ${path} ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${path}" "$(stat -c '%F' -- "${path}")" "$(stat -c '%a' -- "${path}")" \
        "$(stat -c '%u' -- "${path}")" "$(stat -c '%g' -- "${path}")" \
        "$(stat -c '%U' -- "${path}")" "$(stat -c '%G' -- "${path}")" >> "${out}"
    else
      printf '%s\tMISSING\t-\t-\t-\t-\t-\n' "${path}" >> "${out}"
    fi
  done
  chown root:"${ADMIN_GROUP}" -- "${out}"; chmod 0660 -- "${out}"
  log "Captured pre-change state: ${out}"
}

write_smb_runbook() {
  cat <<EOF_RUNBOOK | atomic_write "${POLICY_DIR}/SMB-NO-LDAP-RUNBOOK.md" root "${ADMIN_GROUP}" 0644
# NAS2 SMB + NFS Runbook Without LDAP/AD

## Authority boundary

- DSM local users/groups authenticate SMB users and control Synology ACLs.
- Linux groups/GIDs control the NFS/POSIX layer on A2 and C1.
- Create each DSM group first, query its DSM-assigned GID, then mirror that GID
  exactly on every trusted NFS client.
- SMB-only users do not need A2/C1 accounts.

Core groups:

- ${ADMIN_GROUP}: storage administration
- ${USERS_GROUP}: approved NAS users and baseline read population
- ${DATAAPIS_GROUP}: verified DataAPIs service/operators
- ${PROJECT_PREFIX}<project>: project writers

## DSM-first GID procedure

1. Create groups in DSM Control Panel > User & Group.
2. In a read-only SSH session to the NAS, record:

       getent group ${ADMIN_GROUP}
       getent group ${USERS_GROUP}
       getent group ${DATAAPIS_GROUP}
       getent group ${PROJECT_PREFIX}<project>

3. Run this script with those numeric GIDs on A2 and C1.
4. Never allow the same group name to have different GIDs on different clients.

## SMB security

- Enable SMB2/SMB3; disable SMB1 and guest access.
- Use SMB encryption/signing according to institutional policy.
- Never expose TCP 445 directly to the Internet.
- Remote users connect to the institutional VPN first, then use:

       Windows: \\\\NAS-HOST\\SHARE-NAME
       macOS:   smb://NAS-HOST/SHARE-NAME
       Linux:   smb://NAS-HOST/SHARE-NAME

## DSM ACL pattern and safe order of operations

1. Take a DSM snapshot/backup and export or record current permissions.
2. Run the initial POSIX setup before applying final DSM ACLs.
3. Apply and validate DSM ACLs in DSM/File Station.
4. After DSM ACLs are in production, do not use --repair-permissions unless the
   effect has been reviewed. chmod from Linux can change an ACL-managed item to
   Unix permission type.

At the shared-folder root:
- ${ADMIN_GROUP}: Full control
- ${USERS_GROUP}: Read/traverse only, if baseline discovery is required
- guest/Everyone: no write permission

For ${POLICY_DIR}, grant ${USERS_GROUP} read/traverse so NFS users can source the
published umask helpers. Keep ${IDENTITY_DIR}, ${OPERATIONS_DIR}, and migration
logs restricted to ${ADMIN_GROUP}.

Manage SMB permissions in DSM/File Station, not with setfacl from A2/C1.
Avoid explicit Deny entries for ${USERS_GROUP} when project members also belong
to ${USERS_GROUP}; DSM resolves No access above Read/Write and Read only. Remove
unwanted inheritance and grant only required entries.

OPEN-READ project:
- ${ADMIN_GROUP}: Full control
- ${PROJECT_PREFIX}<project>: Modify
- ${USERS_GROUP}: Read

On the NFS/POSIX layer, mode 2775 implements open-read with the "other" read
bits because one POSIX object cannot have two owning groups without ACLs. This
means every local account on a trusted NFS client can read OPEN-READ content.
Use RESTRICTED/PRIVATE for data that must not be visible to all workstation
accounts, and never export NFS to unmanaged clients.

RESTRICTED project:
- ${ADMIN_GROUP}: Full control
- ${PROJECT_PREFIX}<project>: Modify
- optional dedicated read-only group: Read
- no baseline ${USERS_GROUP} grant

Normal user folder:
- named user: Modify
- ${ADMIN_GROUP}: Full control
- ${USERS_GROUP}: Read

Private user folder:
- named user: Modify
- ${ADMIN_GROUP}: Full control
- no ${USERS_GROUP} grant

DataAPIs:
- ${ADMIN_GROUP}: Full control
- ${DATAAPIS_GROUP}: only required service/operator access
- no ${USERS_GROUP} grant

## NFS

Restrict NFS to A2, C1, and trusted managed Linux clients. Use No mapping only
when numeric UID/GID consistency is verified. Do not provide NFS to unmanaged
external laptops.

## Test matrix

From A2 NFS, C1 NFS, and an SMB-only test account, test list/read/create/modify/
rename/delete for each classification. Also confirm an ordinary account cannot
create a new top-level directory under ${DST_ROOT}.
EOF_RUNBOOK
}

write_policy_docs() {
  cat <<EOF_POLICY | atomic_write "${POLICY_DIR}/README.storage-policy.md" root "${ADMIN_GROUP}" 0644
# NAS2 Storage Policy

NAS2 is authoritative long-term storage. Approved top-level areas:

- 00_ADMIN: policy, identity registry, logs, reports, manifests
- 10_PROJECTS: active curated projects
- 20_DATASETS: canonical shared datasets
- 30_USERS: user-owned retained data
- 40_SHARED: collaboration
- 50_ARCHIVE: completed/frozen/retired curated data
- 90_LEGACY: unmodified migrations

Do not create other top-level directories. Do not write new data to ${SRC}.
Do not use /home for bulk storage. Use /fastscratch or /fastscratch2 for
regenerable temporary work.

Classifications:
- OPEN-READ: owner/project group modifies; all accounts on trusted NFS clients
  can read through POSIX "other" bits because default ACLs are unavailable
- RESTRICTED: named groups and storage administrators only
- PRIVATE: one owner plus storage administration
- SYSTEM: service accounts and storage administration only

The current NFS interface does not support POSIX default ACLs. Use setgid plus
umask 0002 for collaborative Linux writes, and configure DSM ACLs for SMB.
EOF_POLICY

  cat <<'EOF_UMASK' | atomic_write "${POLICY_DIR}/nas2-project-umask.sh" root "${ADMIN_GROUP}" 0644
# Collaborative project/shared writes: files normally 0664, directories 0775.
umask 0002
EOF_UMASK

  cat <<'EOF_UMASK' | atomic_write "${POLICY_DIR}/nas2-user-readable-umask.sh" root "${ADMIN_GROUP}" 0644
# Normal readable user data: files normally 0644, directories 0755.
umask 0022
EOF_UMASK

  cat <<'EOF_UMASK' | atomic_write "${POLICY_DIR}/nas2-private-umask.sh" root "${ADMIN_GROUP}" 0644
# Private data with storage-admin group: files normally 0640, directories 0750.
umask 0027
EOF_UMASK

  cat <<EOF_LEGACY | atomic_write "${LEGACY_ROOT}/README.md" root "${ADMIN_GROUP}" 0644
# Legacy import from ${SRC}

Raw destination: ${DST}

Preserve source layout. Do not reorganize or delete legacy content until owner,
purpose, retention, and final placement are confirmed.
EOF_LEGACY

  cat <<EOF_SHARED | atomic_write "${USERS_OPEN_DIR}/README.md" root "${USERS_GROUP}" 0664
# Shared user-data area

Use: ${USERS_OPEN_DIR}/<team-or-project>/<dataset-or-run>/

Before collaborative Linux/NFS writes:

  source ${POLICY_DIR}/nas2-project-umask.sh

Jobs, cron, notebooks, and services must explicitly use umask 0002 when group
write access is required because default POSIX ACLs are unavailable.
EOF_SHARED

  write_smb_runbook
  log "Wrote policy, umask helpers, and SMB runbook."
}

protect_dataapis() {
  local enforce=$1 path owner group mode=2750
  [[ ${DATAAPIS_GROUP_WRITE} -eq 1 ]] && mode=2770
  for path in "${PROTECTED_DIRS[@]}"; do
    if [[ ! -e ${path} ]]; then warn "DataAPIs path missing: ${path}"; continue; fi
    [[ -d ${path} ]] || die "DataAPIs path is not a directory: ${path}"
    owner="$(stat -c '%U' -- "${path}")"; group="$(stat -c '%G' -- "${path}")"

    if [[ ${ADOPT_DATAAPIS} -eq 1 ]]; then
      [[ -n ${DATAAPIS_SERVICE_USER} ]] || die "--adopt-dataapis requires --dataapis-service-user."
      require_local_user "${DATAAPIS_SERVICE_USER}"
      ensure_user_in_group "${DATAAPIS_SERVICE_USER}" "${DATAAPIS_GROUP}"
      chown "${DATAAPIS_SERVICE_USER}:${DATAAPIS_GROUP}" -- "${path}"
      chmod "${mode}" -- "${path}"
      log "Adopted top-level only: ${DATAAPIS_SERVICE_USER}:${DATAAPIS_GROUP} ${mode} ${path}"
    elif [[ ${APPLY_PERMISSIONS} -eq 1 && ${enforce} -eq 1 ]]; then
      chmod 2750 -- "${path}" || die "Failed to protect ${path}."
      log "Preserved ${owner}:${group}; applied 2750 to ${path}."
    else
      log "Preserved DataAPIs state: ${owner}:${group} $(stat -c '%a' -- "${path}") ${path}"
    fi
  done
}

create_base_structure() {
  local enforce=0
  [[ ! -e ${PERMISSION_MARKER} || ${REPAIR_PERMISSIONS} -eq 1 ]] && enforce=1

  mkdir -p -- "${ADMIN_DIR}" "${POLICY_DIR}" "${IDENTITY_DIR}" "${OPERATIONS_DIR}" "${AUDIT_DIR}" \
    "${SMB_PLAN_DIR}" "${MIGRATION_ROOT}" "${PROJECTS_DIR}" "${DATASETS_DIR}" "${USERS_DIR}" \
    "${SHARED_DIR}" "${USERS_OPEN_DIR}" "${ARCHIVE_DIR}" "${LEGACY_TOP_DIR}" "${LEGACY_ROOT}" "${DST}"

  init_nas_logging
  capture_prechange_state

  apply_dir_state "${ADMIN_DIR}" root "${ADMIN_GROUP}" 2771 "${enforce}"
  apply_dir_state "${POLICY_DIR}" root "${ADMIN_GROUP}" 0755 "${enforce}"
  apply_dir_state "${IDENTITY_DIR}" root "${ADMIN_GROUP}" 2770 "${enforce}"
  apply_dir_state "${OPERATIONS_DIR}" root "${ADMIN_GROUP}" 2770 "${enforce}"
  apply_dir_state "${AUDIT_DIR}" root "${ADMIN_GROUP}" 2770 "${enforce}"
  apply_dir_state "${SMB_PLAN_DIR}" root "${ADMIN_GROUP}" 2770 "${enforce}"
  apply_dir_state "${MIGRATION_ROOT}" root "${ADMIN_GROUP}" 2770 "${enforce}"
  apply_dir_state "${PROJECTS_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${DATASETS_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${USERS_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${SHARED_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${USERS_OPEN_DIR}" root "${USERS_GROUP}" 2770 "${enforce}"
  apply_dir_state "${ARCHIVE_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${LEGACY_TOP_DIR}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${LEGACY_ROOT}" root "${ADMIN_GROUP}" 2775 "${enforce}"
  apply_dir_state "${DST}" root "${ADMIN_GROUP}" 2770 "${enforce}"

  ensure_registry_headers
  upsert_gid_registry "${ADMIN_GROUP}" "${ADMIN_GID}" core dsm-local-static
  upsert_gid_registry "${USERS_GROUP}" "${USERS_GID}" core dsm-local-static
  upsert_gid_registry "${DATAAPIS_GROUP}" "${DATAAPIS_GID}" core dsm-local-static
  write_policy_docs
  protect_dataapis "${enforce}"

  if [[ ${APPLY_PERMISSIONS} -eq 1 && ${enforce} -eq 1 ]]; then
    cat <<EOF_MARKER | atomic_write "${PERMISSION_MARKER}" root "${ADMIN_GROUP}" 0660
script=${SCRIPT_NAME}
version=${SCRIPT_VERSION}
initialized_utc=$(now_utc)
host=${HOST_SHORT}
admin_group=${ADMIN_GROUP}:${ADMIN_GID}
users_group=${USERS_GROUP}:${USERS_GID}
dataapis_group=${DATAAPIS_GROUP}:${DATAAPIS_GID}
EOF_MARKER
    log "Wrote permission marker: ${PERMISSION_MARKER}"
  fi
}

require_initialized() {
  [[ -d ${ADMIN_DIR} && -d ${PROJECTS_DIR} && -d ${USERS_DIR} && -r ${GID_REGISTRY} ]] \
    || die "NAS2 is not initialized. Run --setup-only first."
}

core_groups_from_registry() {
  [[ -n ${ADMIN_GID} ]] || ADMIN_GID="$(registry_gid "${ADMIN_GROUP}" || true)"
  [[ -n ${USERS_GID} ]] || USERS_GID="$(registry_gid "${USERS_GROUP}" || true)"
  [[ -n ${DATAAPIS_GID} ]] || DATAAPIS_GID="$(registry_gid "${DATAAPIS_GROUP}" || true)"
  sync_core_groups
}

###############################################################################
# User/project provisioning
###############################################################################

path_nonempty() {
  [[ -d $1 ]] && find "$1" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

write_user_smb_plan() {
  local user=$1 classification=$2 path=$3 baseline
  [[ ${classification} == OPEN-READ ]] && baseline="- ${USERS_GROUP}: Read" || baseline="- no ${USERS_GROUP} grant"
  cat <<EOF_PLAN | atomic_write "${SMB_PLAN_DIR}/user-${user}.md" root "${ADMIN_GROUP}" 0660
# Pending DSM ACL: ${path}

Classification: ${classification}
- ${user}: Modify
- ${ADMIN_GROUP}: Full control
${baseline}

Validate through SMB and from both NFS clients.
EOF_PLAN
}

create_user_area() {
  local user=$1
  local path="${USERS_DIR}/${user}" classification group mode readme_mode
  require_local_user "${user}"
  ensure_user_in_group "${user}" "${USERS_GROUP}"

  if [[ ${PRIVATE_USER} -eq 1 ]]; then
    classification=PRIVATE; group="${ADMIN_GROUP}"; mode=2750; readme_mode=0640
  else
    classification=OPEN-READ; group="${USERS_GROUP}"; mode=2755; readme_mode=0644
  fi

  [[ ! -e ${path} || -d ${path} ]] || die "User path is not a directory: ${path}"
  if path_nonempty "${path}" && [[ ${REPAIR_PERMISSIONS} -ne 1 ]]; then
    die "User directory is non-empty; use --repair-permissions only after review: ${path}"
  fi
  mkdir -p -- "${path}"
  chown "${user}:${group}" -- "${path}"; chmod "${mode}" -- "${path}"

  if [[ ! -e ${path}/README.NAS2.txt ]]; then
    cat <<EOF_USER | atomic_write "${path}/README.NAS2.txt" "${user}" "${group}" "${readme_mode}"
NAS2 user area
Owner: ${user}
Classification: ${classification}
Path: ${path}

Readable data: source ${POLICY_DIR}/nas2-user-readable-umask.sh
Private data:  source ${POLICY_DIR}/nas2-private-umask.sh
SMB access additionally requires DSM ACL configuration.
EOF_USER
  fi

  upsert_user_registry "${user}" "${classification}" "${group}" "${path}"
  write_user_smb_plan "${user}" "${classification}" "${path}"
  log "Provisioned ${classification} user area: ${user}:${group} ${mode} ${path}"
}

project_group_name() {
  [[ -n ${PROJECT_GROUP} ]] && printf '%s\n' "${PROJECT_GROUP}" || printf '%s%s\n' "${PROJECT_PREFIX}" "$1"
}

add_project_member_callback() { ensure_user_in_group "$1" "${PROJECT_GROUP}"; }
validate_smb_member_callback() { validate_account_token "$1"; }

write_project_smb_plan() {
  local project=$1 classification=$2 path=$3 baseline
  [[ ${classification} == OPEN-READ ]] && baseline="- ${USERS_GROUP}: Read" || baseline="- no baseline ${USERS_GROUP} grant"
  cat <<EOF_PLAN | atomic_write "${SMB_PLAN_DIR}/project-${project}.md" root "${ADMIN_GROUP}" 0660
# Pending DSM ACL: ${path}

Classification: ${classification}
Project group: ${PROJECT_GROUP}:${PROJECT_GID}
SMB-only members requested: ${PROJECT_SMB_MEMBERS:-none}

- ${ADMIN_GROUP}: Full control
- ${PROJECT_GROUP}: Modify
${baseline}

Do not add a broad Deny for ${USERS_GROUP}; remove unwanted inheritance instead.
Validate create/read/modify/rename/delete through SMB and both NFS clients.
EOF_PLAN
}

create_project_area() {
  local project=$1
  local path="${PROJECTS_DIR}/${project}" classification mode file_mode sub
  local -a subdirs=(metadata raw staging processed outputs reports archive)
  validate_project_name "${project}"
  [[ -n ${PROJECT_OWNER} ]] || die "--create-project requires --owner."
  validate_account_token "${PROJECT_OWNER}"

  PROJECT_GROUP="$(project_group_name "${project}")"
  validate_group_name "${PROJECT_GROUP}"
  reject_core_project_group "${PROJECT_GROUP}"
  [[ -n ${PROJECT_GID} ]] || PROJECT_GID="$(registry_gid "${PROJECT_GROUP}" || true)"
  ensure_group_exact "${PROJECT_GROUP}" "${PROJECT_GID}" "project ${project}"
  PROJECT_GID="$(group_gid "${PROJECT_GROUP}")"
  upsert_gid_registry "${PROJECT_GROUP}" "${PROJECT_GID}" project dsm-local-static

  [[ -z ${ADMIN_USER} ]] || ensure_user_in_group "${ADMIN_USER}" "${PROJECT_GROUP}"
  if getent passwd "${PROJECT_OWNER}" >/dev/null 2>&1; then
    ensure_user_in_group "${PROJECT_OWNER}" "${PROJECT_GROUP}"
  else
    warn "Project owner ${PROJECT_OWNER} is recorded as a contact/DSM identity only."
  fi
  csv_each "${PROJECT_MEMBERS}" add_project_member_callback
  csv_each "${PROJECT_SMB_MEMBERS}" validate_smb_member_callback

  if [[ ${PROJECT_RESTRICTED} -eq 1 ]]; then
    classification=RESTRICTED; mode=2770; file_mode=0660
  else
    classification=OPEN-READ; mode=2775; file_mode=0664
  fi

  [[ ! -e ${path} || -d ${path} ]] || die "Project path is not a directory: ${path}"
  if path_nonempty "${path}" && [[ ${REPAIR_PERMISSIONS} -ne 1 ]]; then
    die "Project directory is non-empty; refusing to overwrite/reclassify: ${path}"
  fi
  mkdir -p -- "${path}"
  chown root:"${PROJECT_GROUP}" -- "${path}"; chmod "${mode}" -- "${path}"
  for sub in "${subdirs[@]}"; do
    mkdir -p -- "${path}/${sub}"
    chown root:"${PROJECT_GROUP}" -- "${path}/${sub}"
    chmod "${mode}" -- "${path}/${sub}"
  done

  if [[ ! -e ${path}/README.md && ! -L ${path}/README.md ]]; then
    cat <<EOF_PROJECT | atomic_write "${path}/README.md" root "${PROJECT_GROUP}" "${file_mode}"
# ${project}

- Classification: ${classification}
- Owner/contact: ${PROJECT_OWNER}
- Project group: ${PROJECT_GROUP}
- Numeric GID: ${PROJECT_GID}
- Local NFS members at provisioning: ${PROJECT_MEMBERS:-none}
- SMB-only members to add in DSM: ${PROJECT_SMB_MEMBERS:-none}
- Created UTC: $(now_utc)

Directories: metadata, raw, staging, processed, outputs, reports, archive.
Before collaborative Linux writes:
  source ${POLICY_DIR}/nas2-project-umask.sh
EOF_PROJECT
  else
    log "Preserved existing project README without modification: ${path}/README.md"
  fi

  upsert_project_registry "${project}" "${PROJECT_GROUP}" "${PROJECT_GID}" "${classification}" \
    "${PROJECT_OWNER}" "${PROJECT_MEMBERS}" "${PROJECT_SMB_MEMBERS}"
  write_project_smb_plan "${project}" "${classification}" "${path}"
  log "Provisioned ${classification} project: root:${PROJECT_GROUP} ${mode} ${path}"
}

sync_project_group_only() {
  local project=$1
  validate_project_name "${project}"
  PROJECT_GROUP="$(project_group_name "${project}")"
  validate_group_name "${PROJECT_GROUP}"
  reject_core_project_group "${PROJECT_GROUP}"
  if [[ -z ${PROJECT_GID} && -r ${GID_REGISTRY} ]]; then PROJECT_GID="$(registry_gid "${PROJECT_GROUP}" || true)"; fi
  ensure_group_exact "${PROJECT_GROUP}" "${PROJECT_GID}" "project ${project}"
  PROJECT_GID="$(group_gid "${PROJECT_GROUP}")"
  [[ -z ${ADMIN_USER} ]] || ensure_user_in_group "${ADMIN_USER}" "${PROJECT_GROUP}"
  csv_each "${PROJECT_MEMBERS}" add_project_member_callback
  log "Synchronized ${PROJECT_GROUP}:${PROJECT_GID} on ${HOST_SHORT}."
}

lookup_project_group() {
  local project=$1 found
  validate_project_name "${project}"
  found="$(project_field "${project}" 2 || true)"
  if [[ -n ${found} ]]; then PROJECT_GROUP="${found}"; else PROJECT_GROUP="$(project_group_name "${project}")"; fi
  reject_core_project_group "${PROJECT_GROUP}"
  getent group "${PROJECT_GROUP}" >/dev/null 2>&1 || die "Project group missing locally: ${PROJECT_GROUP}"
}

csv_add_unique() {
  local csv=$1 value=$2 item out="" found=0
  local -a items=()
  [[ -z ${csv} ]] || IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    [[ -n ${item} ]] || continue
    [[ ${item} == "${value}" ]] && found=1
    out+="${out:+,}${item}"
  done
  [[ ${found} -eq 1 ]] || out+="${out:+,}${value}"
  printf '%s\n' "${out}"
}

csv_remove_value() {
  local csv=$1 value=$2 item out=""
  local -a items=()
  [[ -z ${csv} ]] || IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    [[ -n ${item} && ${item} != "${value}" ]] || continue
    out+="${out:+,}${item}"
  done
  printf '%s\n' "${out}"
}

update_project_local_member_registry() {
  local project=$1 user=$2 action=$3 group gid classification owner locals smbs updated
  [[ -r ${PROJECT_REGISTRY} ]] || { warn "Project registry is unavailable; local group membership changed but registry was not updated."; return 0; }
  group="$(project_field "${project}" 2 || true)"
  [[ -n ${group} ]] || { warn "Project ${project} is not registered; local group membership changed but registry was not updated."; return 0; }
  gid="$(project_field "${project}" 3)"
  classification="$(project_field "${project}" 4)"
  owner="$(project_field "${project}" 5)"
  locals="$(project_field "${project}" 6)"
  smbs="$(project_field "${project}" 7)"
  case "${action}" in
    add) updated="$(csv_add_unique "${locals}" "${user}")" ;;
    remove) updated="$(csv_remove_value "${locals}" "${user}")" ;;
    *) die "Internal registry action error: ${action}" ;;
  esac
  upsert_project_registry "${project}" "${group}" "${gid}" "${classification}" "${owner}" "${updated}" "${smbs}"
  log "Updated project registry local members for ${project}: ${updated:-none}"
}

###############################################################################
# Migration
###############################################################################

build_top_level_list() {
  mkdir -p -- "${OP_MANIFEST_DIR}"
  if [[ ${COPY_RECYCLE} -eq 1 ]]; then
    (cd "${SRC}" && find . -mindepth 1 -maxdepth 1 -printf '/%P\0') > "${TOP_LEVEL_LIST}"
  else
    (cd "${SRC}" && find . -mindepth 1 -maxdepth 1 ! -name '#recycle' -printf '/%P\0') > "${TOP_LEVEL_LIST}"
    if [[ -e ${DST}/#recycle ]]; then
      warn "--skip-recycle ignores but does not delete the existing destination ${DST}/#recycle. Quarantine or remove it only after retention review."
    fi
  fi
  chown root:"${ADMIN_GROUP}" -- "${TOP_LEVEL_LIST}"; chmod 0660 -- "${TOP_LEVEL_LIST}"
  log "Captured NUL-safe top-level source list: ${TOP_LEVEL_LIST}"
}

load_rsync_common_flags() {
  local -n out=$1
  out=(--archive --recursive --hard-links --numeric-ids --sparse --one-file-system --protect-args \
    --partial --partial-dir=.rsync-partial)
  [[ ${PRESERVE_XATTRS} -eq 1 ]] && out+=(--xattrs)
  [[ ${PRESERVE_POSIX_ACLS} -eq 1 ]] && out+=(--acls)
  [[ ${COPY_RECYCLE} -eq 0 ]] && out+=("--exclude=/#recycle" "--exclude=/#recycle/***")
  return 0
}

write_source_reports() {
  local summary="${OP_REPORT_DIR}/source-summary.txt" top="${OP_REPORT_DIR}/source-top-level.tsv" inv="${OP_MANIFEST_DIR}/source-inventory.tsv"
  {
    printf 'run_id=%s\nhost=%s\nsource=%s\ndestination=%s\n' "${RUN_ID}" "${HOST_SHORT}" "${SRC}" "${DST}"
    printf 'source_mount=%s\ndestination_mount=%s\n' "$(mount_description "${SRC}")" "$(mount_description "${DST_ROOT}")"
    printf '\nsource_df:\n'; df -h -- "${SRC}"
    printf '\ndestination_df:\n'; df -h -- "${DST_ROOT}"
    printf '\ndestination_inodes:\n'; df -Pi -- "${DST_ROOT}" || true
    printf '\nsource_du_bytes:\n'; du -sx --block-size=1 -- "${SRC}" 2>/dev/null || true
  } > "${summary}"
  find "${SRC}" -mindepth 1 -maxdepth 1 -printf '%M\t%u\t%g\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' 2>/dev/null | sort > "${top}"
  find "${SRC}" -xdev -printf '%P\t%y\t%s\t%U\t%G\t%m\t%T@\n' 2>/dev/null | sort > "${inv}"
  chown root:"${ADMIN_GROUP}" -- "${summary}" "${top}" "${inv}"; chmod 0660 -- "${summary}" "${top}" "${inv}"
  log "Wrote source reports and inventory."
}

probe_destination_capabilities() {
  local f h s uid
  PROBE_DIR="${DST_ROOT}/.nas2-v2-capability.${RUN_ID}"
  mkdir -- "${PROBE_DIR}"; chmod 0700 -- "${PROBE_DIR}"
  f="${PROBE_DIR}/file"; h="${PROBE_DIR}/hardlink"; s="${PROBE_DIR}/symlink"
  : > "${f}"
  uid="$(stat -c '%u' -- "${f}")"
  [[ ${uid} -eq 0 ]] || die "Destination root-squashes UID 0 (probe UID ${uid}); numeric ownership cannot be preserved safely."
  chown 65534:65534 -- "${f}" || die "Destination rejects arbitrary numeric ownership changes required by rsync --numeric-ids."
  [[ $(stat -c '%u:%g' -- "${f}") == "65534:65534" ]] || die "Destination did not retain the numeric ownership probe."
  chown 0:0 -- "${f}" || die "Destination cannot restore root ownership after the numeric ownership probe."
  chmod 0640 -- "${f}"; touch -m -d '2001-02-03 04:05:06 UTC' -- "${f}"
  ln -- "${f}" "${h}"; ln -s -- file "${s}"

  if [[ ${PRESERVE_XATTRS} -eq 1 ]]; then
    require_command setfattr; require_command getfattr
    setfattr -n user.nas2_probe -v supported -- "${f}" || die "xattr probe failed."
    [[ $(getfattr --only-values -n user.nas2_probe -- "${f}" 2>/dev/null) == supported ]] || die "xattr read-back failed."
  fi
  if [[ ${PRESERVE_POSIX_ACLS} -eq 1 ]]; then
    require_command setfacl; require_command getfacl
    setfacl -m u:0:rw- -- "${f}" || die "POSIX ACL probe failed; manage DSM ACLs server-side."
    getfacl -cp -- "${f}" >/dev/null || die "POSIX ACL read-back failed."
  fi

  rm -rf -- "${PROBE_DIR}"; PROBE_DIR=""
  log "Destination capability probe passed."
}

estimate_transfer() {
  local -a flags=(); local stats="${OP_REPORT_DIR}/rsync-estimate-stats.txt" parsed
  load_rsync_common_flags flags
  rsync "${flags[@]}" --dry-run --stats --out-format='' --from0 --files-from="${TOP_LEVEL_LIST}" \
    "${SRC}/" "${DST}/" > "${stats}"
  parsed="$(awk -F': ' '/^Total transferred file size:/ {gsub(/,/,"",$2); sub(/ bytes.*/,"",$2); print $2; exit}' "${stats}")"
  [[ ${parsed} =~ ^[0-9]+$ ]] || die "Could not parse transfer estimate: ${stats}"
  ESTIMATED_TRANSFER_BYTES="${parsed}"
  chown root:"${ADMIN_GROUP}" -- "${stats}"; chmod 0660 -- "${stats}"
  log "Estimated transfer: ${ESTIMATED_TRANSFER_BYTES} bytes."
}

check_free_space() {
  local free headroom required
  free="$(df -PB1 -- "${DST_ROOT}" | awk 'NR==2{print $4}')"
  [[ ${free} =~ ^[0-9]+$ ]] || die "Could not read destination free space."
  headroom=$(( ESTIMATED_TRANSFER_BYTES * SPACE_HEADROOM_PERCENT / 100 ))
  (( headroom >= 1073741824 )) || headroom=1073741824
  required=$(( ESTIMATED_TRANSFER_BYTES + headroom ))
  {
    printf 'estimated_transfer_bytes=%s\nheadroom_bytes=%s\nrequired_free_bytes=%s\navailable_bytes=%s\n' \
      "${ESTIMATED_TRANSFER_BYTES}" "${headroom}" "${required}" "${free}"
  } > "${OP_REPORT_DIR}/space-check.txt"
  chown root:"${ADMIN_GROUP}" -- "${OP_REPORT_DIR}/space-check.txt"; chmod 0660 -- "${OP_REPORT_DIR}/space-check.txt"
  (( free >= required )) || die "Insufficient free space: need ${required}, have ${free} bytes."
  log "Free-space check passed."
}

run_rsync_dry() {
  local -a flags=(); local out="${OP_LOG_DIR}/rsync-dry-run.log"
  load_rsync_common_flags flags
  log "Starting recursive rsync dry run."
  rsync "${flags[@]}" --dry-run --human-readable --info=progress2,stats2 --itemize-changes \
    --from0 --files-from="${TOP_LEVEL_LIST}" "${SRC}/" "${DST}/" | tee "${out}"
  chown root:"${ADMIN_GROUP}" -- "${out}"; chmod 0660 -- "${out}"
  log "Dry-run log: ${out}"
}

run_rsync_copy() {
  local -a flags=(); local out="${OP_LOG_DIR}/rsync-copy.log" marker="${LEGACY_ROOT}/.migration-incomplete"
  load_rsync_common_flags flags
  cat <<EOF_MARK | atomic_write "${marker}" root "${ADMIN_GROUP}" 0660
run_id=${RUN_ID}
started_utc=$(now_utc)
source=${SRC}
destination=${DST}
host=${HOST_SHORT}
EOF_MARK
  chown root:"${ADMIN_GROUP}" -- "${DST}"; chmod 2770 -- "${DST}"
  log "Starting real recursive rsync; destination remains admin-only."
  rsync "${flags[@]}" --human-readable --info=progress2,stats2 --itemize-changes \
    --from0 --files-from="${TOP_LEVEL_LIST}" "${SRC}/" "${DST}/" | tee "${out}"
  chown root:"${ADMIN_GROUP}" -- "${out}"; chmod 0660 -- "${out}"
  if command_exists sync; then sync -f "${DST}" 2>/dev/null || sync; fi
  log "Rsync copy and filesystem flush completed."
}

quick_verify() {
  local checksum=${1:-0} raw="${OP_LOG_DIR}/verify-rsync-raw.log" diff="${OP_LOG_DIR}/verify-rsync-differences.log"
  local -a flags=(--archive --hard-links --numeric-ids --sparse --one-file-system --protect-args \
    --dry-run --delete --itemize-changes '--out-format=%i|%n%L')
  [[ ${PRESERVE_XATTRS} -eq 1 ]] && flags+=(--xattrs)
  [[ ${PRESERVE_POSIX_ACLS} -eq 1 ]] && flags+=(--acls)
  [[ ${checksum} -eq 1 ]] && flags+=(--checksum)
  [[ ${COPY_RECYCLE} -eq 0 ]] && flags+=("--exclude=/#recycle" "--exclude=/#recycle/***")

  log "Running $([[ ${checksum} -eq 1 ]] && printf checksum || printf quick) rsync verification."
  rsync "${flags[@]}" "${SRC}/" "${DST}/" > "${raw}"
  awk -F'|' '$2 != "./"' "${raw}" > "${diff}"
  chown root:"${ADMIN_GROUP}" -- "${raw}" "${diff}"; chmod 0660 -- "${raw}" "${diff}"
  if [[ -s ${diff} ]]; then error "Verification differences: ${diff}"; return 1; fi
  log "Rsync verification found no differences."
}

checksum_file_list() {
  local root=$1
  if [[ ${COPY_RECYCLE} -eq 1 ]]; then
    (cd "${root}" && find . -xdev -type f ! -path '*/.rsync-partial/*' -print0 | sort -z)
  else
    (cd "${root}" && find . -xdev \( -path './#recycle' -o -path './#recycle/*' \) -prune -o \
      -type f ! -path '*/.rsync-partial/*' -print0 | sort -z)
  fi
}

generate_checksum_manifest() {
  local root=$1 out=$2
  log "Generating SHA-256 manifest for ${root}; this can be very slow."
  checksum_file_list "${root}" | (cd "${root}" && xargs -0 -r sha256sum --binary --zero) > "${out}"
  chown root:"${ADMIN_GROUP}" -- "${out}"; chmod 0660 -- "${out}"
}

verify_checksums() {
  local s="${OP_MANIFEST_DIR}/source-sha256.nul" d="${OP_MANIFEST_DIR}/destination-sha256.nul"
  generate_checksum_manifest "${SRC}" "${s}"
  generate_checksum_manifest "${DST}" "${d}"
  cmp -s -- "${s}" "${d}" || { error "SHA-256 manifests differ."; return 1; }
  log "SHA-256 manifests are identical."
}

publish_migration() {
  local incomplete="${LEGACY_ROOT}/.migration-incomplete" complete="${LEGACY_ROOT}/.migration-complete-${RUN_ID}" hash=unavailable
  if command_exists sha256sum && [[ -r $0 ]]; then hash="$(sha256sum -- "$0" | awk '{print $1}')"; fi
  cat <<EOF_DONE | atomic_write "${complete}" root "${ADMIN_GROUP}" 0644
run_id=${RUN_ID}
completed_utc=$(now_utc)
source=${SRC}
destination=${DST}
host=${HOST_SHORT}
script_version=${SCRIPT_VERSION}
script_sha256=${hash}
checksums=$([[ ${MAKE_CHECKSUMS} -eq 1 || ${VERIFY_CHECKSUM} -eq 1 ]] && printf verified || printf not-requested)
EOF_DONE
  rm -f -- "${incomplete}"
  chown root:"${ADMIN_GROUP}" -- "${DST}"; chmod 2755 -- "${DST}"
  log "Published verified legacy data read-only: ${DST}"
}

###############################################################################
# Audit and preflight
###############################################################################

audit_ok() { printf 'OK\t%s\n' "$*"; }
audit_warn() { AUDIT_WARNINGS=$((AUDIT_WARNINGS + 1)); printf 'WARN\t%s\n' "$*"; }
audit_error() { AUDIT_ERRORS=$((AUDIT_ERRORS + 1)); printf 'ERROR\t%s\n' "$*"; }

audit_path() {
  local path=$1 expected_group=${2:-} expected_mode=${3:-} mode group
  if [[ ! -e ${path} ]]; then audit_error "Missing path: ${path}"; return; fi
  mode="$(stat -c '%a' -- "${path}")"; group="$(stat -c '%G' -- "${path}")"
  printf 'PATH\t%s\tmode=%s\towner=%s\tgroup=%s\n' "${path}" "${mode}" "$(stat -c '%U' -- "${path}")" "${group}"
  [[ -z ${expected_group} || ${group} == "${expected_group}" ]] || audit_warn "${path}: expected group ${expected_group}, got ${group}."
  [[ -z ${expected_mode} || ${mode} == "${expected_mode#0}" ]] || audit_warn "${path}: expected mode ${expected_mode}, got ${mode}."
}

run_audit() {
  local tmp="${BOOT_LOG}.audit" root_mode name gid recorded project group pgid classification path actual
  AUDIT_WARNINGS=0; AUDIT_ERRORS=0

  {
    printf '# NAS2 audit\ntimestamp_utc\t%s\nhost\t%s\nscript_version\t%s\n' "$(now_utc)" "${HOST_SHORT}" "${SCRIPT_VERSION}"
    printf 'destination_mount\t%s\n' "$(mount_description "${DST_ROOT}")"
    [[ ! -d ${SRC} ]] || printf 'source_mount\t%s\n' "$(mount_description "${SRC}")"

    root_mode="$(stat -c '%a' -- "${DST_ROOT}")"
    if mode_has_group_or_other_write "${root_mode}"; then
      if [[ ${ALLOW_INSECURE_ROOT} -eq 1 ]]; then
        audit_warn "NAS2 root is group/world writable (${root_mode}); explicit override supplied. Accept this only after an ordinary-user create test proves DSM ACLs block unauthorized top-level creation."
      else
        audit_error "NAS2 root is group/world writable: ${root_mode}."
      fi
    else
      audit_ok "NAS2 root mode ${root_mode}."
    fi

    for name in "${ADMIN_GROUP}" "${USERS_GROUP}" "${DATAAPIS_GROUP}"; do
      if getent group "${name}" >/dev/null 2>&1; then
        gid="$(group_gid "${name}")"; audit_ok "Local group ${name}:${gid}."
        if [[ -r ${GID_REGISTRY} ]]; then
          recorded="$(registry_gid "${name}" || true)"
          [[ -z ${recorded} || ${recorded} == "${gid}" ]] || audit_error "GID drift ${name}: local ${gid}, registry ${recorded}."
        fi
      else audit_error "Missing local group ${name}."; fi
    done

    if [[ -n ${ADMIN_USER} ]] && getent passwd "${ADMIN_USER}" >/dev/null 2>&1; then
      printf 'ADMIN_USER\t%s\tuid=%s\tgroups=%s\n' \
        "${ADMIN_USER}" "$(id -u "${ADMIN_USER}")" "$(id -nG "${ADMIN_USER}")"
    fi

    audit_path "${ADMIN_DIR}" "${ADMIN_GROUP}" 2771
    audit_path "${POLICY_DIR}" "${ADMIN_GROUP}" 0755
    audit_path "${PROJECTS_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${DATASETS_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${USERS_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${SHARED_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${USERS_OPEN_DIR}" "${USERS_GROUP}" 2770
    audit_path "${ARCHIVE_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${LEGACY_TOP_DIR}" "${ADMIN_GROUP}" 2775
    audit_path "${LEGACY_ROOT}" "${ADMIN_GROUP}" 2775

    for path in "${PROTECTED_DIRS[@]}"; do
      if [[ -e ${path} ]]; then
        printf 'PROTECTED\t%s\tmode=%s\towner=%s\tgroup=%s\n' "${path}" "$(stat -c '%a' -- "${path}")" "$(stat -c '%U' -- "${path}")" "$(stat -c '%G' -- "${path}")"
        mode_has_group_or_other_write "$(stat -c '%a' -- "${path}")" && audit_warn "Protected path has group/other write bits: ${path}"
      else audit_warn "Protected path missing: ${path}"; fi
    done

    if [[ -r ${PROJECT_REGISTRY} ]]; then
      while IFS=$'\t' read -r project group pgid classification _; do
        [[ ${project} == project || -z ${project} ]] && continue
        if getent group "${group}" >/dev/null 2>&1; then
          actual="$(group_gid "${group}")"
          [[ ${actual} == "${pgid}" ]] && audit_ok "Project ${project}: ${group}:${pgid} ${classification}." \
            || audit_error "Project GID drift ${project}: ${group} local ${actual}, registry ${pgid}."
        else audit_error "Missing project group ${group}:${pgid}."; fi
        path="${PROJECTS_DIR}/${project}"
        if [[ -d ${path} ]]; then
          local project_mode
          project_mode="$(stat -c '%a' -- "${path}")"
          (( (8#${project_mode} & 2000) != 0 )) || audit_error "Project lacks setgid: ${path}"
          [[ $(stat -c '%g' -- "${path}") == "${pgid}" ]] || audit_warn "Project directory GID differs: ${path}"
        else audit_error "Missing project directory: ${path}"; fi
      done < "${PROJECT_REGISTRY}"
    else audit_warn "Project registry missing: ${PROJECT_REGISTRY}"; fi

    while IFS= read -r -d '' path; do audit_warn "World-writable managed directory: ${path}"; done \
      < <(find "${ADMIN_DIR}" "${PROJECTS_DIR}" "${DATASETS_DIR}" "${USERS_DIR}" "${SHARED_DIR}" "${ARCHIVE_DIR}" "${LEGACY_TOP_DIR}" \
        -xdev -maxdepth 2 -type d -perm -0002 -print0 2>/dev/null || true)

    audit_warn "POSIX setfacl is not used; DSM ACLs must be administered server-side for SMB."
    printf 'SUMMARY\twarnings=%s\terrors=%s\n' "${AUDIT_WARNINGS}" "${AUDIT_ERRORS}"
  } > "${tmp}"

  cat "${tmp}"
  if [[ -d ${AUDIT_DIR} && -w ${AUDIT_DIR} ]]; then
    local final="${AUDIT_DIR}/audit-${RUN_ID}.txt"
    cp -- "${tmp}" "${final}"; chown root:"${ADMIN_GROUP}" -- "${final}" 2>/dev/null || true; chmod 0660 -- "${final}" 2>/dev/null || true
    log "Saved audit: ${final}"
  fi
  (( AUDIT_ERRORS == 0 )) || return 2
}

run_preflight() {
  require_mountpoint_path "Destination" "${DST_ROOT}"
  require_mountpoint_path "Source" "${SRC}"
  check_paths_not_nested
  check_mount_root_security warn || true
  printf 'Destination mount: %s\n' "$(mount_description "${DST_ROOT}")"
  printf 'Source mount:      %s\n' "$(mount_description "${SRC}")"
  printf 'Source read-only:  %s\n' "$(mount_is_readonly "${SRC}" && printf yes || printf no)"
  printf 'Destination mode:  %s\n' "$(stat -c '%a %U:%G' -- "${DST_ROOT}")"
  printf 'rsync version:     %s\n' "$(rsync --version | sed -n '1p')"
  preflight_core_groups
  write_probe
  probe_destination_capabilities
  log "Preflight completed without persistent group or NAS changes."
}

###############################################################################
# Argument parsing
###############################################################################

if [[ $# -eq 0 ]]; then usage; exit 0; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) set_mode preflight; shift;;
    --setup-only) set_mode setup; shift;;
    --sync-groups-only) set_mode sync-groups; shift;;
    --audit) set_mode audit; shift;;
    --add-nas-user) require_value "$1" "${2:-}"; set_mode add-nas-user "$2"; shift 2;;
    --remove-nas-user) require_value "$1" "${2:-}"; set_mode remove-nas-user "$2"; shift 2;;
    --create-user) require_value "$1" "${2:-}"; set_mode create-user "$2"; shift 2;;
    --create-project) require_value "$1" "${2:-}"; set_mode create-project "$2"; shift 2;;
    --sync-project-group) require_value "$1" "${2:-}"; set_mode sync-project-group "$2"; shift 2;;
    --add-project-member) require_value "$1" "${2:-}"; require_value "$1" "${3:-}"; set_mode add-project-member "$2" "$3"; shift 3;;
    --remove-project-member) require_value "$1" "${2:-}"; require_value "$1" "${3:-}"; set_mode remove-project-member "$2" "$3"; shift 3;;
    --dry-run) set_mode dry-run; shift;;
    --run) set_mode run; shift;;
    --verify-only) set_mode verify; shift;;
    --admin-user) require_value "$1" "${2:-}"; ADMIN_USER=$2; shift 2;;
    --admin-group) require_value "$1" "${2:-}"; ADMIN_GROUP=$2; shift 2;;
    --admin-gid) require_value "$1" "${2:-}"; ADMIN_GID=$2; shift 2;;
    --users-group) require_value "$1" "${2:-}"; USERS_GROUP=$2; shift 2;;
    --users-gid) require_value "$1" "${2:-}"; USERS_GID=$2; shift 2;;
    --dataapis-group) require_value "$1" "${2:-}"; DATAAPIS_GROUP=$2; shift 2;;
    --dataapis-gid) require_value "$1" "${2:-}"; DATAAPIS_GID=$2; shift 2;;
    --dataapis-service-user) require_value "$1" "${2:-}"; DATAAPIS_SERVICE_USER=$2; shift 2;;
    --adopt-dataapis) ADOPT_DATAAPIS=1; shift;;
    --dataapis-group-write) DATAAPIS_GROUP_WRITE=1; shift;;
    --owner) require_value "$1" "${2:-}"; PROJECT_OWNER=$2; shift 2;;
    --members) require_value "$1" "${2:-}"; PROJECT_MEMBERS=$2; shift 2;;
    --smb-members) require_value "$1" "${2:-}"; PROJECT_SMB_MEMBERS=$2; shift 2;;
    --project-gid) require_value "$1" "${2:-}"; PROJECT_GID=$2; shift 2;;
    --project-group) require_value "$1" "${2:-}"; PROJECT_GROUP=$2; shift 2;;
    --restricted-project) PROJECT_RESTRICTED=1; shift;;
    --private-user) PRIVATE_USER=1; shift;;
    --checksums) MAKE_CHECKSUMS=1; shift;;
    --verify-checksum) VERIFY_CHECKSUM=1; shift;;
    --skip-recycle) COPY_RECYCLE=0; shift;;
    --preserve-xattrs) PRESERVE_XATTRS=1; shift;;
    --preserve-posix-acls) PRESERVE_POSIX_ACLS=1; shift;;
    --allow-rw-source) ALLOW_RW_SOURCE=1; shift;;
    --space-headroom-percent) require_value "$1" "${2:-}"; SPACE_HEADROOM_PERCENT=$2; shift 2;;
    --repair-permissions) REPAIR_PERMISSIONS=1; shift;;
    --no-permissions) APPLY_PERMISSIONS=0; shift;;
    --harden-root-posix) HARDEN_ROOT_POSIX=1; shift;;
    --allow-insecure-root) ALLOW_INSECURE_ROOT=1; shift;;
    --source) require_value "$1" "${2:-}"; SRC=$2; shift 2;;
    --destination-root) require_value "$1" "${2:-}"; DST_ROOT=$2; shift 2;;
    --version) printf '%s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0;;
    --help|-h) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

[[ -n ${MODE} ]] || die "No operation selected."
validate_group_name "${ADMIN_GROUP}"; validate_group_name "${USERS_GROUP}"; validate_group_name "${DATAAPIS_GROUP}"
[[ -z ${ADMIN_GID} ]] || { validate_gid --admin-gid "${ADMIN_GID}"; ADMIN_GID=$((10#${ADMIN_GID})); }
[[ -z ${USERS_GID} ]] || { validate_gid --users-gid "${USERS_GID}"; USERS_GID=$((10#${USERS_GID})); }
[[ -z ${DATAAPIS_GID} ]] || { validate_gid --dataapis-gid "${DATAAPIS_GID}"; DATAAPIS_GID=$((10#${DATAAPIS_GID})); }
[[ -z ${PROJECT_GID} ]] || { validate_gid --project-gid "${PROJECT_GID}"; PROJECT_GID=$((10#${PROJECT_GID})); }
validate_percent "${SPACE_HEADROOM_PERCENT}"
SPACE_HEADROOM_PERCENT=$((10#${SPACE_HEADROOM_PERCENT}))
validate_core_identity_separation
derive_paths

###############################################################################
# Requirements and dispatch
###############################################################################

for cmd in awk basename cat chmod chown cmp cp date df dirname du find getent grep hostname id ln mkdir mktemp mountpoint mv readlink rm sed sort stat tee touch tr; do require_command "${cmd}"; done

case "${MODE}" in
  preflight|setup|sync-groups|create-user|create-project|sync-project-group|add-project-member|remove-project-member|add-nas-user|remove-nas-user)
    require_command groupadd; require_command usermod; require_command gpasswd;;
esac
case "${MODE}" in preflight|dry-run|run|verify) require_command rsync; require_command findmnt;; esac
if [[ ${MAKE_CHECKSUMS} -eq 1 || ${VERIFY_CHECKSUM} -eq 1 ]]; then require_command sha256sum; require_command xargs; fi

case "${MODE}" in
  sync-groups)
    require_root; acquire_lock; sync_core_groups
    printf '\nCore groups on %s:\n  %s:%s\n  %s:%s\n  %s:%s\n\n' "${HOST_SHORT}" \
      "${ADMIN_GROUP}" "$(group_gid "${ADMIN_GROUP}")" "${USERS_GROUP}" "$(group_gid "${USERS_GROUP}")" \
      "${DATAAPIS_GROUP}" "$(group_gid "${DATAAPIS_GROUP}")"
    ;;

  preflight)
    require_root; acquire_lock; run_preflight
    ;;

  setup)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"
    check_mount_root_security enforce; write_probe; sync_core_groups; create_base_structure
    printf '\nSetup complete. Runbook: %s\nGID registry: %s\nRun --sync-groups-only on C1, then --audit and --dry-run.\n\n' \
      "${POLICY_DIR}/SMB-NO-LDAP-RUNBOOK.md" "${GID_REGISTRY}"
    ;;

  audit)
    require_root; require_mountpoint_path Destination "${DST_ROOT}"
    if run_audit; then :; else rc=$?; [[ ${rc} -eq 2 ]] && exit 2; exit "${rc}"; fi
    ;;

  add-nas-user)
    require_root; acquire_lock; ensure_user_in_group "${MODE_ARG1}" "${USERS_GROUP}"
    ;;

  remove-nas-user)
    require_root; acquire_lock
    [[ -z ${ADMIN_USER} || ${MODE_ARG1} != "${ADMIN_USER}" ]]       || die "Refusing to remove the configured storage administrator ${ADMIN_USER} from ${USERS_GROUP}."
    remove_user_from_group "${MODE_ARG1}" "${USERS_GROUP}"
    ;;

  create-user)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"; check_mount_root_security enforce
    require_initialized; init_nas_logging; core_groups_from_registry; create_user_area "${MODE_ARG1}"
    ;;

  create-project)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"; check_mount_root_security enforce
    require_initialized; init_nas_logging; core_groups_from_registry; create_project_area "${MODE_ARG1}"
    ;;

  sync-project-group)
    require_root; acquire_lock; sync_project_group_only "${MODE_ARG1}"
    ;;

  add-project-member)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"; require_initialized
    lookup_project_group "${MODE_ARG1}"; ensure_user_in_group "${MODE_ARG2}" "${PROJECT_GROUP}"
    update_project_local_member_registry "${MODE_ARG1}" "${MODE_ARG2}" add
    ;;

  remove-project-member)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"; require_initialized
    [[ -z ${ADMIN_USER} || ${MODE_ARG2} != "${ADMIN_USER}" ]]       || die "Refusing to remove the configured storage administrator ${ADMIN_USER} from a managed project group."
    lookup_project_group "${MODE_ARG1}"; remove_user_from_group "${MODE_ARG2}" "${PROJECT_GROUP}"
    update_project_local_member_registry "${MODE_ARG1}" "${MODE_ARG2}" remove
    ;;

  dry-run|run|verify)
    require_root; acquire_lock; require_mountpoint_path Destination "${DST_ROOT}"; require_mountpoint_path Source "${SRC}"
    check_paths_not_nested; check_mount_root_security enforce; require_initialized; init_nas_logging; core_groups_from_registry
    mkdir -p -- "${DST}"; build_top_level_list

    if [[ ${MODE} == verify ]]; then
      quick_verify "${VERIFY_CHECKSUM}" || exit 1
      [[ ${VERIFY_CHECKSUM} -eq 0 ]] || verify_checksums || exit 1
      log "Verification-only operation succeeded."
      exit 0
    fi

    write_source_reports; run_rsync_dry
    if [[ ${MODE} == dry-run ]]; then log "Dry run complete; no source data copied."; exit 0; fi

    check_source_readonly_for_run; probe_destination_capabilities; estimate_transfer; check_free_space; run_rsync_copy
    quick_verify 0 || die "Post-copy verification failed; incomplete marker retained."
    [[ ${VERIFY_CHECKSUM} -eq 0 ]] || quick_verify 1 || die "Checksum-mode rsync verification failed."
    if [[ ${MAKE_CHECKSUMS} -eq 1 || ${VERIFY_CHECKSUM} -eq 1 ]]; then verify_checksums || die "SHA-256 verification failed."; fi
    publish_migration; log "Migration completed and verified."
    ;;

  *) die "Unhandled mode: ${MODE}";;
esac

exit 0
