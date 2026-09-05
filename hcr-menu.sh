#!/usr/bin/env bash
set -euo pipefail

SERVICE="hcr-server"
UNIT="/etc/systemd/system/${SERVICE}.service"

# ============================================================
# HCR CUSTOM MENU NETSYSMOOD
# Lee la configuración REAL del servicio.
# No impone 264/29s al iniciar.
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

pause() {
    echo
    read -r -p "Presiona Enter para continuar..."
}

error() {
    echo
    echo "❌ Error: $*"
    pause
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ Debes ejecutar este menú como root."
        exit 1
    fi
}

check_service_file() {
    if [ ! -f "$UNIT" ]; then
        echo
        echo "❌ No se encontró:"
        echo "$UNIT"
        echo
        echo "Instala primero HCR con install.sh."
        exit 1
    fi
}

get_execstart() {
    systemctl cat "$SERVICE" 2>/dev/null |
        grep '^ExecStart=' |
        tail -n 1 || true
}

get_value() {
    local option="$1"
    local default="$2"
    local line
    local value

    line="$(get_execstart)"

    value="$(printf '%s\n' "$line" |
        sed -nE "s/.*${option}[[:space:]]+([^[:space:]]+).*/\1/p")"

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

get_port() {
    local value

    value="$(get_execstart |
        sed -nE 's/.*--listen[[:space:]]+:([0-9]+).*/\1/p')"

    echo "${value:-8080}"
}

get_target_port() {
    local value

    value="$(get_execstart |
        sed -nE 's/.*--target[[:space:]]+127\.0\.0\.1:([0-9]+).*/\1/p')"

    echo "${value:-22}"
}

get_transport() {
    local value

    value="$(get_value '--transport' 'plain')"

    echo "$value"
}

get_frame() {
    get_value '--max-download-frame' '1032'
}

get_poll_timeout() {
    get_value '--download-poll-timeout' '25s'
}

get_max_connections() {
    get_value '--max-connections' '2048'
}

get_max_sessions() {
    get_value '--max-sessions' '64'
}

get_max_sessions_ip() {
    get_value '--max-sessions-per-ip' '32'
}

get_nofile() {
    local value

    value="$(systemctl show "$SERVICE" \
        --property=LimitNOFILE \
        --value 2>/dev/null || true)"

    echo "${value:-8192}"
}

backup_unit() {
    local date

    date="$(date '+%Y%m%d-%H%M%S')"

    cp -a "$UNIT" "${UNIT}.backup.${date}"

    echo
    echo "✓ Copia de seguridad creada:"
    echo "${UNIT}.backup.${date}"
}

restart_service() {
    echo
    echo "Aplicando configuración..."

    if ! systemd-analyze verify "$UNIT"; then
        echo
        echo "❌ systemd rechazó la configuración."
        return 1
    fi

    systemctl daemon-reload

    if ! systemctl restart "$SERVICE"; then
        echo
        echo "❌ HCR no pudo iniciar."
        systemctl status "$SERVICE" --no-pager --full || true
        return 1
    fi

    sleep 1

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo
        echo "❌ HCR no quedó activo."
        systemctl status "$SERVICE" --no-pager --full || true
        return 1
    fi

    echo
    echo "✓ Configuración aplicada correctamente."
}

