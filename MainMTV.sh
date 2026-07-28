#!/bin/bash

# Verify required environment variables are present (injected by bws run or source .env)
required_vars=(vsphere_pw VCENTER_HOSTNAME scale_lab_pw)
missing=()
for var in "${required_vars[@]}"; do
    [[ -z "${!var}" ]] && missing+=("$var")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Required environment variables not set: ${missing[*]}"
    echo "Current user: $USER"
    echo ""
    echo "Run with bws (recommended):"
    echo "  ./run-with-secrets.sh ./MainMTV.sh"
    echo ""
    echo "Or: bws run -- ./MainMTV.sh"
    exit 1
fi

set -x

source "$(pwd)/lib/common.sh"

main() {
    check_cycles_list_file
    check_root
    check_root_directory

    # Get Scenarios from cycles_list.txt located /home/$USER/MTV
    parse_cycle_list_file
    total_cycles=${#scenario_names[@]}
    i=0  # Initialize the loop variable , for scenario_name value 
    for i in "${!scenario_names[@]}"; do
        scenario_name="${scenario_names[$i]}"
        cycle_label="${cycle_labels[$i]}"
        cycle_value="${cycle_values[$i]}"

        # Set up logging - output to both screen and file, will write to the current directory
        export MAIN_LOG_FILE="${scenario_name}_STDOUT.log"

        {
          login_cluster  &> /dev/null
          # Load Vars from yaml related to this scenario
          load_scenario ${scenario_name} config/tests.yaml

          echo ""
          echo "using Scenario name: ${scenario_name} ,testcase: ${testcase} ,case: ${mtv_case} using ${VMsPrefix} ,total-vms: ${total_vms} against ${provider_url} started at: `time_stemp`"
          echo ""

          if ./SetupProvider.sh; then
            ./RunMigration.sh
          else
            echo "ERROR: SetupProvider.sh failed for scenario: ${scenario_name} - skipping RunMigration.sh" >&2
          fi

        } 2>&1 | tee "$MAIN_LOG_FILE"

        if [ -f /home/$USER/MTV/results/.latest-result.log ]; then
            source /home/$USER/MTV/results/.latest-result.log
            mv "$MAIN_LOG_FILE" "$LogsLocation/" 2>/dev/null
        fi
        ((i++))
    done
}

main
