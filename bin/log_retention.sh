#!/usr/bin/env bash
# =============================================================================
# log_retention.sh - 시간 기반 로그 보존 정책 (보너스 2)
#   1) /var/log/agent-app/*.log 중 7일 경과 파일  -> gzip 압축 후 아카이브로 이동
#   2) 아카이브(*.gz) 중 30일 경과 파일            -> 삭제
#   예외(디렉터리 없음 / 권한 없음 / 대상 0개)는 경고만 남기고 안전하게 종료(exit 0)
#   DRY_RUN=1 ./log_retention.sh  -> 실제 변경 없이 대상만 출력
# =============================================================================
set -u
umask 007

SRC_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"
COMPRESS_DAYS="${COMPRESS_DAYS:-7}"
DELETE_DAYS="${DELETE_DAYS:-30}"
DRY_RUN="${DRY_RUN:-0}"

warn() { echo "[WARNING] $*" >&2; }
info() { echo "[INFO] $*"; }

[ -d "$SRC_DIR" ]      || { warn "Source dir not found: $SRC_DIR"; exit 0; }
[ -r "$SRC_DIR" ]      || { warn "No read permission: $SRC_DIR"; exit 0; }
[ -d "$ARCHIVE_DIR" ]  || { warn "Archive dir not found: $ARCHIVE_DIR"; exit 0; }
[ -w "$ARCHIVE_DIR" ]  || { warn "No write permission: $ARCHIVE_DIR"; exit 0; }

# ---- 1) 7일 경과 .log 압축 + 이동 -------------------------------------------
compressed=0
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  out="${ARCHIVE_DIR}/${base}.$(date +%Y%m%d).gz"
  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] compress $f -> $out"; compressed=$((compressed + 1)); continue
  fi
  # 압축본 무결성 확인 뒤에만 원본 삭제 (실패 시 원본 보존)
  if gzip -c -- "$f" > "$out" 2>/dev/null && gzip -t -- "$out" 2>/dev/null; then
    if rm -f -- "$f" 2>/dev/null; then
      info "Archived: $f -> $out"; compressed=$((compressed + 1))
    else
      warn "Compressed but cannot remove original (permission?): $f"
    fi
  else
    rm -f -- "$out" 2>/dev/null
    warn "Compress failed, original kept: $f"
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.log' -mtime +"$COMPRESS_DAYS" -print0 2>/dev/null)
[ "$compressed" -eq 0 ] && info "No *.log older than ${COMPRESS_DAYS} days."

# ---- 2) 30일 경과 아카이브 삭제 ---------------------------------------------
deleted=0
while IFS= read -r -d '' g; do
  if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] delete $g"; deleted=$((deleted + 1)); continue
  fi
  if rm -f -- "$g" 2>/dev/null; then
    info "Deleted old archive: $g"; deleted=$((deleted + 1))
  else
    warn "Cannot delete: $g"
  fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' -mtime +"$DELETE_DAYS" -print0 2>/dev/null)
[ "$deleted" -eq 0 ] && info "No archive older than ${DELETE_DAYS} days."

exit 0
