#!/usr/bin/env bash
set -euo pipefail

SERVICE="hcr-server"
UNIT="/etc/systemd/system/${SERVICE}.service"

# ─── Colores ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'
# ─────────────────────────────────────────────────────────

clear_screen() {
    clear 2>/dev/null || true
}

pause() {
    echo
    read -r -p "$(echo -e "${YELLOW}Presiona Enter para continuar...${RESET}")"
}

die() {
    echo
    echo -e "${RED}❌ Error: $*${RESET}"
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

    echo -e "${GREEN}✓ Backup: ${UNIT}.backup.${stamp}${RESET}"
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
    echo -e "${CYAN}Valor actual: ${BOLD}${current}${RESET}"

    read -r -p "$(echo -e "${YELLOW}${title}: ${RESET}")" value
    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ Debe ser un número.${RESET}"
        pause
        return
    fi

    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo -e "${RED}❌ Valor fuera de rango.${RESET}"
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_option "$option" "$value"

    if restart_hcr; then
        echo -e "${GREEN}✓ Cambio aplicado.${RESET}"
    else
        echo -e "${RED}❌ HCR no pudo iniciar. Restaurando...${RESET}"
        restore_backup "$backup_file"
    fi

    pause
}

change_timeout() {
    local current value backup_file

    current="$(get_poll)"

    echo
    echo -e "${CYAN}Valor actual: ${BOLD}${current}${RESET}"
    read -r -p "$(echo -e "${YELLOW}Nuevo timeout (ej. 20s, 25s, 30s): ${RESET}")" value

    [ -n "$value" ] || return

    [[ "$value" =~ ^[0-9]+(ms|s|m|h)$ ]] || {
        echo -e "${RED}❌ Formato inválido.${RESET}"
        pause
        return
    }

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_option '--download-poll-timeout' "$value"

    if restart_hcr; then
        echo -e "${GREEN}✓ Cambio aplicado.${RESET}"
    else
        echo -e "${RED}❌ HCR no pudo iniciar. Restaurando...${RESET}"
        restore_backup "$backup_file"
    fi

    pause
}

change_port() {
    local current value backup_file

    current="$(get_port)"

    echo
    echo -e "${CYAN}Puerto actual: ${BOLD}${current}${RESET}"
    read -r -p "$(echo -e "${YELLOW}Nuevo puerto HCR: ${RESET}")" value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo -e "${RED}❌ Puerto inválido.${RESET}"
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_port "$value"

    if restart_hcr; then
        echo -e "${GREEN}✓ Puerto cambiado.${RESET}"
    else
        echo -e "${RED}❌ HCR no pudo iniciar. Restaurando...${RESET}"
        restore_backup "$backup_file"
    fi

    pause
}

change_target() {
    local current value backup_file

    current="$(get_target)"

    echo
    echo -e "${CYAN}Target actual: ${BOLD}${current}${RESET}"
    read -r -p "$(echo -e "${YELLOW}Nuevo puerto SSH/target: ${RESET}")" value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1 ] ||
       [ "$value" -gt 65535 ]; then
        echo -e "${RED}❌ Puerto inválido.${RESET}"
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_target "$value"

    if restart_hcr; then
        echo -e "${GREEN}✓ Target cambiado.${RESET}"
    else
        echo -e "${RED}❌ HCR no pudo iniciar. Restaurando...${RESET}"
        restore_backup "$backup_file"
    fi

    pause
}

change_nofile() {
    local current value backup_file

    current="$(get_nofile)"

    echo
    echo -e "${CYAN}LimitNOFILE actual: ${BOLD}${current}${RESET}"
    read -r -p "$(echo -e "${YELLOW}Nuevo LimitNOFILE: ${RESET}")" value

    [ -n "$value" ] || return

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       [ "$value" -lt 1024 ] ||
       [ "$value" -gt 1048576 ]; then
        echo -e "${RED}❌ Valor inválido.${RESET}"
        pause
        return
    fi

    backup
    backup_file="$(ls -t "${UNIT}.backup."* 2>/dev/null | head -n 1)"

    replace_nofile "$value"

    if restart_hcr; then
        echo -e "${GREEN}✓ LimitNOFILE cambiado.${RESET}"
    else
        echo -e "${RED}❌ HCR no pudo iniciar. Restaurando...${RESET}"
        restore_backup "$backup_file"
    fi

    pause
}

status_menu() {
    clear_screen

    echo -e "${YELLOW}════════════════════════════════════════════${RESET}"
    echo -e "${CYAN}${BOLD}             HCR - CONFIGURACIÓN${RESET}"
    echo -e "${YELLOW}════════════════════════════════════════════${RESET}"
    echo

    if systemctl is-active --quiet "$SERVICE"; then
        echo -e "Servicio:                 ${GREEN}ACTIVO ✓${RESET}"
    else
        echo -e "Servicio:                 ${RED}INACTIVO ✗${RESET}"
    fi

    echo
    echo -e "Puerto HCR:               ${CYAN}$(get_port)${RESET}"
    echo -e "Puerto SSH/target:        ${CYAN}$(get_target)${RESET}"
    echo -e "Transport:                ${CYAN}$(get_transport)${RESET}"
    echo
    echo -e "Max Connections:          ${CYAN}$(get_connections)${RESET}"
    echo -e "Max Sessions:             ${CYAN}$(get_sessions)${RESET}"
    echo -e "Max Sessions/IP:          ${CYAN}$(get_sessions_ip)${RESET}"
    echo -e "Max Download Frame:       ${CYAN}$(get_frame)${RESET}"
    echo -e "Download Poll Timeout:    ${CYAN}$(get_poll)${RESET}"
    echo -e "Session Stats Interval:   ${CYAN}$(get_stats)${RESET}"
    echo -e "LimitNOFILE:              ${CYAN}$(get_nofile)${RESET}"

    echo
    echo -e "${YELLOW}════════════════════════════════════════════${RESET}"

    pause
}

