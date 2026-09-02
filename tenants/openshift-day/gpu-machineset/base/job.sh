#!/usr/bin/env bash

set -euo pipefail

ocp_aws_cluster() {
  if oc -n openshift-machine-api get machinesets.machine.openshift.io -o name 2>/dev/null | grep -q worker; then
    echo "OpenShift AWS cluster detected"
    return 0
  fi

  echo "No worker MachineSets found in openshift-machine-api"
  return 1
}

ocp_aws_create_gpu_machineset() {
  local instance_type="${INSTANCE_TYPE:-g6e.4xlarge}"
  local replicas="${MACHINE_REPLICAS:-1}"
  local volume_size="${NODE_VOLUME_SIZE:-250}"
  local instance_family="${instance_type%%.*}"
  local patch_file="/scripts/machineset-patch.yaml"
  local machine_set
  local source_name
  local machine_set_name
  local machineset_label

  machine_set=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep worker | head -n1)
  source_name=$(oc -n openshift-machine-api get "${machine_set}" -o jsonpath='{.metadata.name}')
  machine_set_name="${source_name/-worker-/-${instance_family}-}"
  machineset_label="${source_name/-worker-/-${instance_type}-}"

  if oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep -q "${instance_family}"; then
    machine_set_name=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep "${instance_family}" | head -n1 | sed 's@.*/@@')
    echo "Exists: machineset ${machine_set_name}"
  else
    echo "Creating: machineset ${machine_set_name} (${instance_type}, replicas=${replicas})"
    oc -n openshift-machine-api get "${machine_set}" -o yaml | \
      sed -e "s/^  name: ${source_name}$/  name: ${machine_set_name}/" \
          -e "s/${source_name}/${machineset_label}/g" \
          -e 's/instanceType: .*/instanceType: '"${instance_type}"'/' \
          -e 's/replicas: .*/replicas: '"${replicas}"'/' | \
      oc apply -f -
  fi

  if [[ -f "${patch_file}" ]]; then
    echo "Patching machinesets.machine.openshift.io/${machine_set_name} with ${patch_file}"
    oc -n openshift-machine-api patch "machinesets.machine.openshift.io/${machine_set_name}" \
      --type=merge --patch-file "${patch_file}"
  fi

  oc -n openshift-machine-api patch "machinesets.machine.openshift.io/${machine_set_name}" \
    --type=merge \
    --patch "{\"spec\":{\"replicas\":${replicas},\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"instanceType\":\"${instance_type}\"}}}}}}"

  echo "Patching machinesets.machine.openshift.io/${machine_set_name} blockDevices volumeSize to ${volume_size}"
  oc -n openshift-machine-api patch "machinesets.machine.openshift.io/${machine_set_name}" \
    --type=json \
    --patch "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/providerSpec/value/blockDevices/0/ebs/volumeSize\",\"value\":${volume_size}}]"

  echo "${machine_set_name}"
}

ocp_create_machineset_autoscale() {
  local machine_min="${1:-1}"
  local machine_max="${2:-4}"
  local machine_set="${3:?machine set name is required}"

  cat <<YAML | oc apply -f -
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${machine_set}
  namespace: openshift-machine-api
spec:
  minReplicas: ${machine_min}
  maxReplicas: ${machine_max}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${machine_set}
YAML
}

ocp_aws_cluster

machine_set_name=$(ocp_aws_create_gpu_machineset)
ocp_create_machineset_autoscale "${MACHINE_MIN:-1}" "${MACHINE_MAX:-4}" "${machine_set_name}"
