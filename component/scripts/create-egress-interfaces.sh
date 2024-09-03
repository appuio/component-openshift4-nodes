#!/bin/bash

set -eo pipefail

readonly patched_kubeconfig="/tmp/kubeconfig"

# Patch node kubeconfig to use api.<cluster-domain> instead of
# `api-int.<cluster-domain>` so that the script works on clusters which
# provide the api-int record via in-cluster CoreDNS. This assumes that the
# public API endpoint has a certificate that's issued by a public CA that's
# part of the node's trusted CA certs.
sed -e 's/api-int/api/;/certificate-authority-data/d' "%(kubelet_kubeconfig)s" > "$patched_kubeconfig"
export KUBECONFIG="${patched_kubeconfig}"

shadow_data=$(kubectl -n "%(cm_namespace)s" get configmap "%(cm_name)s" -ojsonpath="{.data.${HOSTNAME}}")
readonly shadow_data

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

rm "${patched_kubeconfig}"

exit 0
