#!/usr/bin/env bash
# Start/stop sar background collection and emit text reports.
set -euo pipefail

SAR_DAT="${SAR_DAT:-${RUNNER_TEMP}/sar.dat}"
SAR_REPORTS_DIR="${SAR_REPORTS_DIR:-${RUNNER_TEMP}/sar-reports}"
SAR_INTERVAL="${SAR_INTERVAL:-10}"

start_monitor() {
  mkdir -p "$(dirname "$SAR_DAT")"
  echo "MONITOR_START_EPOCH=$(date +%s)" >> "${GITHUB_ENV:?GITHUB_ENV must be set}"
  echo "SAR_INTERVAL=$SAR_INTERVAL" >> "$GITHUB_ENV"
  sar -o "$SAR_DAT" "$SAR_INTERVAL" >/dev/null 2>&1 &
  echo "SAR_PID=$!" >> "${GITHUB_ENV:?GITHUB_ENV must be set}"
  echo "SAR_DAT=$SAR_DAT" >> "$GITHUB_ENV"
  echo "SAR_REPORTS_DIR=$SAR_REPORTS_DIR" >> "$GITHUB_ENV"
}

stop_monitor() {
  if [[ -n "${SAR_PID:-}" ]]; then
    kill "$SAR_PID" 2>/dev/null || true
    wait "$SAR_PID" 2>/dev/null || true
  fi

  if [[ ! -f "$SAR_DAT" ]]; then
    echo "No sar data file at $SAR_DAT"
    return 0
  fi

  mkdir -p "$SAR_REPORTS_DIR"
  sar -u -f "$SAR_DAT" > "$SAR_REPORTS_DIR/cpu.txt" 2>/dev/null || true
  sar -r -f "$SAR_DAT" > "$SAR_REPORTS_DIR/memory.txt" 2>/dev/null || true
  sar -d -p -f "$SAR_DAT" > "$SAR_REPORTS_DIR/disk.txt" 2>/dev/null || true
  sar -q -f "$SAR_DAT" > "$SAR_REPORTS_DIR/queue.txt" 2>/dev/null || true
  sar -W -f "$SAR_DAT" > "$SAR_REPORTS_DIR/swap.txt" 2>/dev/null || true
}

case "${1:-}" in
  start) start_monitor ;;
  stop) stop_monitor ;;
  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 1
    ;;
esac
