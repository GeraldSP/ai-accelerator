#!/bin/bash
set -e

# Default values
LANG=C
TIMEOUT_SECONDS=45
OPERATOR_NS="openshift-gitops-operator"
ARGO_NS="openshift-gitops"
GITOPS_OVERLAY=components/operators/openshift-gitops/operator/overlays/latest/

# shellcheck source=/dev/null
source "$(dirname "$0")/functions.sh"
source "$(dirname "$0")/util.sh"
source "$(dirname "$0")/command_flags.sh" "$@"

apply_firmly(){
  if [ ! -f "${1}/kustomization.yaml" ]; then
    print_error "Please provide a dir with \"kustomization.yaml\""
    return 1
  fi

  # kludge
  until oc kustomize "${1}" --enable-helm | oc apply -f- 2>/dev/null
  do
    echo -n "."
    sleep 5
  done
  echo ""
  # until_true oc apply -k "${1}" 2>/dev/null
}

install_gitops(){
  echo
  echo "Checking if GitOps Operator is already installed and running"
  
  if [[ $(oc get csv -n ${OPERATOR_NS} -l operators.coreos.com/openshift-gitops-operator.${OPERATOR_NS}='' -o jsonpath='{.items[0].status.phase}' 2>/dev/null) == "Succeeded" ]]; then
    echo
    echo "GitOps operator is already installed and running"
  else
    echo
    echo "Installing GitOps Operator."

    apply_firmly ${GITOPS_OVERLAY} 

    # oc wait docs:
    # https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/developer-cli-commands.html#oc-wait
    #
    # kubectl wait docs:
    # https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#wait

    echo -n "Retrieving the InstallPlan name: "
    INSTALL_PLAN_NAME=$(oc get sub openshift-gitops-operator -n ${OPERATOR_NS} -o jsonpath='{.status.installPlanRef.name}')
    echo "$INSTALL_PLAN_NAME was found in the namespace $OPERATOR_NS"

    echo -n "Retrieving the CSV name: "
    CSV_NAME=$(oc get ip $INSTALL_PLAN_NAME -n ${OPERATOR_NS} -o jsonpath='{.spec.clusterServiceVersionNames[0]}')
    echo "$CSV_NAME"

    echo "Waiting for the GitOps Operator installation to complete..."
    oc wait --for jsonpath='{.status.phase}'=Succeeded csv/$CSV_NAME -n ${OPERATOR_NS}

    echo ""
    echo "OpenShift GitOps successfully installed."
  fi
}



