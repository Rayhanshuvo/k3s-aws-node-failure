#!/usr/bin/env bash
# Runs ON THE MASTER. Every second, logs (only when something changes):
#   - the Ready status of each node
#   - the pod IPs currently behind the whoami Service (EndpointSlice, ready endpoints only)
# Lines start with a Unix timestamp so scripts/timeline.py can line them up with the load test.
# Usage: watch-cluster.sh <seconds>
DURATION=${1:-180}
prev_nodes=""; prev_eps=""
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date +%s.%N)
  nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')
  eps=$(kubectl get endpointslices -l kubernetes.io/service-name=whoami \
        -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}@{.nodeName} {end}' 2>/dev/null \
        | tr ' ' '\n' | sort | tr '\n' ' ')
  if [ "$nodes" != "$prev_nodes" ]; then echo "$now NODES $nodes"; prev_nodes=$nodes; fi
  if [ "$eps" != "$prev_eps" ]; then echo "$now ENDPOINTS $eps"; prev_eps=$eps; fi
  sleep 1
done
