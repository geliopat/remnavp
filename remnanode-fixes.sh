#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="/usr/local/bin/remnanode"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SCRIPT}.backup-${TIMESTAMP}"
PATCH_APPLIED=0

rollback_on_patch_error() {
    rc=$?
    if [[ "${PATCH_APPLIED:-0}" -eq 1 && -f "$BACKUP" ]]; then
        echo "ОШИБКА проверки исправлений. Восстанавливаю резервную копию: $BACKUP" >&2
        cp -a "$BACKUP" "$SCRIPT"
    fi
    exit "$rc"
}
trap rollback_on_patch_error ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Запусти этот скрипт от root." >&2
    exit 1
fi

if [[ ! -f "$SCRIPT" ]]; then
    echo "Не найден файл $SCRIPT." >&2
    exit 1
fi

for cmd in python3 docker curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Необходимая команда не найдена: $cmd" >&2
        exit 1
    fi
done

if ! grep -qE '^[[:space:]]*local[[:space:]]+show_prereleases=false([[:space:]]*(#.*)?)?$|^[[:space:]]*local[[:space:]]+show_prereleases=true([[:space:]]*(#.*)?)?$' "$SCRIPT"; then
    echo "Не найден параметр local show_prereleases=false/true. Файл не изменён." >&2
    exit 1
fi

cp -a "$SCRIPT" "$BACKUP"
echo "Резервная копия: $BACKUP"
echo "Применяю исправления RemnaNode..."

python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

function = r'''get_remnanode_version() {
    local container_name="$APP_NAME"
    local image_id repo_digest token releases tag remote_digest version

    image_id=$(docker inspect -f '{{.Image}}' "$container_name" 2>/dev/null) || {
        echo "unknown"
        return 1
    }

    repo_digest=$(docker image inspect \
        -f '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null |
        awk '/^ghcr\.io\/remnawave\/node@sha256:/ {
            sub(/^.*@/, "")
            print
            exit
        }')

    if [ -z "$repo_digest" ]; then
        echo "unknown"
        return 1
    fi

    token=$(curl -fsSL --max-time 15 \
        'https://ghcr.io/token?scope=repository%3Aremnawave%2Fnode%3Apull' |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || {
        echo "unknown"
        return 1
    }

    releases=$(curl -fsSL --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/remnawave/node/releases?per_page=100') || {
        echo "unknown"
        return 1
    }

    while IFS= read -r tag; do
        [ -n "$tag" ] || continue

        remote_digest=$(curl -sSL --max-time 15 \
            -D - -o /dev/null \
            -H "Authorization: Bearer $token" \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://ghcr.io/v2/remnawave/node/manifests/$tag" 2>/dev/null |
            awk 'tolower($1)=="docker-content-digest:" {
                gsub("\r","",$2)
                print $2
                exit
            }')

        if [ "$remote_digest" = "$repo_digest" ]; then
            version="${tag#v}"
            echo "$version"
            return 0
        fi
    done < <(
        printf '%s\n' "$releases" |
        python3 -c '
import json,sys
print("\n".join(
    x["tag_name"] for x in json.load(sys.stdin)
    if x.get("tag_name")
))
'
    )

    echo "unknown"
    return 1
}'''

pattern = re.compile(r'(?ms)^get_remnanode_version[ \t]*\(\)[ \t]*\{.*?^\}')
matches = list(pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(
        f"Ожидалась ровно одна функция get_remnanode_version(), найдено: {len(matches)}. Файл не изменён."
    )
text = pattern.sub(lambda _: function, text, count=1)

flag_pattern = re.compile(r'(?m)^([ \t]*local[ \t]+show_prereleases=)false([ \t]*(?:#.*)?)$')
if flag_pattern.search(text):
    text = flag_pattern.sub(r'\1true\2', text, count=1)
elif not re.search(r'(?m)^[ \t]*local[ \t]+show_prereleases=true([ \t]*(?:#.*)?)$', text):
    raise SystemExit("Не найден параметр show_prereleases=false/true. Файл не изменён.")

path.write_text(text)
PY

PATCH_APPLIED=1

if ! bash -n "$SCRIPT"; then
    echo "ОШИБКА: синтаксическая проверка remnanode не пройдена." >&2
    cp -a "$BACKUP" "$SCRIPT"
    PATCH_APPLIED=0
    exit 1
fi

if ! grep -qE '^[[:space:]]*local[[:space:]]+show_prereleases=true([[:space:]]*(#.*)?)?$' "$SCRIPT" ||
   ! grep -qE '^get_remnanode_version[[:space:]]*\(\)' "$SCRIPT"; then
    echo "ОШИБКА: проверка внесённых исправлений не пройдена." >&2
    cp -a "$BACKUP" "$SCRIPT"
    PATCH_APPLIED=0
    exit 1
fi

trap - ERR
echo "Исправления RemnaNode применены и проверены."
echo "Резервная копия: $BACKUP"

echo
echo "=== Подготовка автоматического обновления Xray ==="

if ! command -v expect >/dev/null 2>&1; then
    echo "Устанавливаю expect..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y expect
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y expect
    elif command -v yum >/dev/null 2>&1; then
        yum install -y expect
    elif command -v apk >/dev/null 2>&1; then
        apk add expect
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install expect
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm expect
    else
        echo "ОШИБКА: не найден поддерживаемый пакетный менеджер для установки expect." >&2
        exit 1
    fi
fi

if ! command -v expect >/dev/null 2>&1; then
    echo "ОШИБКА: expect не установлен." >&2
    exit 1
fi

echo
echo "Запускаю RemnaNode и отправляю последовательность: 11 → 1 → y → Enter → Enter."
echo "Ожидание завершения операции Xray — до 15 минут."

set +e
expect <<'EXPECT_SCRIPT'
set timeout 900
log_user 1

spawn -noecho /usr/local/bin/remnanode

sleep 2
send -- "11\r"
sleep 2
send -- "1\r"
sleep 2
send -- "y\r"
sleep 2
send -- "\r"
sleep 2
send -- "\r"
sleep 3
send -- "0\r"

expect {
    eof {
        set result [wait]
        set status [lindex $result 3]
        if {$status != 0} {
            send_user "\nОШИБКА: RemnaNode завершился с кодом $status\n"
            exit $status
        }
    }
    timeout {
        send_user "\nОШИБКА: RemnaNode не завершился за 15 минут.\n"
        exit 124
    }
}
EXPECT_SCRIPT
UPDATE_STATUS=$?
set -e

if [[ "$UPDATE_STATUS" -ne 0 ]]; then
    echo "ОШИБКА: автоматическое обновление Xray завершилось с кодом $UPDATE_STATUS." >&2
    echo "Исправления RemnaNode сохранены. Резервная копия: $BACKUP"
    exit "$UPDATE_STATUS"
fi

echo
echo "Скрипт исправлений RemnaNode и запуска обновления Xray завершён."
echo "Проверь фактическую версию Xray в RemnaNode."
