#!/usr/bin/env bash
# =============================================================================
# report.sh - monitor.log 요약 리포트 (보너스 1)
#   사용법: report.sh                              전체 로그
#           report.sh "2026-02-25 13:58" "2026-02-25 14:00"   구간 지정(시작 종료)
#           report.sh "2026-02-25"                  하루치 (종료 생략 시 같은 날 끝까지)
#   입력 형식: YYYY-MM-DD / YYYY-MM-DD HH:MM / YYYY-MM-DD HH:MM:SS
# =============================================================================
set -u

LOG_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"
START="${1:-}"
END="${2:-}"

# 시작/종료 시각을 'YYYY-MM-DD HH:MM:SS' 비교용으로 맞춤 (문자열 비교가 곧 시간순 비교)
norm_start() {
  case "${#1}" in
    10) echo "$1 00:00:00" ;;
    16) echo "$1:00" ;;
    *)  echo "$1" ;;
  esac
}
norm_end() {
  case "${#1}" in
    10) echo "$1 23:59:59" ;;
    16) echo "$1:59" ;;
    *)  echo "$1" ;;
  esac
}

if [ ! -r "$LOG_FILE" ]; then
  echo "[ERROR] Cannot read log file: $LOG_FILE" >&2
  exit 1
fi

[ -n "$START" ] && [ -z "$END" ] && [ "${#START}" -eq 10 ] && END="$START"
S=""; E=""
[ -n "$START" ] && S=$(norm_start "$START")
[ -n "$END" ]   && E=$(norm_end "$END")

grep -E '^\[[0-9-]+ [0-9:]+\] PID:[^ ]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9.]+%' "$LOG_FILE" \
  | awk -v s="$S" -v e="$E" '
    function num(re, off) { match($0, re); return substr($0, RSTART + off, RLENGTH - off) + 0 }
    {
      match($0, /^\[[^]]+\]/); ts = substr($0, RSTART + 1, RLENGTH - 2)
      if (s != "" && ts < s) next
      if (e != "" && ts > e) next
      c = num("CPU:[0-9.]+", 4); m = num("MEM:[0-9.]+", 4); d = num("DISK_USED:[0-9.]+", 10)
      n++; cs += c; ms += m; ds += d
      if (n == 1 || c > cmax) { cmax = c; cmaxt = ts }
      if (n == 1 || c < cmin) { cmin = c; cmint = ts }
      if (n == 1 || m > mmax) { mmax = m; mmaxt = ts }
      if (n == 1 || m < mmin) { mmin = m; mmint = ts }
      if (n == 1 || d > dmax) { dmax = d; dmaxt = ts }
      if (n == 1 || d < dmin) { dmin = d; dmint = ts }
    }
    END {
      if (n == 0) { print "[WARNING] No samples in the selected range."; exit 0 }
      print "====== STATISTICS REPORT ======"
      printf "[CPU]\n  Average : %.1f%%\n  Maximum : %.1f%% at %s\n  Minimum : %.1f%% at %s\n", cs/n, cmax, cmaxt, cmin, cmint
      printf "[Memory]\n  Average : %.1f%%\n  Maximum : %.1f%% at %s\n  Minimum : %.1f%% at %s\n", ms/n, mmax, mmaxt, mmin, mmint
      printf "[Disk]\n  Average : %.1f%%\n  Maximum : %.1f%% at %s\n  Minimum : %.1f%% at %s\n", ds/n, dmax, dmaxt, dmin, dmint
      printf "[Samples]\n  Data Points: %d samples\n", n
    }'
