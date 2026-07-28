#!/bin/bash

set -x
source "/home/$USER/MTV/.current_scenario_vars.txt"

findtimediff()
{
  t1=`date -d "$1" +%s`
  t2=`date -d "$2" +%s`

  timediff=`expr ${t2} - ${t1}`

  echo `date +%H:%M:%S -ud @${timediff}`
}


ClusterLogin()
{
  export KUBECONFIG="${KUBECONFIG:-/home/$USER/clusterconfigs/auth/kubeconfig}"
  oc login -u kubeadmin -p $(cat "${KUBECONFIG%/*}/kubeadmin-password") -n $SourceMTVns
}

# NetworkMap will be created for each Plan. It using the inputs from networklist.txt
# First, create a dummy network map and right after adding the VMs network and remove the dummy network
CreateNetworkMap()
{
oc apply -f - << __EOF__
---
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: ${OffloadPrefix}networkmap-perf${planNum}
  namespace: ${SourceMTVns}
spec:
  map:
    - destination:
        type: pod 
      source: 
        id: dummy-network-1000
        name: dummy-network
  provider:
    source:
      name: ${provider_name}
      namespace: ${SourceMTVns}
    destination:
      name: host
      namespace: ${SourceMTVns}
__EOF__
}


AddNetworkMap()
{
  if [ ! -s "$TempFolder/networklist.txt" ]; then
    echo "ERROR: $TempFolder/networklist.txt is empty - no real network entries to add. Refusing to remove the dummy entry and ship an empty NetworkMap. Aborting." >&2
    exit 1
  fi

  while IFS= read -r line; do
    id="${line%% *}"
    name="${line#* }"
    oc patch networkmap ${OffloadPrefix}networkmap-perf${planNum} -n$SourceMTVns --type='json' -p="[
    {
      \"op\": \"add\",
      \"path\": \"/spec/map/-\",
      \"value\": {\"destination\":{\"type\":\"pod\"},\"source\":{\"id\":\"${id}\",\"name\":\"${name}\"}}
    }
  ]"
  done < $TempFolder/networklist.txt

  # Remove the dummy network
  oc patch networkmap ${OffloadPrefix}networkmap-perf${planNum} -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/map/0"
    }
  ]'
}

# StoragekMap will be created for each Plan. It using the inputs from storagelist.txt
# First, create a dummy storage map and right after adding the VMs storage and remove the dummy storage
CreateStorageMap()
{
oc apply -f - << __EOF__
---
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: ${OffloadPrefix}storagemap-perf${planNum}
  namespace: ${SourceMTVns}
spec:
  map:
    - destination:
        storageClass: dummy-storage-class
      source:
        id: dummy-datastore-1000
        name: dummy-datastore
  provider:
    source:
      name: ${provider_name}
      namespace: ${SourceMTVns}
    destination:
      name: host
      namespace: ${SourceMTVns}
__EOF__
}

CreateOffloadStorageMap()
{
oc apply -f - << __EOF__
---
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: ${OffloadPrefix}storagemap-perf${planNum}
  namespace: ${SourceMTVns}
spec:
  map:
  - destination:
      accessMode: ReadWriteMany
      storageClass: netapp-ontap-perf-iscsi
    offloadPlugin:
      vsphereXcopyConfig:
        secretRef: ontap
        storageVendorProduct: ontap
    source:
      id: datastore-35082
      name: PerfTest_VC7_1_ISCSI_24TB
  provider:
    source:
      name: ${provider_name}
      namespace: ${SourceMTVns}
    destination:
      name: host
      namespace: ${SourceMTVns}
__EOF__
}

AddStorageMap()
{
  if [ ! -s "$TempFolder/storagelist.txt" ]; then
    echo "ERROR: $TempFolder/storagelist.txt is empty - no real storage entries to add. Refusing to remove the dummy entry and ship an empty StorageMap. Aborting." >&2
    exit 1
  fi

  while IFS= read -r line; do
    id="${line%% *}"
    name="${line#* }"

    if [ "$StorageOffload" == "true" ] ; then
      #Example: TargetStorageClass: netapp-ontap-perf-iscsi (Should be part of tests.yaml)
      oc patch storagemap ${OffloadPrefix}storagemap-perf${planNum} -n$SourceMTVns --type='json' -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/map/-\",
        \"value\": {\"destination\":{\"accessMode\":\"ReadWriteMany\",\"storageClass\":\"${TargetStorageClass}\"},
        \"offloadPlugin\":{\"vsphereXcopyConfig\":{\"secretRef\":\"${SECRET_NAME}\",\"storageVendorProduct\":\"${STORAGE_VENDOR}\"}},
        \"source\":{\"id\":\"${id}\",\"name\":\"${name}\"}}
      }
    ]"
    else
      oc patch storagemap storagemap-perf${planNum} -n$SourceMTVns --type='json' -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/map/-\",
        \"value\": {\"destination\":{\"storageClass\": \"${TargetStorageClass}\"},\"source\": {\"id\":\"${id}\",\"name\":\"${name}\"}}
      }
    ]"
    fi
    done < $TempFolder/storagelist.txt

  # Remove the dummy storage
  oc patch storagemap ${OffloadPrefix}storagemap-perf${planNum} -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/map/0"
    }
  ]'
}

