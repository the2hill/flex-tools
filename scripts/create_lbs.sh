#!/bin/bash

usage() {
  echo "Usage: $0 [options] <count> <member_ip1> [member_ip2] ..."
  echo ""
  echo "Options:"
  echo "  -c, --os-cloud <cloud>        OpenStack cloud name"
  echo "  -e, --os-extra <args>         Additional openstack client flags e.g. '--insecure'"
  echo "  -s, --subnet <subnet_id>      Subnet ID to use for VIP and members (auto-detected if not set)"
  echo "  -n, --network <network_id>    External network for floating IPs (auto-detected if not set)"
  echo "  -p, --protocol <proto>        Listener/pool protocol (default: HTTP)"
  echo "  -P, --port <port>             Listener port (skips prompt if set)"
  echo "  -m, --member-port <port>      Member port (skips prompt if set)"
  echo "  -a, --algorithm <algo>        LB algorithm (default: ROUND_ROBIN)"
  echo "  -x, --parallel                Create all load balancers in parallel"
  echo "  -h, --help                    Show this help"
  echo ""
  echo "Environment variables (flags take precedence):"
  echo "  OS_CLOUD                      OpenStack cloud name"
  echo "  OS_CLIENT_ARGS                Additional openstack client flags"
  echo "  OS_SUBNET_ID                  Subnet ID to use"
  echo "  OS_EXT_NETWORK_ID             External network ID for floating IPs"
  echo ""
  echo "Examples:"
  echo "  $0 -c mycloud 3 10.0.0.1 10.0.0.2"
  echo "  $0 -c mycloud -x 3 10.0.0.1 10.0.0.2"
  echo "  $0 -c mycloud -s subnet-uuid -n ext-net-uuid -P 443 -m 8443 3 10.0.0.1"
  exit 0
}

# Defaults
CLOUD="${OS_CLOUD:-}"
EXTRA_ARGS="${OS_CLIENT_ARGS:-}"
SUBNET="${OS_SUBNET_ID:-}"
EXT_NETWORK="${OS_EXT_NETWORK_ID:-}"
PROTOCOL="HTTP"
PROTOCOL_PORT=""
MEMBER_PORT=""
LB_ALGORITHM="ROUND_ROBIN"
PARALLEL=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--os-cloud)    CLOUD="$2";         shift 2 ;;
    -e|--os-extra)    EXTRA_ARGS="$2";    shift 2 ;;
    -s|--subnet)      SUBNET="$2";        shift 2 ;;
    -n|--network)     EXT_NETWORK="$2";   shift 2 ;;
    -p|--protocol)    PROTOCOL="$2";      shift 2 ;;
    -P|--port)        PROTOCOL_PORT="$2"; shift 2 ;;
    -m|--member-port) MEMBER_PORT="$2";   shift 2 ;;
    -a|--algorithm)   LB_ALGORITHM="$2";  shift 2 ;;
    -x|--parallel)    PARALLEL=true;      shift ;;
    -h|--help)        usage ;;
    --) shift; break ;;
    -*) echo "Unknown flag: $1"; usage ;;
    *)  break ;;
  esac
done

COUNT=$1
shift
MEMBER_IPS=("$@")

