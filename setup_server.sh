#!/usr/bin/env bash
# =============================================================================
# setup_server.sh - B4-1 계정/그룹/디렉터리/권한/환경변수/키 파일/cron 구성 (idempotent)
#   실행: sudo ./setup_server.sh      (레포 루트에서, bin/ 폴더가 옆에 있어야 함)
#   ※ SSH 포트 변경과 방화벽은 접속이 끊길 수 있어 이 스크립트에 넣지 않았음 -> README의 수동 절차 참고
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행하세요: sudo $0"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_HOME="${ADMIN_HOME:-/home/agent-admin}"
AGENT_HOME="${AGENT_HOME:-${ADMIN_HOME}/agent-app}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"

step() { echo; echo "==> $*"; }

# 1) 그룹 / 계정 (비밀번호 없는 계정: SSH 키·sudo -u 로만 사용)
step "그룹/계정 생성"
for g in agent-common agent-core; do
  getent group "$g" >/dev/null || groupadd "$g"
done
for u in agent-admin agent-dev agent-test; do
  id "$u" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$u"
done
usermod -aG agent-common,agent-core agent-admin
usermod -aG agent-common,agent-core agent-dev
usermod -aG agent-common            agent-test      # test 는 core 제외 (최소 권한)

# 2) 디렉터리 구조 + 권한 (setgid 2xxx: 새 파일이 부모 그룹을 물려받음)
step "디렉터리/권한 설정"
install -d -o agent-admin -g agent-core   -m 750  "$AGENT_HOME"
install -d -o agent-admin -g agent-common -m 2770 "$AGENT_HOME/upload_files"
install -d -o agent-admin -g agent-core   -m 2770 "$AGENT_HOME/api_keys"
install -d -o agent-dev   -g agent-core   -m 2750 "$AGENT_HOME/bin"
install -d -o agent-admin -g agent-core   -m 2770 "$LOG_DIR"
install -d -o agent-admin -g agent-core   -m 2770 "$ARCHIVE_DIR"

# ACL: 홈(750)이라 agent-dev/test 가 upload_files 까지 못 들어가는 문제를 '경로 통과' 권한만 열어 해결
if command -v setfacl >/dev/null 2>&1; then
  setfacl -m  g:agent-common:--x "$ADMIN_HOME"
  setfacl -m  g:agent-common:r-x "$AGENT_HOME"
  setfacl -m  g:agent-common:rwx "$AGENT_HOME/upload_files"
  setfacl -d -m g:agent-common:rwx "$AGENT_HOME/upload_files"   # 앞으로 생길 파일에도 상속
  setfacl -d -m g:agent-core:rwx   "$AGENT_HOME/api_keys" "$LOG_DIR"
else
  echo "[WARN] setfacl 없음: sudo apt install acl 후 다시 실행하세요"
fi

# 3) 키 파일 (내용 1줄, agent-core 그룹만 R/W)
#    미션 문서는 t_secret.key 라고 하지만, 제공 앱은 api_keys/secret.key 를 찾는다(Boot 3/5에서 확인).
#    그래서 문서 기준(t_secret.key)과 앱 기준(secret.key)을 둘 다 둔다.
step "키 파일 생성"
KEY_FILE="$AGENT_HOME/api_keys/t_secret.key"
printf '%s\n' "agent_api_key_test" > "$KEY_FILE"
chown agent-admin:agent-core "$KEY_FILE"
chmod 660 "$KEY_FILE"
cp -p "$KEY_FILE" "$AGENT_HOME/api_keys/secret.key"

# 4) 스크립트 배포 (monitor.sh: agent-dev:agent-core 750)
step "스크립트 배포"
for s in monitor.sh report.sh log_retention.sh; do
  if [ -f "$SCRIPT_DIR/bin/$s" ]; then
    install -o agent-dev -g agent-core -m 750 "$SCRIPT_DIR/bin/$s" "$AGENT_HOME/bin/$s"
    echo "installed: $AGENT_HOME/bin/$s"
  else
    echo "[WARN] $SCRIPT_DIR/bin/$s 없음 - 건너뜀"
  fi
done

# 5) 환경 변수 (agent-admin 로그인 셸에서 고정)
step "환경 변수 등록 (${ADMIN_HOME}/.bashrc)"
BASHRC="$ADMIN_HOME/.bashrc"
if ! grep -q '# >>> agent-app env >>>' "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" <<EOF

# >>> agent-app env >>>
export AGENT_HOME=$AGENT_HOME
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=\$AGENT_HOME/upload_files
export AGENT_KEY_PATH=\$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$LOG_DIR
# <<< agent-app env <<<
EOF
  chown agent-admin:agent-admin "$BASHRC"
fi
# 제공 앱은 AGENT_KEY_PATH 를 '파일'이 아니라 'api_keys 폴더'로 기대한다(Boot 2/5).
# 이전 버전 스크립트로 만든 .bashrc 도 같은 값으로 고쳐 준다 (idempotent).
sed -i 's#^export AGENT_KEY_PATH=.*#export AGENT_KEY_PATH=$AGENT_HOME/api_keys#' "$BASHRC"

# 6) cron: agent-admin crontab 에 매분 monitor.sh (중복 등록 방지)
step "cron 등록 (agent-admin)"
if command -v crontab >/dev/null 2>&1; then
  systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
  TMP="$(mktemp)"
  { crontab -u agent-admin -l 2>/dev/null | grep -v 'agent-app-b41' || true
    cat <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AGENT_HOME=$AGENT_HOME
AGENT_PORT=15034
AGENT_LOG_DIR=$LOG_DIR
* * * * * $AGENT_HOME/bin/monitor.sh >/dev/null 2>&1 # agent-app-b41
EOF
  } | awk '!seen[$0]++' > "$TMP"          # 변수 줄이 이미 있으면 중복 제거
  crontab -u agent-admin "$TMP"
  rm -f "$TMP"
  crontab -u agent-admin -l
else
  echo "[WARN] crontab 명령 없음: sudo apt install cron"
fi

step "완료 - 이제 agent-admin 으로 앱을 실행하세요 (README 4단계)"
