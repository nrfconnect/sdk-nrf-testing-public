#!/usr/bin/env bash
# Parse sar.dat and phase timestamps to produce per-phase bottleneck verdicts.
set -euo pipefail

SAR_DAT="${SAR_DAT:-${RUNNER_TEMP}/sar.dat}"
PHASE_LOG="${PHASE_LOG:-${RUNNER_TEMP}/phase-timestamps.log}"
SUMMARY_FILE="${SUMMARY_FILE:-${RUNNER_TEMP}/bottleneck-summary.txt}"
MONITOR_START_EPOCH="${MONITOR_START_EPOCH:-0}"
SAR_INTERVAL="${SAR_INTERVAL:-10}"
NPROC="${NPROC:-$(nproc)}"

if [[ ! -f "$SAR_DAT" ]]; then
  echo "No sar data at $SAR_DAT" | tee "$SUMMARY_FILE"
  exit 0
fi

if [[ ! -f "$PHASE_LOG" ]]; then
  echo "No phase log at $PHASE_LOG" | tee "$SUMMARY_FILE"
  exit 0
fi

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

# Per-sample metrics keyed by estimated epoch (monitor start + index * interval).
sar -u -f "$SAR_DAT" 2>/dev/null | awk -v ms="$MONITOR_START_EPOCH" -v iv="$SAR_INTERVAL" '
  BEGIN { idx = 0 }
  /^[0-9][0-9]:/ && $3 == "all" {
    idx++
    t = ms + (idx - 1) * iv
    print t, ($4 + $6), ($7 + 0)
  }
' > "$metrics_dir/cpu"

sar -q -f "$SAR_DAT" 2>/dev/null | awk -v ms="$MONITOR_START_EPOCH" -v iv="$SAR_INTERVAL" '
  BEGIN { idx = 0 }
  /^[0-9][0-9]:/ && $3 ~ /^[0-9]/ {
    idx++
    t = ms + (idx - 1) * iv
    print t, ($3 + 0)
  }
' > "$metrics_dir/queue"

sar -d -p -f "$SAR_DAT" 2>/dev/null | awk -v ms="$MONITOR_START_EPOCH" -v iv="$SAR_INTERVAL" '
  BEGIN { idx = 0 }
  /^[0-9][0-9]:/ && $3 != "DEV" {
    idx++
    t = ms + (idx - 1) * iv
    util = $(NF - 1)
    await = $NF + 0
    gsub(/%/, "", util)
    if (util > max_util[t]) max_util[t] = util + 0
    if (await > max_await[t]) max_await[t] = await
  }
  END {
    for (t in max_util) print t, max_util[t], max_await[t]
  }
' | sort -n > "$metrics_dir/disk"

sar -r -f "$SAR_DAT" 2>/dev/null | awk -v ms="$MONITOR_START_EPOCH" -v iv="$SAR_INTERVAL" '
  BEGIN { idx = 0 }
  /^[0-9][0-9]:/ && $3 ~ /^[0-9]/ {
    idx++
    t = ms + (idx - 1) * iv
    mem = $4
    commit = $8
    gsub(/%/, "", mem)
    gsub(/%/, "", commit)
    print t, mem + 0, commit + 0
  }
' > "$metrics_dir/mem"

sar -W -f "$SAR_DAT" 2>/dev/null | awk -v ms="$MONITOR_START_EPOCH" -v iv="$SAR_INTERVAL" '
  BEGIN { idx = 0 }
  /^[0-9][0-9]:/ && $3 ~ /^[0-9]/ {
    idx++
    t = ms + (idx - 1) * iv
    print t, ($3 + 0), ($4 + 0)
  }
' > "$metrics_dir/swap"

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

  read -r peak_runq < <(
    peaks_for_phase "$start" "$end" "$metrics_dir/queue" | awk '
      { if ($2 > max) max = $2 }
      END { print max + 0 }
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
  peak_disk_util=${peak_disk_util:-0}
  peak_disk_await=${peak_disk_await:-0}
  peak_memused=${peak_memused:-0}
  peak_commit=${peak_commit:-0}
  peak_swap_in=${peak_swap_in:-0}
  peak_swap_out=${peak_swap_out:-0}

  local verdict="INCONCLUSIVE"
  local reason="insufficient saturation signal"

  case "$phase" in
    cpu)
      if awk -v r="$peak_runq" -v n="$NPROC" -v c="$peak_cpu" 'BEGIN { exit !(r > n || c >= 80) }'; then
        verdict="CPU-bound"
        reason="peak runq=${peak_runq} (nproc=${NPROC}), peak cpu=${peak_cpu}%, peak iowait=${peak_iowait}%"
      else
        reason="peak runq=${peak_runq}, peak cpu=${peak_cpu}% (expected runq>nproc or cpu>=80%)"
      fi
      ;;
    memory)
      if awk -v si="$peak_swap_in" -v so="$peak_swap_out" -v co="$peak_commit" \
        'BEGIN { exit !(si > 0 || so > 0 || co > 100) }'; then
        verdict="RAM-bound"
        reason="peak memused=${peak_memused}%, peak commit=${peak_commit}%, swap in/out=${peak_swap_in}/${peak_swap_out}/s"
      elif awk -v m="$peak_memused" 'BEGIN { exit !(m >= 70) }'; then
        verdict="RAM-pressure"
        reason="peak memused=${peak_memused}%, peak commit=${peak_commit}% (no swap observed)"
      else
        reason="peak memused=${peak_memused}%, peak commit=${peak_commit}%"
      fi
      ;;
    disk)
      if awk -v u="$peak_disk_util" -v w="$peak_iowait" -v a="$peak_disk_await" \
        'BEGIN { s=0; if (u>=80) s++; if (w>=10) s++; if (a>=20) s++; exit !(s>=2) }'; then
        verdict="IO-bound"
        reason="peak disk util=${peak_disk_util}%, peak await=${peak_disk_await}ms, peak iowait=${peak_iowait}%"
      elif awk -v u="$peak_disk_util" -v w="$peak_iowait" -v a="$peak_disk_await" \
        'BEGIN { exit !(u>=50 || w>=5 || a>=10) }'; then
        verdict="IO-pressure"
        reason="peak disk util=${peak_disk_util}%, peak await=${peak_disk_await}ms, peak iowait=${peak_iowait}%"
      else
        reason="peak disk util=${peak_disk_util}%, peak await=${peak_disk_await}ms"
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
  echo "monitor_start_epoch=${MONITOR_START_EPOCH}"
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
