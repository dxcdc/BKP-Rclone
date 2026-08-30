#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/cdc-backup-test.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

make_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/scripts" "$fixture/services/Servico Teste" "$fixture/bin"
  cp "$ROOT/scripts/backup_run.sh" "$fixture/scripts/backup_run.sh"
  printf 'Serviço de teste\n' > "$fixture/services/Servico Teste/info.txt"
  printf 'GPG_PASSPHRASE="segredo-de-teste"\nRCLONE_REMOTE_ROOT="mock:backups"\n' > "$fixture/.env"
  for tool in docker gpg rclone curl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/$tool"
    chmod +x "$fixture/bin/$tool"
  done
}

assert_exit() {
  local expected="$1"; shift
  set +e; "$@" >/dev/null 2>&1; local actual=$?; set -e
  [[ "$actual" -eq "$expected" ]] || { printf 'esperado exit %s, recebido %s\n' "$expected" "$actual" >&2; return 1; }
}

fixture="$TEST_DIR/inactive"; make_fixture "$fixture"
PATH="$fixture/bin:$PATH" assert_exit 0 "$fixture/scripts/backup_run.sh"

fixture="$TEST_DIR/invalid"; make_fixture "$fixture"
printf 'BACKUP_TYPE="postgres"\nCOMANDO=$(id)\n' > "$fixture/services/Servico Teste/backup.conf"
PATH="$fixture/bin:$PATH" assert_exit 1 "$fixture/scripts/backup_run.sh"

fixture="$TEST_DIR/no-secret"; make_fixture "$fixture"; printf 'MATTERMOST_WEBHOOK_URL=""\n' > "$fixture/.env"
PATH="$fixture/bin:$PATH" assert_exit 1 "$fixture/scripts/backup_run.sh"

fixture="$TEST_DIR/not-found"; make_fixture "$fixture"
PATH="$fixture/bin:$PATH" assert_exit 64 "$fixture/scripts/backup_run.sh" "Inexistente"

fixture="$TEST_DIR/postgres"; make_fixture "$fixture"; mkdir -p "$fixture/remote"
printf 'BACKUP_TYPE="postgres"\nDB_CONTAINER="db-estavel"\nDB_USER="usuario"\nDB_NAME="banco"\n' > "$fixture/services/Servico Teste/backup.conf"
cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == inspect && "$2" == --format=* ]]; then printf 'POSTGRES_PASSWORD=senha\nPOSTGRES_USER=usuario\nPOSTGRES_DB=banco\n'; exit; fi
if [[ "$1" == container && "$2" == inspect ]]; then exit 0; fi
if [[ "$1" == inspect ]]; then exit 0; fi
if [[ "$1" == exec ]]; then printf '%s\n' 'CREATE TABLE teste(id integer);'; exit; fi
exit 1
MOCK
cat > "$fixture/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
output=''; input=''; while (($#)); do case "$1" in -o) output="$2"; shift 2;; *) input="$1"; shift;; esac; done
cp "$input" "$output"
MOCK
cat > "$fixture/bin/rclone" <<'MOCK'
#!/usr/bin/env bash
map_path() { printf '%s' "${1/mock:backups/$MOCK_REMOTE}"; }
action="$1"; shift
case "$action" in
  mkdir) mkdir -p "$(map_path "$1")" ;;
  copy) source="$1"; target="$(map_path "$2")"; mkdir -p "$target"; cp "$source" "$target/" ;;
  copyto) source="$(map_path "$1")"; target="$(map_path "$2")"; mkdir -p "$(dirname "$target")"; cp "$source" "$target" ;;
  lsf) target="$(map_path "$1")"; [[ -d "$target" ]] && find "$target" -maxdepth 1 -type f -printf '%f\n' ;;
  delete) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$fixture/bin/docker" "$fixture/bin/gpg" "$fixture/bin/rclone"
PATH="$fixture/bin:$PATH" MOCK_REMOTE="$fixture/remote" assert_exit 0 "$fixture/scripts/backup_run.sh"
find "$fixture/remote/Servico Teste/db" -name '*.gpg' -type f | grep -q .
find "$fixture/remote/Servico Teste/db" -name '*.sha256' -type f | grep -q .

printf '5 testes aprovados\n'