if [ -z "$COUNT" ] || [ ${#MEMBER_IPS[@]} -eq 0 ]; then
  usage
fi

# Build openstack command
OSC="openstack"
[ -n "$CLOUD" ]      && OSC="$OSC --os-cloud $CLOUD"
[ -n "$EXTRA_ARGS" ] && OSC="$OSC $EXTRA_ARGS"

# Auto-detect subnet
if [ -z "$SUBNET" ]; then
  echo "No subnet specified, auto-detecting..."
  SUBNET_LIST=$($OSC subnet list -f value -c ID -c Name | grep -iv "public")
  SUBNET_COUNT=$(echo "$SUBNET_LIST" | grep -c .)

  if [ "$SUBNET_COUNT" -eq 0 ]; then
    echo "ERROR: No non-public subnets found. Please specify with -s"
    exit 1
  elif [ "$SUBNET_COUNT" -eq 1 ]; then
    SUBNET=$(echo "$SUBNET_LIST" | awk '{print $1}')
    SUBNET_NAME=$(echo "$SUBNET_LIST" | awk '{print $2}')
    echo "  Auto-selected subnet: $SUBNET_NAME ($SUBNET)"
  else
    echo "  Multiple subnets available (excluding PUBLIC):"
    echo ""
    i=1
    while IFS= read -r line; do
      echo "  $i) $line"
      SUBNET_IDS[$i]=$(echo "$line" | awk '{print $1}')
      SUBNET_NAMES[$i]=$(echo "$line" | awk '{print $2}')
      ((i++))
    done <<< "$SUBNET_LIST"
    echo ""
    read -rp "  Select subnet number [1-$((i-1))]: " SELECTION
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -ge "$i" ]; then
      echo "ERROR: Invalid selection"
      exit 1
    fi
    SUBNET="${SUBNET_IDS[$SELECTION]}"
    SUBNET_NAME="${SUBNET_NAMES[$SELECTION]}"
    echo "  Selected: $SUBNET_NAME ($SUBNET)"
  fi
fi

# Auto-detect external network
if [ -z "$EXT_NETWORK" ]; then
  echo "No external network specified, auto-detecting..."
  EXT_NET_LIST=$($OSC network list --external -f value -c ID -c Name)
  EXT_NET_COUNT=$(echo "$EXT_NET_LIST" | grep -c .)

  if [ "$EXT_NET_COUNT" -eq 0 ]; then
    echo "ERROR: No external networks found. Please specify with -n"
    exit 1
  elif [ "$EXT_NET_COUNT" -eq 1 ]; then
    EXT_NETWORK=$(echo "$EXT_NET_LIST" | awk '{print $1}')
    EXT_NET_NAME=$(echo "$EXT_NET_LIST" | awk '{print $2}')
    echo "  Auto-selected external network: $EXT_NET_NAME ($EXT_NETWORK)"
  else
    echo "  Multiple external networks available:"
    echo ""
    i=1
    while IFS= read -r line; do
      echo "  $i) $line"
      EXT_NET_IDS[$i]=$(echo "$line" | awk '{print $1}')
      EXT_NET_NAMES[$i]=$(echo "$line" | awk '{print $2}')
      ((i++))
    done <<< "$EXT_NET_LIST"
    echo ""
    read -rp "  Select network number [1-$((i-1))]: " SELECTION
    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -ge "$i" ]; then
      echo "ERROR: Invalid selection"
      exit 1
    fi
    EXT_NETWORK="${EXT_NET_IDS[$SELECTION]}"
    EXT_NET_NAME="${EXT_NET_NAMES[$SELECTION]}"
    echo "  Selected: $EXT_NET_NAME ($EXT_NETWORK)"
  fi
fi

# Prompt for listener port
if [ -z "$PROTOCOL_PORT" ]; then
  while true; do
    read -rp "Listener port [80]: " PROTOCOL_PORT
    PROTOCOL_PORT="${PROTOCOL_PORT:-80}"
    [[ "$PROTOCOL_PORT" =~ ^[0-9]+$ ]] && [ "$PROTOCOL_PORT" -ge 1 ] && [ "$PROTOCOL_PORT" -le 65535 ] && break
    echo "  Invalid port, must be 1-65535"
  done
fi

# Prompt for member port
if [ -z "$MEMBER_PORT" ]; then
  while true; do
    read -rp "Member port [$PROTOCOL_PORT]: " MEMBER_PORT
    MEMBER_PORT="${MEMBER_PORT:-$PROTOCOL_PORT}"
    [[ "$MEMBER_PORT" =~ ^[0-9]+$ ]] && [ "$MEMBER_PORT" -ge 1 ] && [ "$MEMBER_PORT" -le 65535 ] && break
    echo "  Invalid port, must be 1-65535"
  done
fi

# -------------------------------------------------------
# Pre-flight: build a shared pool of available FIP IDs
# stored in TMPDIR so parallel jobs can claim them
# -------------------------------------------------------
TMPDIR=$(mktemp -d)
#trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "Checking for available floating IPs on $EXT_NETWORK..."
$OSC floating ip list \
  --network "$EXT_NETWORK" \
  --status DOWN \
  -f value -c ID -c "Floating IP Address" | while read -r fip_id fip_addr; do
    echo "$fip_id $fip_addr" >> "$TMPDIR/available_fips"
done

AVAIL_COUNT=$(wc -l < "$TMPDIR/available_fips" 2>/dev/null || echo 0)
echo "  Found $AVAIL_COUNT unassociated floating IP(s) available"

echo ""
echo "Configuration:"
echo "  OpenStack command : $OSC"
echo "  Subnet            : $SUBNET"
echo "  External network  : $EXT_NETWORK"
echo "  Protocol          : $PROTOCOL"
echo "  Listener port     : $PROTOCOL_PORT"
echo "  Member port       : $MEMBER_PORT"
echo "  Algorithm         : $LB_ALGORITHM"
echo "  LB count          : $COUNT"
echo "  Members           : ${MEMBER_IPS[*]}"
echo "  Parallel          : $PARALLEL"
echo "  Available FIPs    : $AVAIL_COUNT"
echo ""

