#!/usr/bin/env bash
# Parse sar reports and phase timestamps to produce per-phase bottleneck verdicts.
set -euo pipefail

SAR_DAT="${SAR_DAT:-${RUNNER_TEMP}/sar.dat}"
SAR_REPORTS_DIR="${SAR_REPORTS_DIR:-${RUNNER_TEMP}/sar-reports}"
PHASE_LOG="${PHASE_LOG:-${RUNNER_TEMP}/phase-timestamps.log}"
SUMMARY_FILE="${SUMMARY_FILE:-${RUNNER_TEMP}/bottleneck-summary.txt}"
NPROC="${NPROC:-$(nproc)}"

if [[ ! -f "$PHASE_LOG" ]]; then
  echo "No phase log at $PHASE_LOG" | tee "$SUMMARY_FILE"
  exit 0
fi

if [[ ! -d "$SAR_REPORTS_DIR" ]] && [[ ! -f "$SAR_DAT" ]]; then
  echo "No sar reports or data found" | tee "$SUMMARY_FILE"
  exit 0
fi

# Ensure text reports exist (generate from binary if stop step was skipped).
if [[ ! -f "$SAR_REPORTS_DIR/cpu.txt" ]] && [[ -f "$SAR_DAT" ]]; then
  mkdir -p "$SAR_REPORTS_DIR"
  sar -u -f "$SAR_DAT" > "$SAR_REPORTS_DIR/cpu.txt" 2>/dev/null || true
  sar -r -f "$SAR_DAT" > "$SAR_REPORTS_DIR/memory.txt" 2>/dev/null || true
  sar -d -p -f "$SAR_DAT" > "$SAR_REPORTS_DIR/disk.txt" 2>/dev/null || true
  sar -q -f "$SAR_DAT" > "$SAR_REPORTS_DIR/queue.txt" 2>/dev/null || true
  sar -W -f "$SAR_DAT" > "$SAR_REPORTS_DIR/swap.txt" 2>/dev/null || true
fi

SAR_DATE="$(
  grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{2}' "$SAR_REPORTS_DIR/cpu.txt" 2>/dev/null | head -1 || true
)"
SAR_DATE="${SAR_DATE:-$(date +%m/%d/%y)}"

declare -a PHASE_NAMES=()
declare -a PHASE_STARTS=()
declare -a PHASE_ENDS=()

prev_name=""
prev_start=""
while IFS=',' read -r name epoch; do
  if [[ "$name" == "end" ]]; then
    if [[ -n "$prev_name" ]]; then
      PHASE_NAMES+=("$prev_name")
      PHASE_STARTS+=("$prev_start")
      PHASE_ENDS+=("$epoch")
    fi
    break
  fi
  if [[ -n "$prev_name" ]]; then
    PHASE_NAMES+=("$prev_name")
    PHASE_STARTS+=("$prev_start")
    PHASE_ENDS+=("$epoch")
  fi
  prev_name="$name"
  prev_start="$epoch"
done < "$PHASE_LOG"

metrics_dir="${RUNNER_TEMP}/sar-metrics"
mkdir -p "$metrics_dir"

# Map each sample timestamp (HH:MM:SS) to epoch once.
: > "$metrics_dir/times.map"
grep -hE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' "$SAR_REPORTS_DIR"/*.txt 2>/dev/null \
  | awk '{print $1}' | sort -u | while read -r sample_time; do
  sample_epoch=$(date -d "${SAR_DATE} ${sample_time}" '+%s' 2>/dev/null || echo 0)
  echo "${sample_time} ${sample_epoch}" >> "$metrics_dir/times.map"
done

# CPU: epoch user_pct system_pct iowait_pct idle_pct
awk -v mapfile="$metrics_dir/times.map" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, f, " ")
      epoch[f[1]] = f[2]
    }
    close(mapfile)
  }
  $2 == "all" && $1 in epoch {
    print epoch[$1], ($3 + $5), ($6 + 0), ($8 + 0)
  }
