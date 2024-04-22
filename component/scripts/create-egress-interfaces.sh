#!/bin/bash

set -eo pipefail

export KUBECONFIG="%(kubelet_kubeconfig)s"

readonly shadow_data=$(kubectl -n "%(cm_namespace)s" get configmap "%(cm_name)s" -ojsonpath="{.data.${HOSTNAME}}")

for prefix in $(echo "$shadow_data" | jq -r '.|keys[]'); do
  base=$(echo "$shadow_data" | jq -r ".${prefix}.base")
  from=$(echo "$shadow_data" | jq -r ".${prefix}.from")
  to=$(echo "$shadow_data" | jq -r ".${prefix}.to")
  echo "Configuring dummy interfaces for egress range ${prefix}: base=${base}, from=${from}, to=${to}"
  for suffix in $(seq "$from" "$to"); do
    idx=$(("$suffix" - "$from"))
    iface="${prefix}_${idx}"
    ip l del "$iface" 2>/dev/null || true
    ip l add "$iface" type dummy
    ip a add "${base}.${suffix}" dev "$iface"
  done
done

exit 0
