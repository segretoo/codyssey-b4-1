#!/usr/bin/env bash
# =============================================================================
# monitor.sh - 에이전트 앱 상태 점검 + 리소스 수집 + 로그 누적 (Codyssey B4-1)
#   위치/권한 : $AGENT_HOME/bin/monitor.sh  (agent-dev:agent-core, 750)
#   실행 계정 : agent-admin (crontab, agent-core 소속)
#   종료 코드 : 0 정상(경고 포함) / 1 헬스체크 실패 / 2 로그 기록 불가
# =============================================================================
set -u
set -o pipefail
umask 007   # 로그 파일: agent-core 그룹만 읽기/쓰기, other 접근 불가

# ---------- 설정 (환경 변수로 덮어쓸 수 있고, 미지정 시 과제 기본값) ----------
AGENT_HOME="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
AGENT_APP_LABEL="${AGENT_APP_LABEL:-agent_app}"
# 실행 파일(또는 인터프리터가 실행하는 스크립트) 이름에 적용하는 정규식
#   'python3 agent_app.py' -> agent_app.py / './agent-app-linux-x86' -> agent-app-linux-x86 : 매칭
#   'vim agent_app.py', 'tail -f /var/log/agent-app/..', monitor.sh 자신                  : 매칭 안 됨
AGENT_PROC_REGEX="${AGENT_PROC_REGEX:-^agent[-_]app}"

LOG_FILE="${AGENT_LOG_DIR}/monitor.log"
CPU_LIMIT="${CPU_LIMIT:-20}"      # % 초과 시 경고 (과제 기준 20)
MEM_LIMIT="${MEM_LIMIT:-10}"      # % 초과 시 경고 (과제 기준 10)
DISK_LIMIT="${DISK_LIMIT:-80}"    # % 초과 시 경고 (과제 기준 80)
MAX_LOG_BYTES="${MAX_LOG_BYTES:-$((10 * 1024 * 1024))}"   # 파일 1개 최대 10MB
MAX_LOG_FILES=10                                          # monitor.log + .1 ~ .9
STAT_WINDOW=10        # 콘솔 통계에 쓸 최근 샘플 수

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# ---------- 헬스체크 ----------
# 'pgrep -f' 처럼 명령줄 전체를 뒤지면 vim/tail/자기 자신까지 걸리므로,
# argv0 (인터프리터면 첫 번째 스크립트 인자)의 파일명만 보고 판단한다.
find_app_pid() {
  ps -eo pid=,args= 2>/dev/null | awk -v re="$AGENT_PROC_REGEX" -v self="$$" '
    {
      pid = $1
      n = split($2, p, "/"); base = p[n]
      if (base ~ /^(python[0-9.]*|bash|sh|dash|node|perl)$/) {
        t = ""
        for (i = 3; i <= NF; i++) {
          if ($i == "-c") { t = ""; break }
          if ($i ~ /^-/) continue
          t = $i; break
        }
        n = split(t, p, "/"); base = p[n]
      }
      if (pid != self && base ~ re) { print pid; exit }
    }'
}

port_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p="$AGENT_PORT" \
      'NR>1 && $4 ~ (":" p "$") {found=1} END{exit !found}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p="$AGENT_PORT" \
      'NR>2 && $4 ~ (":" p "$") {found=1} END{exit !found}'
  else
    return 1
  fi
}

# 방화벽 활성 여부 (일반 계정은 'ufw status'가 root 전용이라 설정 파일 + 서비스 상태로 판단)
firewall_active() {
  local has_systemd=0
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && has_systemd=1

  if command -v ufw >/dev/null 2>&1 && grep -qiE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    if [ "$has_systemd" -eq 0 ] || systemctl is-active --quiet ufw 2>/dev/null; then
      return 0
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 \
     && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
    return 0
  fi
  return 1
}

# ---------- 리소스 수집 ----------
# CPU: /proc/stat을 1초 간격으로 두 번 읽어 (전체 - idle) 비율 계산
cpu_usage() {
  local _c u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
  read -r _c u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
  sleep 1
  read -r _c u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
  local t1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1))
  local t2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2))
  awk -v dt=$((t2 - t1)) -v di=$(((i2 + w2) - (i1 + w1))) \
    'BEGIN { if (dt <= 0) print "0.0"; else printf "%.1f", (dt - di) * 100 / dt }'
}

# MEM: (MemTotal - MemAvailable) / MemTotal
mem_usage() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
       END { if (t > 0) printf "%.1f", (t - a) * 100 / t; else print "0.0" }' /proc/meminfo
}

# DISK: Root partition(/) Used %
disk_usage() {
  df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}'
}

exceeds() { awk -v v="$1" -v t="$2" 'BEGIN { exit !(v > t) }'; }

