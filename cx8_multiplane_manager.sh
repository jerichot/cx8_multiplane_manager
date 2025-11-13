#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# ConnectX8 SMI manager + OpenSM launcher
#
# This script combines:
#   1) cx8_smi_mgr.sh
#      - Detect all ConnectX8 devices from `mst status -v`
#      - Ensure one SMI per ConnectX8 mlx5_N named smiN
#      - Optional deletion / recreation of existing SMI devices
#      - Optional status table of all SMI devices (parent + ibstat state)
#
#   2) run_opensm_on_smis.sh
#      - For a list of SMI devices, start opensm per Port GUID (one daemon
#        per GUID) and verify that all ports are Active.
#      - Logs are written under: ./<script_name>_<YYYYmmdd-HHMMSS>/
#
# Usage examples (see more at bottom of file):
#   sudo ./cx8_smi_opensm_mgr.sh
#   sudo ./cx8_smi_opensm_mgr.sh --smi-status
#   sudo ./cx8_smi_opensm_mgr.sh --recreate-smi
#   sudo ./cx8_smi_opensm_mgr.sh --select-smi
#   sudo ./cx8_smi_opensm_mgr.sh --run-opensm
#   sudo ./cx8_smi_opensm_mgr.sh --run-opensm --no-require-active
#   sudo ./cx8_smi_opensm_mgr.sh --recreate-smi --run-opensm --smi-status
#
# Options:
#   --dry-run          : Print rdma/opensm commands but do not execute them
#   --recreate-smi     : Delete ALL existing SMI devices, then recreate
#                        canonical smiN for ConnectX8 parents
#   --select-smi       : Interactively select which SMI devices to delete
#                        (single/multiple/all), then recreate canonical
#                        smiN for ConnectX8 parents
#   --smi-status       : Print table of all SMI devices, parent mlx5_*,
#                        and per-port status via ibstat
#   --run-opensm       : After SMI management, start/verify opensm for all
#                        resulting ConnectX8 smiN devices
#   --no-require-active: Do NOT fail overall RC if ports are not Active
#   -h, --help         : Show this help
# =========================================================
#
# Additional logging:
#   Phases:
#     Phase A: Existing SMI discovery + optional deletion
#     Phase B: ConnectX-8 parent detection + SMI creation/assignment
#     Phase C: Optional OpenSM startup + port state verification
#
#   Logs:
#     ./cx8_smi_opensm_mgr_YYYYmmdd-HHMMSS/master.log
#         - All phases, decisions, command results
#     ./cx8_smi_opensm_mgr_YYYYmmdd-HHMMSS/smi_assign.log
#         - Detailed Phase B info (SMI assignment / creation)
#     ./cx8_smi_opensm_mgr_YYYYmmdd-HHMMSS/opensm_smi_<GUID>.log
#         - Individual opensm output per GUID
# =========================================================

# -------------------------
# Global flags / defaults
# -------------------------
DRY_RUN="no"
RECREATE_SMI="no"
SELECT_SMI="no"
SHOW_SMI_STATUS="no"
RUN_OPENSM="no"
REQUIRE_ACTIVE="yes"   # yes|no

# -------------------------
# CLI parsing
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="yes"
      shift
      ;;
    --recreate-smi)
      RECREATE_SMI="yes"
      shift
      ;;
    --select-smi)
      SELECT_SMI="yes"
      shift
      ;;
    --smi-status)
      SHOW_SMI_STATUS="yes"
      shift
      ;;
    --run-opensm)
      RUN_OPENSM="yes"
      shift
      ;;
    --no-require-active)
      REQUIRE_ACTIVE="no"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

SMI management options:
  --dry-run          Print rdma/opensm commands but do not execute them
  --recreate-smi     Delete ALL existing SMI devices, then recreate canonical
                     smiN for ConnectX8 parents
  --select-smi       Interactively select which SMI devices to delete and
                     then recreate canonical smiN for ConnectX8 parents
  --smi-status       Print table of all SMI devices, parent mlx5_* and
                     per-port states via ibstat