CreatePlanCR()
{
oc apply -f - << __EOF__
---
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: ${PlanMigrationName}
  namespace: ${SourceMTVns}
spec:
  map:
    network:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: NetworkMap
      name: ${OffloadPrefix}networkmap-perf${planNum}
      namespace: ${SourceMTVns}
    storage:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: StorageMap
      name: ${OffloadPrefix}storagemap-perf${planNum}
      namespace: ${SourceMTVns}
  provider:
    destination:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: host
      namespace: ${SourceMTVns}
    source:
      apiVersion: forklift.konveyor.io/v1beta1
      kind: Provider
      name: ${provider_name}
      namespace: ${SourceMTVns}
  targetNamespace: ${TargetMigrationNS}
  preserveStaticIPs: false
  type: ${MigrationType}
  vms:
${list_of_vms}
__EOF__
}

CreateMigrationCR()
{
oc apply -f - << __EOF__
---
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${PlanMigrationName}
  namespace: ${SourceMTVns}
spec:
  plan:
    name: ${PlanMigrationName}
    namespace: ${SourceMTVns}
__EOF__
}

# Create MTV Secret for Storage Offload. It is used to store the storage credentials for the storage offload
CreateMTVSecretForStorageOffload()
{
oc $1 -f - << __EOF__
---
apiVersion: v1
kind: Secret
metadata:
  name: ontap
  namespace: ${SourceMTVns}
type: Opaque
data:
  STORAGE_HOSTNAME: $(echo -n "${STORAGE_NETAPP_MGMT_IP}" | base64)
  STORAGE_USERNAME: $(echo -n "${STORAGE_NETAPP_USER}" | base64)
  STORAGE_PASSWORD: $(echo -n "${STORAGE_NETAPP_MGMT_PW}" | base64)
  ONTAP_SVM: aXNjc2kx
__EOF__
}

# Create IBM Secret for Storage Offload. It is used to store the IBM storage credentials for the storage offload
CreateIBMSecretForStorageOffload()
{
oc $1 -f - << __EOF__
---
apiVersion: v1
kind: Secret
metadata:
  name: ibm-backend-secret
  namespace: ${SourceMTVns}
type: Opaque
data:
  STORAGE_HOSTNAME: $(echo -n "${STORAGE_IBM_MGMT_IP}" | base64)
  STORAGE_USERNAME: $(echo -n "${STORAGE_IBM_USER}" | base64)
  STORAGE_PASSWORD: $(echo -n "${STORAGE_IBM_PW}" | base64)
  STORAGE_SKIP_SSL_VERIFICATION: dHJ1ZQ==
__EOF__
}

CheckPlanStatus()
{
  echo $(oc get plan $PlanMigrationName -n$SourceMTVns -o jsonpath="{.status.conditions[$1].type}")
}

CheckMigrationStatus()
{
  echo $(oc get migration $PlanMigrationName -n$SourceMTVns -o jsonpath="{.status.conditions[$1].type}")
}

GetMigrationTime()
{
  echo $(oc get migration $PlanMigrationName -n$SourceMTVns -o jsonpath="{.status.$1}")
}

MigrationSummary()
{
  for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
  do
    PlanMigrationName=$MigrationName
    TargetMigrationNS=$MigrationName
    echo "Migration Cycle #"$TotalLoopCycles":" "MigrationName: " $PlanMigrationName ", MigrationStatus:" $(CheckMigrationStatus 1) ", Total migrated VMs:" $(oc get virtualmachine -n$TargetMigrationNS | grep -v NAME | wc -l ) ", StartTime:" $(date +'%Y-%m-%d %H:%M:%S' -ud @$(date -d $(GetMigrationTime started) +%s)) ", EndTime:" $(date +'%Y-%m-%d %H:%M:%S' -ud @$(date -d $(GetMigrationTime completed) +%s)) ", Total Duration:" $(findtimediff $(GetMigrationTime started) $(GetMigrationTime completed)) >> $OutputFile
  done
}

