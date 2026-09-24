#!/bin/bash
#
# Migration Health Validator
# A tool to generate health reports for MTV migrations - both post-completion and live monitoring
#
# Usage:
#   ./MigrationHealthValidator.sh [report] <PlanName> [Namespace]     # 'report' is default
#   ./MigrationHealthValidator.sh --from-logs=<PATH>                  # Offline with interactive cycle selection
#   ./MigrationHealthValidator.sh monitor <PlanName> [Namespace] [--timeout=3600]
#
# Examples:
#   # Online (from live cluster)
#   ./MigrationHealthValidator.sh single-vm-warm-ibm
#   ./MigrationHealthValidator.sh report single-vm-warm-ibm
#   ./MigrationHealthValidator.sh monitor 10vms-cold-migration openshift-mtv --timeout=7200
#
#   # Offline (from saved logs folder - shows cycle list with PASS/FAIL status)
#   ./MigrationHealthValidator.sh --from-logs=~/MTV/results/2-11-0-33/10vm-cold-tc6-1/logs
#

set -o pipefail

#######################################
# Configuration & Defaults
#######################################
DEFAULT_NAMESPACE="openshift-mtv"
DEFAULT_TIMEOUT=3600  # 1 hour default for monitoring
STUCK_THRESHOLD_MINUTES=30  # Consider VM stuck if no progress for 30 min
OUTLIER_THRESHOLD_PERCENT=200  # VM taking 2x avg time is an outlier
POLL_INTERVAL=30  # Seconds between monitoring checks
DEFAULT_RESULTS_PATH="/home/$USER/MTV/results"  # Default logs folder location
DEFAULT_MTV_DEBUG_PATH="/home/$USER/Tzahi_MTV"  # Default mtv-debug folder location
DEFAULT_WEB_OUTPUT_PATH="/tmp/MTV-Dashboard/results-data"  # Temp folder for web generation

# Verify required environment variables are present (injected by bws run or source .env)
if [[ -z "${REMOTE_WEB_SERVER}" || -z "${REMOTE_WEB_USER}" || -z "${REMOTE_WEB_PATH}" ]]; then
    echo "ERROR: Required environment variables not set: REMOTE_WEB_SERVER, REMOTE_WEB_USER, REMOTE_WEB_PATH"
    echo "Current user: $USER"
    echo ""
    echo "Run with bws (recommended):"
    echo "  cd /home/$USER/git/mpqe-scale-scripts/MTV"
    echo "  ./run-with-secrets.sh ./utils/MigrationHealthValidator/MigrationHealthValidator.sh"
    echo ""
    echo "Or: bws run -- ./MigrationHealthValidator.sh (from this directory)"
    exit 1
fi

# Remote Web Server Configuration (sourced from environment / bws)
REMOTE_WEB_SERVER="${REMOTE_WEB_SERVER}"
REMOTE_WEB_USER="${REMOTE_WEB_USER}"
REMOTE_WEB_PATH="${REMOTE_WEB_PATH}/results-data"
REMOTE_WEB_ENABLED=true  # Set to false to disable remote sync
REMOTE_WEB_CLEANUP=true  # Clean up temp folder after sync

# Offline mode flag
OFFLINE_MODE=false
LOGS_FOLDER=""
WEB_OUTPUT_PATH=""
WEB_ONLINE_MODE=false  # For generate-web: try online first, fallback to offline
FORCE_REGENERATE=false  # For generate-web: regenerate all reports even if they exist
SELECTED_CYCLE=""  # Specific cycle to use (empty = latest)
SELECTED_CYCLE_PATH=""  # Full path to selected cycle (from interactive selection)
MIGRATION_JSON_FILE=""  # Path to migration JSON file (for finding related files)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#######################################
# Utility Functions
#######################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_header() {
    echo ""
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

# Convert ISO timestamp to epoch seconds
timestamp_to_epoch() {
    local ts="$1"
    if [[ -z "$ts" || "$ts" == "null" ]]; then
        echo "0"
        return
    fi
    date -d "$ts" +%s 2>/dev/null || echo "0"
}

# Calculate time difference in seconds
time_diff_seconds() {
    local start="$1"
    local end="$2"
    local start_epoch=$(timestamp_to_epoch "$start")
    local end_epoch=$(timestamp_to_epoch "$end")
    echo $((end_epoch - start_epoch))
}

# Format seconds to HH:MM:SS
format_duration() {
    local seconds=$1
    printf '%02d:%02d:%02d' $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}

# Check if oc command is available and logged in
check_oc_connection() {
    if ! command -v oc &> /dev/null; then
        log_error "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
    
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi
}

# Check if jq is available
check_jq() {
    if ! command -v jq &> /dev/null; then
        log_error "jq command not found. Please install jq."
        exit 1
    fi
}

#######################################
# Validation Functions
#######################################

# List all test cycles in a logs folder
# Cycles are subfolders with format: <planname>_<timestamp>
# Searches both at the given path and in logs/ subfolder
list_test_cycles() {
    local logs_path="$1"
    
    # Find all subdirectories that match the pattern *_YYYYMMDD-HHMMSS
    # Search in the given path and also in logs/ subfolder (common structure)
    {
        find "$logs_path" -maxdepth 1 -type d -name "*_[0-9]*-[0-9]*" 2>/dev/null
        find "$logs_path/logs" -maxdepth 1 -type d -name "*_[0-9]*-[0-9]*" 2>/dev/null
    } | sort -u
}

# Get the latest test cycle from a logs folder
# Returns the folder with the most recent timestamp
get_latest_cycle() {
    local logs_path="$1"
    
    # Find all cycle folders and sort by name (timestamp is in the name)
    # The format is <planname>_YYYYMMDD-HHMMSS, so sorting alphabetically gives chronological order
    local cycles=$(list_test_cycles "$logs_path")
    
    if [[ -z "$cycles" ]]; then
        echo ""
        return 1
    fi
    
    # Return the last one (most recent)
    echo "$cycles" | tail -1
}

