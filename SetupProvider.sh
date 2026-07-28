#!/bin/bash

#set -x
source "/home/$USER/MTV/.current_scenario_vars.txt"

ClusterLogin()
{
  export KUBECONFIG="${KUBECONFIG:-/home/$USER/clusterconfigs/auth/kubeconfig}"
  oc login -u kubeadmin -p $(cat "${KUBECONFIG%/*}/kubeadmin-password") -n $SourceMTVns
}

CheckProviderStatus()
{
  echo $(oc get providers $provider_name -n$SourceMTVns -o jsonpath="{.status.phase}")
}


CreateSourceProvider()
{
cat > $TempFolder/$YMLsFolder/CreateSourceProvider.yaml << __EOF__
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: ${provider_name}
  namespace: ${SourceMTVns}
spec:
  type: vsphere
  url: ${provider_url}
  settings:
    sdkEndpoint: vcenter
    vddkInitImage: ${VDDKURL}
  secret:
    name: ${ProviderSecretName}
    namespace: ${SourceMTVns}
__EOF__

oc apply -f $TempFolder/$YMLsFolder/CreateSourceProvider.yaml
# Patch based on aio_enable
if [ "$aio_enable" = true ]; then
  echo "Patching provider to enable useVddkAioOptimization..."

  oc patch provider "$provider_name" -n "$SourceMTVns" --type='json' -p='[
    {
      "op": "add",
      "path": "/spec/settings/useVddkAioOptimization",
      "value": "true"
    }
  ]'
  # AIO patch triggers a provider re-sync which clears the VM inventory temporarily.
  # Without this wait, the VM list fetch below returns empty and the script exits.
  echo "Waiting 30s for provider inventory to re-sync after AIO patch..."
  sleep 30
else
  echo "Removing useVddkAioOptimization from provider if exists..."

  oc patch provider "$provider_name" -n "$SourceMTVns" --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/settings/useVddkAioOptimization"
    }
  ]' 2>/dev/null || echo "useVddkAioOptimization not set, no need to remove."
fi
}


CreateProviderSecret()
{
cat > $TempFolder/$YMLsFolder/CreateProviderSecret.yaml << __EOF__
apiVersion: v1
kind: Secret
metadata:
  name: ${ProviderSecretName}
  namespace: ${SourceMTVns}
  labels:
    createdForProviderType: vsphere
    createdForResourceType: providers
type: Opaque
data:
  insecureSkipVerify: dHJ1ZQ==
  password: $(echo -n "${vsphere_pw}" | base64)
  url: $(echo -n $provider_url | base64)
  user: $(echo -n "${vsphere_user}" | base64)
__EOF__

oc apply -f $TempFolder/$YMLsFolder/CreateProviderSecret.yaml
}

# Get Network, Datastore and ESXi Host of each VM using GOVC
# That data will enable accurate mapping of VMs to networks, datastores and ESXi hosts
CreateNetworkDatastoreHostsLists()
{
  grep -v "id:" $TempFolder/list_of_vms.txt | awk '{print $2}' > $TempFolder/vm_names_file.txt
  vSphere_url="${provider_url#*://}"
  vSphere_url="${vSphere_url%%/*}"

  ansible-playbook `pwd`/GOVC/CreateNetworkDatastoreHostsLists.yaml -e vSphere_url="$vSphere_url" -e vm_names_file="$TempFolder/vm_names_file.txt" -e outPath="$TempFolder" -v
  if [ $? -ne 0 ]; then
    echo "ERROR: CreateNetworkDatastoreHostsLists.yaml playbook failed - networklist.txt/storagelist.txt were not populated. Aborting." >&2
    exit 1
  fi
}

##################################################
#####                  MAIN                  #####
##################################################

ProviderSecretName=$(echo $provider_name"-secret")
TempFolder="/home/$USER/TempFiles"
YMLsFolder="ConfigYMLfiles"
# total_vms allows for limiting size of list_of_vms.txt to specific number of vms (var is not required - when not defined entire list is used)
#total_vms=2
TotalRetriesCycles=1
MaxRetriesCycles=60    # 10min timeout

# Check if HostNetwork is not defined from tests.yaml if not then set it to "vm"
: ${HostNetwork="vmk"}

ClusterLogin

# Create TempFolder for temporary files
mkdir -p $TempFolder
mkdir -p $TempFolder/$YMLsFolder
CreateSourceProvider
CreateProviderSecret


while [ "$(CheckProviderStatus)" != "Ready" ] && [ $TotalRetriesCycles -le $MaxRetriesCycles ]
do
  echo "Cycle #"$TotalRetriesCycles:" PROVIDER Status:" $(CheckProviderStatus) ", WAITING FOR READY STATUS"
  TotalRetriesCycles=$((TotalRetriesCycles+1))
  sleep 10  # 10Min timeout , 10 seconds
done


if [ $TotalRetriesCycles -ge $MaxRetriesCycles ]
then
  echo "PROVIDER status is not 'Ready' , abort script"
  exit 1
fi