# Cleanup the migration, plan, storagemap, networkmap and target namespace if the migration is completed.
# Incase of 'failed' or 'running' migration, keep for debugging.
# Also, stop collecting ESXs metrics and delete the metrics container and image
MigrationCleanup()
{
  TotalMigrationFailed=0
  if [ "$UseMultiPlans" == "false" ] ; then
    CleanupCommands  
  elif [ "$UseMultiPlans" == "true" ] ; then
    for planNum in `seq 1 $((NumOfPlans))`
    do
      PlanMigrationName=$(echo "$tempPlanMigrationName-$planNum")
      TargetMigrationNS=$(echo "$tempTargetMigrationNS-$planNum")
      CleanupCommands ; sleep 1
    done
  fi

  ###   Stop collecting ESXs metrics   ###
  StopCollectESXsMetrics

  if [ $TotalMigrationFailed -gt 0 ] ; then
    echo "Migration Failed or Timeout reached"
    echo "Total Migration Failed:" $TotalMigrationFailed ", Exit script"
    echo "Delete manually the failed plans, migrations, storagemaps, networkmaps and target namespaces"
    exit 1
  fi
} 

CleanupCommands()
{
  MigrationFinalStatus=$(oc get migration $PlanMigrationName -n$SourceMTVns -ojson | jq -r '.status.conditions[] | select(.type=="Succeeded"  or .type=="Failed" or .type == "Running") | .type')
  if [[ "$MigrationFinalStatus" == "Failed" || "$MigrationFinalStatus" == "Running" ]] ; then
    echo "Migration $PlanMigrationName status is: $MigrationFinalStatus, skipping cleanup"
    TotalMigrationFailed=$((TotalMigrationFailed+1))
  else
    oc delete plan $PlanMigrationName -n$SourceMTVns --ignore-not-found=true
    oc delete migration $PlanMigrationName -n$SourceMTVns --ignore-not-found=true
    oc delete storagemap ${OffloadPrefix}storagemap-perf${planNum} -n$SourceMTVns --ignore-not-found=true
    oc delete networkmap ${OffloadPrefix}networkmap-perf${planNum} -n$SourceMTVns --ignore-not-found=true
    oc delete ns $TargetMigrationNS --ignore-not-found=true
  fi
}

# Power On / Shutdown the VMs
VMs_PowerOnOff()
{
  local auth_b64=$(echo -n "${vsphere_user}:${vsphere_pw}" | base64)
  SessionID=$(curl -s -k -X POST -H "Authorization: Basic $auth_b64" "${provider_url%/sdk}/rest/com/vmware/cis/session" | jq -r '.value')
  ## Extract VM id from list_of_vms file"
  VMsID=$(grep "id:" $TempFolder/list_of_vms.txt | awk '{print $NF}')

  for vmid in $VMsID
  do
    if [ $1 == "warm" ]; then
      PowerAction="start"
      echo "Going to" $PowerAction "VMid:" $vmid
      curl -X POST -H "vmware-api-session-id:$SessionID" "${provider_url%/sdk}/rest/vcenter/vm/$vmid/power/$PowerAction" -k
    elif [ $1 == "cold" ]; then
      PowerAction="shutdown"  
      echo "Going to" $PowerAction "VMid:" $vmid
      curl -X POST -H "vmware-api-session-id:$SessionID" "${provider_url%/sdk}/rest/vcenter/vm/$vmid/guest/power?action=$PowerAction" -k
    fi
    sleep 3
  done
}

# Verify the VMs have the right power state
VMs_PowerState()
{
  local auth_b64=$(echo -n "${vsphere_user}:${vsphere_pw}" | base64)
  SessionID=$(curl -s -k -X POST -H "Authorization: Basic $auth_b64" "${provider_url%/sdk}/rest/com/vmware/cis/session" | jq -r '.value')
  ## Extract VM id from $TempFolder/list_of_vms file"
  VMsID=$(grep "id:" $TempFolder/list_of_vms.txt | awk '{print $NF}')
  TotalVMs=$(grep -c "id:" $TempFolder/list_of_vms.txt)

  PowerState="POWERED_OFF"
  if [ $1 == "warm" ]; then
    PowerState="POWERED_ON"
  fi

  CountVMs=0
  for vmid in $VMsID
  do
    VMstate=$(curl -s -k -X GET -H "vmware-api-session-id: $SessionID" "${provider_url%/sdk}/rest/vcenter/vm/$vmid"  | jq '.[].power_state' | tr -d '"')

    if [ "$VMstate" == "$PowerState" ]; then
      CountVMs=$((CountVMs + 1))
    fi
    sleep 1
  done

  if [ $TotalVMs -eq $CountVMs ]; then
    echo "ALL VMs" $PowerState
  else
    echo -e "Not all VMs" $PowerState "\nExit script................"
    exit 1
  fi
}