OpenSM options:
  --run-opensm       After SMI management, start/verify opensm for all
                     resulting ConnectX8 smiN devices
  --no-require-active
                     Do NOT fail overall RC if ports are not Active

Other:
  -h, --help         Show this help

Examples:
  sudo $0 --recreate-smi --smi-status
  sudo $0 --run-opensm
  sudo $0 --run-opensm --no-require-active
  sudo $0 --select-smi --run-opensm --smi-status
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --recreate-smi and --select-smi are mutually exclusive
if [[ "$RECREATE_SMI" == "yes" && "$SELECT_SMI" == "yes" ]]; then
  echo "ERROR: Use either --recreate-smi or --select-smi, not both." >&2
  exit 1
fi

# -------------------------
# Log directory & files
# -------------------------
SCRIPT_NAME="$(basename "$0" .sh)"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$(pwd)/${SCRIPT_NAME}_${RUN_TS}"
mkdir -p "$LOG_DIR"

MASTER_LOG="${LOG_DIR}/master.log"
SMI_ASSIGN_LOG="${LOG_DIR}/smi_assign.log"

log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="$*"
  echo "[$ts] $msg" | tee -a "$MASTER_LOG"
}

smi_log() {
  local ts msg
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="$*"
  echo "[$ts] [SMI] $msg" | tee -a "$MASTER_LOG" >>"$SMI_ASSIGN_LOG"
}

log "====================================================="
log "Start run: $SCRIPT_NAME   DRY_RUN=$DRY_RUN   RUN_TS=$RUN_TS"
log "Log directory: $LOG_DIR"
log "====================================================="

trap 'log "ERROR: Unhandled error occurred near line $LINENO"; exit 1' ERR

# -------------------------
# Tool discovery
# -------------------------
MST_BIN="${MST_BIN:-mst}"
RDMA_BIN="/opt/mellanox/iproute2/sbin/rdma"
[[ -x "$RDMA_BIN" ]] || RDMA_BIN="$(command -v rdma || true)"
IBSTAT_BIN="$(command -v ibstat || true)"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: '$1' not found in PATH"
    exit 1
  fi
}

if [[ -z "${RDMA_BIN:-}" ]]; then
  log "ERROR: rdma tool not found (tried /opt/mellanox/iproute2/sbin/rdma and PATH)."
  exit 1
fi

need "$MST_BIN"
need awk
need grep
need sort

log "[Phase 0] Tools detected: MST_BIN=$MST_BIN RDMA_BIN=$RDMA_BIN IBSTAT_BIN=${IBSTAT_BIN:-N/A}"

# -------------------------
# Generic command runner
# -------------------------
run_cmd_logged() {
  local desc="$1"; shift
  local cmd="$*"
  log "[CMD] ($desc) $cmd"
  if [[ "$DRY_RUN" == "yes" ]]; then
    log "[DRY-RUN] ($desc) Skipping execution of: $cmd"
    return 0
  fi
  eval "$cmd"
  local rc=$?
  if (( rc == 0 )); then
    log "[OK] ($desc) exit code $rc"
  else
    log "[FAIL] ($desc) exit code $rc"
  fi
  return $rc
}

