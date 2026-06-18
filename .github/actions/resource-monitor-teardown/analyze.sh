#!/usr/bin/env bash
# Summarize peak CPU, RAM, and disk utilization per marked step.
set -euo pipefail

SAR_REPORTS_DIR="${SAR_REPORTS_DIR:?}"
SUMMARY_FILE="${SUMMARY_FILE:?}"
PHASE_LOG="${PHASE_LOG:-}"

if [[ ! -f "$SAR_REPORTS_DIR/cpu.txt" ]]; then
  echo "No sar CPU report at $SAR_REPORTS_DIR/cpu.txt" | tee "$SUMMARY_FILE"
  exit 0
fi

SAR_DATE="$(grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{2}' "$SAR_REPORTS_DIR/cpu.txt" 2>/dev/null | head -1 || date +%m/%d/%y)"

declare -a STEP_NAMES=() STEP_STARTS=() STEP_ENDS=()

if [[ -f "$PHASE_LOG" ]]; then
  prev_name="" prev_start=""
  while IFS=',' read -r name epoch; do
    if [[ "$name" == "end" ]]; then
      if [[ -n "$prev_name" ]]; then
        STEP_NAMES+=("$prev_name")
        STEP_STARTS+=("$prev_start")
        STEP_ENDS+=("$epoch")
      fi
      break
    fi
    if [[ -n "$prev_name" ]]; then
      STEP_NAMES+=("$prev_name")
      STEP_STARTS+=("$prev_start")
      STEP_ENDS+=("$epoch")
    fi
    prev_name="$name"
    prev_start="$epoch"
  done < "$PHASE_LOG"
fi

if [[ ${#STEP_NAMES[@]} -eq 0 ]]; then
  STEP_NAMES=("job")
  STEP_STARTS=(0)
  STEP_ENDS=(2147483647)
fi

metrics_dir="${RUNNER_TEMP}/sar-metrics"
mkdir -p "$metrics_dir"

: > "$metrics_dir/times.map"
grep -hE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' "$SAR_REPORTS_DIR"/*.txt 2>/dev/null \
  | awk '{print $1}' | sort -u | while read -r sample_time; do
  sample_epoch=$(date -d "${SAR_DATE} ${sample_time}" '+%s' 2>/dev/null || echo 0)
  echo "${sample_time} ${sample_epoch}" >> "$metrics_dir/times.map"
done

awk -v mapfile="$metrics_dir/times.map" '
  BEGIN { while ((getline line < mapfile) > 0) { split(line, f, " "); epoch[f[1]] = f[2] }; close(mapfile) }
  $2 == "all" && $1 in epoch { print epoch[$1], ($3 + $5) }
' "$SAR_REPORTS_DIR/cpu.txt" > "$metrics_dir/cpu"

awk -v mapfile="$metrics_dir/times.map" '
  BEGIN { while ((getline line < mapfile) > 0) { split(line, f, " "); epoch[f[1]] = f[2] }; close(mapfile) }
  $1 in epoch && $5 ~ /^[0-9]/ { print epoch[$1], ($5 + 0) }
' "$SAR_REPORTS_DIR/memory.txt" > "$metrics_dir/mem"

awk -v mapfile="$metrics_dir/times.map" '
  BEGIN { while ((getline line < mapfile) > 0) { split(line, f, " "); epoch[f[1]] = f[2] }; close(mapfile) }
  $1 in epoch {
    dev = $NF; if (dev ~ /^loop/ || dev == "DEV") next
    ts = epoch[$1]; util = $(NF - 1) + 0; gsub(/%/, "", util)
    if (util > max_util[ts]) max_util[ts] = util
  }
  END { for (ts in max_util) print ts, max_util[ts] }
' "$SAR_REPORTS_DIR/disk.txt" | sort -n > "$metrics_dir/disk"

peak_in_window() {
  local start="$1" end="$2" file="$3" col="$4"
  awk -v s="$start" -v e="$end" -v c="$col" '
    $1 >= s && $1 < e { if ($c > m) m = $c }
    END { printf "%.0f", m + 0 }
  ' "$file"
}

report_step() {
  local name="$1" start="$2" end="$3"
  local cpu ram disk
  cpu=$(peak_in_window "$start" "$end" "$metrics_dir/cpu" 2)
  ram=$(peak_in_window "$start" "$end" "$metrics_dir/mem" 2)
  disk=$(peak_in_window "$start" "$end" "$metrics_dir/disk" 2)
  echo "## ${name}"
  echo "CPU:${cpu}%. RAM:${ram}%. DISK:${disk}%."
  echo ""
}

: > "$SUMMARY_FILE"
{
  echo "# Resource utilization summary"
  echo "sar_date=${SAR_DATE}"
  echo ""
  for i in "${!STEP_NAMES[@]}"; do
    report_step "${STEP_NAMES[$i]}" "${STEP_STARTS[$i]}" "${STEP_ENDS[$i]}"
  done
} | tee "$SUMMARY_FILE"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "# Resource utilization"
    echo ""
    cat "$SUMMARY_FILE"
    echo ""
    echo "Full sar reports are in the workflow artifact."
  } >> "$GITHUB_STEP_SUMMARY"
fi
