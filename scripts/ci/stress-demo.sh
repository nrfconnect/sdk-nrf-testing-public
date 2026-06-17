#!/usr/bin/env bash
# Demo workloads that stress CPU, memory, or disk IO.
set -euo pipefail

STRESS_DURATION="${STRESS_DURATION:-45}"
STRESS_IO_DIR="${STRESS_IO_DIR:-${GITHUB_WORKSPACE}/.stress-io}"

stress_cpu() {
  stress-ng --cpu "$(nproc)" --cpu-method all --timeout "${STRESS_DURATION}s"
}

stress_memory() {
  stress-ng --vm 2 --vm-bytes 75% --vm-keep --timeout "${STRESS_DURATION}s"
}

stress_disk() {
  mkdir -p "$STRESS_IO_DIR"
  fio --name=demo-randwrite \
    --directory="$STRESS_IO_DIR" \
    --ioengine=libaio \
    --direct=1 \
    --rw=randwrite \
    --bs=4k \
    --numjobs=4 \
    --iodepth=32 \
    --size=2G \
    --runtime="${STRESS_DURATION}" \
    --time_based \
    --group_reporting \
    --filename_format='fio.$jobnum'
}

case "${1:-}" in
  cpu) stress_cpu ;;
  memory) stress_memory ;;
  disk) stress_disk ;;
  *)
    echo "Usage: $0 {cpu|memory|disk}" >&2
    exit 1
    ;;
esac
