#!/usr/bin/env bash
# =============================================================================
# openstack_cleanup.sh
# Deletes all resources belonging to a given OpenStack project ID.
#
# Usage:
#   ./openstack_cleanup.sh [--dry-run] <project-id>
#
# Options:
#   --dry-run   List resources that would be deleted without deleting them.
#
# Configuration:
#   Set OS_CLOUD below (or export it before running the script).
# =============================================================================

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit this value or export OS_CLOUD before running
# ──────────────────────────────────────────────────────────────────────────────
OS_CLOUD="${OS_CLOUD:-rxt-dfw-admin}"   # <-- change "mycloud" to your clouds.yaml entry

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
detail()  { echo -e "         ${YELLOW}↳ $*${RESET}"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}";
            echo -e "${BOLD}${CYAN}  $*${RESET}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

DRY_RUN=false
PROJECT_ID=""

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 [--dry-run] <project-id>"
    echo ""
    echo "  --dry-run    Show what would be deleted without making any changes."
    echo "  project-id   The OpenStack project (tenant) ID to clean up."
    echo ""
    echo "Set OS_CLOUD in the script or export it before running."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        -*) error "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$PROJECT_ID" ]]; then
                PROJECT_ID="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

[[ -z "$PROJECT_ID" ]] && { error "A project ID is required."; usage; }

# ──────────────────────────────────────────────────────────────────────────────
# Base OpenStack command
# ──────────────────────────────────────────────────────────────────────────────
OSC="openstack --os-cloud ${OS_CLOUD}"

# ──────────────────────────────────────────────────────────────────────────────
# Verify the project exists
# ──────────────────────────────────────────────────────────────────────────────
verify_project() {
    info "Verifying project ID: ${PROJECT_ID} on cloud: ${OS_CLOUD}"
    local name
    name=$($OSC project show "$PROJECT_ID" -f value -c name 2>/dev/null)
    if [[ -z "$name" ]]; then
        error "Project '${PROJECT_ID}' not found or you lack permission to view it."
        exit 1
    fi
    info "Project name: ${BOLD}${name}${RESET}"
}

