#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  cleanup_ovn_octavia_lb_ko.sh --lb-id <octavia-lb-uuid> [options]

Behavior:
  - Default mode is DRY-RUN
  - Use --execute to actually detach and delete
  - Uses: kubectl ko nbctl
  - Finds OVN NB Load_Balancer where name=<lb-id>
  - Prefers external_ids metadata (ls_refs / lr_ref) to discover attachments
  - Falls back to a slower scan only if metadata is missing and --allow-scan is set
  - Removes LS/LR references first, then deletes the LB row

Examples:
  Dry run:
    ./cleanup_ovn_octavia_lb_ko.sh --lb-id 16883b88-119e-4f2c-9297-ddf7ab358e15

  Execute:
    ./cleanup_ovn_octavia_lb_ko.sh --lb-id 16883b88-119e-4f2c-9297-ddf7ab358e15 --execute

  Dry run with fallback scanning enabled:
    ./cleanup_ovn_octavia_lb_ko.sh --lb-id 16883b88-119e-4f2c-9297-ddf7ab358e15 --allow-scan

Options:
  --lb-id <id>        Required. Octavia LB UUID / OVN Load_Balancer.name
  --execute           Actually perform OVN changes
  --verbose           Print extra details
  --allow-scan        If ls_refs/lr_ref are missing, do a slow full scan of LS/LR objects
  --timeout <secs>    nbctl timeout in seconds (default: 15)
  -h, --help          Show this help

Environment overrides:
  KUBECTL=kubectl
  KO_NB_SUBCOMMAND="ko nbctl"
EOF
}

LB_ID=""
EXECUTE=0
VERBOSE=0
ALLOW_SCAN=0
TIMEOUT=15

KUBECTL="${KUBECTL:-kubectl}"
KO_NB_SUBCOMMAND="${KO_NB_SUBCOMMAND:-ko nbctl}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    exit 1
  }
}

run_nbctl() {
  # shellcheck disable=SC2086
  "$KUBECTL" $KO_NB_SUBCOMMAND --timeout="$TIMEOUT" "$@"
}

capture_cmd() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "+ $*" >&2
  fi
  "$@"
}

run_cmd() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    echo "+ $*"
    "$@"
  else
    echo "[DRY-RUN] $*"
  fi
}

trim_cr() {
  tr -d '\r'
}

trim_quotes() {
  sed 's/^"//; s/"$//'
}

# Extract JSON object keys from a simple string like:
# {"neutron-uuid-1": "1", "neutron-uuid-2": "2"}
# This is intentionally simple and works for OVN external_ids:ls_refs format.
json_object_keys_to_lines() {
  sed -E 's/^\{[[:space:]]*//; s/[[:space:]]*\}$//' \
  | grep -oE '"[^"]+"' \
  | sed 's/^"//; s/"$//' \
  | awk 'NR % 2 == 1'
}

# Check whether a given LS/LR references the LB UUID or LB name.
# This avoids using fragile "find set contains" syntax through wrappers.
ls_has_lb() {
  local ls="$1"
  capture_cmd run_nbctl ls-lb-list "$ls" 2>/dev/null | grep -Eq "(^|[[:space:]])($LB_UUID|$LB_ID)($|[[:space:]])|$LB_UUID|$LB_ID"
}

lr_has_lb() {
  local lr="$1"
  capture_cmd run_nbctl lr-lb-list "$lr" 2>/dev/null | grep -Eq "(^|[[:space:]])($LB_UUID|$LB_ID)($|[[:space:]])|$LB_UUID|$LB_ID"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lb-id)
      LB_ID="${2:-}"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --allow-scan)
      ALLOW_SCAN=1
      shift
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$LB_ID" ]]; then
  err "--lb-id is required"
  usage
  exit 1
fi

require_bin "$KUBECTL"
require_bin grep
require_bin sed
require_bin awk
require_bin tr
require_bin head

