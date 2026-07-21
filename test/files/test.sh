#!/bin/bash

# requires a k8s cluster running with cert-manager running in it
# requires kind https://github.com/kubernetes-sigs/kind

set -o errexit

waitForMetrics() {
    for i in $(seq 1 10); do
        if curl --silent --fail http://localhost:8080/metrics > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "ERROR: metrics endpoint not ready after 10 seconds"
    exit 1
}

fetchMetrics() {
    curl --silent http://localhost:8080/metrics
}

# assertMetricLine fails the script with a clear message when a metrics line is missing.
# Bare `grep` under `set -e` exits silently on no match — never use that for assertions.
# Retries briefly so concurrent checkers can finish updating shared gauges.
assertMetricLine() {
    local needle
    local metrics
    local match
    local i
    needle="$1"
    metrics="${2:-}"

    for i in $(seq 1 20); do
        if [ -z "$metrics" ] || [ "$i" -gt 1 ]; then
            metrics=$(fetchMetrics)
        fi

        # Prefer an exact sample line (not HELP/TYPE comments).
        match=$(printf '%s\n' "$metrics" | grep -E "^${needle}([[:space:]]|$)" || true)
        if [ -z "$match" ]; then
            match=$(printf '%s\n' "$metrics" | grep -F "$needle" || true)
        fi

        if [ -n "$match" ]; then
            echo "TEST SUCCESS: $match"
            return 0
        fi
        sleep 0.1
    done

    echo "TEST FAILURE: missing metrics line matching: $needle"
    echo "  Relevant metrics output:"
    printf '%s\n' "$metrics" | grep -E '^(cert_exporter_discovered|cert_exporter_error_total|# HELP cert_exporter_discovered|# HELP cert_exporter_error_total)' || true
    echo "  Full metrics dump follows:"
    printf '%s\n' "$metrics"
    exit 1
}

fetchMetricsTimestampValue() {
    local metrics
    metrics="$1"

    curl --silent http://localhost:8080/metrics \
    | grep -F "$metrics" \
    | awk '{ printf("%.0f",$2) }' || true
}

validateTimestampBefore() {
    local metrics
    local want
    local got
    metrics="$1"
    want="$2"
    got=$(fetchMetricsTimestampValue "$metrics")

    if [ "$got" == "" ]; then
      echo "TEST FAILURE: $metrics" 
      echo "  Unable to find metrics string"
      return 0
    fi

    if [ "$got" -ge "$want" ]; then
      echo "TEST FAILURE: $metrics"
      echo "  Want      : $want"
      echo "  Got       : $got"
    else 
      echo "TEST SUCCESS: $metrics"
    fi
}

