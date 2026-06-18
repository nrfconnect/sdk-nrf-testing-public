#!/usr/bin/env bash
# Mark the start of a profiled step (call between commands in profile_script).
resource_monitor_mark() {
  echo "$1,$(date +%s)" >> "${PHASE_LOG:?}"
}