# =========================================================
# Pretty status table for all SMI devices
# =========================================================
print_smi_status_table() {
  log "[Phase] SMI status table generation started"

  local lines smi_name smi_parent idx port_states state port ibout

  lines="$(
    "$RDMA_BIN" dev 2>/dev/null | \
    awk '
      / type smi / {
        name=$2; sub(/:$/, "", name);
        parent="-";
        for (i=1; i<=NF; i++) {
          if ($i=="parent") { parent=$(i+1); break; }
        }
        print name, parent;
      }
    '
  )"

  if [[ -z "$lines" ]]; then
    log "No SMI devices (type smi) found for status table."
    echo "No SMI devices (type smi) found."
    return
  fi

  if [[ -z "$IBSTAT_BIN" ]]; then
    log "WARNING: ibstat not found; port state info unavailable."
    echo "WARNING: ibstat not found; will not show port states."
  fi

  printf "\n%-4s %-10s %-10s %-40s\n" "No" "SMI" "Parent" "Port States"
  printf "%-4s %-10s %-10s %-40s\n" "----" "----------" "----------" "----------------------------------------"

  idx=0
  while read -r smi_name smi_parent; do
    [[ -z "$smi_name" ]] && continue
    idx=$((idx+1))
    port_states=""

    if [[ -n "$IBSTAT_BIN" ]]; then
      ibout="$("$IBSTAT_BIN" "$smi_name" 2>/dev/null || true)"
      if [[ -n "$ibout" ]]; then
        for port in 1 2 3 4; do
          if echo "$ibout" | grep -q "Port $port"; then
            state="$(echo "$ibout" | awk -v P="$port" '
              $0 ~ ("Port " P) {inblk=1; next}
              inblk && /^[[:space:]]*Port [0-9]+/ {inblk=0}
              inblk && /State:/ {print $2; exit}
            ')"
            [[ -z "$state" ]] && state="Unknown"
            port_states+="${port_states:+, }P${port}:${state}"
          fi
        done
      else
        port_states="ibstat error"
      fi
    else
      port_states="ibstat not available"
    fi

    log "[SMI-status] index=$idx smi=$smi_name parent=$smi_parent ports=${port_states:-N/A}"
    printf "%-4s %-10s %-10s %-40s\n" "$idx" "$smi_name" "$smi_parent" "${port_states:-N/A}"
  done <<< "$lines"

  echo
  log "[Phase] SMI status table generation finished"
}

# =========================================================
# Phase A: Existing SMI devices (for deletion / selection)
# =========================================================
log "[Phase A] Discover existing SMI devices (type smi)"

EXISTING_SMI_LINES="$(
  "$RDMA_BIN" dev 2>/dev/null | \
  awk '
    / type smi / {
      name=$2; sub(/:$/, "", name);
      parent="-";
      for (i=1; i<=NF; i++) {
        if ($i=="parent") { parent=$(i+1); break; }
      }
      print name, parent;
    }
  '
)"

SMI_NAMES=()
SMI_PARENTS=()

if [[ -n "$EXISTING_SMI_LINES" ]]; then
  log "Found existing SMI devices:"
  idx=0
  while read -r smi_name smi_parent; do
    [[ -z "$smi_name" ]] && continue
    SMI_NAMES[$idx]="$smi_name"
    SMI_PARENTS[$idx]="$smi_parent"
    log "  [$((idx+1))] SMI=$smi_name parent=$smi_parent"
    echo "  [$((idx+1))] SMI: $smi_name   (parent: $smi_parent)"
    idx=$((idx+1))
  done <<< "$EXISTING_SMI_LINES"
else
  log "No existing SMI devices found (type smi)."
  echo "No existing SMI devices found (type smi)."
fi

# status-only mode
if [[ "$SHOW_SMI_STATUS" == "yes" && "$RECREATE_SMI" == "no" && "$SELECT_SMI" == "no" && "$RUN_OPENSM" == "no" ]]; then
  log "[Phase A] Only --smi-status requested; printing status and exiting."
  print_smi_status_table
  log "Run finished (status-only)."
  exit 0
fi

