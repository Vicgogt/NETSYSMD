#!/usr/bin/env bash
set -euo pipefail

SERVICE="hcr-server"
UNIT="/etc/systemd/system/${SERVICE}.service"

clear_screen() {
    clear 2>/dev/null || true
}

pause() {
    echo
    read -r -p "Presiona Enter para continuar..."
}

die() {
    echo
    echo "❌ Error: $*"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Ejecuta este menú como root."
}

require_service() {
    [ -f "$UNIT" ] || die "No existe $UNIT. Instala primero HCR con install.sh."
}

execstart() {
    systemctl cat "$SERVICE" 2>/dev/null |
        sed -n '/^ExecStart=/p' |
        tail -n 1
}

get_option() {
    local option="$1"
    local default="$2"
    local line value

    line="$(execstart)"

    value="$(
        printf '%s\n' "$line" |
        sed -nE "s/.*${option}[[:space:]]+([^[:space:]]+).*/\1/p"
    )"

    printf '%s\n' "${value:-$default}"
}

get_port() {
    local value
    value="$(execstart | sed -nE 's/.*--listen[[:space:]]+:([0-9]+).*/\1/p')"
    printf '%s\n' "${value:-8080}"
}

get_target() {
    local value
    value="$(execstart | sed -nE 's/.*--target[[:space:]]+127\.0\.0\.1:([0-9]+).*/\1/p')"
    printf '%s\n' "${value:-22}"
}

get_transport() {
    get_option '--transport' 'auto'
}

get_frame() {
    get_option '--max-download-frame' '1032'
}

get_poll() {
    get_option '--download-poll-timeout' '25s'
}

get_connections() {
    get_option '--max-connections' '2048'
}

get_sessions() {
    get_option '--max-sessions' '64'
}

get_sessions_ip() {
    get_option '--max-sessions-per-ip' '32'
}

get_stats() {
    get_option '--session-stats-interval' '0'
}

get_nofile() {
    local value
    value="$(systemctl show "$SERVICE" --property=LimitNOFILE --value 2>/dev/null || true)"
    printf '%s\n' "${value:-8192}"
}

backup() {
    local stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"

    cp -a "$UNIT" "${UNIT}.backup.${stamp}"

    echo "✓ Backup: ${UNIT}.backup.${stamp}"
}

restore_backup() {
    local backup_file="$1"

    cp -a "$backup_file" "$UNIT"
    systemctl daemon-reload
    systemctl restart "$SERVICE" || true
}

restart_hcr() {
    systemd-analyze verify "$UNIT" || return 1

    systemctl daemon-reload
    systemctl restart "$SERVICE"

    sleep 1

    systemctl is-active --quiet "$SERVICE"
}