# To avoid a plan not running because snapshot exists for the VMs,
# As part of warm migration preparation, deleting all VMs existing snapshots using GOVC.
# Also required for Storage Offload (XCOPY) - XCOPY doesn't work if VMs have snapshots.
VMs_DeleteSnapshots()
{
  if [ "$MigrationType" == "warm" ] || [ "$StorageOffload" == "true" ] ; then
    echo "Deleting snapshots required for: MigrationType=$MigrationType, StorageOffload=$StorageOffload"
    grep -v "id:" $TempFolder/list_of_vms.txt | awk '{print $2}' > $TempFolder/vm_names_file.txt
    vSphere_url="${provider_url#*://}"
    vSphere_url="${vSphere_url%%/*}"

    ansible-playbook `pwd`/GOVC/DeleteVMSnapshots.yaml -e vSphere_url="$vSphere_url" -e vm_names_file="$TempFolder/vm_names_file.txt" -e outPath="$TempFolder" -v

    TotalRemainingSnapshots=$(cat $TempFolder/CountSnapshots.txt | wc -l)
    if [ $TotalRemainingSnapshots -gt 0 ] ; then
      echo "Total Remaining Snapshots:" $TotalRemainingSnapshots
      echo "Some VMs still have snapshots, Exit script"
      exit 1
    fi
    echo "All VMs have no snapshots"
  fi
}

# Add WARM flag to the Plan.
# Only for warm migration TCs. 
AddWARMflag()
{
  echo "Adding WARM flag to Plan:" $1
  oc patch plan $1 -n$SourceMTVns --type=json -p='[ { "op":"add", "path": "/spec/warm", "value": true } ]'
}

# Add cutOver time to the migration CR.
# The time is calculated based on the PreCopyInterval * TotalPreCopies and adding 10 minutes 
AddCutOver()
{
  ForkLiftControllerPod=$(oc get pods -n$SourceMTVns | grep forklift-controller | awk '{print $1}')
  PreCopyInterval=$(oc get pods $ForkLiftControllerPod -n$SourceMTVns -ojson | jq -r '.spec.containers[].env[] | select(.name == "PRECOPY_INTERVAL") | .value' | tr -d '"')
  TotalTimeToAdd=$((PreCopyInterval * (TotalPreCopies-1) +10))
  echo "Total Time To Add in minutes: $TotalTimeToAdd"

  for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
  do
    CutOverTime=$(date -d "+${TotalTimeToAdd} minutes" +"%Y-%m-%dT%H:%M:%S.000Z")
    oc patch migration $MigrationName -n$SourceMTVns --type=json -p='[ { "op":"add", "path": "/spec/cutover", "value": "'$CutOverTime'" } ]'
    echo "Cutover time set to:" $CutOverTime
    sleep 1
  done  
}

# Set Max VM Inflight, default is 20
SetMaxVmInflight()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type=merge -p '{"spec":{"controller_max_vm_inflight":'$MaxVMInflight'}}'
  echo "Max VM Inflight set to:" $MaxVMInflight
}

# Set Max Populator Inflight for Storage Offload
SetMaxPopulatorInflight()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type=merge -p '{"spec":{"controller_max_populator_inflight":'$controller_max_populator_inflight'}}'
  echo "Max Populator Inflight set to:" $controller_max_populator_inflight
}

# Remove Max Populator Inflight setting from ForkliftController
RemoveMaxPopulatorInflight()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/controller_max_populator_inflight"
    }
  ]'
}

# Enable Storage Offload support, default is false
AddStorageOffloadSettings()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type=merge -p '{"spec":{"feature_copy_offload":"true"}}'
  echo "Storage-Offload is set to 'true'"
}

# Remove Storage Offload support
RemoveStorageOffloadSettings()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/feature_copy_offload"
    }
  ]'
}

# Set Max Concurrent Reconciles, default is 10
# For testing MTV-2775.
SetMaxCcReconciles()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type=merge -p '{"spec":{"controller_max_concurrent_reconciles":'$MaxCcReconciles'}}'
  echo "Max Concurrent Reconciles set to:" $MaxCcReconciles
}

# Remove Max Concurrent Reconciles, return to default is 10
RemoveMaxCcReconciles()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/controller_max_concurrent_reconciles"
    }
  ]'
}

# Enable wait_for_final_snapshot_consolidation setting on ForkliftController
AddWaitForFinalSnapshotConsolidation()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type=merge -p '{"spec":{"wait_for_final_snapshot_consolidation":"false"}}'
  echo "wait_for_final_snapshot_consolidation is set to 'false'"
}

# Remove wait_for_final_snapshot_consolidation setting from ForkliftController
RemoveWaitForFinalSnapshotConsolidation()
{
  oc patch forkliftcontroller forklift-controller -n$SourceMTVns --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/wait_for_final_snapshot_consolidation"
    }
  ]'
}