TOKEN=$(oc whoami -t)
ForkliftInventoryHost=$(oc get routes -n$SourceMTVns | grep forklift-inventory | awk {'print $2'})
ClusterID=$(curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere -k 2>/dev/null | jq -r --arg name "$provider_name" '.[] | select(.name == $name) | .id') 
TotalHosts=$(curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/hosts/ -k 2>/dev/null | jq '. | length')
HostsID=$(curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/hosts/ -k 2>/dev/null | jq -r '.[].id')

for HostID in $HostsID
do
  HostIP=$(curl -H "Authorization: Bearer $TOKEN" "https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/hosts/$HostID" -k 2>/dev/null | jq -r --arg HostNetwork "$HostNetwork" '.networkAdapters[] | select(.name | test($HostNetwork; "i")) | .ipAddress')
#  HostIP=$(curl -H "Authorization: Bearer $TOKEN" "https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/hosts/$HostID" -k 2>/dev/null | jq '.networkAdapters[1].ipAddress' | tr -d '"')

cat > $TempFolder/$YMLsFolder/Create-$HostID-Config.yaml << __EOF__
apiVersion: forklift.konveyor.io/v1beta1
kind: Host
metadata:
  name: ${provider_name}-${HostID}-config
  namespace: ${SourceMTVns}
spec:
  id: ${HostID}
  ipAddress: ${HostIP}
  provider:
    name: ${provider_name}
    namespace: ${SourceMTVns}
  secret:
    name: vsphere-${HostID}-secret
    namespace: ${SourceMTVns}
__EOF__

cat > $TempFolder/$YMLsFolder/Create-$HostID-Secret.yaml << __EOF__
apiVersion: v1
kind: Secret
metadata:
  name: vsphere-${HostID}-secret
  namespace: ${SourceMTVns}
  labels:
    createdForResource: ${HostID}
    createdForResourceType: hosts
type: Opaque
data:
  insecureSkipVerify: dHJ1ZQ==
  ip: $(echo -n $HostIP | base64)
  password: $(echo -n "${esx_os_pw}" | base64)
  provider: $(echo -n $provider_name | base64)
  user: $(echo -n "${esx_os_user}" | base64)
__EOF__

oc apply -f $TempFolder/$YMLsFolder/Create-$HostID-Config.yaml
oc apply -f $TempFolder/$YMLsFolder/Create-$HostID-Secret.yaml

done

##echo "Get Networks List"
##curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/networks/ -k 2>/dev/null | jq -r '.[] | "\(.id) \(.name)"' > $TempFolder/networklist.txt

##echo "Get All Datastores List"
##curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/datastores/ -k 2>/dev/null | jq -r '.[] | "\(.id) \(.name)"' > $TempFolder/storagelist.txt

# Get only Datastores with name containing "PerfTest"
#curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/datastores/ -k 2>/dev/null | jq -r '.[] | select(.name | test("PerfTest";"i")) | "\(.id) \(.name)"' > $TempFolder/storagelist.txt


echo "Create VMs list"
if [ "$MixedVMs" == true ]; then
  echo "Creating Mixed VMs list"
  IFS='|' read -r RHEL_VMs WIN_VMs <<< "$VMsPrefix"
  VMsCount=$((total_vms/2))

  VMsTestList=$(curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/vms -k 2>/dev/null | \
  jq --arg rhelpat "^$RHEL_VMs" \
     --arg winpat "^$WIN_VMs" \
     --argjson count "$VMsCount" \
     -r '
    # 1. Select all RHEL VMs
      (
          [.[] | select(.name | test($rhelpat))] | 
          sort_by(.name | split("-") | last | tonumber? // 0) | 
          .[0:$count]
      )
    # 2. Select all WIN VMs
      ,
      (
          [.[] | select(.name | test($winpat))] | 
          sort_by(.name | split("-") | last | tonumber? // 0) |
          .[0:$count]
      )
    # 3. Combine the two lists
      | sort_by(.name | split("-") | last | tonumber? // 0)[]
      | "\(.id) \(.name)"
  ')
else
  VMsTestList=$(curl -H "Authorization: Bearer $TOKEN" https://$ForkliftInventoryHost/providers/vsphere/$ClusterID/vms -k 2>/dev/null | jq --arg pattern "^$VMsPrefix" -r '[.[] | select(.name | test($pattern))] | sort_by(.name | split("-") | last | tonumber? // 0 )[] | "\(.id) \(.name)"')
fi

echo "$VMsTestList" | awk '{print "  - id: " $1 "\n    name: " $2}' > $TempFolder/list_of_vms.txt
# Limit number of vms to desired amount
# If the variable total_vms is defined and greater than 0
if [[ -n "$total_vms" && "$total_vms" -gt 0 ]]; then
    # Calculate the number of lines to keep (total_vms * 2)
    total_vms_lines=$(( total_vms * 2 ))
    # Truncate original_file.txt to total_vms_lines
    head -n "$total_vms_lines" $TempFolder/list_of_vms.txt > $TempFolder/temp.txt && mv $TempFolder/temp.txt $TempFolder/list_of_vms.txt
fi

# Otherwise, count the number of lines in list_of_vms.txt
total_vms=$(($(wc -l < "$TempFolder/list_of_vms.txt") / 2))


# Print the total VMs used in this migration
echo "total vms used in this migration are $total_vms"

# Create Network & Datastore for mapping 
# Create Hosts Lists for Metrics collection
CreateNetworkDatastoreHostsLists