log "Mode: $([[ "$EXECUTE" -eq 1 ]] && echo EXECUTE || echo DRY-RUN)"
log "LB_ID: $LB_ID"
log "Timeout: ${TIMEOUT}s"
log "Using command: $KUBECTL $KO_NB_SUBCOMMAND"

LB_UUID="$(
  capture_cmd run_nbctl --bare --no-heading --columns=_uuid find Load_Balancer name="$LB_ID" \
    | head -n1 | trim_cr
)"

if [[ -z "$LB_UUID" ]]; then
  warn "No OVN NB Load_Balancer row found for name=$LB_ID"
  exit 0
fi

log "LB_UUID: $LB_UUID"

echo
log "=== Load_Balancer row ==="
capture_cmd run_nbctl --columns=_uuid,name,protocol,vips,external_ids list Load_Balancer "$LB_UUID" || true

VIP="$(
  capture_cmd run_nbctl --if-exists --bare --no-heading get Load_Balancer "$LB_UUID" external_ids:neutron:vip 2>/dev/null \
    | trim_cr | trim_quotes || true
)"
VIP_PORT_ID="$(
  capture_cmd run_nbctl --if-exists --bare --no-heading get Load_Balancer "$LB_UUID" external_ids:neutron:vip_port_id 2>/dev/null \
    | trim_cr | trim_quotes || true
)"
LS_REFS_RAW="$(
  capture_cmd run_nbctl --if-exists --bare --no-heading get Load_Balancer "$LB_UUID" external_ids:ls_refs 2>/dev/null \
    | trim_cr | trim_quotes || true
)"
LR_REF_RAW="$(
  capture_cmd run_nbctl --if-exists --bare --no-heading get Load_Balancer "$LB_UUID" external_ids:lr_ref 2>/dev/null \
    | trim_cr | trim_quotes || true
)"

echo
log "VIP: ${VIP:-<not found>}"
log "VIP Port ID: ${VIP_PORT_ID:-<not found>}"
log "ls_refs raw: ${LS_REFS_RAW:-<not found>}"
log "lr_ref raw: ${LR_REF_RAW:-<not found>}"

declare -a LS_MATCHES=()
declare -a LR_MATCHES=()

echo
log "=== Discovering Logical_Switch references ==="

if [[ -n "${LS_REFS_RAW:-}" && "${LS_REFS_RAW:-}" != "{}" ]]; then
  while IFS= read -r ls; do
    [[ -z "$ls" ]] && continue
    LS_MATCHES+=("$ls")
  done < <(printf '%s\n' "$LS_REFS_RAW" | json_object_keys_to_lines)

  if [[ "${#LS_MATCHES[@]}" -eq 0 ]]; then
    echo "  none (ls_refs present but no keys parsed)"
  else
    for ls in "${LS_MATCHES[@]}"; do
      echo "  LS from ls_refs: $ls"
    done
  fi
else
  echo "  none from ls_refs metadata"
  if [[ "$ALLOW_SCAN" -eq 1 ]]; then
    warn "Falling back to slow Logical_Switch scan"
    while IFS= read -r ls; do
      [[ -z "$ls" ]] && continue
      if ls_has_lb "$ls"; then
        LS_MATCHES+=("$ls")
        echo "  LS from scan: $ls"
      fi
    done < <(capture_cmd run_nbctl --bare --no-heading --columns=name list Logical_Switch | trim_cr)
  else
    warn "Skipping LS scan. Re-run with --allow-scan if you want fallback discovery."
  fi
fi

echo
log "=== Discovering Logical_Router references ==="

if [[ -n "${LR_REF_RAW:-}" ]]; then
  LR_MATCHES+=("$LR_REF_RAW")
  echo "  LR from lr_ref: $LR_REF_RAW"
