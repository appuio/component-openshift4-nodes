#!/bin/bash
set -exo pipefail

for pool in $(kubectl get machineconfigpool -ojson | jq -r '.items[].metadata.name'); do
  oc adm prune renderedmachineconfigs list --pool-name="$pool" |\
    grep 'in use: false' |\
    # keep 5 newest mc
    head -n-5 |\
    cut -d' ' -f1 |\
    while read -r mc; do
      kubectl delete machineconfig "$mc"
    done
done