validateMetrics() {
    local metrics
    local expectedVal
    local raw
    local val
    local valInDays
    metrics=$1
    expectedVal=$2

    # grep returns 1 when there is no match; do not trip set -e
    raw=$(curl --silent http://localhost:8080/metrics | grep "$metrics" || true)

    if [ "$raw" == "" ]; then
      echo "TEST FAILURE: $metrics" 
      echo "  Unable to find metrics string"
      return 0
    fi

    val=${raw#* }
    valInDays=$(awk "BEGIN {printf \"%.0f\", $val / (24 * 60 * 60)}")

    if [ "$expectedVal" -ne "$valInDays" ]; then
      echo "TEST FAILURE: $metrics"
      echo "  Expected  : $expectedVal"
      echo "  Raw       : $raw"
      echo "  Val       : $val"
      echo "  ValInDays : $valInDays"
    else 
      echo "TEST SUCCESS: $metrics"
    fi
}

# cleanup certs
./testCleanup.sh

# Resolve the goreleaser binary path. amd64 builds use a microarchitecture
# suffix (_v1); arm64 often does not. Prefer the conventional _v1 path, then
# fall back to the unsuffixed layout.
resolve_cert_exporter() {
    local os arch base
    os="$(go env GOOS)"
    arch="$(go env GOARCH)"
    base="../../dist"
    for candidate in \
        "${base}/cert-exporter_${os}_${arch}_v1/cert-exporter" \
        "${base}/cert-exporter_${os}_${arch}/cert-exporter"
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "ERROR: cert-exporter binary not found under ${base}/cert-exporter_${os}_${arch}*/" >&2
    ls -la "${base}" 2>/dev/null || true
    return 1
}

stop_exporter() {
    local pid=$1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        # Wait for the process (and :8080) to go away so the next run can bind
        for _ in $(seq 1 20); do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

CERT_EXPORTER_PATH="$(resolve_cert_exporter)"

days=${1:-100}
export NODE_NAME="master0"
exporter_pid=""

#
# certs and kubeconfig in the same dir
#
echo "** Testing Certs and kubeconfig in the same dir"
mkdir certs
./genCerts.sh certs $days >/dev/null 2>&1
./genKubeConfig.sh certs ./ >/dev/null 2>&1


# run exporter
$CERT_EXPORTER_PATH -include-cert-glob=certs/*.crt  -include-kubeconfig-glob=certs/kubeconfig &
exporter_pid=$!

waitForMetrics

# 5 cert files (*.crt) + 1 kubeconfig file; concurrent checkers accumulate.
metrics=$(fetchMetrics)
assertMetricLine 'cert_exporter_discovered 6' "$metrics"
assertMetricLine 'cert_exporter_error_total 0' "$metrics"

activation=$(date +%s) # this timestamp is at least 2 seconds off from the actual cert NotBefore attribute ...
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="client",filename="certs/client.crt",issuer="root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="root",filename="certs/root.crt",issuer="root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="example.com",filename="certs/server.crt",issuer="root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="bundle-root",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="example-bundle.be",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="bundle-root",filename="certs/bundle_pfx.crt",issuer="bundle-root",nodename="master0"}' $activation

expiration=$((activation + days * 24 * 60 * 60)) # ... and as a result, this values if off as well
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="client",filename="certs/client.crt",issuer="root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="root",filename="certs/root.crt",issuer="root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="example.com",filename="certs/server.crt",issuer="root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="bundle-root",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="example-bundle.be",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="bundle-root",filename="certs/bundle_pfx.crt",issuer="bundle-root",nodename="master0"}' $expiration

validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="client",filename="certs/client.crt",issuer="root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="root",filename="certs/root.crt",issuer="root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="example.com",filename="certs/server.crt",issuer="root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="bundle-root",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="example-bundle.be",filename="certs/bundle.crt",issuer="bundle-root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="bundle-root",filename="certs/bundle_pfx.crt",issuer="bundle-root",nodename="master0"}' $days


validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="root",filename="certs/kubeconfig",issuer="root",name="cluster1",nodename="master0",type="cluster"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="root",filename="certs/kubeconfig",issuer="root",name="cluster2",nodename="master0",type="cluster"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="client",filename="certs/kubeconfig",issuer="root",name="user1",nodename="master0",type="user"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="client",filename="certs/kubeconfig",issuer="root",name="user2",nodename="master0",type="user"}' $days

# kill exporter
stop_exporter "$exporter_pid"

#
# certs and kubeconfig in sibling dirs
#
echo "** Testing Certs and kubeconfig in sibling dirs"
mkdir certsSibling
mkdir kubeConfigSibling
./genCerts.sh certsSibling $days >/dev/null 2>&1
./genKubeConfig.sh kubeConfigSibling ../certsSibling >/dev/null 2>&1

# run exporter
$CERT_EXPORTER_PATH -include-cert-glob=certsSibling/*.crt  -include-kubeconfig-glob=kubeConfigSibling/kubeconfig &
exporter_pid=$!

waitForMetrics

# 5 cert files + 1 kubeconfig (sibling layout)
metrics=$(fetchMetrics)
assertMetricLine 'cert_exporter_discovered 6' "$metrics"
assertMetricLine 'cert_exporter_error_total 0' "$metrics"

activation=$(date +%s) # this timestamp is at least 2 seconds off from the actual cert NotBefore attribute ...
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="client",filename="certsSibling/client.crt",issuer="root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="root",filename="certsSibling/root.crt",issuer="root",nodename="master0"}' $activation
validateTimestampBefore 'cert_exporter_cert_not_before_timestamp{cn="example.com",filename="certsSibling/server.crt",issuer="root",nodename="master0"}' $activation

expiration=$((activation + days * 24 * 60 * 60)) # ... and as a result, this values if off as well
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="client",filename="certsSibling/client.crt",issuer="root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="root",filename="certsSibling/root.crt",issuer="root",nodename="master0"}' $expiration
validateTimestampBefore 'cert_exporter_cert_not_after_timestamp{cn="example.com",filename="certsSibling/server.crt",issuer="root",nodename="master0"}' $expiration

validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="client",filename="certsSibling/client.crt",issuer="root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="root",filename="certsSibling/root.crt",issuer="root",nodename="master0"}' $days
validateMetrics 'cert_exporter_cert_expires_in_seconds{cn="example.com",filename="certsSibling/server.crt",issuer="root",nodename="master0"}' $days

validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="root",filename="kubeConfigSibling/kubeconfig",issuer="root",name="cluster1",nodename="master0",type="cluster"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="root",filename="kubeConfigSibling/kubeconfig",issuer="root",name="cluster2",nodename="master0",type="cluster"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="client",filename="kubeConfigSibling/kubeconfig",issuer="root",name="user1",nodename="master0",type="user"}' $days
validateMetrics 'cert_exporter_kubeconfig_expires_in_seconds{cn="client",filename="kubeConfigSibling/kubeconfig",issuer="root",name="user2",nodename="master0",type="user"}' $days

# kill exporter
stop_exporter "$exporter_pid"

#
# confirm error metric works
#
echo "** Testing Error metric increments"
echo 'asdfasdf' > certs/client.crt

# run exporter
$CERT_EXPORTER_PATH -include-cert-glob=certs/client.crt &
exporter_pid=$!

waitForMetrics

assertMetricLine 'cert_exporter_error_total 1'
assertMetricLine 'cert_exporter_discovered 1'

# kill exporter
stop_exporter "$exporter_pid"
unset NODE_NAME