# -------------------------------------------------------
# Claim a FIP from the pool or create a new one.
# Uses a lockfile so parallel jobs don't claim the same FIP.
# -------------------------------------------------------
claim_or_create_fip() {
  local port_id=$1
  local FIP_ID=""
  local FIP_ADDRESS=""
  local REUSED=false
  local LOCKFILE="$TMPDIR/fip.lock"

  # Attempt to claim an available FIP atomically
  (
    flock -x 200
    if [ -s "$TMPDIR/available_fips" ]; then
      # Take the first available FIP
      read -r FIP_ID FIP_ADDRESS < "$TMPDIR/available_fips"
      # Remove it from the pool
      sed -i "1d" "$TMPDIR/available_fips"
      echo "$FIP_ID $FIP_ADDRESS" > "$TMPDIR/claimed_$$"
    fi
  ) 200>"$LOCKFILE"

  if [ -f "$TMPDIR/claimed_$$" ]; then
    read -r FIP_ID FIP_ADDRESS < "$TMPDIR/claimed_$$"
    rm -f "$TMPDIR/claimed_$$"
    REUSED=true
  fi

  if [ "$REUSED" = true ] && [ -n "$FIP_ID" ]; then
    # Associate the existing FIP to the VIP port
    echo "  Reusing existing floating IP: $FIP_ADDRESS ($FIP_ID)"
    $OSC floating ip set --port "$port_id" "$FIP_ID" > /dev/null
    if [ $? -ne 0 ]; then
      echo "  WARNING: Failed to associate existing FIP $FIP_ID — creating new one"
      FIP_ID=""
    fi
  fi

  # If no FIP claimed or association failed, create a new one
  if [ -z "$FIP_ID" ]; then
    echo "  No available floating IPs — creating new one..."
    FIP_ID=$($OSC floating ip create \
      --port "$port_id" \
      "$EXT_NETWORK" \
      -f value -c id)
    if [ -z "$FIP_ID" ]; then
      echo "  ERROR: Failed to create floating IP"
      echo "FAILED"
      return 1
    fi
    FIP_ADDRESS=$($OSC floating ip show "$FIP_ID" -f value -c floating_ip_address)
    echo "  Created new floating IP: $FIP_ADDRESS ($FIP_ID)"
  fi

  echo "$FIP_ID $FIP_ADDRESS"
}

