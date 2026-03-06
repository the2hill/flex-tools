#!/bin/bash

# Usage: ./monitor_lbs.sh [options]
# Reads lb_id and floating_ip from stdin or a file
# Example: ./create_lbs.sh ... | ./monitor_lbs.sh
# Example: ./monitor_lbs.sh -f summary.txt
# Example: ./monitor_lbs.sh -i "lb-id-1 1.2.3.4" -i "lb-id-2 5.6.7.8"

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -f, --file <file>         Read LB summary from file"
  echo "  -i, --input <lb_id fip>  Manually specify a LB (repeatable)"
  echo "  -l, --log <file>          Log file (default: lb_monitor_<timestamp>.log)"
  echo "  -t, --interval <secs>     Check interval in seconds (default: 30)"
  echo "  -p, --port <port>         Port to check (default: 80)"
  echo "  -T, --timeout <secs>      Curl timeout in seconds (default: 10)"
  echo "  -h, --help                Show this help"
  echo ""
  echo "Input format (from file or stdin):"
  echo "  Parses any line containing a UUID and an IP address"
  echo "  Compatible with create_lbs.sh summary output"
  echo ""
  echo "Examples:"
  echo "  ./monitor_lbs.sh -f summary.txt"
  echo "  ./monitor_lbs.sh -i 'abc-123 1.2.3.4' -i 'def-456 5.6.7.8'"
  echo "  cat summary.txt | ./monitor_lbs.sh"
  exit 0
}

LOGFILE="lb_monitor_$(date '+%Y%m%d_%H%M%S').log"
INTERVAL=30
PORT=8080
TIMEOUT=10
INPUT_FILE=""
declare -a MANUAL_INPUTS

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)     INPUT_FILE="$2";          shift 2 ;;
    -i|--input)    MANUAL_INPUTS+=("$2");    shift 2 ;;
    -l|--log)      LOGFILE="$2";             shift 2 ;;
    -t|--interval) INTERVAL="$2";            shift 2 ;;
    -p|--port)     PORT="$2";                shift 2 ;;
    -T|--timeout)  TIMEOUT="$2";             shift 2 ;;
    -h|--help)     usage ;;
    -*) echo "Unknown flag: $1"; usage ;;
    *)  break ;;
  esac
done

# -------------------------------------------------------
# Parse LB entries from summary output
# Extracts UUID and IP from any line that contains both
# -------------------------------------------------------
declare -a LB_IDS
declare -a LB_FIPS
declare -a LB_NAMES

parse_line() {
  local line="$1"
  # Skip headers, dashes, empty lines
  echo "$line" | grep -qE '^[-=\s]*$|^NAME' && return
  echo "$line" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}' || return

  # Extract UUID (lb_id)
  local lb_id
  lb_id=$(echo "$line" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

  # Extract floating IP — look for public IP (non-RFC1918)
  local fip
  fip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | grep -vE \
    '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)

  # Extract name — first non-UUID, non-IP field
  local name
  name=$(echo "$line" | awk -F'|' '{print $1}' | xargs)
  [ -z "$name" ] && name="lb-$lb_id"

  if [ -n "$lb_id" ] && [ -n "$fip" ]; then
    LB_IDS+=("$lb_id")
    LB_FIPS+=("$fip")
    LB_NAMES+=("$name")
  fi
}

# Read from file
if [ -n "$INPUT_FILE" ]; then
  while IFS= read -r line; do
    parse_line "$line"
  done < "$INPUT_FILE"
# Read from stdin if piped
elif [ ! -t 0 ]; then
  while IFS= read -r line; do
    parse_line "$line"
  done
fi

# Add manual inputs
for entry in "${MANUAL_INPUTS[@]}"; do
  lb_id=$(echo "$entry" | awk '{print $1}')
  fip=$(echo "$entry" | awk '{print $2}')
  LB_IDS+=("$lb_id")
  LB_FIPS+=("$fip")
  LB_NAMES+=("lb-$lb_id")
done

if [ ${#LB_IDS[@]} -eq 0 ]; then
  echo "ERROR: No load balancers found to monitor."
  echo "       Provide input via -f, -i, or pipe from create_lbs.sh"
  echo ""
  usage
fi

# -------------------------------------------------------
# Logging helper — writes to both stdout and logfile
# with local timestamp
# -------------------------------------------------------
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
  echo "[$ts] $*" | tee -a "$LOGFILE"
}

# -------------------------------------------------------
# Check a single LB FIP
# -------------------------------------------------------
check_lb() {
  local name=$1
  local lb_id=$2
  local fip=$3

  local http_code
  local response_time
  local result

  # Capture HTTP code and response time
  read -r http_code response_time < <(
    curl -sk \
      --max-time "$TIMEOUT" \
      --connect-timeout "$TIMEOUT" \
      -o /dev/null \
      -w "%{http_code} %{time_total}" \
      "http://$fip:$PORT" 2>/dev/null
  )

  if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
    result="DOWN timeout=${TIMEOUT}s"
  else
    result="HTTP $http_code time=${response_time}s"
  fi

  echo "$name|$lb_id|$fip|$result"
}

# -------------------------------------------------------
# Main monitor loop
# -------------------------------------------------------
log "========================================"
log "LB Monitor started"
log "  Log file  : $LOGFILE"
log "  Interval  : ${INTERVAL}s"
log "  Port      : $PORT"
log "  Timeout   : ${TIMEOUT}s"
log "  LBs       : ${#LB_IDS[@]}"
log "========================================"
log ""

for j in "${!LB_IDS[@]}"; do
  log "  Monitoring: ${LB_NAMES[$j]} | ${LB_IDS[$j]} | ${LB_FIPS[$j]}"
done
log ""

# Track previous state per LB to log transitions
declare -A PREV_STATE

while true; do
  log "--- Check $(date '+%Y-%m-%d %H:%M:%S') ---"

  for j in "${!LB_IDS[@]}"; do
    name="${LB_NAMES[$j]}"
    lb_id="${LB_IDS[$j]}"
    fip="${LB_FIPS[$j]}"

    result=$(check_lb "$name" "$lb_id" "$fip")
    status=$(echo "$result" | cut -d'|' -f4)

    # Determine UP/DOWN for state tracking
    if echo "$status" | grep -qE "^HTTP [2345]"; then
      state="UP"
    else
      state="DOWN"
    fi

    prev="${PREV_STATE[$lb_id]:-UNKNOWN}"

    # Log state transitions prominently
    if [ "$state" != "$prev" ] && [ "$prev" != "UNKNOWN" ]; then
      log "*** STATE CHANGE: $name ($fip) $prev → $state ***"
    fi

    PREV_STATE[$lb_id]="$state"

    log "  [$state] $name | $lb_id | $fip | $status"
  done

  log ""
  sleep "$INTERVAL"
done