# Start collecting ESXs metrics using GOVC
# Create the metrics container and start collecting ESXs metrics
# The metrics output files are locate in plan METRIC folder 
StartCollectESXsMetrics()
{
  vSphere_url="${provider_url#*://}"
  vSphere_url="${vSphere_url%%/*}"
  
  ansible-playbook `pwd`/METRICS/CreateImageContainer.yaml -e vSphere_url="$vSphere_url" -v
  sleep 3
  ansible-playbook `pwd`/METRICS/MainCollect.yaml -e TempPath="$TempFolder" -e LogsPath="$MetricsLocation" -v
}

# Stop collecting ESXs metrics using GOVC
# Delete the metrics container and image
StopCollectESXsMetrics()
{
  ansible-playbook `pwd`/METRICS/DeleteImageContainer.yaml -v
  sleep 10
  pkill -f "ansible-playbook CollectMetrics.yaml"
  pkill -f "AnsiballZ_command.py"
  pkill -f "govc_metrics govc metric.sample"
  podman images | grep ubi | awk '{print $1}' | xargs podman rmi -f
}


##################################################
##################################################
#####                                        #####
#####                  MAIN                  #####
#####                                        #####
##################################################
##################################################

# Check if MaxLoopCycles is not defined from tests.yaml if not then set it to 1
: ${MaxLoopCycles:=1}
# Check if TotalPreCopies is not defined from tests.yaml if not then set it to 1
: ${TotalPreCopies:=1}
# Check if Max_VM_Inflight is not defined from tests.yaml if not then set it to 20
: ${MaxVMInflight:=20}
# Check if TestTimeoutInHours is not defined from tests.yaml if not then set it to 8
: ${TestTimeoutInHours:=8}
# Check if Storage-Offload is not defined from tests.yaml if not then set it to false
#: ${StorageOffload:="false"}
# Check if MaxCcReconciles is not defined from tests.yaml if not then set it to 10
#: ${MaxCcReconciles:=10}
# Check if Target Storage Class is not defined from tests.yaml if not then set it to ocs-storagecluster-ceph-rbd
: ${TargetStorageClass:="ocs-storagecluster-ceph-rbd"}

# Create TempFolder for temporary files
TempFolder="/home/$USER/TempFiles"
mkdir -p $TempFolder

# Check if needed to create Multiple Plans 
UseMultiPlans="false"
tempPlanMigrationName=$PlanMigrationName
tempTargetMigrationNS=$TargetMigrationNS
if [[ -v NumOfPlans || -v NumOfVMsPerPlan ]]; then
  if [[ $NumOfPlans -eq 0 || $NumOfVMsPerPlan -eq 0 ]]; then
    echo "The parameter NumOfPlans or NumOfVMsPerPlan are not set or value is 0, Exit script"
    exit 1
  fi
  echo "Creating ${NumOfPlans} plans with ${NumOfVMsPerPlan} VMs per plan"
  UseMultiPlans="true"
fi

list_of_vms=$(cat $TempFolder/list_of_vms.txt) 
if [ $(cat $TempFolder/list_of_vms.txt | egrep "$VMsPrefix" | wc -l) -eq 0 ] ; then
  echo "No VMs found in $TempFolder/list_of_vms.txt with prefix:" $VMsPrefix ", Exit script"
  exit 1
fi

ClusterLogin

### Setting Max VM Inflight ####
SetMaxVmInflight

#### Setting Storage Offload ####
if [ "$StorageOffload" == "true" ] ; then
  AddStorageOffloadSettings
  
  # Set Max Populator Inflight if defined
  if [[ -v controller_max_populator_inflight ]]; then
    SetMaxPopulatorInflight
  fi

  # Detect storage vendor from TargetStorageClass (only when offloading)
  if [ "$TargetStorageClass" == "ibm-perf-iscsi" ]; then
      STORAGE_VENDOR="flashsystem"
      SECRET_NAME="ibm-backend-secret"
      CreateIBMSecretForStorageOffload apply
  else
      # Default to NetApp/ontap
      STORAGE_VENDOR="ontap"
      SECRET_NAME="ontap"
      CreateMTVSecretForStorageOffload apply
  fi
  
  OffloadPrefix="offload-"
else
  RemoveStorageOffloadSettings
  RemoveMaxPopulatorInflight
  CreateMTVSecretForStorageOffload delete
  CreateIBMSecretForStorageOffload delete
fi

#### Setting Max Concurrent Reconciles ####
echo "MaxCcReconciles:" $MaxCcReconciles
if [ -z "$MaxCcReconciles" ] ; then
  echo "MaxCcReconciles does not exist - Default value is 10"
  RemoveMaxCcReconciles
else
  echo "MaxCcReconciles exist"
  SetMaxCcReconciles
fi

#### Setting wait_for_final_snapshot_consolidation ####
if [ "$wait_for_final_snapshot_consolidation" == "false" ] ; then
  AddWaitForFinalSnapshotConsolidation