# -------------------------------------------------------
# Core function to create a single LB
# -------------------------------------------------------
create_lb() {
  local i=$1
  local LB_NAME="lb-test-${i}-$(date +%s)"
  local LOG="$TMPDIR/lb-${i}.log"
  local SUMMARY_FILE="$TMPDIR/lb-${i}.summary"

  {
    echo "--------------------------------------"
    echo "Creating load balancer $i/$COUNT: $LB_NAME"

    LB_ID=$($OSC loadbalancer create \
      --name "$LB_NAME" \
      --vip-subnet-id "$SUBNET" \
      --provider amphora \
      -f value -c id)

    if [ -z "$LB_ID" ]; then
      echo "ERROR: Failed to create load balancer $LB_NAME"
      echo "$LB_NAME | ERROR | - | - | - | - | -" > "$SUMMARY_FILE"
      return 1
    fi
    echo "  LB ID: $LB_ID"

    echo "  Waiting for LB to become ACTIVE..."
    for attempt in $(seq 1 60); do
      STATUS=$($OSC loadbalancer show "$LB_ID" -f value -c provisioning_status)
      if [ "$STATUS" = "ACTIVE" ]; then
        echo "  LB is ACTIVE"
        break
      elif [ "$STATUS" = "ERROR" ]; then
        echo "  ERROR: LB entered ERROR state"
        echo "$LB_NAME | $LB_ID | ERROR | - | - | - | -" > "$SUMMARY_FILE"
        return 1
      fi
      sleep 5
    done

    echo "  Creating listener..."
    LISTENER_ID=$($OSC loadbalancer listener create \
      --name "${LB_NAME}-listener" \
      --protocol "$PROTOCOL" \
      --protocol-port "$PROTOCOL_PORT" \
      "$LB_ID" \
      -f value -c id)
    echo "  Listener ID: $LISTENER_ID"

    for attempt in $(seq 1 30); do
      STATUS=$($OSC loadbalancer show "$LB_ID" -f value -c provisioning_status)
      [ "$STATUS" = "ACTIVE" ] && break
      sleep 3
    done

    echo "  Creating pool..."
    POOL_ID=$($OSC loadbalancer pool create \
      --name "${LB_NAME}-pool" \
      --protocol "$PROTOCOL" \
      --lb-algorithm "$LB_ALGORITHM" \
      --listener "$LISTENER_ID" \
      -f value -c id)
    echo "  Pool ID: $POOL_ID"

    for attempt in $(seq 1 30); do
      STATUS=$($OSC loadbalancer show "$LB_ID" -f value -c provisioning_status)
      [ "$STATUS" = "ACTIVE" ] && break
      sleep 3
    done

    for MEMBER_IP in "${MEMBER_IPS[@]}"; do
      echo "  Adding member: $MEMBER_IP"
      MEMBER_ID=$($OSC loadbalancer member create \
        --address "$MEMBER_IP" \
        --protocol-port "$MEMBER_PORT" \
        --subnet-id "$SUBNET" \
        "$POOL_ID" \
        -f value -c id)
      echo "  Member ID: $MEMBER_ID"

      for attempt in $(seq 1 30); do
        STATUS=$($OSC loadbalancer show "$LB_ID" -f value -c provisioning_status)
        [ "$STATUS" = "ACTIVE" ] && break
        sleep 3
      done
    done

    VIP_PORT_ID=$($OSC loadbalancer show "$LB_ID" -f value -c vip_port_id)
    VIP_ADDRESS=$($OSC loadbalancer show "$LB_ID" -f value -c vip_address)
    echo "  VIP address: $VIP_ADDRESS (port: $VIP_PORT_ID)"

    # Claim or create FIP
    FIP_RESULT=$(claim_or_create_fip "$VIP_PORT_ID")
    if [ "$FIP_RESULT" = "FAILED" ] || [ -z "$FIP_RESULT" ]; then
      echo "  ERROR: Could not assign floating IP"
      echo "$LB_NAME | $LB_ID | $VIP_ADDRESS | NO_FIP | - | $LISTENER_ID | $POOL_ID" > "$SUMMARY_FILE"
      return 1
    fi

    FIP_ID=$(echo "$FIP_RESULT" | tail -1 | awk '{print $1}')
    FIP_ADDRESS=$(echo "$FIP_RESULT" | tail -1 | awk '{print $2}')

    echo "  Done: $LB_NAME"
    echo "$LB_NAME | $LB_ID | $VIP_ADDRESS | $FIP_ADDRESS | $FIP_ID | $LISTENER_ID | $POOL_ID" > "$SUMMARY_FILE"

  } | tee "$LOG"
}

# -------------------------------------------------------
# Execute
# -------------------------------------------------------
declare -a PIDS

if [ "$PARALLEL" = true ]; then
  echo "Running in PARALLEL mode — logs in $TMPDIR"
  echo ""
  for i in $(seq 1 "$COUNT"); do
    create_lb "$i" &
    PIDS+=($!)
    echo "  Spawned LB $i (PID ${PIDS[-1]})"
  done

  echo ""
  echo "Waiting for all $COUNT jobs to complete..."
  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
  echo "All jobs complete."
else
  for i in $(seq 1 "$COUNT"); do
    create_lb "$i"
  done
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "======================================"
echo "SUMMARY"
echo "======================================"
printf "%-30s %-38s %-16s %-16s %-38s %-38s %-38s\n" \
  "NAME" "LB_ID" "VIP" "FLOATING_IP" "FIP_ID" "LISTENER_ID" "POOL_ID"
echo "$(printf '%.0s-' {1..210})"

for i in $(seq 1 "$COUNT"); do
  SUMMARY_FILE="$TMPDIR/lb-${i}.summary"
  if [ -f "$SUMMARY_FILE" ]; then
    IFS='|' read -r name lb_id vip fip fip_id listener_id pool_id < "$SUMMARY_FILE"
    printf "%-30s %-38s %-16s %-16s %-38s %-38s %-38s\n" \
      "$(echo "$name" | xargs)" \
      "$(echo "$lb_id" | xargs)" \
      "$(echo "$vip" | xargs)" \
      "$(echo "$fip" | xargs)" \
      "$(echo "$fip_id" | xargs)" \
      "$(echo "$listener_id" | xargs)" \
      "$(echo "$pool_id" | xargs)"
  else
    printf "%-30s %-38s\n" "lb-test-${i}" "NO SUMMARY — check $TMPDIR/lb-${i}.log"
  fi
done
echo ""

if [ "$PARALLEL" = true ]; then
  echo "Full logs available in: $TMPDIR"
 # echo "(logs are removed on script exit — copy if needed)"
fi