logs_menu() {
    clear_screen

    echo -e "${CYAN}${BOLD}Últimas 50 líneas de HCR:${RESET}"
    echo

    journalctl -u "$SERVICE" -n 50 --no-pager || true

    pause
}

main_menu() {
    while true; do
        clear_screen

        echo -e "${YELLOW}════════════════════════════════════════════${RESET}"
        echo -e "${CYAN}${BOLD}          NETSYS MOD - HCR CUSTOM${RESET}"
        echo -e "${YELLOW}════════════════════════════════════════════${RESET}"
        echo
        echo -e " ${GREEN}[1]${RESET} Puerto HCR:              ${CYAN}$(get_port)${RESET}"
        echo -e " ${GREEN}[2]${RESET} Puerto SSH / Target:     ${CYAN}$(get_target)${RESET}"
        echo -e " ${GREEN}[3]${RESET} Transport:               ${CYAN}$(get_transport)${RESET}"
        echo
        echo -e " ${GREEN}[4]${RESET} Max Download Frame:      ${CYAN}$(get_frame)${RESET}"
        echo -e " ${GREEN}[5]${RESET} Download Poll Timeout:   ${CYAN}$(get_poll)${RESET}"
        echo -e " ${GREEN}[6]${RESET} Max Connections:          ${CYAN}$(get_connections)${RESET}"
        echo -e " ${GREEN}[7]${RESET} Max Sessions:             ${CYAN}$(get_sessions)${RESET}"
        echo -e " ${GREEN}[8]${RESET} Max Sessions Per IP:      ${CYAN}$(get_sessions_ip)${RESET}"
        echo -e " ${GREEN}[9]${RESET} Session Stats Interval:   ${CYAN}$(get_stats)${RESET}"
        echo
        echo -e " ${GREEN}[10]${RESET} Limit NOFILE:             ${CYAN}$(get_nofile)${RESET}"
        echo -e " ${GREEN}[11]${RESET} Estado"
        echo -e " ${GREEN}[12]${RESET} Ver ExecStart"
        echo -e " ${GREEN}[13]${RESET} Ver logs"
        echo -e " ${GREEN}[14]${RESET} Reiniciar HCR"
        echo -e " ${GREEN}[15]${RESET} Iniciar / Detener HCR"
        echo -e " ${GREEN}[16]${RESET} Desinstalar HCR"
        echo
        echo -e " ${GREEN}[0]${RESET} Salir"
        echo
        echo -e "${YELLOW}════════════════════════════════════════════${RESET}"

        read -r -p "$(echo -e "${YELLOW}Ingresa una Opción: ${RESET}")" option

        case "$option" in
            1)
                change_port
                ;;
            2)
                change_target
                ;;
            3)
                echo
                echo -e "${CYAN}Transport se controla desde install.sh:${RESET}"
                echo -e "${CYAN}tls / plain / auto${RESET}"
                echo
                echo -e "${YELLOW}Para no romper certificados, esta opción no modifica${RESET}"
                echo -e "${YELLOW}el servicio automáticamente.${RESET}"
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
                echo -e "${CYAN}${BOLD}ExecStart actual:${RESET}"
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
                    echo -e "${GREEN}✓ HCR reiniciado correctamente.${RESET}"
                else
                    echo
                    echo -e "${RED}❌ HCR no pudo reiniciar.${RESET}"
                fi
                pause
                ;;
            15)
                if systemctl is-active --quiet "$SERVICE"; then
                    systemctl stop "$SERVICE"
                    echo -e "${GREEN}✓ HCR detenido.${RESET}"
                else
                    systemctl start "$SERVICE"

                    if systemctl is-active --quiet "$SERVICE"; then
                        echo -e "${GREEN}✓ HCR iniciado.${RESET}"
                    else
                        echo -e "${RED}❌ HCR no pudo iniciar.${RESET}"
                    fi
                fi
                pause
                ;;
            16)
                clear_screen
                echo -e "${RED}${BOLD}Esto detendrá y deshabilitará HCR.${RESET}"
                echo -e "${YELLOW}El repositorio no será eliminado.${RESET}"
                echo
                read -r -p "$(echo -e "${YELLOW}Escribe SI para confirmar: ${RESET}")" answer

                if [ "$answer" = "SI" ]; then
                    systemctl disable --now "$SERVICE" 2>/dev/null || true
                    rm -f "$UNIT"
                    systemctl daemon-reload
                    systemctl reset-failed "$SERVICE" 2>/dev/null || true
                    echo -e "${GREEN}✓ HCR desinstalado.${RESET}"
                else
                    echo -e "${YELLOW}Cancelado.${RESET}"
                fi

                pause
                ;;
            0)
                echo
                echo -e "${CYAN}👋 Saliendo...${RESET}"
                exit 0
                ;;
            *)
                echo
                echo -e "${RED}❌ Opción inválida.${RESET}"
                sleep 1
                ;;
        esac
    done
}

require_root
require_service
main_menu