# -------------------------
# Phase A.1: delete ALL SMI (--recreate-smi)
# -------------------------
if [[ -n "$EXISTING_SMI_LINES" && "$RECREATE_SMI" == "yes" ]]; then
  log "[Phase A.1] --recreate-smi requested; will delete ALL existing SMIs."

  echo
  echo "You requested --recreate-smi."
  echo "This will delete ALL existing SMI devices above and then recreate"
  echo "canonical smiN devices for ConnectX8 parents."
  read -r -p "Delete ALL existing SMI devices and continue? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES)
      log "User confirmed deletion of ALL existing SMIs."
      echo "Deleting existing SMI devices..."
      i=0
      while [[ $i -lt ${#SMI_NAMES[@]} ]]; do
        smi_name="${SMI_NAMES[$i]}"
        run_cmd_logged "delete SMI $smi_name" "$RDMA_BIN dev del $smi_name"
        i=$((i+1))
      done
      log "[Phase A.1] All existing SMI devices deleted (or simulated if dry-run)."
      ;;
    *)
      log "User declined deletion of existing SMIs; proceeding without deleting."
      echo "Skipping deletion of existing SMI devices."
      ;;
  esac
fi

# -------------------------
# Phase A.2: delete SELECTED SMI (--select-smi)
# -------------------------
if [[ -n "$EXISTING_SMI_LINES" && "$SELECT_SMI" == "yes" ]]; then
  log "[Phase A.2] --select-smi requested."

  echo
  echo "You requested --select-smi."
  echo "Select which SMI devices to delete (they will be recreated"
  echo "canonically as smiN for ConnectX8 parents if applicable)."
  echo
  echo "Enter one of:"
  echo "  - numbers separated by space (e.g. 1 3 5)"
  echo "  - a range like 1-3"
  echo "  - 'all' to delete all SMI devices above"
  echo "  - empty line to skip deletion"
  echo

  read -r -p "Selection: " sel
  log "[Phase A.2] User selection for deletion: '$sel'"

  TO_DELETE=()

  if [[ -z "$sel" ]]; then
    log "No selection given. Skipping SMI deletion."
    echo "No selection given. Skipping SMI deletion."
  elif [[ "$sel" == "all" ]]; then
    i=0
    while [[ $i -lt ${#SMI_NAMES[@]} ]]; do
      TO_DELETE+=( "$i" )
      i=$((i+1))
    done
  else
    for tok in $sel; do
      if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
        start="${tok%-*}"
        end="${tok#*-}"
        if (( start < 1 )); then start=1; fi
        if (( end > ${#SMI_NAMES[@]} )); then end=${#SMI_NAMES[@]}; fi
        n=$start
        while (( n <= end )); do
          TO_DELETE+=( "$((n-1))" )
          n=$((n+1))
        done
      elif [[ "$tok" =~ ^[0-9]+$ ]]; then
        n="$tok"
        if (( n >= 1 && n <= ${#SMI_NAMES[@]} )); then
          TO_DELETE+=( "$((n-1))" )
        else
          log "Ignoring out-of-range SMI index: $n"
          echo "Ignoring out-of-range index: $n"
        fi
      else
        log "Ignoring invalid SMI selection token: '$tok'"
        echo "Ignoring invalid token: $tok"
      fi
    done
  fi

  if (( ${#TO_DELETE[@]} > 0 )); then
    mapfile -t TO_DELETE < <(printf "%s\n" "${TO_DELETE[@]}" | sort -nu)
    log "SMI indices selected for deletion: ${TO_DELETE[*]}"
    echo "Will delete the following SMI indices:"
    for idx in "${TO_DELETE[@]}"; do
      echo "  [$((idx+1))] ${SMI_NAMES[$idx]}"
    done
    read -r -p "Proceed with deletion? [y/N] " ans2
    case "$ans2" in
      y|Y|yes|YES)
        log "User confirmed deletion of selected SMI devices."
        echo "Deleting selected SMI devices..."
        k=0
        while [[ $k -lt ${#TO_DELETE[@]} ]]; do
          idx="${TO_DELETE[$k]}"
          smi_name="${SMI_NAMES[$idx]}"
          run_cmd_logged "delete SMI $smi_name" "$RDMA_BIN dev del $smi_name"
          k=$((k+1))
        done
        ;;
      *)
        log "User canceled deletion of selected SMI devices."
        echo "No SMI deleted."
        ;;
    esac
  else
    log "No valid SMI indices selected; no SMI deleted."
    echo "No valid SMI indices selected. No SMI deleted."
  fi
fi

# =========================================================
# Phase B: Collect ConnectX8 parents and ensure smiN exists
# =========================================================
log "[Phase B] Detect ConnectX8 parents from 'mst status -v' and ensure smiN devices."

MLX5_LIST=()

while read -r col1 col2 col3 col4 rest; do
  if [[ "$col1" == ConnectX8* ]] && [[ "$col4" == mlx5_* ]]; then
    MLX5_LIST+=( "$col4" )
    smi_log "Detected ConnectX8 parent from mst status: DEVICE_TYPE=$col1 parent=$col4"
  fi
done < <("$MST_BIN" status -v)

if [[ "${#MLX5_LIST[@]}" -eq 0 ]]; then
  log "No ConnectX8 mlx5_* devices found in 'mst status -v'."
  echo "No ConnectX8 mlx5_* devices found in 'mst status -v'." >&2
  exit 1
fi

log "[Phase B] ConnectX8 parents list: ${MLX5_LIST[*]}"
echo
echo "ConnectX8 RDMA parents from 'mst status -v': ${MLX5_LIST[*]}"

SMIS=()

for parent in "${MLX5_LIST[@]}"; do
  idx="${parent#mlx5_}"
  smi="smi${idx}"

  smi_log "Processing parent=$parent target_smi=$smi"

  # Does smiN already exist?
  if "$RDMA_BIN" dev 2>/dev/null | awk -v S="$smi" '$2 ~ ("^"S":$"){found=1} END{exit(found?0:1)}'; then
    log "SMI $smi already exists (parent should be $parent)."
    smi_log "SMI $smi exists; skipping creation."
  else
    # Ensure parent is visible in rdma dev
    if ! "$RDMA_BIN" dev 2>/dev/null | awk -v P="$parent" '$2 ~ ("^"P":$"){found=1} END{exit(found?0:1)}'; then
      log "Parent $parent not visible in 'rdma dev'; skipping creation of $smi."
      smi_log "ERROR: Parent $parent missing in rdma dev; cannot create $smi."
      continue
    fi
    cmd="$RDMA_BIN dev add $smi type SMI parent $parent"
    smi_log "Creating SMI device: $cmd"
    run_cmd_logged "create SMI $smi (parent $parent)" "$cmd"
  fi

  SMIS+=( "$smi" )
done

if [[ "${#SMIS[@]}" -eq 0 ]]; then
  log "No SMI devices were created or found for ConnectX8 parents; aborting."
  echo "No SMI devices were created or found for ConnectX8 parents." >&2
  exit 1
fi

log "[Phase B] Final SMI list for ConnectX8 parents: ${SMIS[*]}"
echo
echo "Final SMI list for ConnectX8 parents: ${SMIS[*]}"

# If status requested, show table after Phase B
if [[ "$SHOW_SMI_STATUS" == "yes" ]]; then
  print_smi_status_table
fi

# =========================================================
# Phase C: Optional OpenSM for each SMI
# =========================================================
if [[ "$RUN_OPENSM" != "yes" ]]; then
  log "[Phase C] --run-opensm not set; skipping OpenSM phase."
  echo
  echo "OpenSM step skipped (use --run-opensm to enable)."
  log "Run finished without OpenSM phase."
  exit 0
fi

need opensm
need ps
need nohup

OPENSM_LOG_PREFIX="opensm_smi"
log "[Phase C] OpenSM phase started. REQUIRE_ACTIVE=$REQUIRE_ACTIVE"

get_guid() {
  local ca="$1"
  "$IBSTAT_BIN" "$ca" 2>/dev/null | awk '/Port GUID:/ {print $3; exit}'
}

ensure_opensm_for_guid() {
  local guid="$1"
  local log_file="${LOG_DIR}/${OPENSM_LOG_PREFIX}_${guid}.log"

  if ps -ef | grep -E "[o]pensm.*-g[[:space:]]*$guid" >/dev/null 2>&1; then
    log "[OpenSM] Existing instance detected for GUID=$guid; not starting another."
    echo "  - opensm already running for GUID $guid (skip)"
    return 0
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    log "[OpenSM][DRY-RUN] Would start: nohup opensm -g \"$guid\" -rvo >>\"$log_file\" 2>&1 &"
    echo "[DRY-RUN] nohup opensm -g \"$guid\" -rvo >>\"$log_file\" 2>&1 &"
    return 0
  fi

  log "[OpenSM] Starting opensm for GUID=$guid (log=$log_file)"
  echo "  - starting opensm for GUID $guid ..."
  nohup opensm -g "$guid" -rvo >>"$log_file" 2>&1 &

  sleep 2
  if ps -ef | grep -E "[o]pensm.*-g[[:space:]]*$guid" >/dev/null 2>&1; then
    log "[OpenSM] opensm running for GUID=$guid (log=$log_file)"
    echo "    -> opensm running for $guid (log: $log_file)"
    return 0
  else
    log "[OpenSM][ERROR] Failed to start opensm for GUID=$guid (see $log_file)"
    echo "    !! failed to start opensm for GUID $guid (see $log_file)"
    return 1
  fi
}

detect_ports() {
  local ca="$1"
  "$IBSTAT_BIN" "$ca" 2>/dev/null | awk '/^[[:space:]]*Port [0-9]+/ {print $2}' | tr -d ':' | sort -n
}

check_ports_active() {
  local ca="$1"
  local ports=("$@"); ports=("${ports[@]:1}")
  local ok=1

  for p in "${ports[@]}"; do
    if "$IBSTAT_BIN" "$ca" 2>/dev/null | awk -v target="$p" '
        /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
          cur=$2; gsub(":", "", cur);
        }
        /State:/ {
          if (cur == target && $0 ~ /State:[[:space:]]*Active/) {
            print $0;
            exit;
          }
        }
      ' | grep -q "Active"; then
      log "[OpenSM] Port $ca:$p is Active."
      echo "    -> Port ${p}: Active"
    else
      log "[OpenSM][WARN] Port $ca:$p is NOT Active."
      echo "    !! Port ${p}: NOT Active"
      ok=0
    fi
  done

  (( ok == 1 ))
}

overall_rc=0

echo
echo "[OpenSM] Processing SMI devices: ${SMIS[*]}"
log "[Phase C] Processing SMI devices for OpenSM: ${SMIS[*]}"

if [[ -z "$IBSTAT_BIN" ]]; then
  log "[OpenSM][ERROR] ibstat not available; cannot derive GUID/ports for SMIs."
  echo "  !! ibstat not available; cannot derive GUID/ports. Skipping OpenSM."
  overall_rc=1
else
  for smi in "${SMIS[@]}"; do
    echo
    echo "=== SMI: $smi ==="
    log "[OpenSM] SMI=$smi: start."

    guid="$(get_guid "$smi" || true)"
    if [[ -z "$guid" ]]; then
      log "[OpenSM][ERROR] Could not find Port GUID for $smi via ibstat; skipping."
      echo "  !! Could not find Port GUID for $smi via ibstat, skipping opensm."
      overall_rc=1
      continue
    fi
    log "[OpenSM] SMI=$smi GUID=$guid"
    echo "  - GUID: $guid"

    if ! ensure_opensm_for_guid "$guid"; then
      overall_rc=1
    fi

    echo "  - Detecting ports on $smi ..."
    mapfile -t PORT_LIST < <(detect_ports "$smi")
    if (( ${#PORT_LIST[@]} == 0 )); then
      log "[OpenSM][WARN] No ports detected on $smi via ibstat."
      echo "    !! No ports detected on $smi via ibstat"
      overall_rc=1
      continue
    fi
    log "[OpenSM] SMI=$smi ports=${PORT_LIST[*]}"
    echo "    Ports: ${PORT_LIST[*]}"

    echo "  - Verifying ports are Active ..."
    if ! check_ports_active("$smi" "${PORT_LIST[@]}"); then
      if [[ "$REQUIRE_ACTIVE" == "yes" ]]; then
        log "[OpenSM][ERROR] One or more ports on $smi are not Active (REQUIRE_ACTIVE=yes)."
        echo "    !! One or more ports on $smi are not Active"
        overall_rc=1
      else
        log "[OpenSM][WARN] Non-active ports observed on $smi, but REQUIRE_ACTIVE=no; continuing."
        echo "    (warning) Non-active ports observed, continuing"
      fi
    else
      log "[OpenSM] All ports on $smi are Active."
      echo "    All ports on $smi Active"
    fi
  done
fi

log "[Phase C] OpenSM phase completed. overall_rc=$overall_rc"
echo
echo "[OpenSM] Logs saved under: $LOG_DIR"
log "Run finished. Logs at: $LOG_DIR"
exit "$overall_rc"