# ──────────────────────────────────────────────────────────────────────────────
# print_api_error <captured_output>
#   Prints every non-blank line of an API error response, indented.
# ──────────────────────────────────────────────────────────────────────────────
print_api_error() {
    while IFS= read -r line; do
        [[ -n "$line" ]] && detail "$line"
    done <<< "$1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. SERVERS (Nova)
#    Waits for transitional states, captures the real API error + Nova fault.
# ──────────────────────────────────────────────────────────────────────────────
cleanup_servers() {
    header "Servers"
    local ids
    ids=$($OSC server list --project "$PROJECT_ID" --all-projects -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No servers found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        # Fetch name + status up front (useful in both dry-run and live)
        local name status
        name=$(  $OSC server show "$id" -f value -c name   2>/dev/null || echo "unknown")
        status=$(  $OSC server show "$id" -f value -c status 2>/dev/null || echo "unknown")

        if $DRY_RUN; then
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete server: ${id}  (name=${name}  status=${status})"
            continue
        fi

        echo -e "  Deleting server: ${id}  (name=${name}  status=${status})"

        # Wait out transitional states (BUILD, RESIZE, etc.) before deleting
        local attempts=0
        while [[ "$status" =~ ^(BUILD|RESIZE|VERIFY_RESIZE|MIGRATING|SHELVING|UNSHELVING)$ ]] \
              && (( attempts < 12 )); do
            info "  Waiting for server ${id} to leave transitional state ${status} (10 s)..."
            sleep 10
            status=$($OSC server show "$id" -f value -c status 2>/dev/null || echo "DELETED")
            (( attempts++ ))
        done

        local out rc
        out=$($OSC server delete "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted server: ${id}  (${name})"
        else
            warn "Failed to delete server: ${id}  (name=${name}  status=${status})"
            print_api_error "$out"
            # Pull Nova's fault blob — contains the hypervisor-level error message
            local fault
            fault=$($OSC server show "$id" -f value -c fault 2>/dev/null)
            if [[ -n "$fault" && "$fault" != "None" ]]; then
                detail "Nova fault: ${fault}"
            fi
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. FLOATING IPs (Neutron)
# ──────────────────────────────────────────────────────────────────────────────
cleanup_floating_ips() {
    header "Floating IPs"
    local ids
    ids=$($OSC floating ip list --project "$PROJECT_ID" -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No floating IPs found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        if $DRY_RUN; then
            local addr
            addr=$($OSC floating ip show "$id" -f value -c floating_ip_address 2>/dev/null)
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete floating IP: ${id}  (${addr})"
            continue
        fi

        echo -e "  Deleting floating IP: ${id}"
        local out rc
        out=$($OSC floating ip delete "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted floating IP: ${id}"
        else
            warn "Failed to delete floating IP: ${id}"
            print_api_error "$out"
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. LOAD BALANCERS (Octavia)  --cascade removes listeners/pools/members
# ──────────────────────────────────────────────────────────────────────────────
cleanup_load_balancers() {
    header "Load Balancers"
    local ids
    ids=$($OSC loadbalancer list --project "$PROJECT_ID" -f value -c id 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No load balancers found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        if $DRY_RUN; then
            local name
            name=$($OSC loadbalancer show "$id" -f value -c name 2>/dev/null)
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete load balancer (cascade): ${id}  (${name})"
            continue
        fi

        echo -e "  Deleting load balancer (cascade): ${id}"
        local out rc
        out=$($OSC loadbalancer delete --cascade "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted load balancer: ${id}"
        else
            warn "Failed to delete load balancer: ${id}"
            print_api_error "$out"
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper: emit subnet IDs attached to a router
# ──────────────────────────────────────────────────────────────────────────────
_router_subnet_ids() {
    local router_id="$1"
    $OSC router show "$router_id" -f json -c interfaces_info 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
ifaces = data.get('interfaces_info', [])
if isinstance(ifaces, str):
    ifaces = json.loads(ifaces)
for iface in ifaces:
    sid = iface.get('subnet_id', '')
    if sid:
        print(sid)
" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. ROUTERS — clear gateway, detach all subnet interfaces, then delete
# ──────────────────────────────────────────────────────────────────────────────
cleanup_routers() {
    header "Routers"
    local ids
    ids=$($OSC router list --project "$PROJECT_ID" -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No routers found."
        return
    fi

    while IFS= read -r router_id; do
        [[ -z "$router_id" ]] && continue

        local name
        name=$($OSC router show "$router_id" -f value -c name 2>/dev/null || echo "unknown")

        if $DRY_RUN; then
            local subnet_ids
            subnet_ids=$(_router_subnet_ids "$router_id")
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would clear gateway + detach interfaces from router: ${router_id}  (${name})"
            while IFS= read -r sid; do
                [[ -n "$sid" ]] && echo -e "           ${YELLOW}↳ would detach subnet: ${sid}${RESET}"
            done <<< "$subnet_ids"
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete router: ${router_id}  (${name})"
            continue
        fi

        echo -e "  Processing router: ${router_id}  (${name})"

        # Clear external gateway
        local out rc
        out=$($OSC router unset --external-gateway "$router_id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            info "  Cleared gateway on router ${router_id}"
        else
            # A missing gateway is harmless; only surface real errors
            if ! echo "$out" | grep -qiE "no.*gateway|not.*set|nothing|No.*external"; then
                detail "router unset gateway: $out"
            fi
        fi

        # Detach every subnet interface
        local subnet_ids
        subnet_ids=$(_router_subnet_ids "$router_id")
        while IFS= read -r subnet_id; do
            [[ -z "$subnet_id" ]] && continue
            out=$($OSC router remove subnet "$router_id" "$subnet_id" 2>&1); rc=$?
            if [[ $rc -eq 0 ]]; then
                info "  Detached subnet ${subnet_id} from router ${router_id}"
            else
                warn "  Could not detach subnet ${subnet_id} from router ${router_id}"
                print_api_error "$out"
            fi
        done <<< "$subnet_ids"

        out=$($OSC router delete "$router_id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted router: ${router_id}  (${name})"
        else
            warn "Failed to delete router: ${router_id}  (${name})"
            print_api_error "$out"
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. PORTS — explicit pre-flight before subnet/network deletion.
#
#    After servers, LBs, and routers are gone, some non-system ports may still
#    linger (e.g. trunk ports, direct-attach ports, orphaned compute ports).
#    This step finds and deletes them so subnets and networks can be removed.
#
#    System-owned ports (DHCP agents, router interfaces, LB VIPs) are skipped
#    here — Neutron removes them automatically when their parent is deleted.
# ──────────────────────────────────────────────────────────────────────────────

# Regex of device_owner values that belong to the OpenStack control plane.
# We skip these so we don't race with Neutron's own cleanup.
SYSTEM_OWNERS="^(network:dhcp|network:router_interface|network:router_interface_distributed|network:router_gateway|network:ha_router_replicated_interface|network:floatingip|neutron:LOADBALANCERV2|neutron:LOADBALANCERVIP|octavia:|network:distributed)"

cleanup_ports() {
    header "Ports (orphan cleanup before subnets/networks)"

    local net_ids
    net_ids=$($OSC network list --project "$PROJECT_ID" -f value -c ID 2>/dev/null)
    if [[ -z "$net_ids" ]]; then
        info "No project networks found — skipping port cleanup."
        return
    fi

    local found_any=false

    while IFS= read -r net_id; do
        [[ -z "$net_id" ]] && continue

        # List ports: ID, device_owner, device_id, status, name
        local port_lines
        port_lines=$($OSC port list --network "$net_id" \
            -f value -c ID -c device_owner -c device_id -c status -c name 2>/dev/null)
        [[ -z "$port_lines" ]] && continue

        while IFS= read -r port_line; do
            [[ -z "$port_line" ]] && continue
            found_any=true

            local port_id device_owner device_id p_status p_name
            port_id=$(      echo "$port_line" | awk '{print $1}')
            device_owner=$( echo "$port_line" | awk '{print $2}')
            device_id=$(    echo "$port_line" | awk '{print $3}')
            p_status=$(     echo "$port_line" | awk '{print $4}')
            p_name=$(       echo "$port_line" | awk '{$1=$2=$3=$4=""; print $0}' | xargs)

            # Skip control-plane ports
            if echo "$device_owner" | grep -qE "$SYSTEM_OWNERS"; then
                if $DRY_RUN; then
                    echo -e "  ${CYAN}[DRY-RUN]${RESET} Would skip system port: ${port_id}  owner=${device_owner}"
                else
                    info "  Skipping system port: ${port_id}  (owner=${device_owner})"
                fi
                continue
            fi

            if $DRY_RUN; then
                echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete orphan port: ${port_id}"
                echo -e "           owner=${device_owner}  device=${device_id}  status=${p_status}  name=${p_name}"
                continue
            fi

            echo -e "  Deleting orphan port: ${port_id}  owner=${device_owner}  device=${device_id}  status=${p_status}"
            local out rc
            out=$($OSC port delete "$port_id" 2>&1); rc=$?
            if [[ $rc -eq 0 ]]; then
                success "Deleted port: ${port_id}"
            else
                warn "Failed to delete port: ${port_id}  (owner=${device_owner})"
                print_api_error "$out"
                if [[ -n "$device_id" && "$device_id" != "None" ]]; then
                    detail "Port is still bound to device: ${device_id}"
                    detail "Ensure that device is fully deleted, then re-run the script."
                fi
            fi
        done <<< "$port_lines"
    done <<< "$net_ids"

    $found_any || info "No orphan ports found."
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. SUBNETS
# ──────────────────────────────────────────────────────────────────────────────
cleanup_subnets() {
    header "Subnets"
    local ids
    ids=$($OSC subnet list --project "$PROJECT_ID" -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No subnets found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        if $DRY_RUN; then
            local name cidr
            name=$($OSC subnet show "$id" -f value -c name 2>/dev/null)
            cidr=$($OSC subnet show "$id" -f value -c cidr 2>/dev/null)
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete subnet: ${id}  (name=${name}  cidr=${cidr})"
            continue
        fi

        echo -e "  Deleting subnet: ${id}"
        local out rc
        out=$($OSC subnet delete "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted subnet: ${id}"
        else
            warn "Failed to delete subnet: ${id}"
            print_api_error "$out"
            # Show exactly which ports still hold IPs on this subnet
            local stuck
            stuck=$($OSC port list --fixed-ip subnet="$id" \
                -f value -c ID -c device_owner -c device_id -c status 2>/dev/null)
            if [[ -n "$stuck" ]]; then
                detail "Ports still allocated on subnet ${id} (blocking deletion):"
                while IFS= read -r pline; do
                    [[ -n "$pline" ]] && detail "  → $pline"
                done <<< "$stuck"
            fi
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. NETWORKS
# ──────────────────────────────────────────────────────────────────────────────
cleanup_networks() {
    header "Networks"
    local ids
    ids=$($OSC network list --project "$PROJECT_ID" -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No networks found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        if $DRY_RUN; then
            local name
            name=$($OSC network show "$id" -f value -c name 2>/dev/null)
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete network: ${id}  (${name})"
            continue
        fi

        echo -e "  Deleting network: ${id}"
        local out rc
        out=$($OSC network delete "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted network: ${id}"
        else
            warn "Failed to delete network: ${id}"
            print_api_error "$out"
            # List every remaining port so the user knows exactly what's blocking it
            local remaining
            remaining=$($OSC port list --network "$id" \
                -f value -c ID -c device_owner -c device_id -c status 2>/dev/null)
            if [[ -n "$remaining" ]]; then
                detail "Ports still present on network ${id} (blocking deletion):"
                while IFS= read -r pline; do
                    [[ -n "$pline" ]] && detail "  → $pline"
                done <<< "$remaining"
            fi
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. VOLUMES (Cinder)
#
#    Two classes of problem are handled before every delete attempt:
#
#    A) BAD STATUS — Cinder only deletes from: available, error,
#       error_restoring, error_extending, error_managing.
#       Anything else (reserved, attaching, detaching, in-use, maintenance,
#       backing-up, awaiting-transfer, error_deleting) gets reset to
#       'available' via `volume set --state` first.
#
#    B) STALE ATTACHMENT RECORDS — A volume can be status=available yet still
#       have orphaned attachment rows in Cinder's DB (left behind when a server
#       is force-deleted mid-attach).  Cinder rejects the delete with
#       "must not be...attached" even though status looks clean.
#       We enumerate every attachment via `volume attachment list` and delete
#       each one with `volume attachment delete` before attempting the volume
#       delete.  This is the cinderclient v3 attachments API (microversion 3.27+)
#       and requires the same admin credentials used for the rest of this script.
# ──────────────────────────────────────────────────────────────────────────────

# Statuses that need a reset before Cinder will accept a delete request
VOLUME_RESET_STATUSES="reserved|attaching|detaching|in-use|maintenance|backing-up|awaiting-transfer|error_deleting"

# _purge_volume_attachments <volume-id>
#
#   For every attachment record on the volume, attempts removal in this order:
#
#   1. Try `volume attachment delete` (Cinder v3 attachments API, mv 3.27+).
#      Works for orphaned records whose server is already gone.
#
#   2. If Cinder returns 409 ConflictNovaUsingAttachment it means Nova still
#      holds a lock on that attachment (instance may be in a deleting/error
#      state but Nova's conductor hasn't cleaned up yet).  We:
#        a. Extract the instance ID from the 409 error message.
#        b. Call `server remove volume` on Nova to send the proper detach RPC
#           and release Nova's lock on the attachment.
#        c. Retry `volume attachment delete` once the Nova call completes.
#
#   3. If Nova detach also fails (instance truly gone from Nova's DB), we
#      force-reset the volume state via `volume set --state available`, which
#      clears Cinder's attachment table entry as a side-effect.
#
_purge_volume_attachments() {
    local vol_id="$1"

    # Fetch: attachment-id  instance-id  attach_status
    local att_lines
    att_lines=$($OSC volume attachment list --volume-id "$vol_id" \
                -f value -c ID -c instance_id -c attach_status 2>/dev/null)
    [[ -z "$att_lines" ]] && return 0

    while IFS= read -r att_line; do
        [[ -z "$att_line" ]] && continue

        local att_id instance_id att_status
        att_id=$(     echo "$att_line" | awk '{print $1}')
        instance_id=$(echo "$att_line" | awk '{print $2}')
        att_status=$( echo "$att_line" | awk '{print $3}')

        info "  Removing attachment: ${att_id}  instance=${instance_id}  attach_status=${att_status}"

        # ── Step 1: Try Cinder attachment delete directly ──────────────────
        local aout arc
        aout=$($OSC volume attachment delete "$att_id" 2>&1); arc=$?

        if [[ $arc -eq 0 ]]; then
            success "  Removed attachment record: ${att_id}"
            continue
        fi

        # ── Step 2: 409 means Nova owns this attachment ────────────────────
        if echo "$aout" | grep -q "ConflictNovaUsingAttachment"; then
            # Pull the instance ID from the error text if the column was empty/None
            if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
                instance_id=$(echo "$aout" \
                    | grep -oE 'instance [0-9a-f-]{36}' \
                    | awk '{print $2}' | head -1)
            fi

            if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
                info "  Nova owns attachment — calling 'server remove volume' on instance ${instance_id}"
                local nova_out nova_rc
                nova_out=$($OSC server remove volume "$instance_id" "$vol_id" 2>&1); nova_rc=$?

                if [[ $nova_rc -eq 0 ]]; then
                    success "  Nova detached volume ${vol_id} from instance ${instance_id}"
                    # Brief pause for Nova->Cinder RPC to settle, then retry
                    sleep 3
                    aout=$($OSC volume attachment delete "$att_id" 2>&1); arc=$?
                    if [[ $arc -eq 0 ]]; then
                        success "  Removed attachment record: ${att_id}"
                        continue
                    else
                        # Nova detach may have already removed the record; a 404 is fine
                        if echo "$aout" | grep -qE "404|No.*attachment|not found"; then
                            success "  Attachment ${att_id} already cleaned up by Nova detach"
                            continue
                        fi
                        warn "  Attachment delete still failed after Nova detach: ${att_id}"
                        print_api_error "$aout"
                    fi
                else
                    # Nova doesn't know about the instance — fall through to force-reset
                    info "  Nova detach failed (instance may be fully gone): ${instance_id}"
                    if ! echo "$nova_out" | grep -qiE "404|No.*server|not found"; then
                        print_api_error "$nova_out"
                    fi
                fi
            fi

            # ── Step 3: Force-reset volume state ──────────────────────────
            # `volume set --state available` reinitialises the volume record
            # and drops attachment rows that Nova is no longer tracking.
            info "  Force-resetting volume state to clear Nova-owned attachment: ${att_id}"
            local rout rrc
            rout=$($OSC volume set --state available "$vol_id" 2>&1); rrc=$?
            if [[ $rrc -eq 0 ]]; then
                success "  Force-reset cleared attachment for volume ${vol_id}"
            else
                warn "  Force-reset also failed for volume ${vol_id}"
                print_api_error "$rout"
            fi
        else
            # Some other error on the Cinder attachment delete
            warn "  Could not remove attachment record: ${att_id}  (volume ${vol_id})"
            print_api_error "$aout"
        fi
    done <<< "$att_lines"
}

cleanup_volumes() {
    header "Volumes"
    local ids
    ids=$($OSC volume list --project "$PROJECT_ID" --all-projects -f value -c ID 2>/dev/null)

    if [[ -z "$ids" ]]; then
        info "No volumes found."
        return
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        local name status
        name=$(   $OSC volume show "$id" -f value -c name   2>/dev/null || echo "unknown")
        status=$( $OSC volume show "$id" -f value -c status 2>/dev/null || echo "unknown")

        # ── Dry-run: report status issues and stale attachments, then move on ──
        if $DRY_RUN; then
            echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would delete volume: ${id}  (name=${name}  status=${status})"
            if echo "$status" | grep -qE "$VOLUME_RESET_STATUSES"; then
                echo -e "           ${YELLOW}↳ status '${status}' would be reset to 'available' before deletion${RESET}"
            fi
            local dry_att_ids
            dry_att_ids=$($OSC volume attachment list --volume-id "$id" \
                          -f value -c ID 2>/dev/null)
            if [[ -n "$dry_att_ids" ]]; then
                echo -e "           ${YELLOW}↳ stale attachment records that would be purged:${RESET}"
                while IFS= read -r aid; do
                    [[ -n "$aid" ]] && echo -e "             ${YELLOW}↳ attachment: ${aid}${RESET}"
                done <<< "$dry_att_ids"
            fi
            continue
        fi

        echo -e "  Deleting volume: ${id}  (name=${name}  status=${status})"

        # ── A) Reset non-deletable status ────────────────────────────────────
        if echo "$status" | grep -qE "$VOLUME_RESET_STATUSES"; then
            info "  Volume is in non-deletable status '${status}' — resetting to 'available'"
            local reset_out reset_rc
            reset_out=$($OSC volume set --state available "$id" 2>&1); reset_rc=$?
            if [[ $reset_rc -eq 0 ]]; then
                success "  Reset volume ${id} to 'available'"
                status="available"
            else
                warn "  Could not reset volume ${id} state — skipping delete"
                print_api_error "$reset_out"
                detail "Try manually:  openstack --os-cloud ${OS_CLOUD} volume set --state available ${id}"
                continue
            fi
        fi

        # ── B) Purge any stale attachment records (even when status=available) ─
        #    These are left behind when a server is force-deleted mid-attach.
        #    Cinder's delete check inspects the attachments table directly, so a
        #    clean status field is not enough — the rows must be gone too.
        _purge_volume_attachments "$id"

        # ── Attempt deletion ──────────────────────────────────────────────────
        local out rc
        out=$($OSC volume delete "$id" 2>&1); rc=$?
        if [[ $rc -eq 0 ]]; then
            success "Deleted volume: ${id}  (${name})"
        else
            local new_status
            new_status=$($OSC volume show "$id" -f value -c status 2>/dev/null || echo "unknown")
            warn "Failed to delete volume: ${id}  (name=${name}  status=${new_status})"
            print_api_error "$out"
            # Surface any attachment records that are still blocking
            local remaining_att
            remaining_att=$($OSC volume attachment list --volume-id "$id" \
                            -f value -c ID -c attach_status -c instance_id 2>/dev/null)
            if [[ -n "$remaining_att" ]]; then
                detail "Attachment records still present on volume ${id}:"
                while IFS= read -r aline; do
                    [[ -n "$aline" ]] && detail "  → ${aline}"
                done <<< "$remaining_att"
            fi
            detail "To retry manually:"
            detail "  openstack --os-cloud ${OS_CLOUD} volume attachment list --volume-id ${id}"
            detail "  openstack --os-cloud ${OS_CLOUD} volume attachment delete <attachment-id>"
            detail "  openstack --os-cloud ${OS_CLOUD} volume delete ${id}"
        fi
    done <<< "$ids"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}OpenStack Project Cleanup${RESET}"
    echo -e "  Cloud:      ${BOLD}${OS_CLOUD}${RESET}"
    echo -e "  Project ID: ${BOLD}${PROJECT_ID}${RESET}"
    if $DRY_RUN; then
        echo -e "  Mode:       ${YELLOW}${BOLD}DRY RUN — no changes will be made${RESET}"
    else
        echo -e "  Mode:       ${RED}${BOLD}LIVE — resources WILL be deleted${RESET}"
    fi
    echo ""

    if ! $DRY_RUN; then
        read -r -p "$(echo -e "${RED}WARNING:${RESET} This will permanently delete resources. Type the project ID to confirm: ")" confirm
        if [[ "$confirm" != "$PROJECT_ID" ]]; then
            error "Confirmation did not match. Aborting."
            exit 1
        fi
    fi

    verify_project

    # ── Deletion order ────────────────────────────────────────────────────────
    # Each step removes blockers so the next step can succeed cleanly.
    #
    #  1. Servers       — releases compute ports + detaches volumes
    #  2. Floating IPs  — must be gone before router gateways clear
    #  3. LBs           — cascade removes listeners/pools/amphora ports
    #  4. Routers       — gateway cleared, subnet interfaces detached
    #  5. Ports         — any orphan ports still on project networks
    #  6. Subnets       — should now be clear of all port allocations
    #  7. Networks      — should now be clear of all ports/subnets
    #  8. Volumes       — after servers have fully released them
    # ─────────────────────────────────────────────────────────────────────────
    cleanup_servers
    cleanup_floating_ips
    cleanup_load_balancers
    cleanup_routers
    cleanup_ports
    cleanup_subnets
    cleanup_networks
    cleanup_volumes

    echo ""
    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}Dry run complete. No resources were modified.${RESET}"
        echo -e "Run without --dry-run to perform the actual deletion."
    else
        echo -e "${GREEN}${BOLD}Cleanup complete for project: ${PROJECT_ID}${RESET}"
    fi
    echo ""
}

main
