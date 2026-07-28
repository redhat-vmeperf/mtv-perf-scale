# MTV Repository Usage and Workflow

This README explains how to configure and run migration test scenarios using the MTV framework. 
Each test scenario is defined in `MTV/config/tests.yaml`, select which scenarios to run by editing `~/MTV/cycles_list.txt`. 
Finally, running `bash MainMTV.sh` will execute all listed scenarios in sequence.

---
 **Important:** executing as **kni** user
```
Please switch to the kni user by executing su --login kni
 ```
---

### Quick Start
-----

Code runs from default location of /home/$USER/git/mpqe-scale-scripts/MTV


1) Define migration scenario: /home/$USER/git/mpqe-scale-scripts/MTV/config/tests.yaml
2) Edit cycles_list: /home/$USER/MTV/cycles_list.txt to define which scenario and the order of scenarios executed
3) Execute: bash MainMTV.sh to begin executing scenarios listed in /home/$USER/MTV/cycles_list.txt

-----
### Results

Results are written: to /home/$USER/MTV/results/

Inside /home/$USER/MTV/results/ runs are organized by scenario name.

```bash

[kni@f01-h07-000-r640 MTV]$ ls  /home/$USER/MTV/results
dsl-4-small  dsl-4-small-plan  windows-sanity
```

Per scenaario there are a summary of the runs and logs sub-folder per run executed.
Summary txt report showing times of looped iterations

```bash
[kni@f01-h07-000-r640 MTV]$ ls  /home/$USER/MTV/results/dsl-4-small
logs  MigrationSummary_dsl-4-small_20250531-231446.txt
```

Per Log folder are the logs from each run itteration


```bash


[kni@f01-h07-000-r640 MTV]$ ls  /home/$USER/MTV/results/dsl-4-small/logs/
dsl-4-small_20250531-233720  dsl-4-small_20250601-000245

[kni@f01-h07-000-r640 MTV]$ ls  /home/$USER/MTV/results/dsl-4-small/logs/dsl-4-small_20250531-233720
MigrationBreakdown_dsl-4-small_20250531-233741.txt  MTV_forklift-ui-plugin-796cb87bd7-l4nzq.log                    Plan_dsl-4-small.json
MTV_forklift-api-6d654d9c94-k67lc.log               MTV_forklift-ui-plugin-796cb87bd7-l4nzq.txt                    report_flow_generation.log
MTV_forklift-api-6d654d9c94-k67lc.txt               MTV_forklift-validation-6568d5bb96-zgs76.log                   sessions_list.json
MTV_forklift-controller-888bc6d75-lqrvm.log         MTV_forklift-validation-6568d5bb96-zgs76.txt                   VirtV2V_dsl-4-small-vm-23090-mqgrd.log
MTV_forklift-controller-888bc6d75-lqrvm.txt         MTV_forklift-volume-populator-controller-7fd9f564f9-cbzcs.log  VirtV2V_dsl-4-small-vm-23090-mqgrd.txt
MTV_forklift-operator-796558779f-tz59d.log          MTV_forklift-volume-populator-controller-7fd9f564f9-cbzcs.txt  VirtV2V_dsl-4-small-vm-23092-jngg4.log
MTV_forklift-operator-796558779f-tz59d.txt          Plan_dsl-4-small                                               VirtV2V_dsl-4-small-vm-23092-jngg4.txt

```


### Report Generation flow 

To do

```bash
# Generate report for a completed migration
./AdvancedParseMigrationCR.sh <MigrationCRname> [SourceMTVns]

# Example
./AdvancedParseMigrationCR.sh 10vms-1disk-50gb-35usage-cold-tc2-7
```

The script will:
1. Collect all MTV operator pod logs
2. Collect VirtV2V conversion pod logs  
3. Export Plan and Migration CRs as JSON
4. Generate a detailed per-VM timing breakdown
5. Calculate min/max/avg statistics for each migration phase

Reports are saved to `/home/$USER/MTV/results/<MigrationCRname>/logs/`

### Currently Not Supported - Gotchas

To do


## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Directory Layout](#directory-layout)
3. [Configuration Files](#configuration-files)

   1. [`config/tests.yaml` (Scenario Definitions)](#configtestsyaml-scenario-definitions)
   2. [`~/MTV/cycles_list.txt` (Which Scenarios to Run)](#mtvcycles_listtxt-which-scenarios-to-run)
4. [Key Scripts and Their Roles](#key-scripts-and-their-roles)

   1. [`lib/common.sh`](#libcommonsh)
   2. [`MainMTV.sh`](#mainmtvsh)
   3. [`SetupProvider.sh`](#setupprovidersh)
   4. [`RunMigration.sh`](#runmigrationsh)
   5. [Other Utility Scripts](#other-utility-scripts)
5. [Step-By-Step Usage](#step-by-step-usage)

   1. [1. Install Dependencies](#1-install-dependencies)
   2. [2. Define Scenarios in `tests.yaml`](#2-define-scenarios-in-testsyaml)
   3. [3. Populate `~/MTV/cycles_list.txt`](#3-populate-mtvmcycles_listtxt)
   4. [4. Run `MainMTV.sh`](#4-run-mainmtvsh)
6. [Workflow Details](#workflow-details)

   1. [A. How `parse_cycle_list_file` Reads Your List](#a-how-parse_cycle_list_file-reads-your-list)
   2. [B. How `load_scenario` Pulls Variables from `tests.yaml`](#b-how-load_scenario-pulls-variables-from-testsyaml)
   3. [C. What `SetupProvider.sh` Does](#c-what-setupprovidersh-does)
   4. [D. What `RunMigration.sh` Does](#d-what-runmigrationsh-does)
7. [Example `cycles_list.txt`](#example-cycles_listtxt)
8. [Tips & Troubleshooting](#tips--troubleshooting)

---

## Prerequisites

1. **Scale Lab host with kni user** with Bash shell.
2. **`yq`** CLI tool (for parsing YAML) note this is golang version not python found at: https://github.com/mikefarah/yq.
3. **`oc`** (OpenShift Client) installed and on your `$PATH`.
4. A valid **kubeconfig** at:

   ```
   $HOME/clusterconfigs/auth/kubeconfig
   ```

   and the **kubeadmin password** at:

   ```
   $HOME/clusterconfigs/auth/kubeadmin-password
   ```
5. **sudo privileges** (the scripts check for running as root).
6. Access to a **vSphere SDK endpoint** and credentials (URL, username, password) so the migration provider can be created.
7. **`containers.podman` Ansible collection** used by the `GOVC/*.yaml` and `METRICS/CreateImageContainer.yaml` playbooks for the `podman_container`/`podman_image` modules:

   ```bash
   ansible-galaxy collection install containers.podman
   ```

---

## Directory Layout

After extracting the repository, you should see a structure like this:

```
MTV/
├─ .venv/                          ← Python virtual‐env (can be ignored)
├─ ConfigYMLfiles/                 ← (Folder used to write out yamls by SetupProvider)
├─ config/
│   ├─ env.yaml                    ← (general environment variables not currently used.)
│   └─ tests.yaml                  ← Scenario definitions (scenarios: name, cloud settings, etc.)
│
├─ lib/
│   └─ common.sh                   ← Shared functions:
│                                   • check_cycles_list_file
│                                   • parse_cycle_list_file
│                                   • load_scenario
│                                   • time_stamp, check_root, etc.
│
├─ utils/                          ← (miscellaneous helper scripts; reporting logic)
│
├─ MainMTV.sh                      ← Entry point: reads your cycles_list, loops through scenarios
├─ SetupProvider.sh                ← Logs in, creates/patches MigrationProvider, generates VM lists
├─ RunMigration.sh                 ← Runs the actual migration commands (OC and CR-based)
├─ AdvancedParseMigrationCR.sh     ← Advanced reporting: detailed breakdown, logs, statistics
├─ ParseMigrationCR.sh             ← Utility: extracts migration CRs (internal use)
├─ RunMigrationCR.sh               ← Utility: apply a migration CustomResource
├─ SetupProviderCR.sh              ← Utility: apply the provider CustomResource
├─ SetupVMLists.sh                 ← Utility: generates a preliminary list_of_vms.txt
├─ GenerateVMIDsFromMigrationCR.sh ← Utility: collects VM IDs from an existing MigrationCR
```

> **Note**: Some scripts may be abbreviated in listings (e.g., with `…`). In your local copy, those sections are fully implemented.

---

## Configuration Files

### `config/tests.yaml` (Scenario Definitions)

This file contains a top‐level key: `scenarios:`. Under it, each scenario is defined as a YAML block. Example:

```yaml
scenarios:

  - name: 1vm-1disk-50gb-35usage-cold-tc2-0
    testcase: 2.0
    case: NET-FC-C-01V-STD-01
    description: "1VM 1disk 50GB cold (Netapp, FC)"
    VMsPrefix: rhel79-50gb-70usage-vm
    total_vms: 1
    MigrationType: cold
    PlanMigrationName: 1vm-1disk-50gb-35usage-cold-tc2-0
    TargetMigrationNS: 1vm-1disk-50gb-35usage-cold-tc2-0
    SourceMTVns: openshift-mtv
    VDDKURL: ${VDDK_IMAGE_8}
    MaxLoopCycles: 1
    provider:
      url: https://vsphere.example.com/sdk
      name: vsphere-8.0.3-1

  - name: 1vm-ibm-1disk-50gb-35usage-cold-iscsi-tc6-0
    testcase: 6.0
    case: IBM-ISC-C-01V-STD-01
    description: "IBM 1VM cold ISCSI"
    VMsPrefix: ibm-rhel79-50gb-70usage-iscsi-vm
    total_vms: 1
    MigrationType: cold
    PlanMigrationName: 1vm-ibm-1disk-50gb-35usage-cold-iscsi-tc6-0
    TargetMigrationNS: 1vm-ibm-1disk-50gb-35usage-cold-iscsi-tc6-0
    SourceMTVns: openshift-mtv
    VDDKURL: ${VDDK_IMAGE_8}
    MaxLoopCycles: 1
    provider:
      url: https://vsphere.example.com/sdk
      name: vsphere-8.0.3-1

  # … (more scenarios) …
```

#### Logical ID Naming Convention

The `case` field uses an alphanumeric tagging convention for consistent test case identification.

Format: `[STOR]-[PROT]-[TYPE]-[VM_QTY]-[FEAT]-[SEQ]`

| Component | Values | Description |
|-----------|--------|-------------|
| STOR | NET, IBM, ANY | Storage type (NetApp, IBM, Storage Agnostic) |
| PROT | FC, ISC, MIX, ANY | Protocol (Fibre Channel, iSCSI, Mixed, Any) |
| TYPE | C, W | Migration type (Cold, Warm) |
| VM_QTY | 01V, 10V, 50V, etc. | Number of VMs |
| FEAT | STD, LRG, MDK, MOS, OFL, AIO, MPL, SOK | Feature (Standard, Large disk, Multi-disk, Mixed OS, Offload, AIO Buffer, Multi-plan, Soak) |
| SEQ | 01, 02, etc. | Sequence number |

**Example:** `IBM-ISC-C-10V-AIO-01` = IBM storage, iSCSI protocol, Cold migration, 10 VMs, AIO Buffer feature, sequence 01

##### NetApp Test Cases

| TC# | Description | Logical ID |
|-----|-------------|------------|
| 2.0 | 1VM 1disk 50GB cold (FC) | NET-FC-C-01V-STD-01 |
| 2.1 | 1VM 1disk 50GB warm (ISCSI) | NET-ISC-W-01V-STD-01 |
| 2.2 | 1VM 2disk warm (FC) | NET-FC-W-01V-MDK-01 |
| 2.3 | 1VM 3disks warm (FC) | NET-FC-W-01V-MDK-02 |
| 2.4 | 1VM 1TB 820GB usage cold (ISCSI) | NET-ISC-C-01V-LRG-01 |
| 2.5 | 1VM 1TB 820GB usage warm (ISCSI) | NET-ISC-W-01V-LRG-01 |
| 2.6 | mixed 10VMs 5Win+5Rhel cold (FC) | NET-FC-C-10V-MOS-01 |
| 2.7 | 10VMs cold FC 1ESXI | NET-FC-C-10V-STD-02 |
| 2.8 | 80VMs 8ESXI mixed protocols | NET-MIX-C-80V-STD-01 |
| 3.0 | 10VMs AIO cold | NET-ANY-C-10V-AIO-01 |
| 3.3 | 10VMs warm FC | NET-FC-W-10V-STD-01 |
| 3.4 | 136VMs 2disks warm | NET-ISC-W-136V-MDK-01 |
| 3.5 | Soak test 50VMs x 50 loops | NET-FC-C-50V-SOK-01 |
| 4.0 | 1VM 1TB Storage-offload cold (ISCSI) | NET-ISC-C-01V-OFL-01 |
| 4.1 | 1VM 1TB offload warm | NET-ISC-W-01V-OFL-01 |
| 5.0 | 10vms multi-plan | ANY-ANY-W-10V-MPL-01 |
| 5.1 | 50vms warm multi-plan | ANY-ANY-W-50V-MPL-01 |

##### IBM Test Cases

| TC# | Description | Logical ID |
|-----|-------------|------------|
| 6.0 | IBM 1VM cold ISCSI | IBM-ISC-C-01V-STD-01 |
| 6.1 | IBM 1VM cold FC | IBM-FC-C-01V-STD-01 |
| 6.2 | IBM 1VM warm ISCSI | IBM-ISC-W-01V-STD-01 |
| 6.3 | IBM 1VM warm FC | IBM-FC-W-01V-STD-01 |
| 6.4 | IBM 1VM 1TB cold ISCSI | IBM-ISC-C-01V-LRG-01 |
| 6.5 | IBM 1VM 1TB cold FC | IBM-FC-C-01V-LRG-01 |
| 6.6 | IBM 1VM 1TB FIO warm ISCSI | IBM-ISC-W-01V-LRG-02 |
| 6.7 | IBM 1VM 2disk warm ISCSI | IBM-ISC-W-01V-MDK-01 |
| 7.0 | IBM 10VMs mixed (5 RHEL + 5 Win) cold FC | IBM-FC-C-10V-MOS-01 |
| 7.1 | IBM 10VMs cold ISCSI | IBM-ISC-C-10V-STD-01 |
| 7.2 | IBM 10VMs cold FC | IBM-FC-C-10V-STD-01 |
| 7.3 | IBM 10VMs warm FC | IBM-FC-W-10V-STD-01 |
| 7.4 | IBM 50VMs cold FC | IBM-FC-C-50V-STD-01 |
| 7.5 | IBM 50VMs soak cold FC (50 loops) | IBM-FC-C-50V-SOK-01 |
| 7.6 | IBM 80VMs cold ISCSI | IBM-ISC-C-80V-STD-01 |
| 8.0 | IBM 10VMs AIO buffer cold ISCSI | IBM-ISC-C-10V-AIO-01 |
| 9.0 | IBM 1VM 1TB offload cold ISCSI | IBM-ISC-C-01V-OFL-01 |
| 9.1 | IBM 1VM 1TB offload warm ISCSI | IBM-ISC-W-01V-OFL-01 |
| 9.2 | IBM 5VMs 10disks offload cold ISCSI | IBM-ISC-C-05V-OFL-MDK-01 |
| 9.3 | IBM 50VMs 2disk offload cold ISCSI | IBM-ISC-C-50V-OFL-MDK-01 |


* `name` - Unique scenario identifier
* `testcase` - Test case number for tracking (e.g., `2.0`, `6.1`)
* `case` - Alphanumeric logical ID following the naming convention (e.g., `NET-FC-C-01V-STD-01`, `IBM-ISC-C-10V-AIO-01`)
* `description` - Human-readable description of the test case
* `VMsPrefix` - VM name prefix pattern (supports `|` for mixed VMs, e.g., `"rhel79-50gb-70usage-vm|win2019-vm"`)
* `total_vms` - Total number of VMs to migrate
* `MigrationType` - Migration type: `cold` or `warm`
* `PlanMigrationName` - Name of the Migration Plan CR
* `TargetMigrationNS` - Target namespace for migrated VMs
* `SourceMTVns` - MTV operator namespace (typically `openshift-mtv`)
* `VDDKURL` - VDDK container image URL
* `MaxLoopCycles` - Number of times to repeat the scenario
* `provider.url` - vSphere SDK endpoint
* `provider.name` - Provider resource name

#### Optional Parameters

The following **optional** parameters provide additional control over migration behavior:
| Parameter | Type | Description | Example |
|-----------|------|-------------|---------|
| `MixedVMs` | boolean | Enable mixed VM migration (RHEL + Windows) | `true` |
| `NumOfPlans` | integer | Number of parallel migration plans | `10` |
| `NumOfVMsPerPlan` | integer | VMs per migration plan | `1` |
| `MaxVMInflight` | integer | Maximum concurrent VM migrations | `100` |
| `MaxCcReconciles` | integer | Maximum controller reconciles | `100` |
| `HostNetwork` | string | ESXi network interface for data transfer | `vmk` |
| `TotalPreCopies` | integer | Number of precopy iterations (warm only) | `10` |
| `aio_enable` | boolean | Enable AIO (Async I/O) buffer | `true` |
| `StorageOffload` | boolean | Enable storage-assisted offload | `true` |
| `TargetStorageClass` | string | Target storage class | (for offload) `netapp-ontap-perf-iscsi` | Default 'ocs-storagecluster-ceph-rbd'

#### Example with Optional Parameters

```yaml
- name: 10vms-advanced-migration
  testcase: 5.0
  VMsPrefix: "rhel79-50gb-70usage-vm|win2019-vm"
  total_vms: 10
  MixedVMs: true
  NumOfPlans: 10
  NumOfVMsPerPlan: 1
  MaxVMInflight: 100
  MigrationType: warm
  TotalPreCopies: 5
  PlanMigrationName: 10vms-advanced-migration
  TargetMigrationNS: 10vms-advanced-migration
  SourceMTVns: openshift-mtv
  VDDKURL: ${VDDK_IMAGE_8}
  MaxLoopCycles: 1
  provider:
    url: https://vsphere.example.com/sdk
    name: vsphere-8.0.3-1
```

---

### GOVC
govc is a vSphere CLI built on top of govmomi.

The CLI is designed to be a user friendly CLI alternative to the GUI and well suited for automation tasks. It also acts as a test harness for the govmomi APIs and provides working examples of how to use the APIs.

By using GOVC, several operations are performed:
1. Get VM info - network name, datastore name , ESX host name 
2. Delete VM snapshots. For warm migration, delete all snapshots from all participating VMs in the test.
3. Collecting METRICS. During migration, collecting network transmitted rate and disk read rate from all participating ESXs in the test.

---

### Multi plans support
To test parallel migration plans, 2 parameters need to be added to the "tests.yaml" file.
'NumOfPlans' - Number of plans to run in parallel
'NumOfVMsPerPlan' - Number of VMs per plan.

Total migrated VMs are results of 'NumOfPlans' * 'NumOfVMsPerPlan', but no more than the "total_vms" parameter.

---

### `~/MTV/cycles_list.txt` (Which Scenarios to Run)

Before starting any migration, create or edit:

```
/home/$USER/MTV/cycles_list.txt
```

(where `$USER` is `kni`).

* **Every non‐empty line** is one scenario entry.
* **Allowed formats**:

  1. **One word (scenario name only)**

     ```
     dsl-4-small
     windows-3-vms
     ```

     In this case:

     * `cycle_label` and `cycle_value` default to empty strings.
  2. **Three space‐separated columns**:

     ```
     <scenario_name> <cycle_label> <cycle_value>
     ```

     Example:

     ```
     windows-3-vms  nightly  dry-run
     dsl-4-small    integration  value42
     ```

Blank lines or lines starting with `#` are ignored. Any line with fewer than 1 word or more than 3 words will cause an error.

---

## Key Scripts and Their Roles

### `lib/common.sh`

This file contains all shared functions and global variables. It is sourced by `MainMTV.sh`.

#### 1. `check_cycles_list_file`

* Verifies that `/home/$USER/MTV/cycles_list.txt` exists.
* If missing, prints an error and exits.

#### 2. `parse_cycle_list_file`

* Reads each non‐empty line from `~/MTV/cycles_list.txt`.
* Splits the line into “words.”

  * **1 word**:

    ```bash
    scenario_names+=( "${words[0]}" )
    cycle_labels+=( "" )
    cycle_values+=( "" )
    echo "Scenario_name=${words[0]}"
    ```
  * **3 words**:

    ```bash
    scenario_names+=( "${words[0]}" )
    cycle_labels+=( "${words[1]}" )
    cycle_values+=( "${words[2]}" )
    echo "Scenario_name=${words[0]}, cycle_label=${words[1]}, cycle_value=${words[2]}"
    ```
  * **Otherwise**: print an error and exit.

After parsing:

```bash
scenario_names=( "dsl-4-small" "windows-3-vms" … )
cycle_labels=( ""           "nightly"       … )
cycle_values=( ""           "dry-run"       … )
```

`total_cycles=${#scenario_names[@]}`.

#### 3. `load_scenario <scenario_name> <config_yaml>`

* Clears:

  ```bash
  : > /home/$USER/MTV/.current_scenario_vars.txt
  ```
* Uses `yq` to extract all keys from the matching scenario block in `tests.yaml`.

  * For `provider`, iterates subkeys (`url`, `name`, etc.), writing:

    ```bash
    export provider_url="https://vsphere.example.com/sdk"
    export provider_name="vsphere-8.0.3-1"
    ```
  * For other scalar fields, writes:

    ```bash
    export name="1vm-1disk-50gb-35usage-cold-tc2-0"
    export testcase="2.0"
    export mtv_case="NET-FC-C-01V-STD-01"  # Note: 'case' is exported as 'mtv_case' (bash reserved word)
    export description="1VM 1disk 50GB cold (Netapp, FC)"
    export VMsPrefix="rhel79-50gb-70usage-vm"
    export total_vms="1"
    export MigrationType="cold"
    export PlanMigrationName="1vm-1disk-50gb-35usage-cold-tc2-0"
    export TargetMigrationNS="1vm-1disk-50gb-35usage-cold-tc2-0"
    export SourceMTVns="openshift-mtv"
    export VDDKURL="${VDDK_IMAGE_8}"
    export MaxLoopCycles="1"
    ```

  > **Note:** The YAML key `case` is exported as `mtv_case` because `case` is a reserved word in bash.
* The result is `/home/$USER/MTV/.current_scenario_vars.txt` containing only `export …` lines.
* After returning, `MainMTV.sh` does:

  ```bash
  source "/home/$USER/MTV/.current_scenario_vars.txt"
  ```

  so all scenario variables become available.

#### 4. Utility Functions

* `check_root` (ensures script runs as root).
* `check_root_directory` (ensures you’re in the repository root).
* `time_stamp` (prints a date/time string).
* `login_cluster` (sets `KUBECONFIG` and runs `oc login -u kubeadmin -p <password> -n <SourceMTVns>`).

---

### `MainMTV.sh`

```bash
#!/bin/bash
set -x

source "$(pwd)/lib/common.sh"

main() {
    check_cycles_list_file
    check_root
    check_root_directory

    # 1. Parse ~/MTV/cycles_list.txt ⇒ populates arrays
    parse_cycle_list_file
    total_cycles=${#scenario_names[@]}

    # 2. Loop over each scenario
    for i in "${!scenario_names[@]}"; do
        scenario_name="${scenario_names[$i]}"
        cycle_label="${cycle_labels[$i]}"
        cycle_value="${cycle_values[$i]}"

        # (A) Log in to cluster
        login_cluster &> /dev/null

        # (B) Load scenario variables into .current_scenario_vars.txt and source them
        load_scenario "${scenario_name}" config/tests.yaml
        source "/home/$USER/MTV/.current_scenario_vars.txt"

        echo ""
        echo "Using Scenario: ${scenario_name}, Case: ${testcase}, Total VMs: ${total_vms} against provider URL: ${provider_url} (started at: $(time_stamp))"
        echo ""

        # (C) Setup provider (creates/patches MigrationProvider, builds/trims VM list)
        ./SetupProvider.sh

        # (D) Run migration (creates MigrationPlan, triggers migration, waits)
        ./RunMigration.sh

        # (E) Next scenario
    done
}

main
```

**Workflow**:

1. **check\_cycles\_list\_file** → ensure your list exists.
2. **check\_root** → must run as root.
3. **check\_root\_directory** → must execute from repo root.
4. **parse\_cycle\_list\_file** → fills `scenario_names`, `cycle_labels`, `cycle_values`.
5. Loop over each scenario name:

   * **login\_cluster** → authenticate to OpenShift.
   * **load\_scenario** → write scenario variables, then `source` them.
   * **Print diagnostic** (scene name, testcase, total\_vms, provider\_url, timestamp).
   * **`./SetupProvider.sh`** → provision/patch MigrationProvider & build VM list.
   * **`./RunMigration.sh`** → create & run MigrationPlan, wait for completion.

---

### `SetupProvider.sh`

```bash
#!/bin/bash
set -x
source "/home/$USER/MTV/.current_scenario_vars.txt"

ClusterLogin() {
  export KUBECONFIG="$HOME/clusterconfigs/auth/kubeconfig"
  oc login -u kubeadmin -p "$(cat "$HOME/clusterconfigs/auth/kubeadmin-password")" -n "$SourceMTVns"
}

CheckProviderStatus() {
  oc get providers "$provider_name" -n "$SourceMTVns" -o jsonpath="{.status.phase}"
}

# 1. Login to the OpenShift cluster in $SourceMTVns
ClusterLogin

# 2. Create directory for YAMLs, if needed
YMLsFolder="$HOME/mtv-ymls/${scenario_name}"
mkdir -p "$YMLsFolder"

# 3. Create or patch the MigrationProvider CR
oc get provider "$provider_name" -n "$SourceMTVns" &> /dev/null
if [[ $? -ne 0 ]]; then
  # Provider does not exist → create it
  cat <<EOF > "$YMLsFolder/provider-cr.yaml"
apiVersion: migration.openshift.io/v1alpha1
kind: MigrationControllerProvider
metadata:
  name: "${provider_name}"
  namespace: "${SourceMTVns}"
spec:
  url: "${provider_url}"
  # … add username, password, thumbprint if needed …
EOF
  oc apply -f "$YMLsFolder/provider-cr.yaml"
else
  # Provider exists → patch its URL if changed
  oc patch provider "$provider_name" -n "$SourceMTVns" \
    --type=merge -p '{ "spec": { "url": "'"${provider_url}"'" } }'
fi

# 4. Wait for the provider to become “Ready” (timeout 300s)
timeout=300
elapsed=0
while [[ "$(CheckProviderStatus)" != "Ready" && $elapsed -le $timeout ]]; do
  sleep 5
  (( elapsed += 5 ))
done
if [[ "$(CheckProviderStatus)" != "Ready" ]]; then
  echo "Provider '${provider_name}' never became Ready; aborting."
  exit 1
fi

# 5. Generate or trim the VM list (list_of_vms.txt)
#    - We assume a helper (e.g. SetupVMLists.sh) already built a “master” list_of_vms.txt
#    - Each VM is two lines: <VMName>, <VMUID>
#    - Keep only $total_vms VMs → head -n "$(( total_vms * 2 ))"
if [[ -z "$total_vms" || "$total_vms" -le 0 ]]; then
  # If total_vms not set, use entire file
  total_vms=$(( $(wc -l < list_of_vms.txt) / 2 ))
else
  total_vms_lines=$(( total_vms * 2 ))
  head -n "$total_vms_lines" list_of_vms.txt > temp.txt && mv temp.txt list_of_vms.txt
fi

echo "total vms used in this migration are $total_vms"
```

**Summary**:

1. **Source scenario variables** (so `$provider_url`, `$provider_name`, `$total_vms`, `$SourceMTVns` are defined).
2. **ClusterLogin()** → set `KUBECONFIG` and `oc login` in `$SourceMTVns`.
3. **Create or patch MigrationProvider**:

   * If missing, generate a CR YAML under `$HOME/mtv-ymls/$scenario_name/provider-cr.yaml` and `oc apply -f …`.
   * Otherwise, `oc patch` to update `spec.url`.
4. **Wait for Provider status = Ready** (up to 300 seconds).
5. **Build/Trim `list_of_vms.txt`**: each VM occupies two lines (Name, UID). Keep exactly `$total_vms` VMs.

---

### `RunMigration.sh`

```bash
#!/bin/bash
set -x
source "/home/$USER/MTV/.current_scenario_vars.txt"

# 1. Ensure we are logged in again
export KUBECONFIG="$HOME/clusterconfigs/auth/kubeconfig"
oc login -u kubeadmin -p "$(cat "$HOME/clusterconfigs/auth/kubeadmin-password")" -n "$SourceMTVns"

# 2. Create (or patch) a MigrationPlan CR
cat <<EOF > migrationplan-${scenario_name}.yaml
apiVersion: migration.openshift.io/v1alpha1
kind: MigrationPlan
metadata:
  name: ${PlanMigrationName}
  namespace: ${SourceMTVns}
spec:
  sourceNamespace: ${SourceMTVns}
  targetNamespace: ${TargetMigrationNS}
  provider: ${provider_name}
  migplanRef: ${PlanMigrationName}
  vms:
EOF

# Append each VM (2 lines per VM in list_of_vms.txt)
while read -r vmName && read -r vmUID; do
  cat <<EOF >> migrationplan-${scenario_name}.yaml
  - name: $vmName
    uid: $vmUID
EOF
done < list_of_vms.txt

oc apply -f migrationplan-${scenario_name}.yaml

# 3. Wait until MigrationPlan.Status.Phase == “Ready” (timeout 600s)
timeout=600
elapsed=0
while [[ "$(oc get migrationplan "$PlanMigrationName" -n "$SourceMTVns" -o jsonpath="{.status.phase}")" != "Ready" && $elapsed -le $timeout ]]; do
  sleep 10
  (( elapsed += 10 ))
done
if [[ "$(oc get migrationplan "$PlanMigrationName" -n "$SourceMTVns" -o jsonpath="{.status.phase}")" != "Ready" ]]; then
  echo "MigrationPlan '${PlanMigrationName}' never became Ready; aborting."
  exit 1
fi

# 4. Trigger the migration by patching “start: true”
oc patch migrationplan "$PlanMigrationName" -n "$SourceMTVns" --type=merge \
  -p '{"spec":{"start":true}}'

# 5. Wait until MigrationPlan.Status.Phase == “Completed” (timeout 600s)
elapsed=0
while [[ "$(oc get migrationplan "$PlanMigrationName" -n "$SourceMTVns" -o jsonpath="{.status.phase}")" != "Completed" && $elapsed -le $timeout ]]; do
  sleep 15
  (( elapsed += 15 ))
done
if [[ "$(oc get migrationplan "$PlanMigrationName" -n "$SourceMTVns" -o jsonpath="{.status.phase}")" != "Completed" ]]; then
  echo "Migration for Plan '${PlanMigrationName}' did not complete in time; aborting."
  exit 1
fi

# 6. Optionally collect results (e.g., save logs to results/${scenario_name}-migration.log)
echo "MigrationPlan '${PlanMigrationName}' completed successfully for scenario '${scenario_name}'."
```

**Summary**:

1. **Source scenario variables** (so `$PlanMigrationName`, `$TargetMigrationNS`, `$provider_name`, `$SourceMTVns` are defined).
2. **Log in again** to ensure `oc` context.
3. **Build a MigrationPlan YAML**:

   * Under `spec.vms`, read pairs from `list_of_vms.txt` and append `- name: <VMName>  uid: <VMUID>`.
   * Apply it with `oc apply`.
4. **Wait for `.status.phase == "Ready"`** (up to 600 seconds).
5. **Patch `.spec.start: true`** to trigger migration.
6. **Wait for `.status.phase == "Completed"`** (another 600 seconds).
7. **Print success** or exit on timeout/failure.

---

### Other Utility Scripts

* **`AdvancedParseMigrationCR.sh`**
  Advanced migration analysis and reporting tool that generates detailed breakdown reports.

  **Usage:**
  ```bash
  ./AdvancedParseMigrationCR.sh <MigrationCRname> [SourceMTVns]
  ```

  **Parameters:**
  | Parameter | Required | Default | Description |
  |-----------|----------|---------|-------------|
  | `MigrationCRname` | Yes | - | Name of the Migration CR to analyze |
  | `SourceMTVns` | No | `openshift-mtv` | MTV operator namespace |

  **Example:**
  ```bash
  ./AdvancedParseMigrationCR.sh 10vms-1esx-default-network
  ./AdvancedParseMigrationCR.sh 10vms-1esx-default-network openshift-mtv
  ```

  **Capabilities:**
  - Collects all MTV pod logs (forklift-controller, forklift-api, forklift-operator, etc.)
  - Collects VirtV2V conversion pod logs
  - Exports Plan and Migration CRs as JSON
  - Collects ForkliftController and Provider configurations
  - Captures forklift-controller reconcile timings (MTV-2775)
  - Generates per-VM migration breakdown with timing for each pipeline step
  - Calculates min/max/avg statistics for all migration phases
  - Detects MTV version and IIB index

  **Output Location:**
  Results are saved to: `/home/$USER/MTV/results/<MigrationCRname>/logs/<MigrationCRname>_<timestamp>/`

  **Generated Files:**
  - `MigrationBreakdown_<name>_<timestamp>.txt` - Detailed timing breakdown per VM
  - `Plan_<name>.json` / `Migration_<name>.json` - CR exports
  - `ForkliftController_forklift-controller.json` - Controller configuration
  - `Provider_configuration.json` - Provider CR export
  - `ForkliftController_Reconcile.log` - Reconcile timing logs
  - `MTV_<pod>.log` / `MTV_<pod>.txt` - Pod logs and descriptions
  - `VirtV2V_<pod>.log` / `VirtV2V_<pod>.txt` - Conversion pod logs

  **Sample Breakdown Report:**
  ```
  Report Date: 2025-06-01  ,  14:30:45
  MTV Version: 2.9.0-123  ,  IIB: iib:12345
  MigrationStartTime: 2025-06-01 14:00:00  ,  MigrationEndTime: 2025-06-01 14:25:30
  MigrationName: 10vms-migration , Total VMs: 10 , Total Duration: 00:25:30
  TargetNamespace: 10vms-migration , Total VMs: 10
  MigrationType: COLD
  MigrationStatus: Succeeded

  VM                                       MigrationTime Initialize DiskTransfer Convert PostHook Cleanup
  ---------------------------------------- ------------- ---------- ------------ ------- -------- -------
  vm-001                                   00:12:30      00:00:05   00:10:20     00:01:45 00:00:10 00:00:10
  vm-002                                   00:11:45      00:00:04   00:09:50     00:01:31 00:00:10 00:00:10
  ...

  avg                                      00:12:05      00:00:04   00:10:00     00:01:40 00:00:10 00:00:10
  min                                      00:10:30      00:00:03   00:08:45     00:01:20 00:00:08 00:00:08
  max                                      00:14:15      00:00:06   00:12:30     00:02:00 00:00:12 00:00:12
  ```

* **`ParseMigrationCR.sh`**
  Extracts VM IDs from an existing Migration CR. Useful for post-run analysis or re-runs.

* **`RunMigrationCR.sh`**
  Applies a fully prepared Migration CustomResource YAML. Can be used instead of generating the MigrationPlan in `RunMigration.sh`.

* **`SetupProviderCR.sh`**
  Applies a static MigrationProvider YAML, bypassing the dynamic creation logic in `SetupProvider.sh`.

* **`SetupVMLists.sh`**
  Queries vSphere (via API or CLI) for all VMs matching `$VMsPrefix` and writes `list_of_vms.txt` in the format:

  ```
  <VMName1>
  <VMUID1>
  <VMName2>
  <VMUID2>
  …
  ```

* **`GenerateVMIDsFromMigrationCR.sh`**
  Reads an existing Migration CR’s `.spec.vms` and outputs a new `list_of_vms.txt`. Useful if you want to re-use or adjust the VM list from a prior run.

---

## Step-By-Step Usage

### 1. Install Dependencies

1. **`yq`** (e.g., install via Homebrew or download the Linux binary from GitHub).
2. **`oc`** (OpenShift CLI).
3. Ensure you have a valid kubeconfig at:

   ```
   $HOME/clusterconfigs/auth/kubeconfig
   ```

   and the password at:

   ```
   $HOME/clusterconfigs/auth/kubeadmin-password
   ```
4. Manually test login:

   ```bash
   oc login -u kubeadmin -p "$(cat "$HOME/clusterconfigs/auth/kubeadmin-password")"
   ```

---

### 2. Define Scenarios in `tests.yaml`

Open `MTV/config/tests.yaml` and ensure each scenario block has these fields:

```yaml
scenarios:

  - name: example-2-vms
    testcase: 2.1
    VMsPrefix: testvm-*
    total_vms: 2
    MigrationType: warm
    PlanMigrationName: example-plan
    TargetMigrationNS: example-ns
    SourceMTVns: openshift-mtv
    VDDKURL: quay.io/example/vddk
    MaxLoopCycles: 1
    provider:
      url: https://vsphere.mycompany.com/sdk
      name: vsphere-8.0.3-1
      # Optional: username and password can be added here
      username: administrator@vsphere.local
      password: s3cret
```

> **Tip**: If you add extra keys (e.g., `vCenterDatacenter`, `network`), update `load_scenario` in `lib/common.sh` to export those fields.

---

### 3. Populate `/home/$USER/MTV/cycles_list.txt`

Create (or edit) the file:

```
/home/$USER/MTV/cycles_list.txt
```

Each non-empty line is one scenario. Example:

```
# /home/$USER/MTV/cycles_list.txt

dsl-4-small
windows-3-vms  nightly  dry-run
example-2-vms
```

* **First line**: `dsl-4-small` → no extra labels/values.
* **Second line**: `windows-3-vms  nightly  dry-run` → sets `cycle_label="nightly"`, `cycle_value="dry-run"`.
* **Third line**: `example-2-vms` → just the scenario name.

Save and close. Blank lines or lines starting with `#` are ignored.

---

### 4. Run `MainMTV.sh` with kni user

From the repository root (where `MainMTV.sh` lives), run:

```bash
bash MainMTV.sh
```

You should see output similar to:

```
+ check_cycles_list_file
+ check_root
+ check_root_directory
+ parse_cycle_list_file
Scenario_name=dsl-4-small
Scenario_name=windows-3-vms, cycle_label=nightly, cycle_value=dry-run
Scenario_name=example-2-vms
+ total_cycles=3

--- Running scenario “dsl-4-small” (testcase=1.0) ---
Using Scenario: dsl-4-small, Case: 1.0, Total VMs: 4 against provider URL: https://vsphere.example.com/sdk (started at: 2025-06-01--08:15:22)
+ ./SetupProvider.sh
… (provider creation, list_of_vms truncation) …
+ ./RunMigration.sh
… (migration plan apply, wait) …

--- Next: “windows-3-vms” (cycle_label=nightly; cycle_value=dry-run) ---
Using Scenario: windows-3-vms, Case: 1.3, Total VMs: 3 against provider URL: https://vsphere.example.com/sdk (started at: 2025-06-01--08:23:10)
+ ./SetupProvider.sh
… 
+ ./RunMigration.sh
… 

--- Next: “example-2-vms” ---
Using Scenario: example-2-vms, Case: 2.1, Total VMs: 2 against provider URL: https://vsphere.example.com/sdk (started at: 2025-06-01--08:35:45)
+ ./SetupProvider.sh
… 
+ ./RunMigration.sh
… 
```

If any step fails (e.g., provider never Ready, MigrationPlan never Completed), the script will print an error and exit.

---

## Workflow Details

### A. How `parse_cycle_list_file` Reads Your List

1. **Location**: `lib/common.sh` → function `parse_cycle_list_file()`.
2. **Reads**: `/home/$USER/MTV/cycles_list.txt`.
3. **Logic**:

   * Read each non-empty line → split on whitespace → count words.
   * **1 word** → add `scenario_names+=(<that_word>)`, `cycle_labels+=("")`, `cycle_values+=("")`.
   * **3 words** → treat as `<scenario> <label> <value>`.
   * **Otherwise** → print error and exit.
4. **Result**:

   ```
   scenario_names=(…)
   cycle_labels=(…)
   cycle_values=(…)
   ```

   Then `total_cycles=${#scenario_names[@]}`.

---

### B. How `load_scenario` Pulls Variables from `tests.yaml`

1. **Location**: `lib/common.sh` → function `load_scenario()`.
2. **Invocation**: `load_scenario "${scenario_name}" config/tests.yaml`.
3. **Process**:

   * Empty `/home/$USER/MTV/.current_scenario_vars.txt`.
   * Use `yq` to extract all keys under the matching scenario block:

     ```bash
     yq e ".scenarios[] | select(.name == \"${scenario_name}\") | keys | .[]" config/tests.yaml
     ```
   * For each top-level key:

     * If `provider`, iterate subkeys (`url`, `name`, …) and write:

       ```bash
       export provider_url="…"
       export provider_name="…"
       ```
     * Else, write:

       ```bash
       export <KEY>=<value>
       # e.g., export testcase="1.0"
       #       export VMsPrefix="dsl-4g-thick-fc-vm"
       ```
   * Final result: `/home/$USER/MTV/.current_scenario_vars.txt` with `export …` lines only.
4. **After loading**: `MainMTV.sh` does:

   ```bash
   source "/home/$USER/MTV/.current_scenario_vars.txt"
   ```

   making all scenario variables available.

---

### C. What `SetupProvider.sh` Does

1. **Source scenario variables** (so `$provider_url`, `$provider_name`, `$total_vms`, `$SourceMTVns`, etc. are defined).
2. **ClusterLogin()**:

   ```bash
   export KUBECONFIG="$HOME/clusterconfigs/auth/kubeconfig"
   oc login -u kubeadmin -p "$(cat "$HOME/clusterconfigs/auth/kubeadmin-password")" -n "$SourceMTVns"
   ```
3. **Create or patch MigrationProvider CR**:

   * If `oc get provider $provider_name -n $SourceMTVns` fails → create:

     ```yaml
     apiVersion: migration.openshift.io/v1alpha1
     kind: MigrationControllerProvider
     metadata:
       name: "${provider_name}"
       namespace: "${SourceMTVns}"
     spec:
       url: "${provider_url}"
       # (add username, password if needed)
     ```

     and `oc apply -f …`.
   * Else → `oc patch provider $provider_name` to update `spec.url`.
4. **Wait for Provider to become “Ready”** (loop up to 300 seconds).

   * If still not Ready after 300s → exit with error.
5. **Generate/Trim `list_of_vms.txt`** (each VM = 2 lines: name + UID).

   * If `$total_vms` unset or ≤ 0 → set it based on file length:

     ```bash
     total_vms=$(( $(wc -l < list_of_vms.txt) / 2 ))
     ```
   * Else → keep only `$(( total_vms * 2 ))` lines:

     ```bash
     head -n "$(( total_vms * 2 ))" list_of_vms.txt > temp.txt
     mv temp.txt list_of_vms.txt
     ```
6. **Print**:

   ```
   total vms used in this migration are $total_vms
   ```

---

### D. What `RunMigration.sh` Does

1. **Source scenario variables** (so `$PlanMigrationName`, `$TargetMigrationNS`, `$provider_name`, `$SourceMTVns` are defined).
2. **Login again**:

   ```bash
   export KUBECONFIG="$HOME/clusterconfigs/auth/kubeconfig"
   oc login -u kubeadmin -p "$(cat "$HOME/clusterconfigs/auth/kubeadmin-password")" -n "$SourceMTVns"
   ```
3. **Build MigrationPlan YAML**:

   ```bash
   cat <<EOF > migrationplan-${scenario_name}.yaml
   apiVersion: migration.openshift.io/v1alpha1
   kind: MigrationPlan
   metadata:
     name: ${PlanMigrationName}
     namespace: ${SourceMTVns}
   spec:
     sourceNamespace: ${SourceMTVns}
     targetNamespace: ${TargetMigrationNS}
     provider: ${provider_name}
     migplanRef: ${PlanMigrationName}
     vms:
   EOF

   # Append VM entries from list_of_vms.txt
   while read -r vmName && read -r vmUID; do
     cat <<EOF >> migrationplan-${scenario_name}.yaml
     - name: $vmName
       uid: $vmUID
   EOF
   done < list_of_vms.txt

   oc apply -f migrationplan-${scenario_name}.yaml
   ```
4. **Wait for `.status.phase == "Ready"`** (up to 600 seconds).

   * If not Ready by timeout → exit with error.
5. **Trigger migration**:

   ```bash
   oc patch migrationplan "$PlanMigrationName" -n "$SourceMTVns" \
     --type=merge -p '{"spec":{"start":true}}'
   ```
6. **Wait for `.status.phase == "Completed"`** (another 600 seconds).

   * If not Completed by timeout → exit with error.
7. **Print success**:

   ```
   MigrationPlan '${PlanMigrationName}' completed successfully for scenario '${scenario_name}'.
   ```

---

## Example `cycles_list.txt`

Below is a sample file to place at `/home/$USER/MTV/cycles_list.txt`:

```text
# /home/$USER/MTV/cycles_list.txt

# Run the 'dsl-4-small' scenario with defaults
dsl-4-small

# Run the 'windows-3-vms' scenario with a "nightly" label and "dry-run" value
windows-3-vms  nightly  dry-run

# Run the 'example-2-vms' scenario
example-2-vms
```

* The first and third lines specify only the scenario name.
* The second line specifies `scenario_name`, `cycle_label`, and `cycle_value`.

---

## Tips & Troubleshooting

1. **“\~/MTV/cycles\_list.txt” doesn’t exist**

   ```bash
   mkdir -p ~/MTV
   touch ~/MTV/cycles_list.txt
   # Add scenario names, then save.
   ```

2. **“check\_root” failed**

   * Run with root privileges:

     ```bash
     sudo bash MainMTV.sh
     ```

3. **“Could not find scenario named ‘foo’ in tests.yaml”**

   * Verify the exact `name:` in `tests.yaml` matches the entry in `cycles_list.txt` (case‐sensitive).

4. **Provider CR never becomes Ready**

   * Confirm that `provider.url` is reachable from the cluster.
   * Inspect provider logs/events:

     ```bash
     oc describe provider <provider_name> -n <SourceMTVns>
     oc logs deployment/vm-migrate-controller -n openshift-mtv
     ```

5. **`list_of_vms.txt` missing or incorrect**

   * Run `SetupVMLists.sh` (or your custom VM-list builder) manually to generate `list_of_vms.txt`.
   * Ensure it has pairs of lines (VMName, VMUID) for each VM.

6. **MigrationPlan phase never changes**

   * Check migration operator logs:

     ```bash
     oc logs deployment/migration-operator -n openshift-mtv
     ```
   * Verify namespace quotas, storage classes, and the VDDK image are valid.

7. **Adding a New Scenario**

   * Append a new `- name: your-new-test` block to `MTV/config/tests.yaml` with all required fields.
   * Update `/home/$USER/MTV/cycles_list.txt` with `your-new-test` (and optional label/value).

---

## Summary

1. **Define test scenarios** in `MTV/config/tests.yaml`.
2. **List which scenarios to run** in `/home/$USER/MTV/cycles_list.txt`.
3. **Execute**:

   ```bash
   sudo bash MainMTV.sh
   ```

   * The script will:

     1. Read `cycles_list.txt` and build arrays.
     2. For each scenario:

        * Log into the OpenShift cluster.
        * Load scenario variables.
        * Create/patch MigrationProvider CR, generate/trim `list_of_vms.txt`.
        * Create MigrationPlan CR, wait until `Ready`, then trigger migration.
        * Wait until migration `Completed`, report success.
     3. Move on to the next scenario.

Once configured, you can scale your test matrix by editing `tests.yaml` and `cycles_list.txt` as needed.
