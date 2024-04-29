#!/usr/bin/env bash

ocp_aws_cluster(){
    echo "Checking if secret/aws-creds exists in kube-system namespace"
    oc -n kube-system get secret/aws-creds -o name > /dev/null 2>&1 || return 1
}

ocp_aws_create_gpu_machineset(){
    # https://aws.amazon.com/ec2/instance-types/g4
    # single gpu: g4dn.{2,4,8,16}xlarge
    # multi gpu: g4dn.12xlarge
    # cheapest: g4ad.4xlarge
    # a100 (MIG): p4d.24xlarge
    # h100 (MIG): p5.48xlarge
    INSTANCE_TYPE=${1:-g4dn.4xlarge}
    MACHINE_SET=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep worker | head -n1)

    # check for an existing gpu machine set
    if oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep gpu; then
        echo "Exists: GPU machineset"
    else
        echo "Creating: GPU machineset"
        oc -n openshift-machine-api get "${MACHINE_SET}" -o yaml | \
        sed '/machine/ s/-worker/-gpu/g
            /name/ s/-worker/-gpu/g
            s/instanceType.*/instanceType: '"${INSTANCE_TYPE}"'/
            s/replicas.*/replicas: 0/' | \
        oc apply -f -
    fi

    MACHINE_SET_GPU=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep gpu | head -n1)

    echo "Patching: GPU machineset"

    # cosmetic
    oc -n openshift-machine-api \
        patch "${MACHINE_SET_GPU}" \
        --type=merge --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"node-role.kubernetes.io/gpu":""}}}}}}'

    # taint nodes for gpu-only workloads
    oc -n openshift-machine-api \
        patch "${MACHINE_SET_GPU}" \
        --type=merge --patch '{"spec":{"template":{"spec":{"taints":[{"key":"nvidia-gpu-only","value":"","effect":"NoSchedule"}]}}}}'

    # should use the default profile
    # oc -n openshift-machine-api \
    #   patch "${MACHINE_SET_GPU}" \
    #   --type=merge --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"nvidia.com/device-plugin.config":"no-time-sliced"}}}}}}'

    # should help auto provisioner
    oc -n openshift-machine-api \
        patch "${MACHINE_SET_GPU}" \
        --type=merge --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"cluster-api/accelerator":"nvidia-gpu"}}}}}}'

        oc -n openshift-machine-api \
        patch "${MACHINE_SET_GPU}" \
        --type=merge --patch '{"metadata":{"labels":{"cluster-api/accelerator":"nvidia-gpu"}}}'

    oc -n openshift-machine-api \
        patch "${MACHINE_SET_GPU}" \
        --type=merge --patch '{"spec":{"template":{"spec":{"providerSpec":{"value":{"instanceType":"'"${INSTANCE_TYPE}"'"}}}}}}'
}

ocp_create_machineset_autoscale(){
MACHINE_MIN=${1:-0}
MACHINE_MAX=${2:-4}
MACHINE_SETS=${3:-$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | sed 's@.*/@@' )}

for set in ${MACHINE_SETS}
do
echo "Creation MachineAutoscaler for ${set}"

cat << YAML
apiVersion: "autoscaling.openshift.io/v1beta1"
kind: "MachineAutoscaler"
metadata:
name: "${set}"
namespace: "openshift-machine-api"
spec:
minReplicas: ${MACHINE_MIN}
maxReplicas: ${MACHINE_MAX}
scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: "${set}"
YAML

cat << YAML | oc apply -f -
apiVersion: "autoscaling.openshift.io/v1beta1"
kind: "MachineAutoscaler"
metadata:
name: "${set}"
namespace: "openshift-machine-api"
spec:
minReplicas: ${MACHINE_MIN}
maxReplicas: ${MACHINE_MAX}
scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: "${set}"
YAML
done
}

ocp_aws_cluster || exit 0
ocp_aws_create_gpu_machineset
ocp_create_machineset_autoscale