bootstrap_cluster(){

  base_dir="bootstrap/overlays"

  # Check if bootstrap_dir is already set
  if [ -n "$BOOTSTRAP_DIR" ]; then
    bootstrap_dir=$BOOTSTRAP_DIR
    test -n "$base_dir/$bootstrap_dir";
    echo "Using bootstrap folder: $bootstrap_dir"
  else
    echo
    PS3="Please enter a number to select a bootstrap folder: "
    
    select bootstrap_dir in $(basename -a $base_dir/*/); 
    do
        test -n "$base_dir/$bootstrap_dir" && break;
        echo ">>> Invalid Selection";
    done

    echo
    echo "Selected: ${bootstrap_dir}"
    echo
  fi

  check_branch
  check_repo
  
  echo "Apply overlay to override default instance"
  kustomize build "${base_dir}/${bootstrap_dir}" | oc apply -f -

  wait_for_openshift_gitops

  echo
  echo "Restart the application-controller to start the sync"
  # Restart is necessary to resolve a bug where apps don't start syncing after they are applied
  oc delete pods -l app.kubernetes.io/name=openshift-gitops-application-controller -n ${ARGO_NS}

  wait_for_openshift_gitops

  route=$(oc get route openshift-gitops-server -o jsonpath='{.spec.host}' -n ${ARGO_NS})
  echo
  echo "GitOps has successfully deployed!  Check the status of the sync here:"
  echo "https://${route}"
}

bootstrap_cluster_manual(){

  base_dir="bootstrap/overlays"
  clusters_dir="clusters/overlays"
  output_dir="manualBootstrap"

  # Check if bootstrap_dir is already set
  if [ -n "$BOOTSTRAP_DIR" ]; then
    bootstrap_dir=$BOOTSTRAP_DIR
    test -n "$base_dir/$bootstrap_dir";
    echo "Using bootstrap folder: $bootstrap_dir"
  else
    echo
    PS3="Please enter a number to select a bootstrap folder: "
    
    select bootstrap_dir in $(basename -a $base_dir/*/); 
    do
        test -n "$base_dir/$bootstrap_dir" && break;
        echo ">>> Invalid Selection";
    done

    echo
    echo "Selected: ${bootstrap_dir}"
    echo
  fi

  # Verify that the corresponding cluster overlay exists
  if [ ! -d "${clusters_dir}/${bootstrap_dir}" ]; then
    echo "Error: Cluster overlay not found at ${clusters_dir}/${bootstrap_dir}"
    echo "Please ensure the cluster overlay exists for the selected bootstrap directory."
    exit 1
  fi

  check_branch
  check_repo
  
  # Create output directory
  echo "Creating output directory: ${output_dir}"
  mkdir -p "${output_dir}"
  
  # Generate YAML files from cluster overlay only (excludes ArgoCD instance)
  # Since ArgoCD is already installed, we only need the cluster configuration
  echo "Generating YAML files from cluster overlay: ${clusters_dir}/${bootstrap_dir}"
  echo "  (ArgoCD instance resources are excluded since ArgoCD is already installed)"
  
  # Generate timestamp suffix (format: YYYYMMDD-HHMMSS)
  timestamp=$(date +"%Y%m%d-%H%M%S")
  output_file="${output_dir}/bootstrap-${bootstrap_dir}-${timestamp}.yaml"
  
  echo
  echo "Running: kustomize build \"${clusters_dir}/${bootstrap_dir}\" --enable-helm"
  echo "Building kustomization..."
  echo "  (Errors and warnings will be shown below, YAML output saved to file)"
  echo
  
  # Build: save YAML to file, show stderr (errors/warnings) in real-time
  # Use a temporary file to capture stderr for error checking
  stderr_log=$(mktemp)
  
  if kustomize build "${clusters_dir}/${bootstrap_dir}" --enable-helm > "${output_file}" 2> "${stderr_log}"; then
    # Show any warnings/errors that were captured
    if [ -s "${stderr_log}" ]; then
      echo "Warnings/Errors during build:"
      cat "${stderr_log}"
      echo
    fi
    
    # Count resources generated
    resource_count=$(grep -c "^kind:" "${output_file}" 2>/dev/null || echo "0")
    file_size=$(wc -l < "${output_file}" 2>/dev/null | tr -d ' ')
    file_size_kb=$(du -h "${output_file}" 2>/dev/null | cut -f1)
    
    echo "✓ Build completed successfully"
    echo "  - Resources generated: ${resource_count}"
    echo "  - Total lines: ${file_size}"
    echo "  - File size: ${file_size_kb}"
    
    # Show resource type breakdown
    echo
    echo "Resource breakdown:"
    grep "^kind:" "${output_file}" 2>/dev/null | sort | uniq -c | sort -rn | while read count kind; do
      echo "  - ${kind}: ${count}"
    done || echo "  (Unable to parse resource types)"
    
    # Clean up temp file
    rm -f "${stderr_log}"
  else
    build_exit_code=$?
    echo "✗ Build failed with exit code: ${build_exit_code}"
    echo
    echo "Error output:"
    cat "${stderr_log}"
    echo
    echo "Check the output file for partial results: ${output_file}"
    rm -f "${stderr_log}"
    exit ${build_exit_code}
  fi
  
  echo
  echo "Generated YAML files have been saved to: ${output_dir}/"
  echo "Main bootstrap file: ${output_file}"
  echo
  echo "You can now apply these files to your cluster manually using:"
  echo "  oc apply -f ${output_file}"
}

# Verify CLI tooling
setup_bin

# In manual mode, only kustomize is needed (no cluster operations)
if [[ "${MANUAL_MODE}" == "true" ]]; then
  check_bin kustomize
  # Execute manual bootstrap (generates YAML only)
  bootstrap_cluster_manual
else
  # Standard mode: full bootstrap with cluster operations
  check_bin oc
  check_bin kustomize
  # check_bin kubeseal
  check_oc_login

  # Verify sealed secrets
  #check_sealed_secret

  # Execute bootstrap functions
  install_gitops
  bootstrap_cluster
fi