' "$SAR_REPORTS_DIR/cpu.txt" > "$metrics_dir/cpu"

# Queue: epoch runq load1
awk -v mapfile="$metrics_dir/times.map" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, f, " ")
      epoch[f[1]] = f[2]
    }
    close(mapfile)
  }
  $1 in epoch && $2 ~ /^[0-9]/ {
    print epoch[$1], ($2 + 0), ($4 + 0)
  }
' "$SAR_REPORTS_DIR/queue.txt" > "$metrics_dir/queue"

# Memory: epoch memused_pct commit_pct
awk -v mapfile="$metrics_dir/times.map" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, f, " ")
      epoch[f[1]] = f[2]
    }
    close(mapfile)
  }
  $1 in epoch && $5 ~ /^[0-9]/ {
    print epoch[$1], ($5 + 0), ($9 + 0)
  }
' "$SAR_REPORTS_DIR/memory.txt" > "$metrics_dir/mem"

# Swap: epoch pswpin pswpout
awk -v mapfile="$metrics_dir/times.map" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, f, " ")
      epoch[f[1]] = f[2]
    }
    close(mapfile)
  }
  $1 in epoch && $2 ~ /^[0-9]/ {
    print epoch[$1], ($2 + 0), ($3 + 0)
  }
' "$SAR_REPORTS_DIR/swap.txt" > "$metrics_dir/swap"

# Disk: max util/await per timestamp across real block devices (skip loop*).
awk -v mapfile="$metrics_dir/times.map" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, f, " ")
      epoch[f[1]] = f[2]
    }
    close(mapfile)
  }
  $1 in epoch {
    dev = $NF
    if (dev ~ /^loop/ || dev == "DEV") next
    ts = epoch[$1]
    util = $(NF - 1) + 0
    await = $(NF - 2) + 0
    gsub(/%/, "", util)
    if (util > max_util[ts]) max_util[ts] = util
    if (await > max_await[ts]) max_await[ts] = await
  }
  END {
    for (ts in max_util) print ts, max_util[ts], max_await[ts]
  }
' "$SAR_REPORTS_DIR/disk.txt" | sort -n > "$metrics_dir/disk"

peaks_for_phase() {
  local start="$1"
  local end="$2"
  local file="$3"
  awk -v s="$start" -v e="$end" '$1 >= s && $1 < e { print }' "$file"
}

