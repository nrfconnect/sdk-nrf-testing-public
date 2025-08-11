#!/usr/bin/env bash
set -euo pipefail

# --- Usage check ---
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <outdir> <subset>"
    echo "Example: $0 twister_build 5/40"
    exit 1
fi

OUTDIR=$1
SUBSET=$2

EXTRA_FLAGS=""
NRFUTIL=""
OS="$(uname)"
TOOLCHAIN_BUNDLE_ID=$(./nrf/scripts/print_toolchain_checksum.sh)

echo "Detected OS: $OS"
echo "Toolchain bundle: $TOOLCHAIN_BUNDLE_ID"
echo "Using subset: $SUBSET"
echo "Output dir: $OUTDIR"

# Detect OS and set OS-specific commands
case "$(uname -s)" in
    MINGW*)
        EXTRA_FLAGS="--short-build-path --quarantine-list nrf\\scripts\\quarantine_windows_mac.yaml --no-detailed-test-id"
        export PYTHONUTF8=1
        NRFUTIL="../nrfutil.exe sdk-manager toolchain launch --toolchain-bundle-id $TOOLCHAIN_BUNDLE_ID -- python zephyr\\scripts\\twister"
        ;;
    Linux*)
        sudo apt-get update && sudo apt-get install gcc-multilib
        EXTRA_FLAGS="--jobs 8"
        NRFUTIL="../nrfutil sdk-manager toolchain launch --toolchain-bundle-id $TOOLCHAIN_BUNDLE_ID -- python zephyr/scripts/twister"
        ;;
    Darwin*)
        EXTRA_FLAGS="--quarantine-list nrf/scripts/quarantine_windows_mac.yaml"
        NRFUTIL="sudo ../nrfutil sdk-manager toolchain launch --toolchain-bundle-id $TOOLCHAIN_BUNDLE_ID -- python zephyr/scripts/twister"
        ;;
    *)
        echo "Unsupported OS: $(uname -s)"
        exit 1
        ;;
esac

set -x
$NRFUTIL --ninja --inline-logs --verbose --overflow-as-errors --integration \
  --retry-build-errors \
  --quarantine-list nrf/scripts/quarantine.yaml \
  --subset "$SUBSET" --outdir "$OUTDIR" --report-dir results_samples \
  -T nrf/samples -T nrf/applications $EXTRA_FLAGS