# ---------- 로그 관리 ----------
# 10MB 이상이면 monitor.log -> .1 -> .2 ... 밀어내고 .9 는 삭제 (최대 10개 유지)
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size i
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  [ "$size" -ge "$MAX_LOG_BYTES" ] || return 0

  rm -f "${LOG_FILE}.$((MAX_LOG_FILES - 1))"
  for ((i = MAX_LOG_FILES - 2; i >= 1; i--)); do
    [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
}

# 최근 N개 샘플의 CPU/MEM/DISK 평균·최대·최소 출력 (샘플 형식에 맞는 줄만 집계)
print_stats() {
  grep -E '^\[[0-9-]+ [0-9:]+\] PID:[^ ]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9.]+%' "$LOG_FILE" 2>/dev/null \
    | tail -n "$STAT_WINDOW" \
    | awk '
      function num(re, off) { match($0, re); return substr($0, RSTART + off, RLENGTH - off) + 0 }
      {
        match($0, /^\[[^]]+\]/); ts = substr($0, RSTART + 1, RLENGTH - 2)
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
        if (n == 0) { print "(no samples yet)"; exit }
        print "====== STATISTICS REPORT ======"
        printf "[CPU]\nAverage : %.1f%%\nMaximum : %.1f%% at %s\nMinimum : %.1f%% at %s\n", cs/n, cmax, cmaxt, cmin, cmint
        printf "[Memory]\nAverage : %.1f%%\nMaximum : %.1f%% at %s\nMinimum : %.1f%% at %s\n", ms/n, mmax, mmaxt, mmin, mmint
        printf "[Disk]\nAverage : %.1f%%\nMaximum : %.1f%% at %s\nMinimum : %.1f%% at %s\n", ds/n, dmax, dmaxt, dmin, dmint
        printf "[Samples]\nData Points: %d samples\n", n
      }'
}

# ---------- 메인 ----------
main() {
  if [ ! -d "$AGENT_LOG_DIR" ] || [ ! -w "$AGENT_LOG_DIR" ]; then
    echo "[ERROR] Log directory is missing or not writable: $AGENT_LOG_DIR" >&2
    exit 2
  fi

  # 동시 실행 방지: 앞선 실행이 아직 끝나지 않았으면 이번 회차는 건너뜀
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${AGENT_LOG_DIR}/.monitor.lock"
    flock -n 9 || { echo "[INFO] Previous monitor.sh still running. Skip."; exit 0; }
  fi

  echo "====== SYSTEM MONITOR RESULT ======"
  echo
  echo "[HEALTH CHECK]"

  local pid health_ok=1
  pid=$(find_app_pid)
  if [ -n "$pid" ]; then
    echo "Checking process '${AGENT_APP_LABEL}'... [OK] (PID: ${pid})"
  else
    echo "Checking process '${AGENT_APP_LABEL}'... [FAIL] not running"
    health_ok=0
  fi

  if port_listening; then
    echo "Checking port ${AGENT_PORT}... [OK]"
  else
    echo "Checking port ${AGENT_PORT}... [FAIL] not LISTEN"
    health_ok=0
  fi

  if firewall_active; then
    echo "Checking firewall... [OK]"
  else
    echo "[WARNING] Firewall (ufw/firewalld) is not active"   # 경고만, 종료하지 않음
  fi

  if [ "$health_ok" -eq 0 ]; then
    rotate_log
    printf '[%s] HEALTH_FAIL: process=%s port=%s\n' "$(timestamp)" \
      "$([ -n "$pid" ] && echo OK || echo DOWN)" \
      "$(port_listening && echo LISTEN || echo DOWN)" >> "$LOG_FILE"
    echo "[ERROR] Health check failed. Abort."
    exit 1
  fi

  local cpu mem disk
  cpu=$(cpu_usage)
  mem=$(mem_usage)
  disk=$(disk_usage)

  echo
  echo "[RESOURCE MONITORING]"
  echo "CPU Usage : ${cpu}%"
  echo "MEM Usage : ${mem}%"
  echo "DISK Used : ${disk}%"
  echo

  # 임계값 경고 (경고만 출력, 종료하지 않음)
  local warned=0
  if exceeds "$cpu"  "$CPU_LIMIT";  then echo "[WARNING] CPU threshold exceeded (${cpu}% > ${CPU_LIMIT}%)";    warned=1; fi
  if exceeds "$mem"  "$MEM_LIMIT";  then echo "[WARNING] MEM threshold exceeded (${mem}% > ${MEM_LIMIT}%)";    warned=1; fi
  if exceeds "$disk" "$DISK_LIMIT"; then echo "[WARNING] DISK threshold exceeded (${disk}% > ${DISK_LIMIT}%)"; warned=1; fi
  [ "$warned" -eq 1 ] && echo

  rotate_log
  printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
    "$(timestamp)" "$pid" "$cpu" "$mem" "$disk" >> "$LOG_FILE"

  print_stats
  echo
  echo "[INFO] Log appended: ${LOG_FILE}"
  exit 0
}

main "$@"