analyze_phase() {
  local phase="$1"
  local start="$2"
  local end="$3"

  read -r peak_cpu peak_iowait < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/cpu" | awk '
      { if ($2 > max_cpu) max_cpu = $2; if ($3 > max_io) max_io = $3 }
      END { printf "%.1f %.1f\n", max_cpu + 0, max_io + 0 }
    '
  )

  read -r peak_runq peak_load1 < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/queue" | awk '
      { if ($2 > max_runq) max_runq = $2; if ($3 > max_load) max_load = $3 }
      END { printf "%.0f %.2f\n", max_runq + 0, max_load + 0 }
    '
  )

  read -r peak_disk_util peak_disk_await < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/disk" | awk '
      { if ($2 > max_u) max_u = $2; if ($3 > max_a) max_a = $3 }
      END { printf "%.1f %.1f\n", max_u + 0, max_a + 0 }
    '
  )

  read -r peak_memused peak_commit < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/mem" | awk '
      { if ($2 > max_m) max_m = $2; if ($3 > max_c) max_c = $3 }
      END { printf "%.1f %.1f\n", max_m + 0, max_c + 0 }
    '
  )

  read -r peak_swap_in peak_swap_out < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/swap" | awk '
      { if ($2 > max_in) max_in = $2; if ($3 > max_out) max_out = $3 }
      END { printf "%.2f %.2f\n", max_in + 0, max_out + 0 }
    '
  )

  peak_cpu=${peak_cpu:-0}
  peak_iowait=${peak_iowait:-0}
  peak_runq=${peak_runq:-0}
  peak_load1=${peak_load1:-0}
  peak_disk_util=${peak_disk_util:-0}
  peak_disk_await=${peak_disk_await:-0}
  peak_memused=${peak_memused:-0}
  peak_commit=${peak_commit:-0}
  peak_swap_in=${peak_swap_in:-0}
  peak_swap_out=${peak_swap_out:-0}

  local sample_count
  sample_count=$(peaks_for_phase "$start" "$end" "$metrics_dir/cpu" | wc -l | tr -d ' ')

  local verdict="INCONCLUSIVE"
  local reason="insufficient saturation signal"

  case "$phase" in
    cpu)
      if awk -v c="$peak_cpu" 'BEGIN { exit !(c >= 80) }'; then
        verdict="CPU-bound"
        reason="peak cpu=${peak_cpu}% (user+system), load1=${peak_load1}, runq=${peak_runq}, iowait=${peak_iowait}%"
      elif awk -v l="$peak_load1" -v n="$NPROC" 'BEGIN { exit !(l > n) }'; then
        verdict="CPU-bound"
        reason="load1=${peak_load1} > nproc=${NPROC}, peak cpu=${peak_cpu}%, runq=${peak_runq}"
      else
        reason="peak cpu=${peak_cpu}%, load1=${peak_load1}, runq=${peak_runq} (${sample_count} sar samples in window)"
      fi
      ;;
    memory)
      if awk -v si="$peak_swap_in" -v so="$peak_swap_out" \
        'BEGIN { exit !(si > 0.01 || so > 0.01) }'; then
        verdict="RAM-bound"
        reason="swap in/out=${peak_swap_in}/${peak_swap_out}/s, memused=${peak_memused}%, commit=${peak_commit}%"
      elif awk -v co="$peak_commit" 'BEGIN { exit !(co >= 90) }'; then
        verdict="RAM-bound"
        reason="peak commit=${peak_commit}%, memused=${peak_memused}%"
      elif awk -v m="$peak_memused" 'BEGIN { exit !(m >= 40) }'; then
        verdict="RAM-pressure"
        reason="peak memused=${peak_memused}%, commit=${peak_commit}% (no swap observed)"
      else
        reason="peak memused=${peak_memused}%, commit=${peak_commit}%"
      fi
      ;;
    disk)
      if awk -v u="$peak_disk_util" -v w="$peak_iowait" -v a="$peak_disk_await" \
        'BEGIN { exit !(u >= 80 || (w >= 5 && a >= 10) || a >= 20) }'; then
        verdict="IO-bound"
        reason="peak disk util=${peak_disk_util}%, await=${peak_disk_await}ms, iowait=${peak_iowait}%"
      elif awk -v u="$peak_disk_util" -v a="$peak_disk_await" \
        'BEGIN { exit !(u >= 50 || a >= 10) }'; then
        verdict="IO-pressure"
        reason="peak disk util=${peak_disk_util}%, await=${peak_disk_await}ms, iowait=${peak_iowait}%"
      else
        reason="peak disk util=${peak_disk_util}%, await=${peak_disk_await}ms, iowait=${peak_iowait}%"
      fi
      ;;
  esac

  echo "## Phase: $phase"
  echo "VERDICT: $verdict ($reason)"
  echo ""
}

: > "$SUMMARY_FILE"
{
  echo "# Resource bottleneck summary"
  echo "nproc=${NPROC}"
  echo "sar_date=${SAR_DATE}"
  echo ""
  for i in "${!PHASE_NAMES[@]}"; do
    analyze_phase "${PHASE_NAMES[$i]}" "${PHASE_STARTS[$i]}" "${PHASE_ENDS[$i]}"
  done
} | tee "$SUMMARY_FILE"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "# Resource Monitor Demo Results"
    echo ""
    cat "$SUMMARY_FILE"
    echo ""
    echo "Full sar reports are in the workflow artifact."
  } >> "$GITHUB_STEP_SUMMARY"
fi
