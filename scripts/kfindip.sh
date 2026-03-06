#!/bin/bash

usage() {
  echo "Usage: $0 <ip[:port]>"
  echo ""
  echo "Examples:"
  echo "  $0 10.0.0.5           Search by IP across pods, services, endpoints"
  echo "  $0 10.0.0.5:8080      Search by IP and port"
  echo "  $0 :443               Search by port only"
  exit 0
}

if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
fi

search="$1"

# Split ip:port if colon present
if [[ "$search" == *:* ]]; then
  IP="${search%:*}"
  PORT="${search#*:}"
else
  IP="$search"
  PORT=""
fi

echo "Searching for IP=${IP:-any} PORT=${PORT:-any} across all namespaces..."
echo ""

echo "=== Pods (by podIP and container port) ==="
kubectl get pods --all-namespaces -o json | jq -r --arg ip "$IP" --argjson port "${PORT:-0}" '
  .items[] | select(
    ($ip == "" or .status.podIP == $ip) and
    (if $port > 0 then
      ((.spec.containers // [])[]?.ports // [])[]?.containerPort == $port
    else true end)
  ) |
  [.metadata.namespace,
   .metadata.name,
   .status.podIP,
   .status.phase,
   ((.spec.containers // []) | map(.ports // [] | map(.containerPort | tostring) | join(",")) | join(","))
  ] | @tsv' | \
  column -t

echo ""
echo "=== Pods (by hostIP and hostPort) ==="
kubectl get pods --all-namespaces -o json | jq -r --arg ip "$IP" --argjson port "${PORT:-0}" '
  .items[] | select(
    ($ip == "" or .status.hostIP == $ip) and
    (if $port > 0 then
      ((.spec.containers // [])[]?.ports // [])[]?.hostPort == $port
    else true end)
  ) |
  [.metadata.namespace,
   .metadata.name,
   .status.hostIP,
   .status.phase,
   ((.spec.containers // []) | map(.ports // [] | map("\(.containerPort):\(.hostPort // "")") | join(",")) | join(","))
  ] | @tsv' | \
  column -t

echo ""
echo "=== Services (by ClusterIP, ExternalIP, NodePort, port) ==="
kubectl get svc --all-namespaces -o json | jq -r --arg ip "$IP" --argjson port "${PORT:-0}" '
  .items[] | select(
    ($ip == "" or
      .spec.clusterIP == $ip or
      (.spec.externalIPs // [])[]? == $ip or
      (.status.loadBalancer.ingress // [])[]?.ip == $ip
    ) and
    (if $port > 0 then
      ((.spec.ports // [])[]? |
        .port == $port or
        .nodePort == $port or
        .targetPort == ($port | tostring) or
        .targetPort == $port)
    else true end)
  ) |
  [.metadata.namespace,
   .metadata.name,
   .spec.type,
   .spec.clusterIP,
   ((.spec.ports // []) | map("port=\(.port) nodePort=\(.nodePort // "-") targetPort=\(.targetPort)") | join(" | ")),
   ((.status.loadBalancer.ingress // []) | map(.ip // .hostname) | join(","))
  ] | @tsv' | \
  column -t

echo ""
echo "=== Endpoints (by address IP and port) ==="
kubectl get endpoints --all-namespaces -o json | jq -r --arg ip "$IP" --argjson port "${PORT:-0}" '
  .items[] |
  .metadata.namespace as $ns |
  .metadata.name as $name |
  (.subsets // [])[] |
  . as $subset |
  (.addresses // [])[] |
  select($ip == "" or .ip == $ip) |
  .ip as $addr |
  ($subset.ports // [])[] |
  select($port == 0 or .port == $port) |
  [$ns, $name, $addr, (.port | tostring), .protocol] | @tsv' | \
  column -t

echo ""
echo "=== Nodes (by InternalIP, ExternalIP) ==="
kubectl get nodes -o json | jq -r --arg ip "$IP" '
  .items[] | select(
    $ip == "" or
    (.status.addresses // [])[]?.address == $ip
  ) |
  [.metadata.name,
   ((.status.addresses // []) | map("\(.type)=\(.address)") | join(" | ")),
   (.metadata.labels // {} | to_entries | map(select(.key == "kubernetes.io/role" or .key == "node-role.kubernetes.io/master" or .key == "node-role.kubernetes.io/worker")) | map("\(.key)=\(.value)") | join(","))
  ] | @tsv' | \
  column -t

echo ""
echo "=== Ingresses (by host/IP and port) ==="
kubectl get ingress --all-namespaces -o json | jq -r --arg ip "$IP" --argjson port "${PORT:-0}" '
  .items[] | select(
    $ip == "" or
    (.status.loadBalancer.ingress // [])[]?.ip == $ip
  ) |
  [.metadata.namespace,
   .metadata.name,
   ((.status.loadBalancer.ingress // []) | map(.ip // .hostname) | join(",")),
   ((.spec.rules // []) | map(.host) | join(",")),
   ((.spec.rules // [])[]?.http?.paths // []) | map("\(.path // "/") -> \(.backend.service.name // ""):\(.backend.service.port.number // "")") | join(" | ")
  ] | @tsv' | \
  column -t