replace_option() {
    local option="$1"
    local value="$2"

    python3 - "$UNIT" "$option" "$value" <<'PY'
import sys
import re

path = sys.argv[1]
option = sys.argv[2]
value = sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pattern = r'(?<!\S)' + re.escape(option) + r'\s+\S+'
replacement = option + " " + value

if re.search(pattern, data):
    data = re.sub(pattern, replacement, data, count=1)
else:
    lines = data.splitlines()

    found = False

    for i, line in enumerate(lines):
        if line.startswith("ExecStart="):
            lines[i] = line + " " + replacement
            found = True
            break

    if not found:
        raise SystemExit("No se encontró ExecStart.")

    data = "\n".join(lines) + "\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

replace_port() {
    local value="$1"

    python3 - "$UNIT" "$value" <<'PY'
import sys
import re

path = sys.argv[1]
value = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pattern = r'(--listen\s+):[0-9]+'

data, count = re.subn(
    pattern,
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

replace_target_port() {
    local value="$1"

    python3 - "$UNIT" "$value" <<'PY'
import sys
import re

path = sys.argv[1]
value = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

pattern = r'(--target\s+127\.0\.0\.1:)[0-9]+'

data, count = re.subn(
    pattern,
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

path = sys.argv[1]
value = sys.argv[2]

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

change_number() {
    local title="$1"
    local option="$2"
    local current="$3"
    local min="$4"
    local max="$5"

    local value

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

    backup_unit

    replace_option "$option" "$value"

    if ! restart_service; then
        echo
        echo "⚠ Restaurando copia de seguridad..."

        local backup
        backup="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1 || true)"

        if [ -n "$backup" ]; then
            cp -a "$backup" "$UNIT"
            systemctl daemon-reload
            systemctl restart "$SERVICE" || true
        fi
    fi

    pause
}

change_timeout() {
    local current
    local value

    current="$(get_poll_timeout)"

    echo
    echo "Valor actual: $current"
    read -r -p "Nuevo timeout (ej. 25s, 28s, 30s): " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+(ms|s|m|h)$ ]]; then
        echo "❌ Formato inválido."
        echo "Ejemplos: 25s  28s  30s"
        pause
        return
    fi

    backup_unit

    replace_option '--download-poll-timeout' "$value"

    restart_service || true

    pause
}

change_port_menu() {
    local current
    local value

    current="$(get_port)"

    echo
    echo "Puerto HCR actual: $current"
    read -r -p "Nuevo puerto: " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo "❌ Puerto inválido."
        pause
        return
    fi

    backup_unit

    replace_port "$value"

    restart_service || true

    pause
}

change_target_port_menu() {
    local current
    local value

    current="$(get_target_port)"

    echo
    echo "Puerto target actual: $current"
    read -r -p "Nuevo puerto SSH/target: " value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo "❌ Puerto inválido."
        pause
        return
    fi

    backup_unit

    replace_target_port "$value"

    restart_service || true

    pause
}

change_nofile_menu() {
    local current
    local value

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

    backup_unit

    replace_nofile "$value"

    restart_service || true

    pause
}

show_status() {
    clear_screen

    local status

    if systemctl is-active --quiet "$SERVICE"; then
        status="ACTIVO ✓"
    else
        status="INACTIVO ✗"
    fi

    echo "════════════════════════════════════════════"
    echo "              HCR CONFIGURACIÓN"
    echo "════════════════════════════════════════════"
    echo
    echo "Servicio:                 $status"
    echo
    echo "Puerto HCR:               $(get_port)"
    echo "Puerto SSH/target:        $(get_target_port)"
    echo "Transport:                $(get_transport)"
    echo
    echo "Max Download Frame:       $(get_frame)"
    echo "Download Poll Timeout:    $(get_poll_timeout)"
    echo
    echo "Max Connections:          $(get_max_connections)"
    echo "Max Sessions:             $(get_max_sessions)"
    echo "Max Sessions/IP:          $(get_max_sessions_ip)"
    echo
    echo "LimitNOFILE:              $(get_nofile)"
    echo
    echo "════════════════════════════════════════════"

    pause
}

show_execstart() {
    clear_screen

    echo "════════════════════════════════════════════"
    echo "                 EXECSTART"
    echo "════════════════════════════════════════════"
    echo

    get_execstart

    echo
    echo "════════════════════════════════════════════"

    pause
}

restart_menu() {
    echo

    if restart_service; then
        echo
        echo "✓ HCR reiniciado correctamente."
    fi

    pause
}

start_stop_menu() {
    if systemctl is-active --quiet "$SERVICE"; then
        systemctl stop "$SERVICE"
        echo
        echo "✓ HCR detenido."
    else
        systemctl start "$SERVICE"

        if systemctl is-active --quiet "$SERVICE"; then
            echo
            echo "✓ HCR iniciado."
        else
            echo
            echo "❌ No pudo iniciar."
        fi
    fi

    pause
}

uninstall_menu() {
    clear_screen

    echo "════════════════════════════════════════════"
    echo "             DESINSTALAR HCR"
    echo "════════════════════════════════════════════"
    echo
    echo "Esto detendrá y deshabilitará hcr-server."
    echo
    read -r -p "Escribe SI para confirmar: " answer

    if [ "$answer" != "SI" ]; then
        echo
        echo "Cancelado."
        pause
        return
    fi

    systemctl disable --now "$SERVICE" 2>/dev/null || true

    rm -f "$UNIT"

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true

    echo
    echo "✓ HCR desinstalado."
    echo "El directorio del proyecto NO fue eliminado."

    pause
}

main_menu() {
    while true; do

        clear_screen

        echo "════════════════════════════════════════════"
        echo "           NETSYS MOD - HCR CUSTOM"
        echo "════════════════════════════════════════════"
        echo
        echo " [1] PUERTO HCR:              $(get_port)"
        echo " [2] PUERTO REDIRECCIÓN SSH:  $(get_target_port)"
        echo " [3] MAX DOWNLOAD FRAME:      $(get_frame)"
        echo " [4] DOWNLOAD POLL TIMEOUT:   $(get_poll_timeout)"
        echo " [5] MAX CONNECTIONS:          $(get_max_connections)"
        echo " [6] MAX SESSIONS:             $(get_max_sessions)"
        echo " [7] MAX SESSIONS PER IP:      $(get_max_sessions_ip)"
        echo " [8] LIMIT NOFILE:             $(get_nofile)"
        echo " [9] MODO TRANSPORT:            $(get_transport)"
        echo
        echo " [10] ESTADO DEL SERVICIO"
        echo " [11] VER EXECSTART"
        echo " [12] REINICIAR HCR"
        echo " [13] INICIAR / DETENER HCR"
        echo " [14] DESINSTALAR HCR"
        echo
        echo " [0] SALIR"
        echo
        echo "════════════════════════════════════════════"

        read -r -p "Ingresa una Opción: " option

        case "$option" in

            1)
                change_port_menu
                ;;

            2)
                change_target_port_menu
                ;;

            3)
                change_number \
                    "Nuevo MAX DOWNLOAD FRAME" \
                    "--max-download-frame" \
                    "$(get_frame)" \
                    1 \
                    16384
                ;;

            4)
                change_timeout
                ;;

            5)
                change_number \
                    "Nuevo MAX CONNECTIONS" \
                    "--max-connections" \
                    "$(get_max_connections)" \
                    1 \
                    1048576
                ;;

            6)
                change_number \
                    "Nuevo MAX SESSIONS" \
                    "--max-sessions" \
                    "$(get_max_sessions)" \
                    1 \
                    1048576
                ;;

            7)
                change_number \
                    "Nuevo MAX SESSIONS PER IP" \
                    "--max-sessions-per-ip" \
                    "$(get_max_sessions_ip)" \
                    0 \
                    1048576
                ;;

            8)
                change_nofile_menu
                ;;

            9)
                echo
                echo "El transport se mantiene bajo control del install.sh."
                echo "Para cambiar plain/tls/auto es mejor reinstalar el servicio"
                echo "con --transport para conservar correctamente TLS."
                pause
                ;;

            10)
                show_status
                ;;

            11)
                show_execstart
                ;;

            12)
                restart_menu
                ;;

            13)
                start_stop_menu
                ;;

            14)
                uninstall_menu
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
check_service_file
main_menu