else
  echo "  none from lr_ref metadata"
  if [[ "$ALLOW_SCAN" -eq 1 ]]; then
    warn "Falling back to slow Logical_Router scan"
    while IFS= read -r lr; do
      [[ -z "$lr" ]] && continue
      if lr_has_lb "$lr"; then
        LR_MATCHES+=("$lr")
        echo "  LR from scan: $lr"
      fi
    done < <(capture_cmd run_nbctl --bare --no-heading --columns=name list Logical_Router | trim_cr)
  else
    warn "Skipping LR scan. Re-run with --allow-scan if you want fallback discovery."
  fi
fi

echo
log "=== Verifying discovered references before delete ==="

declare -a LS_VERIFIED=()
declare -a LR_VERIFIED=()

for ls in "${LS_MATCHES[@]}"; do
  if ls_has_lb "$ls"; then
    LS_VERIFIED+=("$ls")
    echo "  confirmed LS attachment: $ls"
  else
    warn "LS listed but LB not currently attached: $ls"
  fi
done

for lr in "${LR_MATCHES[@]}"; do
  if lr_has_lb "$lr"; then
    LR_VERIFIED+=("$lr")
    echo "  confirmed LR attachment: $lr"
  else
    warn "LR listed but LB not currently attached: $lr"
  fi
done

echo
log "=== Planned actions ==="
for ls in "${LS_VERIFIED[@]}"; do
  echo "  detach LB from LS: $ls"
done
for lr in "${LR_VERIFIED[@]}"; do
  echo "  detach LB from LR: $lr"
done
echo "  delete Load_Balancer row: $LB_UUID"

echo
if [[ "$EXECUTE" -eq 0 ]]; then
  warn "Dry-run only. No changes made."
  warn "Re-run with --execute to perform cleanup."
else
  log "=== Executing detach from Logical_Switch objects ==="
  for ls in "${LS_VERIFIED[@]}"; do
    if ! run_cmd run_nbctl --if-exists ls-lb-del "$ls" "$LB_UUID"; then
      warn "UUID detach failed for LS $ls, retrying with LB name"
      run_cmd run_nbctl --if-exists ls-lb-del "$ls" "$LB_ID"
    fi
  done

  log "=== Executing detach from Logical_Router objects ==="
  for lr in "${LR_VERIFIED[@]}"; do
    if ! run_cmd run_nbctl --if-exists lr-lb-del "$lr" "$LB_UUID"; then
      warn "UUID detach failed for LR $lr, retrying with LB name"
      run_cmd run_nbctl --if-exists lr-lb-del "$lr" "$LB_ID"
    fi
  done

  log "=== Deleting Load_Balancer row ==="
  if ! run_cmd run_nbctl --if-exists lb-del "$LB_UUID"; then
    warn "UUID delete failed, retrying with LB name"
    run_cmd run_nbctl --if-exists lb-del "$LB_ID"
  fi
fi

echo
log "=== Verification ==="

POST_LB="$(
  capture_cmd run_nbctl --bare --no-heading --columns=_uuid find Load_Balancer name="$LB_ID" \
    | head -n1 | trim_cr
)"

if [[ -n "$POST_LB" ]]; then
  warn "Load_Balancer row still present: $POST_LB"
else
  log "Load_Balancer row no longer present"
fi

POST_FOUND=0

for ls in "${LS_VERIFIED[@]}"; do
  if ls_has_lb "$ls"; then
    warn "Still attached to LS: $ls"
    POST_FOUND=1
  fi
done

for lr in "${LR_VERIFIED[@]}"; do
  if lr_has_lb "$lr"; then
    warn "Still attached to LR: $lr"
    POST_FOUND=1
  fi
done

if [[ "$POST_FOUND" -eq 0 ]]; then
  log "No remaining references found on previously verified LS/LR objects"
fi

if [[ -n "${VIP:-}" ]]; then
  echo
  log "Optional downstream verification hint: grep for VIP-related flow state where applicable"
  echo "  VIP=$VIP"
fi

echo
log "Done"