else
  RemoveWaitForFinalSnapshotConsolidation 2>/dev/null || true
fi

echo "Depending on the number of changes, the forklift-controller pod may restart twice to apply all the changes"
echo "Running ${MigrationType} Migration !!!"
echo "Total loops: ${MaxLoopCycles}"

if [ "$MigrationType" == "warm" ]; then
  echo "Total PreCopies: ${TotalPreCopies}"
fi
MTV_BUILD=`$(dirname "$0")/utils/find-version-build.sh`
TotalLoopCycles=1
ReportsLocation="/home/$USER/MTV/results/${MTV_BUILD}/${PlanMigrationName}"
tempPlanName=$PlanMigrationName
if [ "$UseMultiPlans" == "true" ] ; then
  ReportsLocation="/home/$USER/MTV/results/${MTV_BUILD}/${PlanMigrationName}-1"
  tempPlanName=$PlanMigrationName-1
fi
OutputFile="$ReportsLocation/MigrationSummary_${PlanMigrationName}_$(date +"%Y%m%d-%H%M%S").txt"

echo "You can abort the script within 60 seconds using Ctrl+C" 
sleep 60

########################################################
while [ $TotalLoopCycles -le $MaxLoopCycles ]
do
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
  echo ">>>>>>>                                                                                                           <<<<<<<"       
  echo ">>>>>>>    RunMigration.sh main loop cycles: $TotalLoopCycles of $MaxLoopCycles - $(date '+%Y-%m-%d %H:%M:%S')    <<<<<<<"
  echo ">>>>>>>                                                                                                           <<<<<<<"       
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

  export ReportDate=$(date +"%Y%m%d-%H%M%S")
  MetricsLocation="$ReportsLocation/logs/${tempPlanName}_${ReportDate}/METRICS"
  mkdir -p $MetricsLocation

  ClusterLogin

  MigrationCleanup 

  ##############################################################
  ###   Delete VM snapshots , Power On / Shutdown the VMs   ####
  ##############################################################
  echo "Deleting VM snapshots"
  VMs_DeleteSnapshots

  echo "Going to power On / Shutdown the VMs"
  VMs_PowerOnOff $MigrationType

  echo "Verify VMs power state"
  VMs_PowerState $MigrationType

  #########################################
  ###   Start collecting ESXs metrics   ###
  #########################################
  echo "--------------------------------------------------------------------------"
  echo " MultiPlans - METRICS folder will be created in the First Plan Folder !!!!"
  echo "--------------------------------------------------------------------------"
  StartCollectESXsMetrics

  #################################
  ###   Create Migration Plan   ###
  #################################
  if [ "$UseMultiPlans" == "false" ] ; then
    CreatePlanCR
    CreateNetworkMap
    AddNetworkMap
    CreateStorageMap
    AddStorageMap
  elif [ "$UseMultiPlans" == "true" ] ; then 
  ## Split the VMs list using NumOfVMsPerPlan parameter
    VMsFileSuffix=1
    split -l $((NumOfVMsPerPlan * 2)) $TempFolder/list_of_vms.txt SplitFile_
    for filename in SplitFile_*
    do
      mv "$filename" "SplitFile_$VMsFileSuffix.txt"
      ((VMsFileSuffix++))
    done

    sleep 1

    TotalPlansCreated=0
    for planNum in `seq 1 $((NumOfPlans))`
    do
      list_of_vms=$(cat SplitFile_$planNum.txt)
      if [ -z "${list_of_vms}" ]; then
	      echo "plan $planNum have no VMs.....plan will not created"
	      continue
      fi
      PlanMigrationName=$(echo "$tempPlanMigrationName-$planNum")
      TargetMigrationNS=$(echo "$tempTargetMigrationNS-$planNum")
      CreatePlanCR
      CreateNetworkMap
      AddNetworkMap
      CreateStorageMap
      AddStorageMap

      TotalPlansCreated=$((TotalPlansCreated+1))
    done	    

    rm -f SplitFile_*.txt

    echo "TotalPlansCreated:" $TotalPlansCreated
    if [ $TotalPlansCreated -eq 0 ] ; then
      echo "No plans created, Exit script"
      exit 1
    fi
  fi

  # Create PlansToGrep pattern to filter by full plan name
  if [ "$UseMultiPlans" == "false" ] ; then
    PlansToGrep=$(echo "^$tempPlanMigrationName$")
  elif [ "$UseMultiPlans" == "true" ] ; then
    PlansToGrep=$(echo "^$tempPlanMigrationName-[0-9]+$")
  fi

  #################################
  ###   Add WARM flag to Plan   ###
  #################################
  if [ "$MigrationType" == "warm" ] ; then
    sleep 10
    for planName in $(oc get plans -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
    do
      AddWARMflag $planName
      sleep 1
    done
  fi

  ###################################################
  ###   Waiting for the Plans to become Ready     ###
  ###   10 minutes timeout = 20times * 30 seconds ###
  ###################################################
  TotalRetriesCycles=1
  # MTV-5319: 80VM plans take ~28min to become Ready, increased from 10min to 45min
  MaxRetriesCycles=90    # 45min timeout = 90times * 30 seconds

  TotalPlans=$(oc get plans -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | wc -l) 
  while true
  do
    ListOfPlans=$(oc get plans -n$SourceMTVns -ojson)
    TotalReadyPlans=0
    for planName in $(oc get plans -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
    do
      current_ready_status=$(printf '%s' $ListOfPlans | jq -r --arg PLAN "$planName" '.items[] | select(.metadata.name == $PLAN) | .status.conditions[]? | select(.type == "Ready") | .status')
      if [ "$current_ready_status" == "True" ] ; then
        TotalReadyPlans=$((TotalReadyPlans+1))
      else
        break  
      fi
    done

    echo "Cycle #"$TotalRetriesCycles:" TotalReadyPlans:" $TotalReadyPlans "/" $TotalPlans

    if [ $TotalReadyPlans -eq $TotalPlans ] ; then
      echo "All plans are ready"
      break
    fi

    if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
    then
      echo "Plans are not 'Ready' within 45min timeout, running cleanup"
      TotalLoopCycles=$((TotalLoopCycles+1))

      MigrationCleanup
      break
    fi

    TotalRetriesCycles=$((TotalRetriesCycles+1))
    sleep 30  # 10Min timeout , 30 seconds    
  done

  if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
  then
    echo "Continue to the next cycle."
    continue
  fi

  #################################
  ###     Running Migration     ###
  #################################
  # Create temp folder for importer logs collection (warm migrations)
  IMPORTER_LOGS_TMP="/tmp/importer_logs_$$"
  mkdir -p "$IMPORTER_LOGS_TMP"
  export IMPORTER_LOGS_TMP

  # Create temp folder for populate pod logs (StorageOffload migrations)
  # Populate pods finish early (xcopy) and get GC'd before migration ends on newer CNV
  POPULATE_LOGS_TMP="/tmp/populate_logs_$$"
  mkdir -p "$POPULATE_LOGS_TMP"
  export POPULATE_LOGS_TMP
  
  for MigrationName in $(oc get plans -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
  do
    echo "MigrationName:" $MigrationName  
    PlanMigrationName=$MigrationName
    CreateMigrationCR ; sleep 1
  done  

  ##########################################################
  ###  Waiting for all the Migrations to become Running  ###
  ###      10 minutes timeout = 20times * 30 seconds     ###
  ##########################################################
  TotalRetriesCycles=1
  # MTV-5319: 80VM migrations take ~28min to transition to Running, increased from 10min to 45min
  MaxRetriesCycles=90    # 45min timeout = 90times * 30 seconds

  TotalMigrations=$(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | wc -l) 
  while true
  do
    ListOfMigrations=$(oc get migrations -n$SourceMTVns -ojson)
    TotalRunningMigrations=0
    for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
    do
      current_running_status=$(printf '%s' $ListOfMigrations | jq -r --arg MIGRATION "$MigrationName" '.items[] | select(.metadata.name == $MIGRATION) | .status.conditions[]? | select(.type == "Running") | .status')
      if [ "$current_running_status" == "True" ] ; then
        TotalRunningMigrations=$((TotalRunningMigrations+1))
      else
        break  
      fi
    done

    echo "Cycle #"$TotalRetriesCycles:" TotalRunningMigrations:" $TotalRunningMigrations "/" $TotalMigrations

    if [ $TotalRunningMigrations -eq $TotalMigrations ] ; then
      echo "All migrations are running"
      if [ "$MigrationType" == "warm" ]; then
        AddCutOver
      fi
      break
    fi

    if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
    then
      echo "Migrations are not 'Running' within 45min timeout, running cleanup"
      TotalLoopCycles=$((TotalLoopCycles+1))

      MigrationCleanup
      break
    fi

    TotalRetriesCycles=$((TotalRetriesCycles+1))
    sleep 30  # 10Min timeout , 30 seconds    
  done

  if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
  then
    echo "Continue to the next cycle."
    continue
  fi

  #####################################################
  ###  Waiting for the Migrations to complete       ###
  ###  timeout = TestTimeoutInHours * 60 seconds    ###
  #####################################################
  TotalRetriesCycles=1
  MaxRetriesCycles=$((TestTimeoutInHours * 60))   # TestTimeoutInHours * 60 seconds

  TotalMigrations=$(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | wc -l) 
  while true
  do
    ListOfMigrations=$(oc get migrations -n$SourceMTVns -ojson)
    TotalPassedMigrations=0
    TotalFailedMigrations=0
    for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
    do
      current_migration_status=$(printf '%s' $ListOfMigrations | jq -r --arg MIGRATION "$MigrationName" '.items[] | select(.metadata.name == $MIGRATION) | .status.conditions[]? | select(.type == "Succeeded" or .type=="Failed") | .type' | head -n 1)
      if [ "$current_migration_status" == "Succeeded" ] ; then
        TotalPassedMigrations=$((TotalPassedMigrations+1))
        echo "Cycle #"$TotalRetriesCycles:" TotalRunningMigrations:" $TotalRunningMigrations "/" $TotalMigrations
      elif [ "$current_migration_status" == "Failed" ] ; then 
        TotalFailedMigrations=$((TotalFailedMigrations+1))
      else 
        break  
      fi
    done

    if [ $((TotalPassedMigrations + TotalFailedMigrations)) -eq $TotalMigrations ] ; then
      echo "Migration completed. Total plans passed:" $TotalPassedMigrations ", Total plans failed:" $TotalFailedMigrations
      break
    fi

    if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
    then
      echo "Migrations are 'Running' more than ${TestTimeoutInHours} hours - reached script timeout, collecting logs"
      break
    fi

    # Collect importer pod logs during warm migration (they disappear after completion)
    # Use append (>>) to preserve logs across pod restarts - captures first failure + subsequent restarts
    if [ "$MigrationType" == "warm" ]; then
      for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
      do
        TargetNS=$(oc get plan $MigrationName -n$SourceMTVns -o jsonpath='{.spec.targetNamespace}' 2>/dev/null)
        if [ -n "$TargetNS" ]; then
          for getpod in $(oc get pods -n$TargetNS 2>/dev/null | grep -E "^importer-" | cut -d " " -f1)
          do
            RESTARTS=$(oc get pod $getpod -n$TargetNS -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
            echo "=== Log capture at $(date -Iseconds) | Restarts: $RESTARTS ===" >> "$IMPORTER_LOGS_TMP/Importer_${getpod}.log"
            oc logs $getpod -n$TargetNS >> "$IMPORTER_LOGS_TMP/Importer_${getpod}.log" 2>&1
          done
        fi
      done
    fi

    # Collect populate pod logs during StorageOffload (pod gets GC'd before migration ends)
    if [ "$StorageOffload" == "true" ]; then
      for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
      do
        TargetNS=$(oc get plan $MigrationName -n$SourceMTVns -o jsonpath='{.spec.targetNamespace}' 2>/dev/null)
        if [ -n "$TargetNS" ]; then
          for getpod in $(oc get pods -n$TargetNS --no-headers 2>/dev/null | grep populate | awk '{print $1}')
          do
            echo "=== Log capture at $(date -Iseconds) ===" >> "$POPULATE_LOGS_TMP/Populate_${getpod}.log"
            oc logs $getpod -n$TargetNS >> "$POPULATE_LOGS_TMP/Populate_${getpod}.log" 2>&1
          done
        fi
      done
    fi

    TotalRetriesCycles=$((TotalRetriesCycles+1))
    sleep 60 
  done

  #################################
  ### Parsing Migration Results ###
  #################################
  echo "Parsing Migration Results"
  echo "------------------------------------------------------------------------------------"
  echo " MultiPlans - Migration Summary Report will be created in the First Plan Folder !!!!"
  echo "------------------------------------------------------------------------------------"
  MigrationSummary

  ## The script "AdvancedParseMigrationCR.sh"  <Migration CR> <MTV Namespace>
  ## collect MTV & VirtV2V logs , Create Breakdown report
  for MigrationName in $(oc get migrations -n$SourceMTVns | awk '{print $1}' | grep -E "$PlansToGrep" | sort -V)
  do
    PlanMigrationName=$MigrationName
    ./AdvancedParseMigrationCR.sh $PlanMigrationName $SourceMTVns
    cd "$(dirname "$0")"
    # Get LogLocation Variables that were set by AdvancedParseMigrationCR.sh
    source /home/$USER/MTV/results/.latest-result.log
    echo $LogsLocation
    utils/report_etl.sh "$LogsLocation" > "$LogsLocation/report_flow_generation.log"
  done
  TotalLoopCycles=$((TotalLoopCycles+1))
  MigrationCleanup

  if [ "$MaxLoopCycles" -gt 1 ] && [ -f "$MAIN_LOG_FILE" ]; then
    cp "$MAIN_LOG_FILE" "$LogsLocation/"
  fi

  # Sleep between loops
  sleep 200

done

#### Remove wait_for_final_snapshot_consolidation after test completes ####
if [ "$wait_for_final_snapshot_consolidation" == "false" ] ; then
  RemoveWaitForFinalSnapshotConsolidation
fi