# Display available cycles
display_available_cycles() {
    local logs_path="$1"
    local interactive="${2:-false}"  # Optional: enable interactive selection
    
    local cycles=$(list_test_cycles "$logs_path")
    
    if [[ -z "$cycles" ]]; then
        log_warning "No test cycles found in: $logs_path"
        return 1
    fi
    
    # Store cycles in array for interactive selection
    local -a cycle_array=()
    local -a valid_cycles=()  # Only cycles with migration data
    local -a duration_array=()  # Store durations for averaging
    local index=1
    local pass_count=0
    local fail_count=0
    local total_duration_secs=0
    local min_duration_secs=999999999
    local max_duration_secs=0
    
    # First pass: filter out cycles without migration data and deduplicate by name
    local -A seen_cycles=()  # Associative array to track seen cycle names
    while IFS= read -r cycle; do
        local cycle_name=$(basename "$cycle")
        
        # Skip if we've already seen this cycle name (dedup root vs logs folder)
        if [[ -n "${seen_cycles[$cycle_name]}" ]]; then
            continue
        fi
        
        local plan_name=$(echo "$cycle_name" | sed 's/_[0-9]\{8\}-[0-9]\{6\}$//')
        local migration_file=$(find "$cycle" -name "Migration_*.json" -type f 2>/dev/null | head -1)
        if [[ -z "$migration_file" ]]; then
            migration_file=$(find "$cycle" -name "Plan_*.json" -type f 2>/dev/null | head -1)
        fi
        
        if [[ -n "$migration_file" && -f "$migration_file" ]]; then
            valid_cycles+=("$cycle")
            seen_cycles[$cycle_name]=1
        fi
    done <<< "$cycles"
    
    local valid_count=${#valid_cycles[@]}
    if [[ $valid_count -eq 0 ]]; then
        log_warning "No test cycles with migration data found in: $logs_path"
        return 1
    fi
    
    log_info "Found $valid_count test cycle(s) in: $logs_path"
    echo ""
    echo "  Available cycles (oldest to newest):"
    echo "  --------------------------------------------------------------------------------------------------------"
    
    # Second pass: display valid cycles
    for cycle in "${valid_cycles[@]}"; do
        cycle_array+=("$cycle")
        local cycle_name=$(basename "$cycle")
        local timestamp=$(echo "$cycle_name" | grep -oP '\d{8}-\d{6}$' || echo "unknown")
        
        # Format timestamp for display
        if [[ "$timestamp" != "unknown" ]]; then
            local formatted_ts=$(echo "$timestamp" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        else
            local formatted_ts="unknown"
        fi
        
        # Get cycle status and duration from migration JSON
        local status_text=""
        local duration_text=""
        local duration_secs=0
        local plan_name=$(echo "$cycle_name" | sed 's/_[0-9]\{8\}-[0-9]\{6\}$//')
        # Look for Migration_*.json first, then Plan_*.json (older format)
        local migration_file=$(find "$cycle" -name "Migration_*.json" -type f 2>/dev/null | head -1)
        if [[ -z "$migration_file" ]]; then
            migration_file=$(find "$cycle" -name "Plan_*.json" -type f 2>/dev/null | head -1)
        fi
        
        if [[ -n "$migration_file" && -f "$migration_file" ]]; then
            # Check if succeeded or failed
            local succeeded=$(jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' "$migration_file" 2>/dev/null)
            local failed=$(jq -r '.status.conditions[]? | select(.type=="Failed") | .status' "$migration_file" 2>/dev/null)
            
            if [[ "$succeeded" == "True" ]]; then
                status_text="${GREEN}[PASS]${NC}"
                ((pass_count++))
            elif [[ "$failed" == "True" ]]; then
                status_text="${RED}[FAIL]${NC}"
                ((fail_count++))
            else
                status_text="${YELLOW}[????]${NC}"
            fi
            
            # Get duration
            local start_time=$(jq -r '.status.started // empty' "$migration_file" 2>/dev/null)
            local end_time=$(jq -r '.status.completed // empty' "$migration_file" 2>/dev/null)
            
            if [[ -n "$start_time" && -n "$end_time" && "$start_time" != "null" && "$end_time" != "null" ]]; then
                duration_secs=$(time_diff_seconds "$start_time" "$end_time")
                if [[ $duration_secs -gt 0 ]]; then
                    duration_text="Duration: $(format_duration $duration_secs)"
                    duration_array+=("$duration_secs")
                    total_duration_secs=$((total_duration_secs + duration_secs))
                    [[ $duration_secs -lt $min_duration_secs ]] && min_duration_secs=$duration_secs
                    [[ $duration_secs -gt $max_duration_secs ]] && max_duration_secs=$duration_secs
                fi
            fi
        else
            # Skip cycles without migration data (N/A)
            continue
        fi
        
        # Build the display line
        local latest_marker=""
        if [[ $index -eq $valid_count ]]; then
            latest_marker="${CYAN}[LATEST]${NC}"
        fi
        
        # Print formatted line
        printf "    [%d] %-60s %-20s %s  %s  %s\n" \
            "$index" \
            "$cycle_name" \
            "($formatted_ts)" \
            "$status_text" \
            "$duration_text" \
            "$latest_marker" | sed 's/\x1b\[[0-9;]*m//g' > /dev/null  # Calculate width without colors
        
        # Actually print with colors
        echo -e "    [$index] $cycle_name  ($formatted_ts)  $status_text  $duration_text  $latest_marker"
        
        ((index++))
    done <<< "$cycles"
    
    echo "  --------------------------------------------------------------------------------------------------------"
    
    # Display summary statistics if we have multiple cycles with duration data
    local duration_count=${#duration_array[@]}
    if [[ $duration_count -gt 1 ]]; then
        echo ""
        echo -e "  ${CYAN}Summary Statistics (${duration_count} cycles with timing data):${NC}"
        echo "  --------------------------------------------------------------------------------------------------------"
        
        # Calculate average
        local avg_duration_secs=$((total_duration_secs / duration_count))
        
        # Calculate standard deviation (approximate)
        local sum_sq_diff=0
        for d in "${duration_array[@]}"; do
            local diff=$((d - avg_duration_secs))
            sum_sq_diff=$((sum_sq_diff + diff * diff))
        done
        local variance=$((sum_sq_diff / duration_count))
        # Approximate sqrt using Newton's method (integer approximation)
        local stddev=0
        if [[ $variance -gt 0 ]]; then
            stddev=$variance
            for _ in {1..10}; do
                stddev=$(( (stddev + variance / stddev) / 2 ))
            done
        fi
        
        echo -e "    Pass/Fail:     ${GREEN}$pass_count passed${NC}, ${RED}$fail_count failed${NC}"
        echo -e "    Average:       ${CYAN}$(format_duration $avg_duration_secs)${NC}"
        echo -e "    Min:           $(format_duration $min_duration_secs)"
        echo -e "    Max:           $(format_duration $max_duration_secs)"
        echo -e "    Std Dev:       ~$(format_duration $stddev)"
        echo -e "    Total Time:    $(format_duration $total_duration_secs)"
        echo "  --------------------------------------------------------------------------------------------------------"
    fi
    
    echo ""
    
    # Interactive selection
    local array_count=${#cycle_array[@]}
    if [[ "$interactive" == "true" && $array_count -gt 1 ]]; then
        # Try to read from /dev/tty for interactive input (works even when stdin is piped)
        if [[ -t 1 ]] || [[ -e /dev/tty ]]; then
            echo -e "  Enter cycle number [1-$array_count] or press Enter for latest [$array_count]: \c"
            read -r selection < /dev/tty 2>/dev/null || read -r selection
            
            # Default to latest if empty
            if [[ -z "$selection" ]]; then
                selection=$array_count
            fi
            
            # Validate selection
            if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le $array_count ]]; then
                local selected_cycle="${cycle_array[$((selection-1))]}"
                local selected_name=$(basename "$selected_cycle")
                SELECTED_CYCLE="$selected_name"
                SELECTED_CYCLE_PATH="$selected_cycle"
                echo ""
                log_info "Selected cycle: $selected_name"
                return 0
            else
                log_error "Invalid selection: $selection"
                return 1
            fi
        fi
    fi
    
    return 0
}

# Check if this is an mtv-debug folder format
# mtv-debug folders have *-migrations.yaml files instead of Migration_*.json
is_mtv_debug_folder() {
    local folder_path="$1"
    
    # Check for mtv-debug naming pattern or presence of *-migrations.yaml
    if [[ "$(basename "$folder_path")" == mtv-debug-* ]] || \
       [[ -n "$(find "$folder_path" -maxdepth 1 -name "*-migrations.yaml" -type f 2>/dev/null | head -1)" ]]; then
        return 0
    fi
    return 1
}

# Convert mtv-debug YAML to JSON format
# Extracts migration data from *-migrations.yaml file
convert_mtv_debug_yaml_to_json() {
    local folder_path="$1"
    local plan_name="$2"
    
    # Find the migrations.yaml file (but NOT openshift-mtv-all-migrations.yaml)
    local yaml_file=""
    
    # Priority 1: Look for plan-specific YAML file first
    if [[ -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "${plan_name}-migrations.yaml" -type f 2>/dev/null | head -1)
    fi
    
    # Priority 2: Find any migrations.yaml that's NOT the "all" file
    if [[ -z "$yaml_file" ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "*-migrations.yaml" ! -name "openshift-mtv-all-*" ! -name "*-all-migrations.yaml" -type f 2>/dev/null | head -1)
    fi
    
    # Priority 3: Fall back to any migrations.yaml (including "all")
    if [[ -z "$yaml_file" ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "*-migrations.yaml" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -z "$yaml_file" || ! -f "$yaml_file" ]]; then
        return 1
    fi
    
    # Check if yq is available
    if ! command -v yq &> /dev/null; then
        log_warning "yq not found - cannot convert YAML files. Install yq for mtv-debug folder support." >&2
        return 1
    fi
    
    # Extract plan name from yaml filename if not provided
    if [[ -z "$plan_name" || "$plan_name" == mtv-debug-* ]]; then
        plan_name=$(basename "$yaml_file" | sed 's/-migrations\.yaml$//')
    fi
    
    # Create JSON file from YAML
    local json_file="${folder_path}/Migration_${plan_name}.json"
    
    # Convert first item from the migrations list to JSON
    if yq -o=json '.items[0]' "$yaml_file" > "$json_file" 2>/dev/null; then
        log_info "Converted mtv-debug YAML to JSON" >&2
        echo "$json_file"
        return 0
    fi
    
    return 1
}

# Convert mtv-debug plans YAML to JSON format
convert_mtv_debug_plans_yaml_to_json() {
    local folder_path="$1"
    local plan_name="$2"
    
    # Check if yq is available
    if ! command -v yq &> /dev/null; then
        return 1
    fi
    
    # Priority 1: Check for plan-<name>.yaml (single plan file from Collect script)
    if [[ -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
        local single_plan_yaml="${folder_path}/plan-${plan_name}.yaml"
        if [[ -f "$single_plan_yaml" ]]; then
            local json_file="${folder_path}/Plan_${plan_name}.json"
            if yq -o=json '.' "$single_plan_yaml" > "$json_file" 2>/dev/null; then
                echo "$json_file"
                return 0
            fi
        fi
    fi
    
    # Priority 2: Find the plans.yaml file (but NOT openshift-mtv-all-plans.yaml)
    local yaml_file=""
    
    # Look for plan-specific YAML file first
    if [[ -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "${plan_name}-plans.yaml" -type f 2>/dev/null | head -1)
    fi
    
    # Find any plans.yaml that's NOT the "all" file
    if [[ -z "$yaml_file" ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "*-plans.yaml" ! -name "openshift-mtv-all-*" ! -name "*-all-plans.yaml" -type f 2>/dev/null | head -1)
    fi
    
    # If we have a plan name and an "all" file, try to extract the specific plan
    if [[ -z "$yaml_file" && -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
        yaml_file=$(find "$folder_path" -maxdepth 1 -name "*-all-plans.yaml" -type f 2>/dev/null | head -1)
        if [[ -n "$yaml_file" && -f "$yaml_file" ]]; then
            local json_file="${folder_path}/Plan_${plan_name}.json"
            # Extract the specific plan by name from the items array
            if yq -o=json ".items[] | select(.metadata.name == \"$plan_name\")" "$yaml_file" > "$json_file" 2>/dev/null; then
                # Check if the file has content
                if [[ -s "$json_file" ]] && jq -e '.metadata.name' "$json_file" &>/dev/null; then
                    echo "$json_file"
                    return 0
                fi
            fi
        fi
    fi
    
    if [[ -z "$yaml_file" || ! -f "$yaml_file" ]]; then
        return 1
    fi
    
    # Extract plan name from yaml filename if not provided
    if [[ -z "$plan_name" || "$plan_name" == mtv-debug-* ]]; then
        plan_name=$(basename "$yaml_file" | sed 's/-plans\.yaml$//')
    fi
    
    # Create JSON file from YAML
    local json_file="${folder_path}/Plan_${plan_name}.json"
    
    # Convert first item from the plans list to JSON
    if yq -o=json '.items[0]' "$yaml_file" > "$json_file" 2>/dev/null; then
        echo "$json_file"
        return 0
    fi
    
    return 1
}

# Find migration JSON file in logs folder
# Searches for Migration_<name>.json in the logs directory structure
# Structure: <tc-folder>/logs/<planname>_<timestamp>/Migration_<planname>.json
# Now supports multiple cycles - uses latest by default or specific cycle if set
# Also supports mtv-debug folder format (converts YAML to JSON on-the-fly)
find_migration_json_file() {
    local logs_path="$1"
    local plan_name="$2"
    
    local search_path="$logs_path"
    
    # Check if this is an mtv-debug folder format (from Collect_ns_data_for_debug.sh)
    if is_mtv_debug_folder "$logs_path"; then
        log_info "Detected mtv-debug folder format" >&2
        
        # Priority 1: Check for migrations-for-plan-<name>.json (plan-specific, from Collect script)
        local plan_specific_json=$(find "$logs_path" -maxdepth 1 -name "migrations-for-plan-*.json" -type f 2>/dev/null | head -1)
        if [[ -n "$plan_specific_json" && -f "$plan_specific_json" ]]; then
            # Check if it has content (not just "[]")
            local content_check=$(jq -r 'if type == "array" and length > 0 then "has_data" else "empty" end' "$plan_specific_json" 2>/dev/null)
            if [[ "$content_check" == "has_data" ]]; then
                # Convert to standard Migration_*.json format
                local extracted_plan_name=$(basename "$plan_specific_json" | sed 's/migrations-for-plan-//' | sed 's/\.json$//')
                local migration_json="${logs_path}/Migration_${extracted_plan_name}.json"
                if jq '.[0]' "$plan_specific_json" > "$migration_json" 2>/dev/null; then
                    log_info "Using plan-specific migration: $extracted_plan_name" >&2
                    echo "$migration_json"
                    return 0
                fi
            fi
        fi
        
        # Priority 2: Check for existing Migration_*.json (but NOT *-all.json)
        local existing_json=$(find "$logs_path" -maxdepth 1 -name "Migration_*.json" ! -name "*-all*" -type f 2>/dev/null | head -1)
        if [[ -n "$existing_json" && -f "$existing_json" ]]; then
            echo "$existing_json"
            return 0
        fi
        
        # Priority 3: Try to convert plan-specific YAML (e.g., <plan>-migrations.yaml)
        if [[ -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
            local plan_yaml="${logs_path}/${plan_name}-migrations.yaml"
            if [[ -f "$plan_yaml" ]]; then
                log_info "Converting plan-specific YAML" >&2
                local converted_file=$(convert_mtv_debug_yaml_to_json "$logs_path" "$plan_name")
                if [[ -n "$converted_file" && -f "$converted_file" ]]; then
                    echo "$converted_file"
                    return 0
                fi
            fi
        fi
        
        # Priority 4: Fall back to generic YAML conversion (but avoid openshift-mtv-all-*)
        log_info "Converting YAML to JSON" >&2
        local converted_file=$(convert_mtv_debug_yaml_to_json "$logs_path" "$plan_name")
        if [[ -n "$converted_file" && -f "$converted_file" ]]; then
            echo "$converted_file"
            return 0
        fi
        
        return 1
    fi
    
    # Check if there are multiple cycles in this folder
    local cycles=$(list_test_cycles "$logs_path")
    local cycle_count=0
    if [[ -n "$cycles" ]]; then
        cycle_count=$(echo "$cycles" | wc -l)
    fi
    
    if [[ $cycle_count -gt 1 ]]; then
        # Multiple cycles detected
        if [[ -n "$SELECTED_CYCLE_PATH" && -d "$SELECTED_CYCLE_PATH" ]]; then
            # Use full path from interactive selection
            search_path="$SELECTED_CYCLE_PATH"
        elif [[ -n "$SELECTED_CYCLE" ]]; then
            # User specified a cycle by name
            if [[ -d "${logs_path}/${SELECTED_CYCLE}" ]]; then
                search_path="${logs_path}/${SELECTED_CYCLE}"
            else
                # Try to find by index or partial match
                local match=$(echo "$cycles" | grep -i "$SELECTED_CYCLE" | head -1)
                if [[ -n "$match" ]]; then
                    search_path="$match"
                else
                    log_error "Specified cycle not found: $SELECTED_CYCLE"
                    log_info "Use --list-cycles to see available cycles"
                    return 1
                fi
            fi
        else
            # Use latest cycle
            local latest=$(get_latest_cycle "$logs_path")
            if [[ -n "$latest" ]]; then
                search_path="$latest"
            fi
        fi
    elif [[ $cycle_count -eq 1 ]]; then
        search_path=$(echo "$cycles" | head -1)
    fi
    
    # Search recursively for Migration_<planname>.json file
    local migration_file
    migration_file=$(find "$search_path" -name "Migration_${plan_name}.json" -type f 2>/dev/null | head -1)
    
    if [[ -n "$migration_file" && -f "$migration_file" ]]; then
        echo "$migration_file"
        return 0
    fi
    
    # Try with wildcard if exact match not found (search any Migration_*.json containing plan name)
    migration_file=$(find "$search_path" -name "Migration_*.json" -type f 2>/dev/null | grep -i "$plan_name" | head -1)
    
    if [[ -n "$migration_file" && -f "$migration_file" ]]; then
        echo "$migration_file"
        return 0
    fi
    
    # Last resort - find any Migration_*.json in the folder
    migration_file=$(find "$search_path" -name "Migration_*.json" -type f 2>/dev/null | head -1)
    
    if [[ -n "$migration_file" && -f "$migration_file" ]]; then
        echo "$migration_file"
        return 0
    fi
    
    # Fallback: Try Plan_*.json (older format used in MTV 2.9.0 and earlier)
    migration_file=$(find "$search_path" -name "Plan_${plan_name}.json" -type f 2>/dev/null | head -1)
    if [[ -n "$migration_file" && -f "$migration_file" ]]; then
        echo "$migration_file"
        return 0
    fi
    
    # Last resort for Plan_*.json
    migration_file=$(find "$search_path" -name "Plan_*.json" -type f 2>/dev/null | head -1)
    if [[ -n "$migration_file" && -f "$migration_file" ]]; then
        echo "$migration_file"
        return 0
    fi
    
    return 1
}

# Find plan JSON file in logs folder
# Uses the same cycle selection logic as find_migration_json_file
# Also supports mtv-debug folder format
find_plan_json_file() {
    local logs_path="$1"
    local plan_name="$2"
    
    local search_path="$logs_path"
    
    # Check if this is an mtv-debug folder format
    if is_mtv_debug_folder "$logs_path"; then
        # Priority 1: Check for plan-<name>.yaml or plan-<name>.json from Collect script
        if [[ -n "$plan_name" && "$plan_name" != mtv-debug-* ]]; then
            local plan_specific_yaml="${logs_path}/plan-${plan_name}.yaml"
            local plan_specific_json="${logs_path}/Plan_${plan_name}.json"
            
            if [[ -f "$plan_specific_json" ]]; then
                echo "$plan_specific_json"
                return 0
            fi
        fi
        
        # Priority 2: Check for existing Plan_*.json (but NOT *-all*)
        local existing_json=$(find "$logs_path" -maxdepth 1 -name "Plan_*.json" ! -name "*-all*" -type f 2>/dev/null | head -1)
        if [[ -n "$existing_json" && -f "$existing_json" ]]; then
            echo "$existing_json"
            return 0
        fi
        
        # Priority 3: Try to convert YAML to JSON
        local converted_file=$(convert_mtv_debug_plans_yaml_to_json "$logs_path" "$plan_name")
        if [[ -n "$converted_file" && -f "$converted_file" ]]; then
            echo "$converted_file"
            return 0
        fi
        
        return 1
    fi
    
    # Check if there are multiple cycles in this folder
    local cycles=$(list_test_cycles "$logs_path")
    local cycle_count=0
    if [[ -n "$cycles" ]]; then
        cycle_count=$(echo "$cycles" | wc -l)
    fi
    
    if [[ $cycle_count -gt 1 ]]; then
        if [[ -n "$SELECTED_CYCLE" ]]; then
            local match=$(echo "$cycles" | grep -i "$SELECTED_CYCLE" | head -1)
            if [[ -n "$match" ]]; then
                search_path="$match"
            fi
        else
            local latest=$(get_latest_cycle "$logs_path")
            if [[ -n "$latest" ]]; then
                search_path="$latest"
            fi
        fi
    elif [[ $cycle_count -eq 1 ]]; then
        search_path=$(echo "$cycles" | head -1)
    fi
    
    # Search recursively for Plan_<planname>.json file
    local plan_file
    plan_file=$(find "$search_path" -name "Plan_${plan_name}.json" -type f 2>/dev/null | head -1)
    
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi
    
    # Try with wildcard if exact match not found
    plan_file=$(find "$search_path" -name "Plan_*.json" -type f 2>/dev/null | grep -i "$plan_name" | head -1)
    
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi
    
    # Last resort - find any Plan_*.json in the folder
    plan_file=$(find "$search_path" -name "Plan_*.json" -type f 2>/dev/null | head -1)
    
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi
    
    return 1
}

# Get MTV version from env_meta_info.json or from cluster
get_mtv_version() {
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - look for version info in various locations
        local mtv_version=""
        
        # 1. Check for mtv_version_info.json in mtv-debug folders (from Collect_ns_data_for_debug.sh)
        if [[ -f "$LOGS_FOLDER/mtv_version_info.json" ]]; then
            mtv_version=$(jq -r '.mtv_version // empty' "$LOGS_FOLDER/mtv_version_info.json" 2>/dev/null)
            if [[ -n "$mtv_version" ]]; then
                echo "$mtv_version"
                return 0
            fi
        fi
        
        # 2. Check for env_meta_info.json in .report-artifacts folder (automation logs)
        local env_meta_file=""
        if [[ -n "$MIGRATION_JSON_FILE" ]]; then
            local cycle_dir=$(dirname "$MIGRATION_JSON_FILE")
            env_meta_file="$cycle_dir/.report-artifacts/env_meta_info.json"
        fi
        
        # Also try direct path in logs folder
        if [[ ! -f "$env_meta_file" ]]; then
            env_meta_file=$(find "$LOGS_FOLDER" -name "env_meta_info.json" -path "*/.report-artifacts/*" 2>/dev/null | head -1)
        fi
        
        if [[ -f "$env_meta_file" ]]; then
            # Try nested structure first (target_env.mtv_version)
            mtv_version=$(jq -r '.target_env.mtv_version // empty' "$env_meta_file" 2>/dev/null)
            if [[ -z "$mtv_version" ]]; then
                # Try flat structure
                mtv_version=$(jq -r '.mtv_version // empty' "$env_meta_file" 2>/dev/null)
            fi
            if [[ -n "$mtv_version" ]]; then
                echo "$mtv_version"
                return 0
            fi
        fi
        
        # 3. Try to extract from folder path (e.g., ~/MTV/results/2-11-0-33/... or ~/MTV/results/2.10.4/...)
        # Try dash format first (2-11-0-33)
        local version_from_path=$(echo "$LOGS_FOLDER" | grep -oP '(?<=/results/)[0-9]+-[0-9]+-[0-9]+-[0-9]+' | head -1)
        if [[ -n "$version_from_path" ]]; then
            echo "$version_from_path"
            return 0
        fi
        
        # Try dot format (2.10.4 or 2.10.3)
        version_from_path=$(echo "$LOGS_FOLDER" | grep -oP '(?<=/results/)[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$version_from_path" ]]; then
            echo "$version_from_path"
            return 0
        fi
        
        echo ""
        return 1
    else
        # Online mode - get from ForkliftController or CSV
        local forklift_version=$(oc get csv -n openshift-mtv -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | startswith("mtv-operator")) | .spec.version' 2>/dev/null | head -1)
        if [[ -n "$forklift_version" ]]; then
            echo "$forklift_version"
            return 0
        fi
        
        echo ""
        return 1
    fi
}

# Get CNV (OpenShift Virtualization) version
get_cnv_version() {
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        local cnv_version=""
        
        # Check for version info in mtv_version_info.json
        if [[ -f "$LOGS_FOLDER/mtv_version_info.json" ]]; then
            cnv_version=$(jq -r '.cnv_version // empty' "$LOGS_FOLDER/mtv_version_info.json" 2>/dev/null)
            if [[ -n "$cnv_version" ]]; then
                echo "$cnv_version"
                return 0
            fi
        fi
        
        # Check env_meta_info.json (try nested target_env structure first, then flat)
        local env_meta_file=""
        if [[ -n "$MIGRATION_JSON_FILE" ]]; then
            env_meta_file=$(dirname "$MIGRATION_JSON_FILE")/.report-artifacts/env_meta_info.json
        fi
        if [[ ! -f "$env_meta_file" ]]; then
            env_meta_file=$(find "$LOGS_FOLDER" -name "env_meta_info.json" -path "*/.report-artifacts/*" 2>/dev/null | head -1)
        fi
        
        if [[ -f "$env_meta_file" ]]; then
            # Try nested structure first (target_env.cnv_version)
            cnv_version=$(jq -r '.target_env.cnv_version // empty' "$env_meta_file" 2>/dev/null)
            if [[ -z "$cnv_version" ]]; then
                # Try flat structure
                cnv_version=$(jq -r '.cnv_version // empty' "$env_meta_file" 2>/dev/null)
            fi
            if [[ -n "$cnv_version" ]]; then
                echo "$cnv_version"
                return 0
            fi
        fi
        
        echo ""
        return 1
    else
        # Online mode - get from CSV in openshift-cnv namespace
        local cnv_version=$(oc get csv -n openshift-cnv -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | startswith("kubevirt-hyperconverged-operator")) | .spec.version' 2>/dev/null | head -1)
        if [[ -n "$cnv_version" ]]; then
            echo "$cnv_version"
            return 0
        fi
        
        echo ""
        return 1
    fi
}

# Get OCP (OpenShift Container Platform) version
get_ocp_version() {
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        local ocp_version=""
        
        # Check for version info in mtv_version_info.json
        if [[ -f "$LOGS_FOLDER/mtv_version_info.json" ]]; then
            ocp_version=$(jq -r '.ocp_version // empty' "$LOGS_FOLDER/mtv_version_info.json" 2>/dev/null)
            if [[ -n "$ocp_version" ]]; then
                echo "$ocp_version"
                return 0
            fi
        fi
        
        # Check env_meta_info.json (try nested target_env structure first, then flat)
        local env_meta_file=""
        if [[ -n "$MIGRATION_JSON_FILE" ]]; then
            env_meta_file=$(dirname "$MIGRATION_JSON_FILE")/.report-artifacts/env_meta_info.json
        fi
        if [[ ! -f "$env_meta_file" ]]; then
            env_meta_file=$(find "$LOGS_FOLDER" -name "env_meta_info.json" -path "*/.report-artifacts/*" 2>/dev/null | head -1)
        fi
        
        if [[ -f "$env_meta_file" ]]; then
            # Try nested structure first (target_env.openshift_version)
            ocp_version=$(jq -r '.target_env.openshift_version // empty' "$env_meta_file" 2>/dev/null)
            if [[ -z "$ocp_version" ]]; then
                # Try flat structure
                ocp_version=$(jq -r '.ocp_version // .openshift_version // empty' "$env_meta_file" 2>/dev/null)
            fi
            if [[ -n "$ocp_version" ]]; then
                echo "$ocp_version"
                return 0
            fi
        fi
        
        echo ""
        return 1
    else
        # Online mode - get from clusterversion
        local ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
        if [[ -n "$ocp_version" ]]; then
            echo "$ocp_version"
            return 0
        fi
        
        echo ""
        return 1
    fi
}

# Get ODF (OpenShift Data Foundation) version
get_odf_version() {
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        local odf_version=""
        
        # Check for version info in mtv_version_info.json
        if [[ -f "$LOGS_FOLDER/mtv_version_info.json" ]]; then
            odf_version=$(jq -r '.odf_version // empty' "$LOGS_FOLDER/mtv_version_info.json" 2>/dev/null)
            if [[ -n "$odf_version" ]]; then
                echo "$odf_version"
                return 0
            fi
        fi
        
        # Check env_meta_info.json (try nested target_env structure first, then flat)
        local env_meta_file=""
        if [[ -n "$MIGRATION_JSON_FILE" ]]; then
            env_meta_file=$(dirname "$MIGRATION_JSON_FILE")/.report-artifacts/env_meta_info.json
        fi
        if [[ ! -f "$env_meta_file" ]]; then
            env_meta_file=$(find "$LOGS_FOLDER" -name "env_meta_info.json" -path "*/.report-artifacts/*" 2>/dev/null | head -1)
        fi
        
        if [[ -f "$env_meta_file" ]]; then
            # Try nested structure first (target_env.openshift_storage_version)
            odf_version=$(jq -r '.target_env.openshift_storage_version // empty' "$env_meta_file" 2>/dev/null)
            if [[ -z "$odf_version" ]]; then
                # Try flat structure with various field names
                odf_version=$(jq -r '.odf_version // .openshift_storage_version // empty' "$env_meta_file" 2>/dev/null)
            fi
            if [[ -n "$odf_version" ]]; then
                echo "$odf_version"
                return 0
            fi
        fi
        
        echo ""
        return 1
    else
        # Online mode - get from CSV in openshift-storage namespace
        local odf_version=$(oc get csv -n openshift-storage -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | startswith("odf-operator")) | .spec.version' 2>/dev/null | head -1)
        if [[ -n "$odf_version" ]]; then
            echo "$odf_version"
            return 0
        fi
        
        # Try ocs-operator if odf-operator not found
        odf_version=$(oc get csv -n openshift-storage -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | startswith("ocs-operator")) | .spec.version' 2>/dev/null | head -1)
        if [[ -n "$odf_version" ]]; then
            echo "$odf_version"
            return 0
        fi
        
        echo ""
        return 1
    fi
}

# Find Provider_configuration.json file (shared by VDDK and provider name lookups)
find_provider_config() {
    local provider_file=""

    if [[ -n "$MIGRATION_JSON_FILE" ]]; then
        local cycle_folder=$(dirname "$MIGRATION_JSON_FILE")
        provider_file=$(find "$cycle_folder" -maxdepth 1 -name "Provider_configuration.json" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$provider_file" && -n "$LOGS_FOLDER" ]]; then
        provider_file=$(find "$LOGS_FOLDER" -name "Provider_configuration.json" -type f 2>/dev/null | head -1)
    fi

    if [[ -n "$provider_file" && -f "$provider_file" ]]; then
        echo "$provider_file"
        return 0
    fi

    return 1
}

# Get VDDK image from Provider_configuration.json
get_vddk_version() {
    local provider_file=$(find_provider_config)
    if [[ -n "$provider_file" ]]; then
        local vddk_image=$(jq -r '.spec.settings.vddkInitImage // empty' "$provider_file" 2>/dev/null)
        if [[ -n "$vddk_image" ]]; then
            echo "$vddk_image"
            return 0
        fi
    fi
    echo ""
    return 1
}

# Get provider name from Provider_configuration.json
get_provider_name() {
    local provider_file=$(find_provider_config)
    if [[ -n "$provider_file" ]]; then
        local provider_name=$(jq -r '.metadata.name // empty' "$provider_file" 2>/dev/null)
        if [[ -n "$provider_name" ]]; then
            echo "$provider_name"
            return 0
        fi
    fi
    echo ""
    return 1
}

# Get migration CR as JSON (supports both online and offline modes)
get_migration_json() {
    local name="$1"
    local namespace="$2"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - read from logs folder
        # If MIGRATION_JSON_FILE is already set and exists, use it directly
        if [[ -n "$MIGRATION_JSON_FILE" && -f "$MIGRATION_JSON_FILE" ]]; then
            cat "$MIGRATION_JSON_FILE" 2>/dev/null
        else
            local migration_file=$(find_migration_json_file "$LOGS_FOLDER" "$name")
            if [[ -n "$migration_file" ]]; then
                # Store the file path for later use (e.g., finding env_meta_info.json)
                MIGRATION_JSON_FILE="$migration_file"
                cat "$migration_file" 2>/dev/null
            fi
        fi
    else
        # Online mode - get from cluster
        oc get migration "$name" -n "$namespace" -o json 2>/dev/null
    fi
}

# Get plan CR as JSON (supports both online and offline modes)
get_plan_json() {
    local name="$1"
    local namespace="$2"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - read from logs folder
        local plan_file=$(find_plan_json_file "$LOGS_FOLDER" "$name")
        if [[ -n "$plan_file" ]]; then
            cat "$plan_file" 2>/dev/null
        fi
    else
        # Online mode - get from cluster
        oc get plan "$name" -n "$namespace" -o json 2>/dev/null
    fi
}

# Resolve migration name (handles both exact name and plan name)
# Returns the actual migration CR name
resolve_migration_name() {
    local name="$1"
    local namespace="$2"
    
    # First, try exact match
    if oc get migration "$name" -n "$namespace" &> /dev/null; then
        echo "$name"
        return 0
    fi
    
    # Try to find migration by plan name (migration names are typically planname-xxxxx)
    local migration_name=$(oc get migration -n "$namespace" -o json 2>/dev/null | \
        jq -r --arg plan "$name" '.items[] | select(.spec.plan.name == $plan) | .metadata.name' | head -1)
    
    if [[ -n "$migration_name" && "$migration_name" != "null" ]]; then
        echo "$migration_name"
        return 0
    fi
    
    # Try prefix match (planname-xxxxx pattern)
    migration_name=$(oc get migration -n "$namespace" --no-headers 2>/dev/null | \
        awk -v prefix="$name" '$1 ~ "^"prefix"-" {print $1; exit}')
    
    if [[ -n "$migration_name" ]]; then
        echo "$migration_name"
        return 0
    fi
    
    # Not found
    return 1
}

# Validate migration exists (supports both online and offline modes)
validate_migration_exists() {
    local name="$1"
    local namespace="$2"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - check if migration JSON file exists in logs folder
        local migration_file=$(find_migration_json_file "$LOGS_FOLDER" "$name")
        
        if [[ -z "$migration_file" ]]; then
            log_error "Migration JSON file for '$name' not found in logs folder"
            log_info "Searched in: $LOGS_FOLDER"
            return 1
        fi
        
        log_success "Found migration file: $(basename "$migration_file")"
        
        # Check if this is an mtv-debug folder (no cycle info needed)
        if ! is_mtv_debug_folder "$LOGS_FOLDER"; then
            # Display cycle info if multiple cycles were available
            local cycle_dir=$(dirname "$migration_file")
            local cycle_name=$(basename "$cycle_dir")
            if [[ "$cycle_name" =~ _[0-9]{8}-[0-9]{6}$ ]]; then
                local cycle_count_check=$(list_test_cycles "$LOGS_FOLDER" | wc -l)
                if [[ $cycle_count_check -gt 1 ]]; then
                    if [[ -n "$SELECTED_CYCLE" ]]; then
                        log_info "Using specified cycle: $cycle_name"
                    else
                        log_info "Multiple cycles found ($cycle_count_check). Using latest: $cycle_name"
                        log_info "Use --list-cycles to see all, or --cycle=<name> to select specific"
                    fi
                else
                    log_info "Using cycle: $cycle_name"
                fi
            fi
        fi
        
        log_info "Path: $migration_file"
        
        # Extract plan name from the migration JSON for RESOLVED_MIGRATION_NAME
        local plan_name=$(jq -r '.spec.plan.name // .metadata.name' "$migration_file" 2>/dev/null)
        RESOLVED_MIGRATION_NAME="$plan_name"
        return 0
    fi
    
    # Online mode - try to resolve the name (exact or by plan name)
    local resolved_name=$(resolve_migration_name "$name" "$namespace")
    
    if [[ -z "$resolved_name" ]]; then
        log_error "Migration '$name' not found in namespace '$namespace'"
        log_info "Hint: You can use either the Migration name or the Plan name"
        log_info "Hint: Use --from-logs=<path> to validate from saved logs"
        return 1
    fi
    
    if [[ "$resolved_name" != "$name" ]]; then
        log_info "Found migration '$resolved_name' for plan '$name'"
    fi
    
    log_success "Migration '$resolved_name' found in namespace '$namespace'"
    # Export the resolved name for use by caller
    RESOLVED_MIGRATION_NAME="$resolved_name"
    return 0
}

# Detect migration type (warm or cold)
detect_migration_type() {
    local migration_json="$1"
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local has_warm=$(echo "$vms" | jq '[.[] | select(.warm != null)] | length')
    local has_cutover=$(echo "$vms" | jq '[.[] | select(.pipeline[]?.name == "Cutover")] | length')
    
    if [[ "$has_warm" -gt 0 || "$has_cutover" -gt 0 ]]; then
        echo "Warm"
    else
        echo "Cold"
    fi
}

# Display migration type with color (Warm=Red, Cold=Blue)
display_migration_type() {
    local migration_type="$1"
    
    if [[ "$migration_type" == "Warm" ]]; then
        echo -e "[INFO] Migration type: ${RED}${migration_type}${NC}"
    else
        echo -e "[INFO] Migration type: ${BLUE}${migration_type}${NC}"
    fi
}

# Validate migration status - check for proper state transitions
validate_migration_status() {
    local migration_json="$1"
    local errors=0
    
    log_header "Migration Status Validation"
    
    # In offline mode, check if there are multiple cycles and indicate which one we're showing
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Find MigrationSummary file to check total cycles
        local summary_file=""
        local search_paths=("$LOGS_FOLDER" "$(dirname "$LOGS_FOLDER")" "$(dirname "$(dirname "$LOGS_FOLDER")")")
        for search_path in "${search_paths[@]}"; do
            summary_file=$(find "$search_path" -maxdepth 1 -name "MigrationSummary_*.txt" -type f 2>/dev/null | head -1)
            [[ -n "$summary_file" ]] && break
        done
        
        if [[ -n "$summary_file" && -f "$summary_file" ]]; then
            local total_cycles=$(grep -c "^Migration Cycle #" "$summary_file" 2>/dev/null || echo "0")
            if [[ $total_cycles -gt 1 ]]; then
                log_info "${YELLOW}Note: This report shows the last cycle (#$total_cycles of $total_cycles total)${NC}"
                log_info "${YELLOW}See 'Multi-Cycle Statistics' section at end for aggregate data${NC}"
                echo ""
            fi
        fi
    fi
    
    # Display version information
    local mtv_version=$(get_mtv_version)
    local cnv_version=$(get_cnv_version)
    local ocp_version=$(get_ocp_version)
    local odf_version=$(get_odf_version)
    local vddk_version=$(get_vddk_version)
    local provider_name=$(get_provider_name)
    
    log_info "MTV Version:   ${CYAN}${mtv_version:-N/A}${NC}"
    log_info "CNV Version:   ${CYAN}${cnv_version:-N/A}${NC}"
    log_info "OCP Version:   ${CYAN}${ocp_version:-N/A}${NC}"
    log_info "ODF Version:   ${CYAN}${odf_version:-N/A}${NC}"
    log_info "VDDK Image:    ${CYAN}${vddk_version:-N/A}${NC}"
    log_info "Provider Name: ${CYAN}${provider_name:-N/A}${NC}"
    
    # Detect and display migration type with color
    local migration_type=$(detect_migration_type "$migration_json")
    display_migration_type "$migration_type"
    
    # Get current conditions
    local conditions=$(echo "$migration_json" | jq -r '.status.conditions // []')
    local succeeded=$(echo "$conditions" | jq -r '.[] | select(.type=="Succeeded") | .status')
    local failed=$(echo "$conditions" | jq -r '.[] | select(.type=="Failed") | .status')
    local running=$(echo "$conditions" | jq -r '.[] | select(.type=="Running") | .status')
    local ready=$(echo "$conditions" | jq -r '.[] | select(.type=="Ready") | .status')
    
    # Check final state
    if [[ "$succeeded" == "True" ]]; then
        log_success "Migration completed successfully (Succeeded=True)"
    elif [[ "$failed" == "True" ]]; then
        log_error "Migration failed (Failed=True)"
        local failure_reason=$(echo "$conditions" | jq -r '.[] | select(.type=="Failed") | .message // "Unknown"')
        log_error "Failure reason: $failure_reason"
        ((errors++))
    elif [[ "$running" == "True" ]]; then
        log_warning "Migration is still running"
    else
        log_warning "Migration in unknown state"
    fi
    
    # Check for started/completed timestamps
    local started=$(echo "$migration_json" | jq -r '.status.started // "null"')
    local completed=$(echo "$migration_json" | jq -r '.status.completed // "null"')
    
    if [[ "$started" == "null" ]]; then
        log_error "Migration has no start timestamp"
        ((errors++))
    else
        log_success "Migration started at: $started"
    fi
    
    if [[ "$succeeded" == "True" && "$completed" == "null" ]]; then
        log_error "Migration succeeded but has no completion timestamp"
        ((errors++))
    elif [[ "$completed" != "null" ]]; then
        log_success "Migration completed at: $completed"
        local duration=$(time_diff_seconds "$started" "$completed")
        log_info "Total duration: $(format_duration $duration)"
    fi
    
    # Check for AIO buffer optimization settings if plan name contains "aio"
    local plan_name=$(echo "$migration_json" | jq -r '.spec.plan.name // .metadata.name')
    if [[ "$plan_name" == *"aio"* ]] && [[ "$OFFLINE_MODE" == "true" ]]; then
        check_aio_optimization "$plan_name"
    fi
    
    # Check for storage offload settings if plan name contains "offload"
    if [[ "$plan_name" == *"offload"* ]] && [[ "$OFFLINE_MODE" == "true" ]]; then
        check_storage_offload "$plan_name"
    fi
    
    return $errors
}

# Check AIO buffer optimization settings from Provider configuration
check_aio_optimization() {
    local plan_name="$1"
    
    echo ""
    echo -e "  ${CYAN}VDDK AIO Optimization Check:${NC}"
    echo "  ----------------------------------------"
    
    # Find Provider_configuration.json in the logs folder
    local provider_file=""
    if [[ -n "$MIGRATION_JSON_FILE" ]]; then
        local cycle_folder=$(dirname "$MIGRATION_JSON_FILE")
        provider_file=$(find "$cycle_folder" -maxdepth 1 -name "Provider_configuration.json" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -z "$provider_file" ]]; then
        provider_file=$(find "$LOGS_FOLDER" -name "Provider_configuration.json" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -z "$provider_file" || ! -f "$provider_file" ]]; then
        echo -e "    ${YELLOW}[WARN]${NC} Provider_configuration.json not found in logs"
        return
    fi
    
    # Check useVddkAioOptimization setting
    local aio_enabled=$(jq -r '.spec.settings.useVddkAioOptimization // "not set"' "$provider_file" 2>/dev/null)
    local vddk_image=$(jq -r '.spec.settings.vddkInitImage // "not set"' "$provider_file" 2>/dev/null)
    local provider_name=$(jq -r '.metadata.name // "unknown"' "$provider_file" 2>/dev/null)
    
    echo -e "    Provider: ${CYAN}$provider_name${NC}"
    
    if [[ "$aio_enabled" == "true" ]]; then
        echo -e "    useVddkAioOptimization: ${GREEN}$aio_enabled${NC} (enabled)"
    elif [[ "$aio_enabled" == "false" ]]; then
        echo -e "    useVddkAioOptimization: ${RED}$aio_enabled${NC} (disabled)"
        echo -e "    ${RED}[WARN]${NC} AIO optimization is disabled but plan name contains 'aio'"
    else
        echo -e "    useVddkAioOptimization: ${YELLOW}$aio_enabled${NC}"
        echo -e "    ${YELLOW}[WARN]${NC} AIO optimization setting not found in provider config"
    fi
    
    if [[ "$vddk_image" != "not set" ]]; then
        echo -e "    VDDK Image: $vddk_image"
    fi
    
    # Show info about buffer values
    # The values are in /mnt/extra-v2v-conf/input.conf inside the pod:
    #   VixDiskLib.nfcAio.Session.BufSizeIn64KB=16
    #   vixDiskLib.nfcAio.Session.BufCount=4
    echo ""
    echo -e "    ${CYAN}Note:${NC} Actual buffer values are in virt-v2v pod at /mnt/extra-v2v-conf/input.conf"
    echo "          Default values: BufSizeIn64KB=16, BufCount=4"
    echo "          These are not captured in standard logs."
    echo ""
}

# Check Storage Offload settings from ForkliftController
check_storage_offload() {
    local plan_name="$1"
    
    echo ""
    echo -e "  ${CYAN}Storage Offload (Copy Offload) Check:${NC}"
    echo "  ----------------------------------------"
    
    # Find ForkliftController file or forklift-controller pod logs in the logs folder
    local controller_file=""
    local controller_log=""
    
    if [[ -n "$MIGRATION_JSON_FILE" ]]; then
        local cycle_folder=$(dirname "$MIGRATION_JSON_FILE")
        controller_file=$(find "$cycle_folder" -maxdepth 1 -name "ForkliftController*.json" -type f 2>/dev/null | head -1)
        controller_log=$(find "$cycle_folder" -maxdepth 1 -name "MTV_forklift-controller-*.txt" -type f 2>/dev/null | head -1)
    fi
    
    if [[ -z "$controller_file" ]]; then
        controller_file=$(find "$LOGS_FOLDER" -name "ForkliftController*.json" -type f 2>/dev/null | head -1)
    fi
    if [[ -z "$controller_log" ]]; then
        controller_log=$(find "$LOGS_FOLDER" -name "MTV_forklift-controller-*.txt" -type f 2>/dev/null | head -1)
    fi
    
    local copy_offload_enabled="not found"
    local source="unknown"
    
    # Try to get settings from controller log (contains env vars)
    if [[ -n "$controller_log" && -f "$controller_log" ]]; then
        # Parse env vars from the controller log
        local offload_line=$(grep "FEATURE_COPY_OFFLOAD:" "$controller_log" 2>/dev/null | head -1)
        if [[ -n "$offload_line" ]]; then
            copy_offload_enabled=$(echo "$offload_line" | awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $NF); print $NF}')
            source="forklift-controller pod env"
        fi
    fi
    
    # Fall back to ForkliftController JSON if available
    if [[ "$copy_offload_enabled" == "not found" && -n "$controller_file" && -f "$controller_file" ]]; then
        local spec_offload=$(jq -r '.spec.feature_copy_offload // "not set"' "$controller_file" 2>/dev/null)
        if [[ "$spec_offload" != "not set" && "$spec_offload" != "null" ]]; then
            copy_offload_enabled="$spec_offload"
            source="ForkliftController spec"
        fi
    fi
    
    if [[ "$copy_offload_enabled" == "not found" ]]; then
        echo -e "    ${YELLOW}[WARN]${NC} Storage offload settings not found in logs"
        echo "          ForkliftController config or forklift-controller pod logs not available"
        # Still check populator settings even when offload not found
        if [[ -n "$controller_file" && -f "$controller_file" ]]; then
            local max_populator
            max_populator=$(jq -r '.spec.controller_max_populator_inflight // empty' "$controller_file" 2>/dev/null)
            local jq_ret=$?
            if [[ $jq_ret -ne 0 ]]; then
                echo -e "    ${YELLOW}[WARN]${NC} Failed to parse $(basename "$controller_file")"
            elif [[ -n "$max_populator" && "$max_populator" != "null" ]]; then
                echo -e "    controller_max_populator_inflight Patched: ${GREEN}True${NC}"
                echo -e "    Max Populator Pods: ${GREEN}$max_populator${NC}"
                echo -e "    ${CYAN}Source:${NC} $(basename "$controller_file")"
            else
                echo -e "    controller_max_populator_inflight: ${YELLOW}Not set (using default)${NC}"
            fi
        fi
        return
    fi
    
    echo -e "    Source: ${CYAN}$source${NC}"
    if [[ "$copy_offload_enabled" == "true" ]]; then
        echo -e "    FEATURE_COPY_OFFLOAD: ${GREEN}$copy_offload_enabled${NC} (enabled)"
    elif [[ "$copy_offload_enabled" == "false" ]]; then
        echo -e "    FEATURE_COPY_OFFLOAD: ${RED}$copy_offload_enabled${NC} (disabled)"
        echo -e "    ${RED}[WARN]${NC} Copy offload is disabled but plan name contains 'offload'"
    else
        echo -e "    FEATURE_COPY_OFFLOAD: ${YELLOW}$copy_offload_enabled${NC}"
    fi
    echo -e "    ${CYAN}Note:${NC} Settings configured in ForkliftController CR"
    
    # Check Max Populator Inflight setting from ForkliftController JSON
    if [[ -n "$controller_file" && -f "$controller_file" ]]; then
        local max_populator=$(jq -r '.spec.controller_max_populator_inflight // empty' "$controller_file" 2>/dev/null)
        if [[ -n "$max_populator" && "$max_populator" != "null" ]]; then
            echo -e "    controller_max_populator_inflight Patched: ${GREEN}True${NC}"
            echo -e "    Max Populator Pods: ${GREEN}$max_populator${NC}"
            echo -e "    ${CYAN}Source:${NC} $(basename "$controller_file")"
        else
            echo -e "    controller_max_populator_inflight: ${YELLOW}Not set (using default)${NC}"
        fi
    fi
    
    # Check XCOPY status from Populate pod logs
    check_xcopy_status_from_populate_logs
    
    echo ""
}

# Check XCOPY status from Populate pod logs (xcopyUsed=0 or xcopyUsed=1)
check_xcopy_status_from_populate_logs() {
    local cycle_folder=""
    
    if [[ -n "$MIGRATION_JSON_FILE" ]]; then
        cycle_folder=$(dirname "$MIGRATION_JSON_FILE")
    elif [[ -n "$LOGS_FOLDER" ]]; then
        cycle_folder="$LOGS_FOLDER"
    fi
    
    if [[ -z "$cycle_folder" || ! -d "$cycle_folder" ]]; then
        return
    fi
    
    # Find Populate pod logs in the cycle folder
    local populate_logs=$(find "$cycle_folder" -maxdepth 1 -name "Populate_*.log" -type f 2>/dev/null | sort)
    
    if [[ -z "$populate_logs" ]]; then
        echo ""
        echo -e "    ${YELLOW}[INFO]${NC} No Populate pod logs found (XCOPY status not available)"
        return
    fi
    
    local xcopy_used_count=0
    local xcopy_not_used_count=0
    
    while IFS= read -r log_file; do
        [[ -z "$log_file" ]] && continue
        local used_1
        local used_0
        used_1=$(grep -c "xcopyUsed=1" "$log_file" 2>/dev/null) || used_1=0
        used_0=$(grep -c "xcopyUsed=0" "$log_file" 2>/dev/null) || used_0=0
        # Ensure values are integers (remove any whitespace/newlines)
        used_1=${used_1//[^0-9]/}
        used_0=${used_0//[^0-9]/}
        [[ -z "$used_1" ]] && used_1=0
        [[ -z "$used_0" ]] && used_0=0
        xcopy_used_count=$((xcopy_used_count + used_1))
        xcopy_not_used_count=$((xcopy_not_used_count + used_0))
    done <<< "$populate_logs"
    
    # Display XCOPY In Use status
    if [[ $xcopy_used_count -gt 0 ]]; then
        echo -e "    XCOPY: ${GREEN}In Use${NC} (xcopyUsed=1)"
    elif [[ $xcopy_not_used_count -gt 0 ]]; then
        echo -e "    XCOPY: ${RED}Not In Use${NC} (xcopyUsed=0) FallBack"
    fi
}

# Validate VM migration consistency
validate_vm_consistency() {
    local migration_json="$1"
    local errors=0
    
    log_header "VM Migration Consistency"
    
    # Get VM statuses
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total_vms=$(echo "$vms" | jq 'length')
    
    if [[ "$total_vms" -eq 0 ]]; then
        log_error "No VMs found in migration status"
        return 1
    fi
    
    log_info "Total VMs in migration: $total_vms"
    
    # Count VMs by status
    local succeeded_vms=$(echo "$vms" | jq '[.[] | select(.conditions[]?.type=="Succeeded" and .conditions[]?.status=="True")] | length')
    local failed_vms=$(echo "$vms" | jq '[.[] | select(.conditions[]?.type=="Failed" and .conditions[]?.status=="True")] | length')
    local running_vms=$(echo "$vms" | jq '[.[] | select(.conditions[]?.type=="Running" and .conditions[]?.status=="True")] | length')
    
    log_info "Succeeded VMs: $succeeded_vms"
    log_info "Failed VMs: $failed_vms"
    log_info "Running VMs: $running_vms"
    
    # Validate all VMs accounted for
    local accounted=$((succeeded_vms + failed_vms + running_vms))
    if [[ $accounted -ne $total_vms ]]; then
        log_warning "Some VMs in unknown state: $((total_vms - accounted)) unaccounted"
    fi
    
    # Check for failed VMs
    if [[ $failed_vms -gt 0 ]]; then
        log_error "$failed_vms VM(s) failed migration"
        ((errors++))
        
        # List failed VMs with detailed error information
        echo "$vms" | jq -r '.[] | select(.conditions[]?.type=="Failed" and .conditions[]?.status=="True") | 
            "  - \(.name): \(.conditions[] | select(.type=="Failed") | .message // "Unknown error")"'
        
        # Extract detailed error information from .error field (phase-level errors)
        local vm_errors=$(echo "$vms" | jq -r '.[] | select(.error != null) | 
            "\n  VM Error Details for \(.name):\n    Phase: \(.error.phase // "Unknown")\n    Reasons:\n\(.error.reasons // [] | map("      - " + .) | join("\n"))"' 2>/dev/null)
        if [[ -n "$vm_errors" && "$vm_errors" != "" ]]; then
            echo -e "${RED}$vm_errors${NC}"
        fi
        
        # Extract pipeline step errors
        local pipeline_errors=$(echo "$vms" | jq -r '.[] | select(.pipeline != null) | 
            .name as $vm | .pipeline[] | select(.error != null) | 
            "\n  Pipeline Error in \($vm) - Step: \(.name)\n    Phase: \(.error.phase // "Unknown")\n    Reasons:\n\(.error.reasons // [] | map("      - " + .) | join("\n"))"' 2>/dev/null)
        if [[ -n "$pipeline_errors" && "$pipeline_errors" != "" ]]; then
            echo -e "${RED}$pipeline_errors${NC}"
        fi
    fi
    
    # Check completion rate
    if [[ $total_vms -gt 0 ]]; then
        local success_rate=$((succeeded_vms * 100 / total_vms))
        if [[ $success_rate -eq 100 ]]; then
            log_success "100% VM migration success rate"
        elif [[ $success_rate -ge 90 ]]; then
            log_warning "VM migration success rate: ${success_rate}%"
        else
            log_error "Low VM migration success rate: ${success_rate}%"
            ((errors++))
        fi
    fi
    
    return $errors
}

# Validate VM timing and detect outliers
validate_vm_timing() {
    local migration_json="$1"
    local errors=0
    
    log_header "VM Timing Analysis"
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total_vms=$(echo "$vms" | jq 'length')
    
    if [[ "$total_vms" -eq 0 ]]; then
        return 0
    fi
    
    # Calculate timing for each completed VM
    local durations=()
    local vm_timings=""
    
    for i in $(seq 0 $((total_vms - 1))); do
        local vm=$(echo "$vms" | jq ".[$i]")
        local vm_name=$(echo "$vm" | jq -r '.name')
        local vm_started=$(echo "$vm" | jq -r '.started // "null"')
        local vm_completed=$(echo "$vm" | jq -r '.completed // "null"')
        
        if [[ "$vm_started" != "null" && "$vm_completed" != "null" ]]; then
            local duration=$(time_diff_seconds "$vm_started" "$vm_completed")
            durations+=($duration)
            vm_timings+="$vm_name:$duration\n"
        fi
    done
    
    if [[ ${#durations[@]} -eq 0 ]]; then
        log_warning "No completed VM timings available"
        return 0
    fi
    
    # Calculate statistics
    local sum=0
    local min=${durations[0]}
    local max=${durations[0]}
    
    for d in "${durations[@]}"; do
        sum=$((sum + d))
        [[ $d -lt $min ]] && min=$d
        [[ $d -gt $max ]] && max=$d
    done
    
    local avg=$((sum / ${#durations[@]}))
    
    log_info "VM Migration Timing Statistics:"
    log_info "  Average: $(format_duration $avg)"
    log_info "  Min:     $(format_duration $min)"
    log_info "  Max:     $(format_duration $max)"
    
    # Detect outliers (VMs taking significantly longer than average)
    local outlier_threshold=$((avg * OUTLIER_THRESHOLD_PERCENT / 100))
    local outliers=0
    
    echo -e "$vm_timings" | while IFS=: read -r name duration; do
        if [[ -n "$name" && "$duration" -gt "$outlier_threshold" ]]; then
            log_warning "Outlier detected: $name took $(format_duration $duration) (>${OUTLIER_THRESHOLD_PERCENT}% of avg)"
            ((outliers++))
        fi
    done
    
    # Check for high variance
    local variance_ratio=$((max * 100 / (avg + 1)))
    if [[ $variance_ratio -gt 300 ]]; then
        log_warning "High timing variance detected (max is ${variance_ratio}% of average)"
    else
        log_success "VM timing variance within acceptable range"
    fi
    
    return $errors
}

# Validate warm migration details (cutover, snapshots, precopies)
validate_warm_migration() {
    local migration_json="$1"
    local errors=0
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total_vms=$(echo "$vms" | jq 'length')
    
    if [[ "$total_vms" -eq 0 ]]; then
        return 0
    fi
    
    # Check if this is a warm migration (look for warm field or Cutover pipeline step)
    local has_warm=$(echo "$vms" | jq '[.[] | select(.warm != null)] | length')
    local has_cutover=$(echo "$vms" | jq '[.[] | select(.pipeline[]?.name == "Cutover")] | length')
    
    if [[ "$has_warm" -eq 0 && "$has_cutover" -eq 0 ]]; then
        log_info "This is a cold migration (no warm migration data)"
        return 0
    fi
    
    log_header "Warm Migration Details"
    
    for i in $(seq 0 $((total_vms - 1))); do
        local vm=$(echo "$vms" | jq ".[$i]")
        local vm_name=$(echo "$vm" | jq -r '.name')
        local warm_data=$(echo "$vm" | jq -r '.warm // null')
        
        if [[ "$warm_data" == "null" ]]; then
            continue
        fi
        
        echo ""
        log_info "VM: $vm_name"
        echo "  ----------------------------------------"
        
        # Precopy statistics
        local precopies=$(echo "$warm_data" | jq -r '.precopies // []')
        local precopy_count=$(echo "$precopies" | jq 'length')
        local successes=$(echo "$warm_data" | jq -r '.successes // 0')
        local failures=$(echo "$warm_data" | jq -r '.failures // 0')
        local consecutive_failures=$(echo "$warm_data" | jq -r '.consecutiveFailures // 0')
        
        echo "  Precopy Summary:"
        echo "    Total precopies: $precopy_count"
        echo "    Successes: $successes"
        echo "    Failures: $failures"
        if [[ "$consecutive_failures" -gt 0 ]]; then
            log_warning "  Consecutive failures: $consecutive_failures"
        fi
        
        # Snapshot breakdown
        if [[ "$precopy_count" -gt 0 ]]; then
            echo ""
            echo "  Snapshot/Precopy Breakdown:"
            
            for j in $(seq 0 $((precopy_count - 1))); do
                local precopy=$(echo "$precopies" | jq ".[$j]")
                local snapshot=$(echo "$precopy" | jq -r '.snapshot // "N/A"')
                local precopy_start=$(echo "$precopy" | jq -r '.start // "null"')
                local precopy_end=$(echo "$precopy" | jq -r '.end // "null"')
                local deltas=$(echo "$precopy" | jq -r '.deltas // []')
                local delta_count=$(echo "$deltas" | jq 'length')
                
                echo "    Precopy #$((j + 1)): $snapshot"
                
                if [[ "$precopy_start" != "null" ]]; then
                    echo "      Started:  $precopy_start"
                fi
                if [[ "$precopy_end" != "null" ]]; then
                    echo "      Ended:    $precopy_end"
                    if [[ "$precopy_start" != "null" ]]; then
                        local precopy_duration=$(time_diff_seconds "$precopy_start" "$precopy_end")
                        echo "      Duration: $(format_duration $precopy_duration)"
                    fi
                fi
                if [[ "$delta_count" -gt 0 ]]; then
                    echo "      Deltas transferred: $delta_count"
                fi
            done
        fi
        
        # Cutover details from pipeline
        local cutover_step=$(echo "$vm" | jq -r '[.pipeline[] | select(.name == "Cutover")] | first // null')
        if [[ "$cutover_step" != "null" && -n "$cutover_step" ]]; then
            local cutover_started=$(echo "$cutover_step" | jq -r '.started // null')
            local cutover_completed=$(echo "$cutover_step" | jq -r '.completed // null')
            local cutover_phase=$(echo "$cutover_step" | jq -r '.phase // "Unknown"')
            
            echo ""
            echo "  Cutover Details:"
            echo "    Phase: $cutover_phase"
            
            if [[ "$cutover_started" != "null" && "$cutover_started" != "" ]]; then
                echo "    Started:   $cutover_started"
            fi
            if [[ "$cutover_completed" != "null" && "$cutover_completed" != "" ]]; then
                echo "    Completed: $cutover_completed"
                if [[ "$cutover_started" != "null" && "$cutover_started" != "" ]]; then
                    local cutover_duration=$(time_diff_seconds "$cutover_started" "$cutover_completed")
                    echo "    Duration:  $(format_duration $cutover_duration)"
                fi
            fi
            
            # Calculate vSphere Snapshot Removal Time
            # This is the time between last completed precopy and cutover start
            # vSphere needs to consolidate/remove snapshots before cutover can proceed
            if [[ "$precopy_count" -gt 0 && "$cutover_started" != "null" && "$cutover_started" != "" ]]; then
                # Find the last precopy with an end time
                # The final precopy might not have an end time if it's the cutover snapshot
                local last_precopy_end=""
                local last_precopy_snapshot=""
                
                for idx in $(seq $((precopy_count - 1)) -1 0); do
                    local pc=$(echo "$precopies" | jq ".[$idx]")
                    local pc_end=$(echo "$pc" | jq -r '.end // "null"')
                    if [[ "$pc_end" != "null" && "$pc_end" != "" ]]; then
                        last_precopy_end="$pc_end"
                        last_precopy_snapshot=$(echo "$pc" | jq -r '.snapshot // "N/A"')
                        break
                    fi
                done
                
                if [[ -n "$last_precopy_end" ]]; then
                    local snapshot_removal_time=$(time_diff_seconds "$last_precopy_end" "$cutover_started")
                    
                    # Only show if there's actually a gap (> 1 minute)
                    if [[ $snapshot_removal_time -gt 60 ]]; then
                        echo ""
                        echo "  vSphere Snapshot Removal/Consolidation:"
                        echo "    Last completed precopy: $last_precopy_snapshot"
                        echo "    Precopy ended:          $last_precopy_end"
                        echo "    Cutover started:        $cutover_started"
                        echo "    Wait time:              $(format_duration $snapshot_removal_time)"
                        
                        # Warn if snapshot removal took a long time (> 30 minutes)
                        if [[ $snapshot_removal_time -gt 1800 ]]; then
                            log_warning "  Long snapshot removal time detected ($(format_duration $snapshot_removal_time))"
                            log_info "  This delay is vSphere-side snapshot consolidation, not MTV-related"
                        elif [[ $snapshot_removal_time -gt 600 ]]; then
                            log_info "  Note: Snapshot consolidation took $(format_duration $snapshot_removal_time)"
                        fi
                    fi
                fi
            fi
            
            # Cutover tasks (disk transfer details)
            local cutover_tasks=$(echo "$cutover_step" | jq -r '.tasks // []')
            local cutover_task_count=$(echo "$cutover_tasks" | jq 'length')
            
            if [[ "$cutover_task_count" -gt 0 ]]; then
                echo "    Disk Cutover Tasks:"
                for k in $(seq 0 $((cutover_task_count - 1))); do
                    local task=$(echo "$cutover_tasks" | jq ".[$k]")
                    local task_name=$(echo "$task" | jq -r '.name' | sed 's/.*\///' | head -c 50)
                    local task_phase=$(echo "$task" | jq -r '.phase // "Unknown"')
                    local precopy_count_task=$(echo "$task" | jq -r '.annotations.Precopy // "N/A"')
                    local progress_completed=$(echo "$task" | jq -r '.progress.completed // 0')
                    local progress_total=$(echo "$task" | jq -r '.progress.total // 0')
                    local unit=$(echo "$task" | jq -r '.annotations.unit // "MB"')
                    
                    echo "      - ${task_name}..."
                    echo "        Status: $task_phase | Precopies: $precopy_count_task | Data: ${progress_completed}/${progress_total} ${unit}"
                done
            fi
        fi
        
        # DiskTransfer phase details (incremental transfers)
        local disk_transfer_step=$(echo "$vm" | jq -r '[.pipeline[] | select(.name == "DiskTransfer")] | first // null')
        if [[ "$disk_transfer_step" != "null" && -n "$disk_transfer_step" ]]; then
            local dt_started=$(echo "$disk_transfer_step" | jq -r '.started // null')
            local dt_completed=$(echo "$disk_transfer_step" | jq -r '.completed // null')
            local dt_progress_completed=$(echo "$disk_transfer_step" | jq -r '.progress.completed // 0')
            local dt_progress_total=$(echo "$disk_transfer_step" | jq -r '.progress.total // 0')
            local dt_unit=$(echo "$disk_transfer_step" | jq -r '.annotations.unit // "MB"')
            
            echo ""
            echo "  Disk Transfer (Incremental):"
            if [[ "$dt_started" != "null" && "$dt_started" != "" ]]; then
                echo "    Started:   $dt_started"
            fi
            if [[ "$dt_completed" != "null" && "$dt_completed" != "" ]]; then
                echo "    Completed: $dt_completed"
                if [[ "$dt_started" != "null" && "$dt_started" != "" ]]; then
                    local dt_duration=$(time_diff_seconds "$dt_started" "$dt_completed")
                    echo "    Duration:  $(format_duration $dt_duration)"
                fi
            fi
            echo "    Data transferred: ${dt_progress_completed}/${dt_progress_total} ${dt_unit}"
            
            # Calculate transfer rate
            if [[ "$dt_started" != "null" && "$dt_completed" != "null" && "$dt_progress_completed" -gt 0 ]]; then
                local dt_duration=$(time_diff_seconds "$dt_started" "$dt_completed")
                if [[ "$dt_duration" -gt 0 ]]; then
                    local rate_mbps=$((dt_progress_completed / dt_duration))
                    echo "    Transfer rate: ~${rate_mbps} MB/s"
                fi
            fi
        fi
    done
    
    # Overall warm migration summary
    echo ""
    log_header "Warm Migration Summary"
    
    local total_precopies=0
    local total_successes=0
    local total_failures=0
    local vms_with_warm=0
    
    for i in $(seq 0 $((total_vms - 1))); do
        local vm=$(echo "$vms" | jq ".[$i]")
        local warm_data=$(echo "$vm" | jq -r '.warm // null')
        
        if [[ "$warm_data" != "null" ]]; then
            ((vms_with_warm++))
            local pc=$(echo "$warm_data" | jq -r '.precopies | length // 0')
            local sc=$(echo "$warm_data" | jq -r '.successes // 0')
            local fc=$(echo "$warm_data" | jq -r '.failures // 0')
            total_precopies=$((total_precopies + pc))
            total_successes=$((total_successes + sc))
            total_failures=$((total_failures + fc))
        fi
    done
    
    log_info "VMs with warm migration data: $vms_with_warm"
    log_info "Total precopies across all VMs: $total_precopies"
    log_info "Total successful precopies: $total_successes"
    
    if [[ "$total_failures" -gt 0 ]]; then
        log_warning "Total failed precopies: $total_failures"
    else
        log_success "No precopy failures detected"
    fi
    
    return $errors
}

# Validate pipeline steps completed for each VM
validate_pipeline_steps() {
    local migration_json="$1"
    local errors=0
    
    log_header "Pipeline Steps Validation"
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total_vms=$(echo "$vms" | jq 'length')
    
    if [[ "$total_vms" -eq 0 ]]; then
        return 0
    fi
    
    # Expected pipeline steps for cold migration
    local expected_steps=("Initialize" "DiskTransfer" "ImageConversion" "VMCreation")
    
    local vms_with_incomplete_pipeline=0
    
    for i in $(seq 0 $((total_vms - 1))); do
        local vm=$(echo "$vms" | jq ".[$i]")
        local vm_name=$(echo "$vm" | jq -r '.name')
        local pipeline=$(echo "$vm" | jq -r '.pipeline // []')
        local pipeline_length=$(echo "$pipeline" | jq 'length')
        
        # Check if VM succeeded
        local vm_succeeded=$(echo "$vm" | jq -r '.conditions[]? | select(.type=="Succeeded") | .status')
        
        if [[ "$vm_succeeded" == "True" && "$pipeline_length" -lt 4 ]]; then
            log_warning "VM '$vm_name' succeeded but has incomplete pipeline ($pipeline_length steps)"
            ((vms_with_incomplete_pipeline++))
        fi
        
        # Check for any failed pipeline steps
        local failed_steps=$(echo "$pipeline" | jq -r '.[] | select(.error != null) | .name')
        if [[ -n "$failed_steps" ]]; then
            log_error "VM '$vm_name' has failed pipeline steps: $failed_steps"
            ((errors++))
        fi
    done
    
    if [[ $vms_with_incomplete_pipeline -eq 0 ]]; then
        log_success "All successful VMs have complete pipeline steps"
    fi
    
    return $errors
}

#######################################
# Log Analysis Functions (Offline Mode)
#######################################

# Get the active search path (respects cycle selection)
get_active_search_path() {
    local logs_path="$1"
    
    local search_path="$logs_path"
    local cycles=$(list_test_cycles "$logs_path")
    local cycle_count=0
    if [[ -n "$cycles" ]]; then
        cycle_count=$(echo "$cycles" | wc -l)
    fi
    
    if [[ $cycle_count -gt 1 ]]; then
        if [[ -n "$SELECTED_CYCLE" ]]; then
            local match=$(echo "$cycles" | grep -i "$SELECTED_CYCLE" | head -1)
            if [[ -n "$match" ]]; then
                search_path="$match"
            fi
        else
            local latest=$(get_latest_cycle "$logs_path")
            if [[ -n "$latest" ]]; then
                search_path="$latest"
            fi
        fi
    elif [[ $cycle_count -eq 1 ]]; then
        search_path=$(echo "$cycles" | head -1)
    fi
    
    echo "$search_path"
}

# Find controller log file in logs folder
find_controller_log_file() {
    local logs_path="$1"
    
    local search_path=$(get_active_search_path "$logs_path")
    
    local controller_log
    controller_log=$(find "$search_path" -name "MTV_forklift-controller-*.log" -type f 2>/dev/null | head -1)
    
    if [[ -n "$controller_log" && -f "$controller_log" ]]; then
        echo "$controller_log"
        return 0
    fi
    
    return 1
}

# Find VirtV2V log files for a specific plan
find_virtv2v_logs() {
    local logs_path="$1"
    local plan_name="$2"
    
    local search_path=$(get_active_search_path "$logs_path")
    
    find "$search_path" -name "VirtV2V_${plan_name}*.log" -type f 2>/dev/null
}

# Analyze controller logs for errors related to the plan
# Filters by EXACT plan name AND timestamp within migration timeframe
# Uses grep + jq for fast processing of large log files
# Note: Log errors don't count as validation failures if migration succeeded
analyze_controller_logs() {
    local migration_json="$1"
    local errors=0
    
    # Check if migration succeeded - if so, log errors are informational only
    local conditions=$(echo "$migration_json" | jq -r '.status.conditions // []')
    local migration_succeeded=$(echo "$conditions" | jq -r '.[] | select(.type=="Succeeded") | .status')
    local is_success="false"
    if [[ "$migration_succeeded" == "True" ]]; then
        is_success="true"
    fi
    
    if [[ "$OFFLINE_MODE" != "true" ]]; then
        return 0
    fi
    
    log_header "Controller Log Analysis"
    
    # Find controller log
    local controller_log=$(find_controller_log_file "$LOGS_FOLDER")
    
    if [[ -z "$controller_log" ]]; then
        log_warning "Controller log file not found"
        return 0
    fi
    
    log_info "Analyzing: $(basename "$controller_log")"
    
    # Get EXACT plan name from migration JSON
    local plan_name=$(echo "$migration_json" | jq -r '.spec.plan.name')
    if [[ -z "$plan_name" || "$plan_name" == "null" ]]; then
        plan_name=$(echo "$migration_json" | jq -r '.metadata.name')
    fi
    
    # Get migration timeframe
    local migration_started=$(echo "$migration_json" | jq -r '.status.started // "null"')
    local migration_completed=$(echo "$migration_json" | jq -r '.status.completed // "null"')
    
    log_info "Plan: $plan_name"
    log_info "Timeframe: $migration_started to $migration_completed"
    
    if [[ "$migration_started" == "null" || "$migration_completed" == "null" ]]; then
        log_warning "Migration timeframe not available - skipping log analysis"
        return 0
    fi
    
    # Convert timestamps to comparable format (YYYY-MM-DD HH:MM:SS)
    local start_ts=$(echo "$migration_started" | sed 's/T/ /; s/Z$//')
    local end_ts=$(echo "$migration_completed" | sed 's/T/ /; s/Z$//')
    
    log_info "Filtering logs: $start_ts to $end_ts"
    echo ""
    
    # Step 1: Fast grep to get only lines with plan name AND (error OR warning)
    # This reduces data before JSON parsing
    local filtered_lines=$(grep -E "\"$plan_name\"" "$controller_log" 2>/dev/null | \
        grep -E '"level":"error"|"type":"Warning"' || true)
    
    if [[ -z "$filtered_lines" ]]; then
        log_success "No errors or warnings found for this plan"
        return 0
    fi
    
    # Step 2: Use jq to filter by timestamp and extract relevant info
    # Process all filtered lines at once (much faster than line-by-line)
    local plan_errors=$(echo "$filtered_lines" | \
        jq -r --arg start "$start_ts" --arg end "$end_ts" \
        'select(.ts >= $start and .ts <= $end and .level == "error") | .error // empty' 2>/dev/null || true)
    
    local plan_warnings=$(echo "$filtered_lines" | \
        jq -r --arg start "$start_ts" --arg end "$end_ts" \
        'select(.ts >= $start and .ts <= $end and .type == "Warning") | .reason // .msg // empty' 2>/dev/null || true)
    
    local error_count=0
    local warning_count=0
    
    if [[ -n "$plan_errors" ]]; then
        error_count=$(echo "$plan_errors" | grep -c . || echo "0")
    fi
    
    if [[ -n "$plan_warnings" ]]; then
        warning_count=$(echo "$plan_warnings" | grep -c . || echo "0")
    fi
    
    log_info "Errors during migration: $error_count"
    log_info "Warnings during migration: $warning_count"
    
    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        log_success "No errors or warnings during migration timeframe for this plan"
        return 0
    fi
    
    # Categorize and display unique errors
    if [[ $error_count -gt 0 ]]; then
        echo ""
        echo "  Error Summary (unique messages):"
        echo "  --------------------------------"
        
        echo "$plan_errors" | \
            sed 's/caused by:.*//' | \
            sort | uniq -c | sort -rn | head -10 | \
            while read count msg; do
                if [[ -n "$msg" ]]; then
                    echo "    [$count] $msg"
                fi
            done
        
        # Only count as validation error if migration failed
        if [[ "$is_success" != "true" ]]; then
            ((errors++))
        else
            log_info "Note: Errors found in logs but migration succeeded - treating as informational"
        fi
    fi
    
    # Show warning types
    if [[ $warning_count -gt 0 ]]; then
        echo ""
        echo "  Warning Summary:"
        echo "  ----------------"
        
        echo "$plan_warnings" | \
            sort | uniq -c | sort -rn | head -10 | \
            while read count msg; do
                if [[ -n "$msg" ]]; then
                    echo "    [$count] $msg"
                fi
            done
    fi
    
    return $errors
}

# Analyze VirtV2V logs for conversion errors
# Note: Log errors don't count as validation failures if migration succeeded
analyze_virtv2v_logs() {
    local migration_json="$1"
    local errors=0
    
    if [[ "$OFFLINE_MODE" != "true" ]]; then
        return 0
    fi
    
    # Check if migration succeeded - if so, log errors are informational only
    local conditions=$(echo "$migration_json" | jq -r '.status.conditions // []')
    local migration_succeeded=$(echo "$conditions" | jq -r '.[] | select(.type=="Succeeded") | .status')
    local is_success="false"
    if [[ "$migration_succeeded" == "True" ]]; then
        is_success="true"
    fi
    
    log_header "VirtV2V Log Analysis"
    
    # Get plan name
    local plan_name=$(echo "$migration_json" | jq -r '.spec.plan.name // .metadata.name' | sed 's/-[a-z0-9]*$//')
    
    # Find VirtV2V logs
    local virtv2v_logs=$(find_virtv2v_logs "$LOGS_FOLDER" "$plan_name")
    
    if [[ -z "$virtv2v_logs" ]]; then
        # Try without plan name prefix
        virtv2v_logs=$(find "$LOGS_FOLDER" -name "VirtV2V_*.log" -type f 2>/dev/null)
    fi
    
    if [[ -z "$virtv2v_logs" ]]; then
        log_warning "No VirtV2V log files found"
        return 0
    fi
    
    local log_count=$(echo "$virtv2v_logs" | wc -l)
    log_info "Found $log_count VirtV2V log file(s)"
    
    local vms_with_real_errors=0
    local vms_with_benign_errors=0
    local vms_completed=0
    local total_real_errors=0
    
    # Collect unique error types across all VMs
    local -A unique_errors
    local -A error_vm_count
    
    while IFS= read -r log_file; do
        [[ -z "$log_file" ]] && continue
        
        local vm_name=$(basename "$log_file" .log | sed 's/VirtV2V_//')
        
        # Check for REAL errors only - these indicate actual conversion failures:
        # - "virt-v2v: error:" prefix (actual virt-v2v errors)
        # - "fatal" messages
        # - "conversion failed" messages
        # - Exit codes != 0 at the end
        # Exclude all debug/trace/info messages which often contain "error" as a data value
        local v2v_errors=$(grep -E "^virt-v2v: error:|^error:.*fatal|conversion failed|virt-v2v.*failed" "$log_file" 2>/dev/null | \
            head -10 || true)
        
        # Check if conversion completed successfully
        local completed="false"
        if grep -q "Finishing off\|Conversion complete\|successful" "$log_file" 2>/dev/null; then
            completed="true"
            ((vms_completed++))
        fi
        
        if [[ -n "$v2v_errors" ]]; then
            local error_count=$(echo "$v2v_errors" | wc -l)
            ((vms_with_real_errors++))
            total_real_errors=$((total_real_errors + error_count))
            
            # Collect unique error messages
            while IFS= read -r err_line; do
                # Normalize the error message (remove timestamps, vm-specific parts)
                local normalized=$(echo "$err_line" | sed 's/vm-[0-9]*-[a-z0-9]*/vm-XXXX/g' | cut -c1-80)
                if [[ -n "$normalized" ]]; then
                    unique_errors["$normalized"]=1
                    error_vm_count["$normalized"]=$((${error_vm_count["$normalized"]:-0} + 1))
                fi
            done <<< "$v2v_errors"
        else
            # Check for benign errors only
            local benign_only=$(grep -iE "error|failed" "$log_file" 2>/dev/null | \
                grep -E "$benign_patterns" | head -1 || true)
            if [[ -n "$benign_only" ]]; then
                ((vms_with_benign_errors++))
            fi
        fi
    done <<< "$virtv2v_logs"
    
    echo ""
    echo "  VM Conversion Summary:"
    echo "  ----------------------"
    echo -e "    Completed successfully: ${GREEN}$vms_completed${NC} / $log_count"
    
    if [[ $vms_with_benign_errors -gt 0 ]]; then
        echo -e "    With benign warnings:   ${YELLOW}$vms_with_benign_errors${NC} (VDDK config messages - expected)"
    fi
    
    if [[ $vms_with_real_errors -gt 0 ]]; then
        echo -e "    With real errors:       ${RED}$vms_with_real_errors${NC}"
        echo ""
        echo "  Unique Error Types Found:"
        echo "  -------------------------"
        for err_msg in "${!unique_errors[@]}"; do
            local count=${error_vm_count["$err_msg"]}
            echo -e "    ${RED}[$count VM(s)]${NC} $err_msg..."
        done
    fi
    
    echo ""
    if [[ $vms_with_real_errors -eq 0 ]]; then
        log_success "No real conversion errors found in VirtV2V logs"
        if [[ $vms_with_benign_errors -gt 0 ]]; then
            log_info "Note: Benign VDDK config warnings present (normal for all migrations)"
        fi
    else
        # Only count as validation error if migration failed
        if [[ "$is_success" != "true" ]]; then
            log_error "$vms_with_real_errors VM(s) have conversion errors (total: $total_real_errors errors)"
            ((errors++))
        else
            log_warning "$vms_with_real_errors VM(s) have log errors - but migration succeeded"
            log_info "Note: These may be transient errors that were retried successfully"
        fi
    fi
    
    return $errors
}

# Analyze importer pod logs for disk transfer errors (online mode)
analyze_importer_logs() {
    local migration_json="$1"
    local errors=0
    
    # Get target namespace from plan
    local plan_name=$(echo "$migration_json" | jq -r '.spec.plan.name')
    local plan_json=$(get_plan_json "$plan_name" "$DEFAULT_NAMESPACE")
    
    if [[ -z "$plan_json" ]]; then
        return 0
    fi
    
    local target_ns=$(echo "$plan_json" | jq -r '.spec.targetNamespace')
    
    if [[ -z "$target_ns" || "$target_ns" == "null" ]]; then
        return 0
    fi
    
    log_header "Importer Pod Log Analysis"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - look for Importer_*.log files in the actual cycle folder
        # Use MIGRATION_JSON_FILE location to find the correct cycle folder
        local cycle_folder="$LOGS_FOLDER"
        if [[ -n "$MIGRATION_JSON_FILE" ]]; then
            cycle_folder=$(dirname "$MIGRATION_JSON_FILE")
        fi
        local importer_logs=$(find "$cycle_folder" -maxdepth 1 -name "Importer_*.log" -type f 2>/dev/null | sort)
        
        if [[ -z "$importer_logs" ]]; then
            log_info "No importer logs found in saved logs"
            log_info "Importer logs are collected during warm migrations by automation"
            return 0
        fi
        
        local log_count=$(echo "$importer_logs" | wc -l)
        log_info "Found $log_count importer log file(s)"
        
        local files_with_errors=0
        local total_error_count=0
        
        echo ""
        echo "  Importer Log Analysis:"
        echo "  -----------------------"
        
        while IFS= read -r log_file; do
            [[ -z "$log_file" ]] && continue
            
            local log_name=$(basename "$log_file")
            # Extract VM info from filename: Importer_importer-<plan>-vm-<id>-<hash>-checkpoint-<num>-snapshot-<num>.log
            local vm_info=$(echo "$log_name" | grep -oE 'vm-[0-9]{4,}' | head -1)
            local snapshot_info=$(echo "$log_name" | grep -oE 'snapshot-[0-9]+' | head -1)
            [[ -z "$vm_info" ]] && vm_info="importer"
            
            # Search for critical errors in the log file (skip benign debug messages)
            # Focus on real errors: E0xxx lines, specific error messages
            local importer_errors=$(grep -E "^E[0-9]{4}.*([Ff]atal|[Ff]ailed|Could not find|not present|No snapshots|Unable to|[Cc]annot|not authenticated|error connecting|connection refused)" "$log_file" 2>/dev/null | grep -v "<nil>" | tail -5 || true)
            
            if [[ -n "$importer_errors" ]]; then
                local error_count=$(echo "$importer_errors" | wc -l)
                ((files_with_errors++))
                total_error_count=$((total_error_count + error_count))
                
                echo "    ${RED}[ERRORS]${NC} $vm_info ($snapshot_info)"
                
                # Show error lines
                echo "$importer_errors" | while read -r line; do
                    local short_msg=$(echo "$line" | sed 's/^[EIW][0-9]* [0-9:.]*[[:space:]]*//' | cut -c1-100)
                    echo "             ${RED}$short_msg${NC}"
                done
                echo ""
            fi
        done <<< "$importer_logs"
        
        if [[ $files_with_errors -gt 0 ]]; then
            log_error "$files_with_errors importer log(s) have errors (total: $total_error_count errors)"
            errors=1
        else
            log_success "No errors found in importer logs"
        fi
        
        return $errors
    fi
    
    # Online mode - only analyze if there are failed VMs (pods may still exist)
    local failed_vms=$(echo "$migration_json" | jq -r '[.status.vms[] | select(.conditions[]?.type=="Failed" and .conditions[]?.status=="True")] | length')
    
    if [[ "$failed_vms" -eq 0 ]]; then
        return 0
    fi
    
    # Online mode - find importer pods in target namespace
    local importer_pods=$(oc get pods -n "$target_ns" -o name 2>/dev/null | grep -E "importer-" || true)
    
    if [[ -z "$importer_pods" ]]; then
        log_info "No importer pods found in namespace '$target_ns'"
        return 0
    fi
    
    local pod_count=$(echo "$importer_pods" | wc -l)
    log_info "Found $pod_count importer pod(s) in '$target_ns'"
    
    local pods_with_errors=0
    local total_errors=0
    
    echo ""
    echo "  Importer Pod Status:"
    echo "  --------------------"
    
    while IFS= read -r pod; do
        [[ -z "$pod" ]] && continue
        
        local pod_name=$(echo "$pod" | sed 's|pod/||')
        
        # Get pod status
        local pod_status=$(oc get "$pod" -n "$target_ns" -o jsonpath='{.status.phase}' 2>/dev/null)
        local restart_count=$(oc get "$pod" -n "$target_ns" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        
        # Get logs and check for errors
        local pod_logs=$(oc logs "$pod" -n "$target_ns" --tail=100 2>/dev/null || true)
        local importer_errors=""
        
        if [[ -n "$pod_logs" ]]; then
            # Look for error patterns in importer logs
            importer_errors=$(echo "$pod_logs" | grep -E "^E[0-9]{4}|error|failed|fatal|Could not find|not present|No snapshots" 2>/dev/null | grep -v "error=0" | tail -5 || true)
        fi
        
        if [[ -n "$importer_errors" ]]; then
            local error_count=$(echo "$importer_errors" | wc -l)
            ((pods_with_errors++))
            total_errors=$((total_errors + error_count))
            
            echo "    ${RED}[ERRORS]${NC} $pod_name"
            echo "             Status: $pod_status | Restarts: $restart_count"
            
            # Show error lines
            echo "$importer_errors" | while read -r line; do
                # Extract the relevant part of the error message
                local short_msg=$(echo "$line" | sed 's/^[EIW][0-9]* [0-9:.]*[[:space:]]*//' | cut -c1-120)
                echo "             ${RED}$short_msg${NC}"
            done
            echo ""
        else
            if [[ "$pod_status" == "Succeeded" || "$pod_status" == "Completed" ]]; then
                echo "    ${GREEN}[OK]${NC} $pod_name - completed successfully"
            elif [[ "$pod_status" == "Running" ]]; then
                echo "    ${YELLOW}[RUNNING]${NC} $pod_name - still in progress"
            elif [[ "$pod_status" == "Failed" || "$restart_count" -gt 5 ]]; then
                echo "    ${RED}[FAILED]${NC} $pod_name - Status: $pod_status | Restarts: $restart_count"
                ((pods_with_errors++))
            else
                echo "    ${YELLOW}[$pod_status]${NC} $pod_name"
            fi
        fi
    done <<< "$importer_pods"
    
    echo ""
    
    if [[ $pods_with_errors -gt 0 ]]; then
        log_error "$pods_with_errors importer pod(s) have errors"
        ((errors++))
    else
        log_success "No critical errors found in importer pod logs"
    fi
    
    return $errors
}

# Validate target namespace has expected VMs
validate_target_namespace() {
    local migration_json="$1"
    local namespace="$2"
    local errors=0
    
    log_header "Target Namespace Validation"
    
    # Get plan name and target namespace
    local plan_name=$(echo "$migration_json" | jq -r '.spec.plan.name')
    local plan_json=$(get_plan_json "$plan_name" "$namespace")
    
    if [[ -z "$plan_json" ]]; then
        log_warning "Could not retrieve plan '$plan_name'"
        return 0
    fi
    
    local target_ns=$(echo "$plan_json" | jq -r '.spec.targetNamespace')
    
    if [[ -z "$target_ns" || "$target_ns" == "null" ]]; then
        log_warning "Could not determine target namespace"
        return 0
    fi
    
    log_info "Target namespace: $target_ns"
    
    # Count expected VMs from migration data
    local expected_vms=$(echo "$migration_json" | jq '[.status.vms[] | select(.conditions[]?.type=="Succeeded" and .conditions[]?.status=="True")] | length')
    log_info "Expected VMs (succeeded): $expected_vms"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # Offline mode - skip cluster check
        log_info "Offline mode - skipping cluster VM count verification"
        return 0
    fi
    
    # Online mode - count actual VMs in cluster
    local actual_vms=$(oc get virtualmachine -n "$target_ns" --no-headers 2>/dev/null | wc -l)
    
    log_info "Actual VMs in target namespace: $actual_vms"
    
    if [[ $actual_vms -eq $expected_vms ]]; then
        log_success "VM count matches: $actual_vms VMs in target namespace"
    elif [[ $actual_vms -gt $expected_vms ]]; then
        log_warning "More VMs in target namespace than expected (may include VMs from other migrations)"
    else
        log_error "Fewer VMs in target namespace than expected (missing: $((expected_vms - actual_vms)))"
        ((errors++))
    fi
    
    return $errors
}

#######################################
# Live Monitoring Functions
#######################################

# Check for stuck VMs (no progress for threshold time)
check_stuck_vms() {
    local migration_json="$1"
    local stuck_found=0
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total_vms=$(echo "$vms" | jq 'length')
    local current_time=$(date +%s)
    local stuck_threshold=$((STUCK_THRESHOLD_MINUTES * 60))
    
    for i in $(seq 0 $((total_vms - 1))); do
        local vm=$(echo "$vms" | jq ".[$i]")
        local vm_name=$(echo "$vm" | jq -r '.name')
        local vm_running=$(echo "$vm" | jq -r '.conditions[]? | select(.type=="Running") | .status')
        
        if [[ "$vm_running" == "True" ]]; then
            # Check pipeline progress
            local pipeline=$(echo "$vm" | jq -r '.pipeline // []')
            local last_update=""
            
            # Find the most recent pipeline step update
            for step_idx in $(seq 0 $(($(echo "$pipeline" | jq 'length') - 1))); do
                local step_completed=$(echo "$pipeline" | jq -r ".[$step_idx].completed // \"null\"")
                local step_started=$(echo "$pipeline" | jq -r ".[$step_idx].started // \"null\"")
                
                if [[ "$step_completed" != "null" ]]; then
                    last_update="$step_completed"
                elif [[ "$step_started" != "null" ]]; then
                    last_update="$step_started"
                fi
            done
            
            if [[ -n "$last_update" && "$last_update" != "null" ]]; then
                local last_update_epoch=$(timestamp_to_epoch "$last_update")
                local time_since_update=$((current_time - last_update_epoch))
                
                if [[ $time_since_update -gt $stuck_threshold ]]; then
                    log_warning "VM '$vm_name' appears stuck - no progress for $(format_duration $time_since_update)"
                    ((stuck_found++))
                fi
            fi
        fi
    done
    
    return $stuck_found
}

# Get current migration progress summary
get_migration_progress() {
    local migration_json="$1"
    
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local total=$(echo "$vms" | jq 'length')
    local succeeded=$(echo "$vms" | jq '[.[] | select(.conditions[]?.type=="Succeeded" and .conditions[]?.status=="True")] | length')
    local failed=$(echo "$vms" | jq '[.[] | select(.conditions[]?.type=="Failed" and .conditions[]?.status=="True")] | length')
    # Count VMs as "in progress" if they are in an active phase (not Pending/Completed and not failed/succeeded)
    local in_progress=$(echo "$vms" | jq '[.[] | select(.phase != null and .phase != "" and .phase != "Pending" and .phase != "Completed")] | length')
    # Subtract already counted succeeded/failed from in_progress
    in_progress=$((in_progress - succeeded - failed))
    [[ $in_progress -lt 0 ]] && in_progress=0
    local pending=$((total - succeeded - failed - in_progress))
    [[ $pending -lt 0 ]] && pending=0
    
    # Get current phase for single VM or summary for multiple
    local phase_info=""
    if [[ $total -eq 1 ]]; then
        local current_phase=$(echo "$vms" | jq -r '.[0].phase // "Unknown"')
        if [[ "$current_phase" != "null" && "$current_phase" != "Completed" && "$current_phase" != "Pending" ]]; then
            phase_info=" [Phase: $current_phase]"
        fi
    fi
    
    echo "Progress: $succeeded/$total succeeded, $failed failed, $in_progress in-progress, $pending pending$phase_info"
}

# Display migration details for monitoring
display_monitor_details() {
    local migration_json="$1"
    
    # Get migration start time
    local mig_started=$(echo "$migration_json" | jq -r '.status.started // empty')
    if [[ -n "$mig_started" && "$mig_started" != "null" ]]; then
        log_info "Migration started: $mig_started"
        local start_epoch=$(timestamp_to_epoch "$mig_started")
        local now_epoch=$(date +%s)
        local running_for=$((now_epoch - start_epoch))
        log_info "Running for: $(format_duration $running_for)"
    fi
    
    # Detect migration type
    local migration_type=$(detect_migration_type "$migration_json")
    log_info "Migration type: ${CYAN}$migration_type${NC}"
    
    # Get VM count
    local total_vms=$(echo "$migration_json" | jq '.status.vms | length')
    log_info "Total VMs: $total_vms"
    
    # For warm migrations, show precopy summary
    if [[ "$migration_type" == "Warm" ]]; then
        echo ""
        echo "  Warm Migration Status:"
        echo "  ----------------------------------------"
        
        local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
        echo "$vms" | jq -r '.[] | @base64' | while read -r vm_b64; do
            local vm=$(echo "$vm_b64" | base64 -d 2>/dev/null)
            local vm_name=$(echo "$vm" | jq -r '.name')
            local vm_phase=$(echo "$vm" | jq -r '.phase // "Unknown"')
            local warm_data=$(echo "$vm" | jq -r '.warm // empty')
            
            echo "  VM: $vm_name"
            echo "    Phase: $vm_phase"
            
            if [[ -n "$warm_data" && "$warm_data" != "null" ]]; then
                local precopies=$(echo "$warm_data" | jq -r '.precopies // []')
                local precopy_count=$(echo "$precopies" | jq 'length')
                local successes=$(echo "$warm_data" | jq -r '.successes // 0')
                local failures=$(echo "$warm_data" | jq -r '.failures // 0')
                
                echo "    Precopies: $precopy_count (successes: $successes, failures: $failures)"
                
                # Show each precopy with timing
                if [[ $precopy_count -gt 0 ]]; then
                    local pc_idx=1
                    echo "$precopies" | jq -r '.[] | @base64' | while read -r pc_b64; do
                        local pc=$(echo "$pc_b64" | base64 -d 2>/dev/null)
                        local snapshot=$(echo "$pc" | jq -r '.snapshot // "unknown"')
                        local pc_start=$(echo "$pc" | jq -r '.start // empty')
                        local pc_end=$(echo "$pc" | jq -r '.end // empty')
                        
                        if [[ -n "$pc_start" ]]; then
                            local start_fmt=$(echo "$pc_start" | sed 's/T/ /' | cut -d'.' -f1)
                            if [[ -n "$pc_end" && "$pc_end" != "null" ]]; then
                                local end_fmt=$(echo "$pc_end" | sed 's/T/ /' | cut -d'.' -f1)
                                local duration_secs=$(time_diff_seconds "$pc_start" "$pc_end")
                                echo "      Precopy #$pc_idx: $snapshot | $start_fmt -> $end_fmt ($(format_duration $duration_secs))"
                            else
                                echo "      Precopy #$pc_idx: $snapshot | Started: $start_fmt (in progress...)"
                            fi
                        fi
                        ((pc_idx++))
                    done
                fi
            fi
            echo ""
        done
    fi
    
    # Show disk transfer progress if available
    local vms=$(echo "$migration_json" | jq -r '.status.vms // []')
    local disk_tasks=$(echo "$vms" | jq -r '.[].pipeline[]? | select(.name=="DiskTransfer" or .name=="Cutover") | .tasks[]? // empty')
    if [[ -n "$disk_tasks" ]]; then
        echo "  Disk Transfer Progress:"
        echo "  ----------------------------------------"
        echo "$vms" | jq -r '.[] | @base64' | while read -r vm_b64; do
            local vm=$(echo "$vm_b64" | base64 -d 2>/dev/null)
            local vm_name=$(echo "$vm" | jq -r '.name')
            local transfer_step=$(echo "$vm" | jq -r '.pipeline[]? | select(.name=="DiskTransfer")')
            if [[ -n "$transfer_step" ]]; then
                local completed=$(echo "$transfer_step" | jq -r '.progress.completed // 0')
                local total=$(echo "$transfer_step" | jq -r '.progress.total // 0')
                if [[ $total -gt 0 ]]; then
                    local pct=$((completed * 100 / total))
                    echo "    $vm_name: ${completed}MB / ${total}MB ($pct%)"
                fi
            fi
        done
        echo ""
    fi
}

# Live monitoring mode
monitor_migration() {
    local name="$1"
    local namespace="$2"
    local timeout="$3"
    
    log_header "Live Migration Monitoring"
    log_info "Monitoring migration: $name"
    log_info "Namespace: $namespace"
    log_info "Timeout: ${timeout}s ($(format_duration $timeout))"
    log_info "Poll interval: ${POLL_INTERVAL}s"
    echo ""
    
    local monitor_start_time=$(date +%s)
    local end_time=$((monitor_start_time + timeout))
    local iteration=0
    local last_progress=""
    local details_shown=false
    
    while true; do
        ((iteration++))
        local current_time=$(date +%s)
        local elapsed=$((current_time - monitor_start_time))
        
        # Check timeout
        if [[ $current_time -ge $end_time ]]; then
            log_error "Monitoring timeout reached after $(format_duration $elapsed)"
            return 1
        fi
        
        # Get current migration state
        local migration_json=$(get_migration_json "$name" "$namespace")
        
        if [[ -z "$migration_json" ]]; then
            log_error "Failed to get migration status"
            sleep $POLL_INTERVAL
            continue
        fi
        
        # Show migration details on first iteration
        if [[ "$details_shown" == "false" ]]; then
            display_monitor_details "$migration_json"
            details_shown=true
            echo "============================================================"
            echo " Progress Updates"
            echo "============================================================"
        fi
        
        # Check migration conditions
        local conditions=$(echo "$migration_json" | jq -r '.status.conditions // []')
        local succeeded=$(echo "$conditions" | jq -r '.[] | select(.type=="Succeeded") | .status')
        local failed=$(echo "$conditions" | jq -r '.[] | select(.type=="Failed") | .status')
        
        # Get progress
        local progress=$(get_migration_progress "$migration_json")
        
        # Print progress if changed
        if [[ "$progress" != "$last_progress" ]]; then
            echo "[$(date '+%H:%M:%S')] $progress"
            last_progress="$progress"
        fi
        
        # Check for completion
        if [[ "$succeeded" == "True" ]]; then
            echo ""
            log_success "Migration completed successfully!"
            log_info "Total monitoring time: $(format_duration $elapsed)"
            return 0
        fi
        
        if [[ "$failed" == "True" ]]; then
            echo ""
            log_error "Migration failed!"
            local failure_msg=$(echo "$conditions" | jq -r '.[] | select(.type=="Failed") | .message // "Unknown"')
            log_error "Reason: $failure_msg"
            return 1
        fi
        
        # Check for stuck VMs (only after first few iterations)
        if [[ $iteration -gt 2 ]]; then
            local stuck_count=$(check_stuck_vms "$migration_json")
            if [[ $stuck_count -gt 0 ]]; then
                log_warning "$stuck_count VM(s) appear to be stuck"
            fi
        fi
        
        # Check for newly failed VMs
        local failed_vms=$(echo "$migration_json" | jq '[.status.vms[] | select(.conditions[]?.type=="Failed" and .conditions[]?.status=="True")] | length')
        if [[ $failed_vms -gt 0 ]]; then
            log_warning "$failed_vms VM(s) have failed"
        fi
        
        sleep $POLL_INTERVAL
    done
}

#######################################
# Report Generation
#######################################

generate_report() {
    local name="$1"
    local namespace="$2"
    
    log_header "Migration Health Report"
    log_info "Migration: $name"
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        log_info "Mode: ${YELLOW}Offline${NC} (from saved logs)"
        log_info "Logs path: $LOGS_FOLDER"
    else
        log_info "Mode: ${GREEN}Online${NC} (live cluster)"
        log_info "Namespace: $namespace"
    fi
    log_info "Report generated: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # In offline mode, find migration file first to set MIGRATION_JSON_FILE for version detection
    if [[ "$OFFLINE_MODE" == "true" && -z "$MIGRATION_JSON_FILE" ]]; then
        MIGRATION_JSON_FILE=$(find_migration_json_file "$LOGS_FOLDER" "$name")
    fi
    
    local migration_json=$(get_migration_json "$name" "$namespace")
    
    if [[ -z "$migration_json" ]]; then
        log_error "Failed to get migration data"
        return 1
    fi
    
    local total_errors=0
    local temp_errors=0
    
    # Run all validations
    validate_migration_status "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    validate_vm_consistency "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    validate_vm_timing "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    validate_pipeline_steps "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    # Warm migration specific validations
    validate_warm_migration "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    validate_target_namespace "$migration_json" "$namespace"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    # Log analysis (offline mode only)
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        analyze_controller_logs "$migration_json"
        temp_errors=$?
        total_errors=$((total_errors + temp_errors))
        
        analyze_virtv2v_logs "$migration_json"
        temp_errors=$?
        total_errors=$((total_errors + temp_errors))
    fi
    
    # Importer log analysis (online mode only, for failed migrations)
    analyze_importer_logs "$migration_json"
    temp_errors=$?
    total_errors=$((total_errors + temp_errors))
    
    # Summary
    log_header "Validation Summary"
    
    if [[ $total_errors -eq 0 ]]; then
        log_success "All validations passed! Migration is healthy."
    else
        log_error "Found $total_errors validation issue(s)"
    fi
    
    # Check for MigrationSummary file with multiple cycles (offline mode)
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        display_multi_cycle_summary "$LOGS_FOLDER" "$name"
    fi
    
    if [[ $total_errors -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Display multi-cycle statistics from MigrationSummary file
display_multi_cycle_summary() {
    local logs_path="$1"
    local plan_name="$2"
    
    # Find MigrationSummary file (could be in parent directory)
    local summary_file=""
    local search_paths=("$logs_path" "$(dirname "$logs_path")" "$(dirname "$(dirname "$logs_path")")")
    
    for search_path in "${search_paths[@]}"; do
        summary_file=$(find "$search_path" -maxdepth 1 -name "MigrationSummary_*.txt" -type f 2>/dev/null | head -1)
        [[ -n "$summary_file" ]] && break
    done
    
    if [[ -z "$summary_file" || ! -f "$summary_file" ]]; then
        return 0  # No summary file, nothing to display
    fi
    
    # Count cycles in the summary file
    local cycle_count=$(grep -c "^Migration Cycle #" "$summary_file" 2>/dev/null || echo "0")
    
    if [[ $cycle_count -le 1 ]]; then
        return 0  # Only one or no cycles, skip summary
    fi
    
    log_header "Multi-Cycle Statistics (from MigrationSummary)"
    log_info "Source: $(basename "$summary_file")"
    log_info "Total cycles: $cycle_count"
    echo ""
    
    # Parse all cycle data
    local -a durations=()
    local pass_count=0
    local fail_count=0
    local total_vms=0
    local total_duration_secs=0
    local min_duration_secs=999999999
    local max_duration_secs=0
    local min_cycle=""
    local max_cycle=""
    
    while IFS= read -r line; do
        # Extract cycle number
        local cycle_num=$(echo "$line" | grep -oP 'Migration Cycle #\K\d+')
        
        # Extract status (Succeeded or Failed)
        local status=$(echo "$line" | grep -oP 'MigrationStatus:\s*\K\w+')
        if [[ "$status" == "Succeeded" ]]; then
            ((pass_count++))
        else
            ((fail_count++))
        fi
        
        # Extract VM count
        local vm_count=$(echo "$line" | grep -oP 'Total migrated VMs:\s*\K\d+')
        [[ -n "$vm_count" ]] && total_vms=$((total_vms + vm_count))
        
        # Extract duration (format: HH:MM:SS)
        local duration=$(echo "$line" | grep -oP 'Total Duration:\s*\K[\d:]+')
        if [[ -n "$duration" ]]; then
            # Convert HH:MM:SS to seconds
            local h=$(echo "$duration" | cut -d: -f1)
            local m=$(echo "$duration" | cut -d: -f2)
            local s=$(echo "$duration" | cut -d: -f3)
            # Remove leading zeros to avoid octal interpretation
            h=$((10#$h))
            m=$((10#$m))
            s=$((10#$s))
            local dur_secs=$((h * 3600 + m * 60 + s))
            
            durations+=("$dur_secs")
            total_duration_secs=$((total_duration_secs + dur_secs))
            
            if [[ $dur_secs -lt $min_duration_secs ]]; then
                min_duration_secs=$dur_secs
                min_cycle="#$cycle_num"
            fi
            if [[ $dur_secs -gt $max_duration_secs ]]; then
                max_duration_secs=$dur_secs
                max_cycle="#$cycle_num"
            fi
        fi
    done < <(grep "^Migration Cycle #" "$summary_file")
    
    local duration_count=${#durations[@]}
    
    if [[ $duration_count -gt 0 ]]; then
        # Calculate average
        local avg_duration_secs=$((total_duration_secs / duration_count))
        
        # Calculate standard deviation
        local sum_sq_diff=0
        for d in "${durations[@]}"; do
            local diff=$((d - avg_duration_secs))
            sum_sq_diff=$((sum_sq_diff + diff * diff))
        done
        local variance=$((sum_sq_diff / duration_count))
        local stddev=0
        if [[ $variance -gt 0 ]]; then
            stddev=$variance
            for _ in {1..10}; do
                stddev=$(( (stddev + variance / stddev) / 2 ))
            done
        fi
        
        echo "  Cycle Results:"
        echo "  ----------------------------------------"
        echo -e "    Passed:        ${GREEN}$pass_count${NC}"
        echo -e "    Failed:        ${RED}$fail_count${NC}"
        echo -e "    Success Rate:  $(( pass_count * 100 / cycle_count ))%"
        echo ""
        echo "  Duration Statistics ($duration_count cycles):"
        echo "  ----------------------------------------"
        echo -e "    ${CYAN}Average:       $(format_duration $avg_duration_secs)${NC}"
        echo -e "    Min:           $(format_duration $min_duration_secs) (Cycle $min_cycle)"
        echo -e "    Max:           $(format_duration $max_duration_secs) (Cycle $max_cycle)"
        echo -e "    Std Dev:       ~$(format_duration $stddev)"
        echo -e "    Total Time:    $(format_duration $total_duration_secs)"
        
        if [[ $total_vms -gt 0 ]]; then
            local vms_per_cycle=$((total_vms / cycle_count))
            echo ""
            echo "  VM Statistics:"
            echo "  ----------------------------------------"
            echo "    Total VMs migrated:  $total_vms"
            echo "    VMs per cycle:       $vms_per_cycle"
        fi
    fi
    
    echo ""
}

#######################################
# Web Report Generation
#######################################

# Extract pipeline step breakdown from Migration JSON
# Returns: mig_type|vm_count|init|diskalloc_or_preflight|imgconv|transfer|cutover|vmcreate|consolidation (9 values)
# mig_type is "warm" or "cold", vm_count is number of VMs, rest are avg durations in seconds
extract_pipeline_breakdown() {
    local migration_json_file="$1"
    
    if [[ ! -f "$migration_json_file" ]]; then
        echo "cold|0|0|0|0|0|0|0|0"
        return 1
    fi
    
    local result=$(jq -r '
    .status.vms as $vms |
    ($vms | length) as $vm_count |
    # Detect warm migration: if Cutover step exists with duration > 0, its warm
    ([$vms[].pipeline[]? | select(.name == "Cutover") | select(.started != null and .completed != null)] | length > 0) as $is_warm |
    (if $is_warm then "warm" else "cold" end) as $mig_type |
    if $vm_count == 0 then
        "cold|0|0|0|0|0|0|0|0"
    else
        def calc_avg(step_name):
            [$vms[].pipeline[]? | select(.name == step_name) |
                select(.started != null and .completed != null) |
                (((.completed | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // 0) -
                 ((.started | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // 0))
            ] |
            if length == 0 then 0
            else (add / length | floor)
            end;
        
        # DiskAlloc (cold) or PreflightInspection (warm)
        (if calc_avg("DiskAllocation") > 0 then calc_avg("DiskAllocation") else calc_avg("PreflightInspection") end) as $col2 |
        # DiskTransferV2v (cold) or DiskTransfer (warm)
        (if calc_avg("DiskTransferV2v") > 0 then calc_avg("DiskTransferV2v") else calc_avg("DiskTransfer") end) as $col4 |
        
        "\($mig_type)|\($vm_count)|\(calc_avg("Initialize"))|\($col2)|\(calc_avg("ImageConversion"))|\($col4)|\(calc_avg("Cutover"))|\(calc_avg("VirtualMachineCreation"))|\(calc_avg("WaitForFinalSnapshotConsolidation"))"
    end
    ' "$migration_json_file" 2>/dev/null)
    
    echo "${result:-cold|0|0|0|0|0|0|0|0}"
}

# Format seconds to mm:ss or h:mm:ss
format_duration_short() {
    local secs="$1"
    secs=${secs:-0}
    if [[ "$secs" -eq 0 ]]; then
        echo "N/A"
    elif [[ "$secs" -ge 3600 ]]; then
        printf '%d:%02d:%02d' $((secs/3600)) $((secs%3600/60)) $((secs%60))
    else
        printf '%d:%02d' $((secs/60)) $((secs%60))
    fi
}

# Strip ANSI color codes from output
strip_colors() {
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\\033\[[0-9;]*m//g'
}

# Convert text to simple HTML
text_to_html() {
    local title="$1"
    local content
    content=$(cat)
    
    cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
    <title>${title}</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        h1 { color: #333; border-bottom: 2px solid #007acc; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        pre {
            background-color: #ffffff;
            color: #333333;
            padding: 15px;
            border-radius: 5px;
            overflow-x: auto;
            font-size: 13px;
            border: 1px solid #ddd;
            line-height: 1.4;
        }
        .pass { color: #4caf50; font-weight: bold; }
        .fail { color: #f44336; font-weight: bold; }
        .warn { color: #ff9800; font-weight: bold; }
        .info { color: #2196f3; }
        code { background-color: #e0e0e0; padding: 2px 6px; border-radius: 3px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 10px; text-align: left; }
        th { background-color: #007acc; color: white; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        a { color: #007acc; }
        .meta { color: #666; font-size: 14px; margin-bottom: 20px; }
        .back-btn {
            display: inline-block;
            padding: 10px 20px;
            background-color: #e94560;
            color: white !important;
            text-decoration: none;
            border-radius: 5px;
            margin-bottom: 20px;
            font-weight: bold;
        }
        .back-btn:hover { background-color: #d63050; text-decoration: none; }
    </style>
</head>
<body>
<a href="../index.html?t=$(date +%s)" class="back-btn">← Back to Test Cycles</a>
<h1>${title}</h1>
<pre>
${content}
</pre>
</body>
</html>
EOF
}

# Generate web reports for all cycles in a version folder
generate_web_reports() {
    local source_folder="$1"
    local output_base="$2"
    
    # Get version name from source folder (e.g., 2.10.3 or 2-11-0-33)
    local version_name=$(basename "$source_folder")
    local output_folder="${output_base}/${version_name}"
    
    echo "============================================================"
    echo " Web Report Generator"
    echo "============================================================"
    echo ""
    echo "Source folder: $source_folder"
    echo "Output folder: $output_folder"
    if [[ "$WEB_ONLINE_MODE" == "true" ]]; then
        echo "Mode: Online (will fetch importer logs from cluster if migration exists)"
    else
        echo "Mode: Offline (from saved logs only)"
    fi
    echo ""
    
    # Get list of existing reports from remote server for THIS VERSION (one SSH call per version)
    local REMOTE_EXISTING_REPORTS=""
    if [[ "$REMOTE_WEB_ENABLED" == "true" ]]; then
        echo "Checking remote server for existing reports in ${version_name}..."
        REMOTE_EXISTING_REPORTS=$(ssh -o ConnectTimeout=10 "${REMOTE_WEB_USER}@${REMOTE_WEB_SERVER}" \
            "find ${REMOTE_WEB_PATH}/${version_name} -name 'health_report.html' 2>/dev/null" 2>/dev/null || echo "")
        local report_count=$(echo "$REMOTE_EXISTING_REPORTS" | grep -c "health_report.html" || echo "0")
        echo "Found $report_count existing reports on remote for ${version_name}"
        echo ""
    fi
    
    # Create output folder
    mkdir -p "$output_folder"
    
    # Find all test folders (direct subdirectories)
    local test_folders=$(find "$source_folder" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    
    if [[ -z "$test_folders" ]]; then
        echo "[ERROR] No test folders found in $source_folder"
        return 1
    fi
    
    local total_tests=$(echo "$test_folders" | wc -l)
    local test_num=0
    local total_cycles=0
    local success=0
    local failed=0
    
    # Array to store test info for index
    declare -a test_info_array
    
    echo "Found $total_tests test folder(s) to process"
    echo ""
    
    # Process each test folder
    while IFS= read -r test_path; do
        [[ -z "$test_path" ]] && continue
        
        local test_name=$(basename "$test_path")
        ((test_num++))
        
        echo "[$test_num/$total_tests] Test: $test_name"
        
        # Create test output folder
        local test_output="${output_folder}/${test_name}"
        mkdir -p "$test_output"
        
        # Find all cycles - check both logs subfolder and direct test_path
        local logs_folder="${test_path}/logs"
        local all_cycles=""
        
        # First check logs/ subfolder (preferred location for data)
        if [[ -d "$logs_folder" ]]; then
            all_cycles=$(find "$logs_folder" -mindepth 1 -maxdepth 1 -type d -name "*_[0-9]*-[0-9]*" 2>/dev/null)
        fi
        
        # Also check for cycle folders directly in test_path (older format)
        local direct_cycles=$(find "$test_path" -mindepth 1 -maxdepth 1 -type d -name "*_[0-9]*-[0-9]*" 2>/dev/null)
        if [[ -n "$direct_cycles" ]]; then
            if [[ -n "$all_cycles" ]]; then
                all_cycles=$(echo -e "${all_cycles}\n${direct_cycles}")
            else
                all_cycles="$direct_cycles"
            fi
        fi
        
        # Deduplicate by cycle name (basename), keeping logs/ path if both exist
        # Sort by basename, then pick first occurrence (logs/ comes before direct due to path)
        local cycles=$(echo "$all_cycles" | awk -F/ '{name=$NF; if(!seen[name]++) print}' | sort)
        
        if [[ -z "$cycles" ]]; then
            echo "  [SKIP] No cycles found"
            ((failed++))
            continue
        fi
        
        local cycle_count=$(echo "$cycles" | wc -l)
        local cycle_num=0
        local cycle_success=0
        
        # Array to store cycle info for this test - clear it first
        cycle_info=()
        
        # Process each cycle
        while IFS= read -r cycle_path; do
            [[ -z "$cycle_path" ]] && continue
            
            local cycle_name=$(basename "$cycle_path")
            ((cycle_num++))
            ((total_cycles++))
            
            echo "  [$cycle_num/$cycle_count] Cycle: $cycle_name"
            
            # Offline mode - use saved logs from the specific cycle folder
            OFFLINE_MODE=true
            LOGS_FOLDER="$cycle_path"
            MIGRATION_JSON_FILE=""
            
            # Find migration JSON in this specific cycle (check both Migration_*.json and Plan_*.json)
            local migration_file=$(find "$cycle_path" -maxdepth 1 -name "Migration_*.json" -type f 2>/dev/null | head -1)
            
            # Fallback to Plan_*.json (older format used in 2.9.x)
            if [[ -z "$migration_file" ]]; then
                migration_file=$(find "$cycle_path" -maxdepth 1 -name "Plan_*.json" -type f 2>/dev/null | head -1)
            fi
            
            if [[ -z "$migration_file" ]]; then
                echo "    [SKIP] No migration data found"
                ((failed++))
                continue
            fi
            
            # Create cycle output folder (only after confirming data exists)
            local cycle_output="${test_output}/${cycle_name}"
            
            # Check if report already exists on REMOTE server (using cached list)
            local report_exists=false
            if [[ "$REMOTE_WEB_ENABLED" == "true" && -n "$REMOTE_EXISTING_REPORTS" ]]; then
                local remote_report_path="${REMOTE_WEB_PATH}/${version_name}/${test_name}/${cycle_name}/health_report.html"
                if echo "$REMOTE_EXISTING_REPORTS" | grep -q "${version_name}/${test_name}/${cycle_name}/health_report.html"; then
                    report_exists=true
                fi
            elif [[ -f "${cycle_output}/health_report.html" ]]; then
                report_exists=true
            fi
            
            # Always create cycle folder (needed for index generation)
            mkdir -p "$cycle_output"
            
            # Skip generation if report already exists on remote (unless --force)
            if [[ "$report_exists" == "true" && "$FORCE_REGENERATE" != "true" ]]; then
                echo "    [SKIP] Report exists on remote, fetching..."
                # Fetch the report from remote to local so rsync preserves it
                scp -q "${REMOTE_WEB_USER}@${REMOTE_WEB_SERVER}:${REMOTE_WEB_PATH}/results-data/${version_name}/${test_name}/${cycle_name}/health_report.html" \
                    "${cycle_output}/health_report.html" 2>/dev/null
                
                # Always copy .combine_report.json if it exists locally (for transfer rate data)
                # This ensures transfer rate is available even for previously generated reports
                local combine_report="${cycle_path}/.combine_report.json"
                if [[ -f "$combine_report" ]]; then
                    cp "$combine_report" "${cycle_output}/.combine_report.json"
                fi
                
                ((success++))
                ((cycle_success++))
                
                # Get status/duration for index
                local mig_json=$(cat "$migration_file" 2>/dev/null)
                local status="Unknown"
                local duration="N/A"
                if [[ -n "$mig_json" ]]; then
                    local succeeded=$(echo "$mig_json" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null | head -1)
                    local failed_status=$(echo "$mig_json" | jq -r '.status.conditions[]? | select(.type=="Failed") | .status' 2>/dev/null | head -1)
                    if [[ "$succeeded" == "True" ]]; then
                        status="Succeeded"
                    elif [[ "$failed_status" == "True" ]]; then
                        status="Failed"
                    fi
                    local started=$(echo "$mig_json" | jq -r '.status.started // empty' 2>/dev/null)
                    local completed=$(echo "$mig_json" | jq -r '.status.completed // empty' 2>/dev/null)
                    if [[ -n "$started" && -n "$completed" ]]; then
                        local start_epoch=$(date -d "$started" +%s 2>/dev/null)
                        local end_epoch=$(date -d "$completed" +%s 2>/dev/null)
                        if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
                            local dur_secs=$((end_epoch - start_epoch))
                            duration=$(printf '%02d:%02d:%02d' $((dur_secs/3600)) $((dur_secs%3600/60)) $((dur_secs%60)))
                        fi
                    fi
                fi
                local breakdown=$(extract_pipeline_breakdown "$migration_file")
                cycle_info+=("${cycle_name}|${status}|${duration}|${breakdown}")
                continue
            fi
            
            MIGRATION_JSON_FILE="$migration_file"
            
            # Get status and duration from migration JSON
            local mig_json=$(cat "$migration_file" 2>/dev/null)
            local status="Unknown"
            local duration="N/A"
            
            if [[ -n "$mig_json" ]]; then
                local succeeded=$(echo "$mig_json" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null | head -1)
                local failed_status=$(echo "$mig_json" | jq -r '.status.conditions[]? | select(.type=="Failed") | .status' 2>/dev/null | head -1)
                
                if [[ "$succeeded" == "True" ]]; then
                    status="Succeeded"
                elif [[ "$failed_status" == "True" ]]; then
                    status="Failed"
                else
                    status="Unknown"
                fi
                
                # Calculate duration
                local started=$(echo "$mig_json" | jq -r '.status.started // empty' 2>/dev/null)
                local completed=$(echo "$mig_json" | jq -r '.status.completed // empty' 2>/dev/null)
                if [[ -n "$started" && -n "$completed" ]]; then
                    local start_epoch=$(date -d "$started" +%s 2>/dev/null)
                    local end_epoch=$(date -d "$completed" +%s 2>/dev/null)
                    if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
                        local dur_secs=$((end_epoch - start_epoch))
                        duration=$(printf '%02d:%02d:%02d' $((dur_secs/3600)) $((dur_secs%3600/60)) $((dur_secs%60)))
                    fi
                fi
            fi
            
            # Generate full report only
            echo "    Generating report..."
            local report_file="${cycle_output}/health_report.html"
            {
                generate_report "$test_name" "$DEFAULT_NAMESPACE" 2>&1 | strip_colors
            } | text_to_html "Health Report: ${cycle_name}" > "$report_file"
            
            # Copy .combine_report.json if it exists (for transfer rate data)
            local combine_report="${cycle_path}/.combine_report.json"
            if [[ -f "$combine_report" ]]; then
                cp "$combine_report" "${cycle_output}/.combine_report.json"
            fi
            
            echo "    [OK] Report saved: $cycle_output"
            ((success++))
            ((cycle_success++))
            
            # Store cycle info with pipeline breakdown
            local breakdown=$(extract_pipeline_breakdown "$migration_file")
            cycle_info+=("${cycle_name}|${status}|${duration}|${breakdown}")
            
        done <<< "$cycles"
        
        # Generate test index with all cycles
        if [[ $cycle_success -gt 0 ]]; then
            generate_test_index "$test_output" "$test_name" "${cycle_info[@]}"
        fi
        
        # Store test info for main index
        test_info_array+=("${test_name}|${cycle_count}")
        
        echo ""
        
    done <<< "$test_folders"
    
    echo ""
    echo "============================================================"
    echo " Summary"
    echo "============================================================"
    echo "Total tests:     $total_tests"
    echo "Total cycles:    $total_cycles"
    echo "Successful:      $success"
    echo "Skipped/Failed:  $failed"
    echo ""
    echo "Output location: $output_folder"
    echo ""
    
    # Generate main index file (HTML)
    generate_version_index "$output_folder" "$version_name" "$source_folder"
    
    echo "Index file created: ${output_folder}/index.html"
    
    return 0
}

# Generate index page for a single test with all its cycles
# cycle_info format: "cycle_name|status|duration|init_sec|diskalloc_sec|imgconv_sec|transfer_sec|vmcreate_sec"
generate_test_index() {
    local test_output="$1"
    local test_name="$2"
    shift 2
    local cycle_info=("$@")
    
    local index_file="${test_output}/index.html"
    
    # Pre-scan cycles to detect migration type and max VM count
    local first_mig_type=$(echo "${cycle_info[0]}" | cut -d'|' -f4)
    local max_vm_count=0
    for info in "${cycle_info[@]}"; do
        local vc=$(echo "$info" | cut -d'|' -f5)
        [[ ${vc:-0} -gt $max_vm_count ]] && max_vm_count=${vc:-0}
    done
    
    # Set column headers based on migration type and VM count
    local diskalloc_header="DiskAlloc"
    [[ "$first_mig_type" == "warm" ]] && diskalloc_header="Preflight"
    
    # Add "(Avg)" suffix if multiple VMs
    local avg_suffix=""
    [[ $max_vm_count -gt 1 ]] && avg_suffix=" (Avg)"
    
    cat > "$index_file" <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
    <title>${test_name} - All Cycles</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            max-width: 1800px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        h1 { color: #333; border-bottom: 2px solid #007acc; padding-bottom: 10px; }
        .header-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
        .back-link a {
            display: inline-block;
            padding: 10px 20px;
            background-color: #dc3545;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            font-weight: bold;
        }
        .back-link a:hover { background-color: #c82333; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #007acc; color: white; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #e8f4fc; }
        a { color: #007acc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .status-pass { color: #28a745; font-weight: bold; }
        .status-fail { color: #dc3545; font-weight: bold; }
        .btn { 
            display: inline-block;
            padding: 5px 15px;
            background-color: #007acc;
            color: white !important;
            border-radius: 3px;
            margin: 2px;
        }
        .btn:hover { background-color: #005a9e; text-decoration: none; }
        .btn-report { background-color: #28a745; }
        .btn-report:hover { background-color: #1e7e34; }
.btn-toggle { background-color: #fd7e14; color: white; cursor: pointer; border: none; border-radius: 20px; padding: 8px 18px; font-size: 14px; }
            .btn-toggle:hover { background-color: #e96b02; }
        .meta { color: #666; font-size: 14px; }
        .breakdown-col { display: none; text-align: center; }
        .breakdown-col.show { display: table-cell; text-align: center; }
        .breakdown-header { display: none; }
        .breakdown-header.show { display: table-cell; }
        .degraded { color: #dc3545; font-weight: bold; }
        .improved { color: #28a745; font-weight: bold; }
        td { white-space: nowrap; }
        .cold-hide { display: none !important; }
    </style>
</head>
<body>
<p class="back-link"><a href="../index.html?t=$(date +%s)">&larr; Back to Version Index</a></p>
<h1>${test_name}</h1>
<div class="header-row">
    <p class="meta"><strong>Total Cycles:</strong> ${#cycle_info[@]}</p>
    <button class="btn btn-toggle" onclick="toggleBreakdown()">📊 Show Pipeline Breakdown</button>
</div>

<table>
    <tr>
        <th>#</th>
        <th>Cycle</th>
        <th>Date</th>
        <th>Status</th>
        <th>Duration</th>
        <th class="breakdown-header">VMs</th>
        <th class="breakdown-header">Init${avg_suffix}</th>
        <th class="breakdown-header">${diskalloc_header}${avg_suffix}</th>
        <th class="breakdown-header">ImgConv${avg_suffix}</th>
        <th class="breakdown-header">DiskTransfer${avg_suffix}</th>
        <th class="breakdown-header cutover-col">Cutover${avg_suffix}</th>
        <th class="breakdown-header">VMCreate${avg_suffix}</th>
        <th class="breakdown-header consol-col">Consol${avg_suffix}</th>
        <th>Report</th>
    </tr>
EOF
    
    local prev_init=0 prev_diskalloc=0 prev_imgconv=0 prev_transfer=0 prev_cutover=0 prev_vmcreate=0 prev_consol=0
    local has_warm_migration=false
    local max_vm_count=0
    local num=0
    for info in "${cycle_info[@]}"; do
        ((num++))
        local cycle_name=$(echo "$info" | cut -d'|' -f1)
        local status=$(echo "$info" | cut -d'|' -f2)
        local duration=$(echo "$info" | cut -d'|' -f3)
        local mig_type=$(echo "$info" | cut -d'|' -f4)
        local vm_count=$(echo "$info" | cut -d'|' -f5)
        local init_sec=$(echo "$info" | cut -d'|' -f6)
        local diskalloc_sec=$(echo "$info" | cut -d'|' -f7)
        local imgconv_sec=$(echo "$info" | cut -d'|' -f8)
        local transfer_sec=$(echo "$info" | cut -d'|' -f9)
        local cutover_sec=$(echo "$info" | cut -d'|' -f10)
        local vmcreate_sec=$(echo "$info" | cut -d'|' -f11)
        local consol_sec=$(echo "$info" | cut -d'|' -f12)
        
        mig_type=${mig_type:-cold}
        vm_count=${vm_count:-0}
        init_sec=${init_sec:-0}
        diskalloc_sec=${diskalloc_sec:-0}
        imgconv_sec=${imgconv_sec:-0}
        transfer_sec=${transfer_sec:-0}
        cutover_sec=${cutover_sec:-0}
        vmcreate_sec=${vmcreate_sec:-0}
        consol_sec=${consol_sec:-0}
        
        # Track if any cycle is warm (to show warm-only columns)
        [[ "$mig_type" == "warm" ]] && has_warm_migration=true
        # Track max VM count for "(Avg)" indicator
        [[ $vm_count -gt $max_vm_count ]] && max_vm_count=$vm_count
        
        local cycle_date="N/A"
        local timestamp=$(echo "$cycle_name" | grep -oE '[0-9]{8}-[0-9]{6}$')
        if [[ -n "$timestamp" ]]; then
            local year=${timestamp:0:4}
            local month=${timestamp:4:2}
            local day=${timestamp:6:2}
            local hour=${timestamp:9:2}
            local min=${timestamp:11:2}
            cycle_date="${day}-${month}-${year} ${hour}:${min}"
        fi
        
        local status_class="status-pass"
        [[ "$status" == "Failed" ]] && status_class="status-fail"
        
        local init_fmt=$(format_duration_short "$init_sec")
        local diskalloc_fmt=$(format_duration_short "$diskalloc_sec")
        local imgconv_fmt=$(format_duration_short "$imgconv_sec")
        local transfer_fmt=$(format_duration_short "$transfer_sec")
        local cutover_fmt=$(format_duration_short "$cutover_sec")
        local vmcreate_fmt=$(format_duration_short "$vmcreate_sec")
        local consol_fmt=$(format_duration_short "$consol_sec")
        
        local init_class="" diskalloc_class="" imgconv_class="" transfer_class="" cutover_class="" vmcreate_class="" consol_class=""
        local init_arrow="" diskalloc_arrow="" imgconv_arrow="" transfer_arrow="" cutover_arrow="" vmcreate_arrow="" consol_arrow=""
        if [[ $num -gt 1 ]]; then
            if [[ $init_sec -gt $((prev_init + 10)) ]]; then init_class="degraded"; init_arrow=" ↑"; fi
            if [[ $init_sec -lt $((prev_init - 10)) ]]; then init_class="improved"; init_arrow=" ↓"; fi
            if [[ $diskalloc_sec -gt $((prev_diskalloc + 10)) ]]; then diskalloc_class="degraded"; diskalloc_arrow=" ↑"; fi
            if [[ $diskalloc_sec -lt $((prev_diskalloc - 10)) ]]; then diskalloc_class="improved"; diskalloc_arrow=" ↓"; fi
            if [[ $imgconv_sec -gt $((prev_imgconv + 10)) ]]; then imgconv_class="degraded"; imgconv_arrow=" ↑"; fi
            if [[ $imgconv_sec -lt $((prev_imgconv - 10)) ]]; then imgconv_class="improved"; imgconv_arrow=" ↓"; fi
            if [[ $transfer_sec -gt $((prev_transfer + 10)) ]]; then transfer_class="degraded"; transfer_arrow=" ↑"; fi
            if [[ $transfer_sec -lt $((prev_transfer - 10)) ]]; then transfer_class="improved"; transfer_arrow=" ↓"; fi
            if [[ $cutover_sec -gt $((prev_cutover + 10)) ]]; then cutover_class="degraded"; cutover_arrow=" ↑"; fi
            if [[ $cutover_sec -lt $((prev_cutover - 10)) ]]; then cutover_class="improved"; cutover_arrow=" ↓"; fi
            if [[ $vmcreate_sec -gt $((prev_vmcreate + 10)) ]]; then vmcreate_class="degraded"; vmcreate_arrow=" ↑"; fi
            if [[ $vmcreate_sec -lt $((prev_vmcreate - 10)) ]]; then vmcreate_class="improved"; vmcreate_arrow=" ↓"; fi
            if [[ $consol_sec -gt $((prev_consol + 10)) ]]; then consol_class="degraded"; consol_arrow=" ↑"; fi
            if [[ $consol_sec -lt $((prev_consol - 10)) ]]; then consol_class="improved"; consol_arrow=" ↓"; fi
        fi
        
        prev_init=$init_sec
        prev_diskalloc=$diskalloc_sec
        prev_imgconv=$imgconv_sec
        prev_transfer=$transfer_sec
        prev_cutover=$cutover_sec
        prev_vmcreate=$vmcreate_sec
        prev_consol=$consol_sec
        
        cat >> "$index_file" <<EOF
    <tr>
        <td>${num}</td>
        <td>${cycle_name}</td>
        <td>${cycle_date}</td>
        <td class="${status_class}">${status}</td>
        <td>${duration}</td>
        <td class="breakdown-col">${vm_count}</td>
        <td class="breakdown-col ${init_class}">${init_fmt}${init_arrow}</td>
        <td class="breakdown-col ${diskalloc_class}">${diskalloc_fmt}${diskalloc_arrow}</td>
        <td class="breakdown-col ${imgconv_class}">${imgconv_fmt}${imgconv_arrow}</td>
        <td class="breakdown-col ${transfer_class}">${transfer_fmt}${transfer_arrow}</td>
        <td class="breakdown-col cutover-col ${cutover_class}">${cutover_fmt}${cutover_arrow}</td>
        <td class="breakdown-col ${vmcreate_class}">${vmcreate_fmt}${vmcreate_arrow}</td>
        <td class="breakdown-col consol-col ${consol_class}">${consol_fmt}${consol_arrow}</td>
        <td>
            <a href="${cycle_name}/health_report.html?t=$(date +%s)" class="btn btn-report">View Report</a>
        </td>
    </tr>
EOF
    done
    
    # Add style to hide cutover/consol columns for cold migrations (only if no warm migrations)
    local cold_style=""
    [[ "$has_warm_migration" != "true" ]] && cold_style=".cutover-col, .consol-col { display: none !important; }"
    
    # Add note about averages if multiple VMs
    local avg_note=""
    [[ $max_vm_count -gt 1 ]] && avg_note="<p class=\"meta\" style=\"margin-top: 10px;\"><em>* Pipeline breakdown values are averages across all VMs in each cycle</em></p>"
    
    cat >> "$index_file" <<EOF
</table>
${avg_note}
<style>${cold_style}</style>

<script>
function toggleBreakdown() {
    var cols = document.querySelectorAll('.breakdown-col, .breakdown-header');
    var btn = document.querySelector('.btn-toggle');
    var isHidden = !cols[0].classList.contains('show');
    
    for (var i = 0; i < cols.length; i++) {
        if (isHidden) {
            cols[i].classList.add('show');
        } else {
            cols[i].classList.remove('show');
        }
    }
    
    btn.textContent = isHidden ? '📊 Hide Pipeline Breakdown' : '📊 Show Pipeline Breakdown';
}
EOF

    # Add JavaScript to hide Cutover/Consol columns for cold migrations (only if no warm)
    if [[ "$has_warm_migration" != "true" ]]; then
        cat >> "$index_file" <<'EOF'
// Hide Cutover and Consol columns for cold migrations
document.addEventListener('DOMContentLoaded', function() {
    var coldCols = document.querySelectorAll('.cutover-col, .consol-col');
    for (var i = 0; i < coldCols.length; i++) {
        coldCols[i].classList.add('cold-hide');
    }
});
EOF
    fi

    cat >> "$index_file" <<'EOF'
</script>
</body>
</html>
EOF
}

# Generate main version index page
generate_version_index() {
    local output_folder="$1"
    local version_name="$2"
    local source_folder="$3"
    
    local index_file="${output_folder}/index.html"
    
    cat > "$index_file" <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
    <meta http-equiv="Pragma" content="no-cache">
    <meta http-equiv="Expires" content="0">
    <title>MTV Performance Results - ${version_name}</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        h1 { color: #333; border-bottom: 2px solid #007acc; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #007acc; color: white; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #e8f4fc; }
        a { color: #007acc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .meta { color: #666; font-size: 14px; margin-bottom: 20px; }
        .btn { 
            display: inline-block;
            padding: 5px 15px;
            background-color: #007acc;
            color: white !important;
            border-radius: 3px;
            margin: 2px;
        }
        .btn:hover { background-color: #005a9e; text-decoration: none; }
        .back-link { margin-bottom: 20px; }
        .back-link a { 
            display: inline-block;
            padding: 10px 20px;
            background-color: #dc3545;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            font-weight: bold;
        }
        .back-link a:hover { background-color: #c82333; }
    </style>
</head>
<body>
<p class="back-link"><a href="/index.html?t=$(date +%s)">← Back to Main Index</a></p>
<h1>MTV Performance Results - ${version_name}</h1>
<p class="meta"><strong>Generated:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>

<h2>Test Results</h2>
<table>
    <tr>
        <th>Test Name</th>
        <th>Last Run</th>
        <th>Cycles</th>
        <th>Actions</th>
    </tr>
EOF
    
    # Find all test output folders
    for test_dir in $(find "$output_folder" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); do
        local test_name=$(basename "$test_dir")
        
        # Count cycles
        local cycle_count=$(find "$test_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        
        # Get the latest cycle timestamp (format: YYYYMMDD-HHMMSS from folder name)
        local latest_cycle=$(find "$test_dir" -mindepth 1 -maxdepth 1 -type d -name "*_[0-9]*-[0-9]*" 2>/dev/null | sort | tail -1)
        local last_run="N/A"
        if [[ -n "$latest_cycle" ]]; then
            # Extract timestamp from folder name (e.g., test_20260305-093126 -> 20260305-093126)
            local timestamp=$(basename "$latest_cycle" | grep -oE '[0-9]{8}-[0-9]{6}$')
            if [[ -n "$timestamp" ]]; then
                # Format: YYYYMMDD-HHMMSS -> dd-mm-yyyy HH:MM
                local year=${timestamp:0:4}
                local month=${timestamp:4:2}
                local day=${timestamp:6:2}
                local hour=${timestamp:9:2}
                local min=${timestamp:11:2}
                last_run="${day}-${month}-${year} ${hour}:${min}"
            fi
        fi
        
        if [[ $cycle_count -gt 0 ]]; then
            cat >> "$index_file" <<EOF
    <tr>
        <td>${test_name}</td>
        <td>${last_run}</td>
        <td>${cycle_count}</td>
        <td><a href="${test_name}/index.html?t=$(date +%s)" class="btn">View Cycles</a></td>
    </tr>
EOF
        fi
    done
    
    cat >> "$index_file" <<EOF
</table>
<style>${cold_style}</style>
<script>
function sortByTCNumber() {
    var table = document.querySelector("table");
    if (!table) return;
    var tbody = table.querySelector("tbody") || table;
    var allRows = Array.prototype.slice.call(tbody.querySelectorAll("tr"));
    var headerRow = null;
    var dataRows = [];
    allRows.forEach(function(row) {
        if (row.querySelector("th")) { headerRow = row; }
        else { dataRows.push(row); }
    });
    dataRows.sort(function(a, b) {
        var nameA = a.cells[0] ? a.cells[0].textContent.trim() : "";
        var nameB = b.cells[0] ? b.cells[0].textContent.trim() : "";
        var matchA = nameA.match(/tc(\\d+)-(\\d+)/);
        var matchB = nameB.match(/tc(\\d+)-(\\d+)/);
        var numA = matchA ? [parseInt(matchA[1], 10), parseInt(matchA[2], 10)] : [999, 999];
        var numB = matchB ? [parseInt(matchB[1], 10), parseInt(matchB[2], 10)] : [999, 999];
        return numA[0] - numB[0] || numA[1] - numB[1];
    });
    var uniqueTCs = {};
    var totalCycles = 0;
    var verifiedRows = [];
    var nonVerifiedRows = [];
    dataRows.forEach(function(row) {
        var name = row.cells[0] ? row.cells[0].textContent.trim() : "";
        if (name.indexOf("-nv-") !== -1 || name.match(/nv-tc/i)) {
            nonVerifiedRows.push(row);
            return;
        }
        var match = name.match(/tc(\\d+)-(\\d+)/);
        if (match) {
            var tcKey = match[1] + "." + match[2];
            var cyclesCell = row.cells[2];
            var cycles = 1;
            if (cyclesCell) { var c = parseInt(cyclesCell.textContent.trim()); if (!isNaN(c)) cycles = c; }
            if (!uniqueTCs[tcKey]) { uniqueTCs[tcKey] = true; }
            totalCycles += cycles;
        }
        verifiedRows.push(row);
    });
    while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
    if (headerRow) tbody.appendChild(headerRow);
    verifiedRows.concat(nonVerifiedRows).forEach(function(row) {
        tbody.appendChild(row);
    });
    var tcCount = Object.keys(uniqueTCs).length;
    var h2 = document.querySelector("h2");
    if (h2 && tcCount > 0) {
        h2.innerHTML = h2.textContent + ' <span style="background:linear-gradient(135deg,#3b82f6,#2563eb);color:#fff;padding:4px 14px;border-radius:12px;font-size:0.65em;vertical-align:middle;margin-left:10px;">Regression TCs: ' + tcCount + ' | Total Cycles: ' + totalCycles + '</span>';
    }
}
window.addEventListener("DOMContentLoaded", sortByTCNumber);
</script>
</body>
</html>
EOF
}

#######################################
# Main Entry Point
#######################################

usage() {
    local script_name=$(basename "$0")
    echo "Migration Health Validator - Generate health reports for MTV migrations"
    echo ""
    echo "Usage:"
    echo "  $script_name --from-logs=<PATH>                    # From saved logs (interactive cycle selection)"
    echo "  $script_name <plan-name>                           # From live cluster"
    echo "  $script_name monitor <plan-name> [--timeout=SEC]   # Monitor running migration"
    echo "  $script_name generate-web <version-folder>         # Batch generate HTML reports"
    echo "  $script_name generate-web <version-folder> --force  # Regenerate ALL reports (skip nothing)"
    echo ""
    echo "Examples:"
    echo "  $script_name --from-logs=2.10.0/my-plan/logs"
    echo "  $script_name --from-logs=mtv-debug-my-plan-20260213-090623"
    echo "  $script_name --from-logs=/full/path/to/logs --cycle=20260130-100747"
    echo "  $script_name my-plan-name"
    echo "  $script_name generate-web 2-11-0-33"
    echo ""
    echo "Options:"
    echo "  --from-logs=PATH    Path to logs folder or mtv-debug folder"
    echo "  --timeout=SECONDS   Monitor timeout (default: 3600)"
    echo "  --output=PATH       Web report output path"
    echo ""
}

main() {
    local command=""
    local migration_name=""
    local namespace="${DEFAULT_NAMESPACE}"
    local timeout=$DEFAULT_TIMEOUT
    local list_cycles=false
    
    # Check if first argument is a command or an option
    if [[ -n "$1" && ! "$1" =~ ^-- ]]; then
        command="$1"
        shift
    fi
    
    # Parse all remaining arguments
    local positional_args=()
    local skip_next=false
    local args=("$@")
    local i=0
    
    while [[ $i -lt ${#args[@]} ]]; do
        local arg="${args[$i]}"
        case $arg in
            --timeout=*)
                timeout="${arg#*=}"
                ;;
            --timeout)
                # Next arg is the timeout value
                ((i++))
                timeout="${args[$i]}"
                ;;
            --from-logs=*)
                OFFLINE_MODE=true
                LOGS_FOLDER="${arg#*=}"
                ;;
            --from-logs)
                # Next arg is the logs folder path
                OFFLINE_MODE=true
                ((i++))
                LOGS_FOLDER="${args[$i]}"
                ;;
            --list-cycles)
                list_cycles=true
                OFFLINE_MODE=true
                ;;
            --cycle=*)
                SELECTED_CYCLE="${arg#*=}"
                ;;
            --cycle)
                # Next arg is the cycle name
                ((i++))
                SELECTED_CYCLE="${args[$i]}"
                ;;
            --output=*)
                WEB_OUTPUT_PATH="${arg#*=}"
                ;;
            --output)
                # Next arg is the output path
                ((i++))
                WEB_OUTPUT_PATH="${args[$i]}"
                ;;
            --online)
                WEB_ONLINE_MODE=true
                ;;
            --force)
                FORCE_REGENERATE=true
                ;;
            --*)
                # Unknown option, ignore
                ;;
            *)
                positional_args+=("$arg")
                ;;
        esac
        ((i++))
    done
    
    # Assign positional arguments
    if [[ ${#positional_args[@]} -ge 1 ]]; then
        migration_name="${positional_args[0]}"
    fi
    if [[ ${#positional_args[@]} -ge 2 ]]; then
        namespace="${positional_args[1]}"
    fi
    
    # Validate inputs - if no command but --from-logs provided, default to 'report'
    if [[ -z "$command" ]]; then
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            command="report"
        else
            usage
            exit 1
        fi
    fi
    
    # Handle offline mode setup
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        # If logs folder provided, check if it exists (try relative paths too)
        if [[ -n "$LOGS_FOLDER" ]]; then
            if [[ ! -d "$LOGS_FOLDER" ]]; then
                # Try as relative path from DEFAULT_RESULTS_PATH
                if [[ -d "${DEFAULT_RESULTS_PATH}/${LOGS_FOLDER}" ]]; then
                    LOGS_FOLDER="${DEFAULT_RESULTS_PATH}/${LOGS_FOLDER}"
                # Try as mtv-debug folder name in DEFAULT_MTV_DEBUG_PATH
                elif [[ -d "${DEFAULT_MTV_DEBUG_PATH}/${LOGS_FOLDER}" ]]; then
                    LOGS_FOLDER="${DEFAULT_MTV_DEBUG_PATH}/${LOGS_FOLDER}"
                # Try as mtv-debug prefix match
                elif [[ -d "${DEFAULT_MTV_DEBUG_PATH}/mtv-debug-${LOGS_FOLDER}" ]]; then
                    LOGS_FOLDER="${DEFAULT_MTV_DEBUG_PATH}/mtv-debug-${LOGS_FOLDER}"
                else
                    log_error "Logs folder does not exist: $LOGS_FOLDER"
                    log_info "Tried: $LOGS_FOLDER"
                    log_info "Tried: ${DEFAULT_RESULTS_PATH}/${LOGS_FOLDER}"
                    log_info "Tried: ${DEFAULT_MTV_DEBUG_PATH}/${LOGS_FOLDER}"
                    exit 1
                fi
            fi
        fi
        
        # Handle --list-cycles option FIRST (before any other processing)
        if [[ "$list_cycles" == "true" ]]; then
            if [[ -z "$LOGS_FOLDER" ]]; then
                log_error "No logs folder specified. Use --from-logs=<path> with --list-cycles"
                exit 1
            fi
            log_info "Logs folder: $LOGS_FOLDER"
            echo ""
            display_available_cycles "$LOGS_FOLDER"
            exit 0
        fi
        
        # If logs folder provided, extract plan name from folder path if migration_name not given
        if [[ -n "$LOGS_FOLDER" && -z "$migration_name" ]]; then
            # Extract folder name as plan name (e.g., /path/to/2-11-0-33/10vm-cold-tc6-1 -> 10vm-cold-tc6-1)
            migration_name=$(basename "$LOGS_FOLDER")
            log_info "Auto-detected plan name from folder: $migration_name"
        fi
        
        # If no logs folder but migration_name provided, search for it
        if [[ -z "$LOGS_FOLDER" && -n "$migration_name" ]]; then
            LOGS_FOLDER=$(find "$DEFAULT_RESULTS_PATH" -type d -name "*${migration_name}*" 2>/dev/null | head -1)
            if [[ -z "$LOGS_FOLDER" ]]; then
                log_error "Could not find logs folder for '$migration_name' in $DEFAULT_RESULTS_PATH"
                exit 1
            fi
        fi
        
        # Still no logs folder? Error
        if [[ -z "$LOGS_FOLDER" ]]; then
            log_error "No logs folder specified. Use --from-logs=<path> or --from-logs <path>"
            exit 1
        fi
        
        log_info "Offline mode: validating from logs"
        log_info "Logs folder: $LOGS_FOLDER"
        echo ""
        
        # Check if this is an mtv-debug folder (no cycles, direct files)
        if is_mtv_debug_folder "$LOGS_FOLDER"; then
            log_info "Detected mtv-debug folder format"
            # Extract plan name from mtv-debug folder name: mtv-debug-<planname>-<timestamp>
            local folder_name=$(basename "$LOGS_FOLDER")
            if [[ "$folder_name" =~ ^mtv-debug-(.+)-[0-9]{8}-[0-9]{6}(-.*)?$ ]]; then
                migration_name="${BASH_REMATCH[1]}"
                log_info "Auto-detected plan name: $migration_name"
            fi
        else
            # If multiple cycles exist and no cycle specified, display cycle list with interactive selection
            if [[ -z "$SELECTED_CYCLE" ]]; then
                local cycle_count=$(list_test_cycles "$LOGS_FOLDER" | wc -l)
                if [[ $cycle_count -gt 1 ]]; then
                    # Enable interactive mode for terminal sessions
                    if [[ -t 0 ]]; then
                        display_available_cycles "$LOGS_FOLDER" "true"
                    else
                        display_available_cycles "$LOGS_FOLDER" "false"
                    fi
                    echo ""
                fi
            fi
        fi
    fi
    
    # Handle generate-web command separately (before other checks)
    if [[ "$command" == "generate-web" ]]; then
        check_jq
        
        local source_folder="$migration_name"  # First positional arg is the source folder
        
        # Handle relative path
        if [[ -n "$source_folder" && ! -d "$source_folder" ]]; then
            if [[ -d "${DEFAULT_RESULTS_PATH}/${source_folder}" ]]; then
                source_folder="${DEFAULT_RESULTS_PATH}/${source_folder}"
            fi
        fi
        
        if [[ -z "$source_folder" || ! -d "$source_folder" ]]; then
            log_error "Source folder is required and must exist"
            log_info "Usage: $0 generate-web <VERSION_FOLDER> [--output=<PATH>]"
            log_info "Example: $0 generate-web ~/MTV/results/2.10.3"
            log_info "Example: $0 generate-web 2-11-0-33"
            exit 1
        fi
        
        # Use default output path if not specified
        if [[ -z "$WEB_OUTPUT_PATH" ]]; then
            WEB_OUTPUT_PATH="$DEFAULT_WEB_OUTPUT_PATH"
        fi
        
        # Create output base folder if needed
        mkdir -p "$WEB_OUTPUT_PATH"
        
        generate_web_reports "$source_folder" "$WEB_OUTPUT_PATH"
        local gen_result=$?
        
        # Sync to remote web server if enabled
        if [[ "$REMOTE_WEB_ENABLED" == "true" && $gen_result -eq 0 ]]; then
            local version_name=$(basename "$source_folder")
            echo ""
            echo "============================================================"
            echo " Syncing to Remote Web Server"
            echo "============================================================"
            echo "Server: ${REMOTE_WEB_USER}@${REMOTE_WEB_SERVER}"
            echo "Path: ${REMOTE_WEB_PATH}/${version_name}/"
            echo ""
            rsync -avz "${WEB_OUTPUT_PATH}/${version_name}/" "${REMOTE_WEB_USER}@${REMOTE_WEB_SERVER}:${REMOTE_WEB_PATH}/${version_name}/"
            if [[ $? -eq 0 ]]; then
                echo ""
                echo "[SUCCESS] Synced to remote web server"
                
                # Clean up temp folder after successful sync
                if [[ "$REMOTE_WEB_CLEANUP" == "true" && "$WEB_OUTPUT_PATH" == /tmp/* ]]; then
                    echo ""
                    echo "Cleaning up temp folder: ${WEB_OUTPUT_PATH}/${version_name}/"
                    rm -rf "${WEB_OUTPUT_PATH}/${version_name}/"
                fi
            else
                echo ""
                echo "[WARNING] Failed to sync to remote web server"
            fi
        fi
        
        exit $gen_result
    fi
    
    # For non-offline mode, migration_name is required
    if [[ "$OFFLINE_MODE" != "true" && -z "$migration_name" && "$command" != "help" && "$command" != "-h" && "$command" != "--help" ]]; then
        log_error "Migration name is required"
        usage
        exit 1
    fi
    
    # Check prerequisites
    if [[ "$OFFLINE_MODE" != "true" && "$command" != "generate-web" ]]; then
        check_oc_connection
    fi
    check_jq
    
    case "$command" in
        monitor)
            if [[ "$OFFLINE_MODE" == "true" ]]; then
                log_error "Monitor command is not supported in offline mode"
                log_info "Use 'report' for offline validation"
                exit 1
            fi
            if ! validate_migration_exists "$migration_name" "$namespace"; then
                exit 1
            fi
            migration_name="$RESOLVED_MIGRATION_NAME"
            monitor_migration "$migration_name" "$namespace" "$timeout"
            exit $?
            ;;
            
        report|*)
            # 'report' is the default command - handle both explicit 'report' and any other input
            # If command is not 'report', 'monitor', 'generate-web', or 'help', treat it as migration name
            if [[ "$command" != "report" && "$command" != "help" && "$command" != "-h" && "$command" != "--help" && "$command" != "generate-web" && "$command" != "monitor" ]]; then
                # Command might be a migration name, shift it to migration_name
                if [[ -z "$migration_name" && -n "$command" && ! "$command" =~ ^-- ]]; then
                    migration_name="$command"
                fi
            fi
            
            if ! validate_migration_exists "$migration_name" "$namespace"; then
                exit 1
            fi
            migration_name="$RESOLVED_MIGRATION_NAME"
            generate_report "$migration_name" "$namespace"
            exit $?
            ;;
            
        help|-h|--help)
            usage
            exit 0
            ;;
    esac
}

main "$@"