replace_option() {
    local option="$1"
    local value="$2"

    python3 - "$UNIT" "$option" "$value" <<'PY'
import sys
import re

path, option, value = sys.argv[1:4]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pattern = r'(?<!\S)' + re.escape(option) + r'\s+\S+'
replacement = option + " " + value

if re.search(pattern, data):
    data = re.sub(pattern, replacement, data, count=1)
else:
    lines = data.splitlines()

    for i, line in enumerate(lines):
        if line.startswith("ExecStart="):
            lines[i] = line + " " + replacement
            data = "\n".join(lines) + "\n"
            break
    else:
        raise SystemExit("No se encontró ExecStart.")

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

replace_port() {
    local value="$1"

    python3 - "$UNIT" "$value" <<'PY'
import sys
import re

path, value = sys.argv[1:3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

data, count = re.subn(
    r'(--listen\s+):[0-9]+',
    r'\1:' + value,
    data,
    count=1
)

if count == 0:
    raise SystemExit("No se encontró --listen.")

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

replace_target() {
    local value="$1"

    python3 - "$UNIT" "$value" <<'PY'
import sys
import re

path, value = sys.argv[1:3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

data, count = re.subn(
    r'(--target\s+127\.0\.0\.1:)[0-9]+',
    r'\1' + value,
    data,
    count=1
)

if count == 0:
    raise SystemExit("No se encontró --target.")

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

replace_nofile() {
    local value="$1"

    python3 - "$UNIT" "$value" <<'PY'
import sys
import re

path, value = sys.argv[1:3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

if re.search(r'(?m)^LimitNOFILE=', data):
    data = re.sub(
        r'(?m)^LimitNOFILE=\S+',
        'LimitNOFILE=' + value,
        data,
        count=1
    )
else:
    data = data.replace(
        '[Service]\n',
        '[Service]\nLimitNOFILE=' + value + '\n',
        1
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

change_option() {
    local title="$1"
    local option="$2"
    local current="$3"
    local min="$4"
    local max="$5"
    local value
    local backup_file

    echo
    echo "Valor actual: $current"

    read -r -p "$title: " value
    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "❌ Debe ser un número."
        pause
        return
    fi

    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "❌ Valor fuera de rango."
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_option "$option" "$value"

    if restart_hcr; then
        echo "✓ Cambio aplicado."
    else
        echo "❌ HCR no pudo iniciar. Restaurando..."
        restore_backup "$backup_file"
    fi

    pause
}

change_timeout() {
    local current value backup_file

    current="$(get_poll)"

    echo
    echo "Valor actual: $current"
    read -r -p "Nuevo timeout (ej. 20s, 25s, 30s): " value

    [ -n "$value" ] || return

    [[ "$value" =~ ^[0-9]+(ms|s|m|h)$ ]] || {
        echo "❌ Formato inválido."
        pause
        return
    }

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_option '--download-poll-timeout' "$value"

    if restart_hcr; then
        echo "✓ Cambio aplicado."
    else
        echo "❌ HCR no pudo iniciar. Restaurando..."
        restore_backup "$backup_file"
    fi

    pause
}

change_port() {
    local current value backup_file

    current="$(get_port)"

    echo
    echo "Puerto actual: $current"
    read -r -p "Nuevo puerto HCR: " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo "❌ Puerto inválido."
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_port "$value"

    if restart_hcr; then
        echo "✓ Puerto cambiado."
    else
        echo "❌ HCR no pudo iniciar. Restaurando..."
        restore_backup "$backup_file"
    fi

    pause
}

change_target() {
    local current value backup_file

    current="$(get_target)"

    echo
    echo "Target actual: $current"
    read -r -p "Nuevo puerto SSH/target: " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo "❌ Puerto inválido."
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_target "$value"

    if restart_hcr; then
        echo "✓ Target cambiado."
    else
        echo "❌ HCR no pudo iniciar. Restaurando..."
        restore_backup "$backup_file"
    fi

    pause
}

change_nofile() {
    local current value backup_file

    current="$(get_nofile)"

    echo
    echo "LimitNOFILE actual: $current"
    read -r -p "Nuevo LimitNOFILE: " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1024 ] ||
       [ "$value" -gt 1048576 ]; then
        echo "❌ Valor inválido."
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_nofile "$value"

    if restart_hcr; then
        echo "✓ LimitNOFILE cambiado."
    else
        echo "❌ HCR no pudo iniciar. Restaurando..."
        restore_backup "$backup_file"
    fi

    pause
}

status_menu() {
    clear_screen

    echo "════════════════════════════════════════════"
    echo "             HCR - CONFIGURACIÓN"
    echo "════════════════════════════════════════════"
    echo

    if systemctl is-active --quiet "$SERVICE"; then
        echo "Servicio:                 ACTIVO ✓"
    else
        echo "Servicio:                 INACTIVO ✗"
    fi

    echo
    echo "Puerto HCR:               $(get_port)"
    echo "Puerto SSH/target:        $(get_target)"
    echo "Transport:                $(get_transport)"
    echo
    echo "Max Connections:          $(get_connections)"
    echo "Max Sessions:             $(get_sessions)"
    echo "Max Sessions/IP:          $(get_sessions_ip)"
    echo "Max Download Frame:       $(get_frame)"
    echo "Download Poll Timeout:    $(get_poll)"
    echo "Session Stats Interval:   $(get_stats)"
    echo "LimitNOFILE:              $(get_nofile)"

    echo
    echo "════════════════════════════════════════════"

    pause
}

logs_menu() {
    clear_screen

    echo "Últimas 50 líneas de HCR:"
    echo

    journalctl -u "$SERVICE" -n 50 --no-pager || true

    pause
}

main_menu() {
    while true; do
        clear_screen

        echo "════════════════════════════════════════════"
        echo "          NETSYS MOD - HCR CUSTOM"
        echo "════════════════════════════════════════════"
        echo
        echo " [1] Puerto HCR:              $(get_port)"
        echo " [2] Puerto SSH / Target:     $(get_target)"
        echo " [3] Transport:               $(get_transport)"
        echo
        echo " [4] Max Download Frame:      $(get_frame)"
        echo " [5] Download Poll Timeout:   $(get_poll)"
        echo " [6] Max Connections:          $(get_connections)"
        echo " [7] Max Sessions:             $(get_sessions)"
        echo " [8] Max Sessions Per IP:      $(get_sessions_ip)"
        echo " [9] Session Stats Interval:   $(get_stats)"
        echo
        echo " [10] Limit NOFILE:             $(get_nofile)"
        echo " [11] Estado"
        echo " [12] Ver ExecStart"
        echo " [13] Ver logs"
        echo " [14] Reiniciar HCR"
        echo " [15] Iniciar / Detener HCR"
        echo " [16] Desinstalar HCR"
        echo
        echo " [0] Salir"
        echo
        echo "════════════════════════════════════════════"

        read -r -p "Ingresa una Opción: " option

        case "$option" in
            1)
                change_port
                ;;
            2)
                change_target
                ;;
            3)
                echo
                echo "Transport se controla desde install.sh:"
                echo "tls / plain / auto"
                echo
                echo "Para no romper certificados, esta opción no modifica"
                echo "el servicio automáticamente."
                pause
                ;;
            4)
                change_option \
                    "Nuevo MAX DOWNLOAD FRAME" \
                    "--max-download-frame" \
                    "$(get_frame)" \
                    1 \
                    1048576
                ;;
            5)
                change_timeout
                ;;
            6)
                change_option \
                    "Nuevo MAX CONNECTIONS" \
                    "--max-connections" \
                    "$(get_connections)" \
                    1 \
                    1048576
                ;;
            7)
                change_option \
                    "Nuevo MAX SESSIONS" \
                    "--max-sessions" \
                    "$(get_sessions)" \
                    1 \
                    1048576
                ;;
            8)
                change_option \
                    "Nuevo MAX SESSIONS PER IP" \
                    "--max-sessions-per-ip" \
                    "$(get_sessions_ip)" \
                    0 \
                    1048576
                ;;
            9)
                change_option \
                    "Nuevo SESSION STATS INTERVAL en segundos (0 = off)" \
                    "--session-stats-interval" \
                    "$(get_stats)" \
                    0 \
                    86400
                ;;
            10)
                change_nofile
                ;;
            11)
                status_menu
                ;;
            12)
                clear_screen
                echo "ExecStart actual:"
                echo
                execstart
                pause
                ;;
            13)
                logs_menu
                ;;
            14)
                if restart_hcr; then
                    echo
                    echo "✓ HCR reiniciado correctamente."
                else
                    echo
                    echo "❌ HCR no pudo reiniciar."
                fi
                pause
                ;;
            15)
                if systemctl is-active --quiet "$SERVICE"; then
                    systemctl stop "$SERVICE"
                    echo "✓ HCR detenido."
                else
                    systemctl start "$SERVICE"

                    if systemctl is-active --quiet "$SERVICE"; then
                        echo "✓ HCR iniciado."
                    else
                        echo "❌ HCR no pudo iniciar."
                    fi
                fi
                pause
                ;;
            16)
                clear_screen
                echo "Esto detendrá y deshabilitará HCR."
                echo "El repositorio no será eliminado."
                echo
                read -r -p "Escribe SI para confirmar: " answer

                if [ "$answer" = "SI" ]; then
                    systemctl disable --now "$SERVICE" 2>/dev/null || true
                    rm -f "$UNIT"
                    systemctl daemon-reload
                    systemctl reset-failed "$SERVICE" 2>/dev/null || true
                    echo "✓ HCR desinstalado."
                else
                    echo "Cancelado."
                fi

                pause
                ;;
            0)
                echo
                echo "👋 Saliendo..."
                exit 0
                ;;
            *)
                echo
                echo "❌ Opción inválida."
                sleep 1
                ;;
        esac
    done
}

require_root
require_service
main_menu
