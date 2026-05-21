#!/bin/bash

# =============================================
#   Port Scanner & Manager - by Claude
# =============================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║     Port Scanner & Manager Tool      ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_success() { echo -e "${GREEN}✔ $1${RESET}"; }
print_error()   { echo -e "${RED}✘ $1${RESET}"; }
print_info()    { echo -e "${YELLOW}➜ $1${RESET}"; }
print_warn()    { echo -e "${RED}⚠ $1${RESET}"; }

press_enter() {
    echo ""
    read -rp "  Presiona Enter para continuar..."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script requiere permisos de superusuario."
        echo "Ejecuta: sudo $0"
        exit 1
    fi
}

# Conocidos puertos comunes
describe_port() {
    case $1 in
        21)   echo "FTP" ;;
        22)   echo "SSH" ;;
        23)   echo "Telnet" ;;
        25)   echo "SMTP" ;;
        53)   echo "DNS" ;;
        80)   echo "HTTP" ;;
        110)  echo "POP3" ;;
        143)  echo "IMAP" ;;
        443)  echo "HTTPS" ;;
        3000) echo "App/Node.js/React" ;;
        3306) echo "MySQL" ;;
        5432) echo "PostgreSQL" ;;
        5672) echo "RabbitMQ" ;;
        6379) echo "Redis" ;;
        8080) echo "HTTP Alt" ;;
        8443) echo "HTTPS Alt" ;;
        8888) echo "Jupyter/App" ;;
        9200) echo "Elasticsearch" ;;
        27017)echo "MongoDB" ;;
        *)    echo "Desconocido" ;;
    esac
}

# Riesgo por puerto
risk_port() {
    case $1 in
        22)  echo "MEDIO" ;;
        80)  echo "BAJO" ;;
        443) echo "BAJO" ;;
        *)   echo "ALTO" ;;
    esac
}

risk_color() {
    case $1 in
        "BAJO")  echo "${GREEN}" ;;
        "MEDIO") echo "${YELLOW}" ;;
        "ALTO")  echo "${RED}" ;;
        *)       echo "${RESET}" ;;
    esac
}

# ── Obtener puertos expuestos ─────────────────

get_exposed_ports() {
    # Puertos escuchando en 0.0.0.0 o :: (expuestos públicamente)
    ss -tulnp 2>/dev/null | awk '
        /LISTEN|UNCONN/ {
            addr = $5
            # Excluir localhost
            if (addr !~ /^127\./ && addr !~ /^\[::1\]/ && addr !~ /^127\.0\.0\.53/ && addr !~ /^127\.0\.0\.54/) {
                print $0
            }
        }
    '
}

# ── Opción 1: Escanear puertos expuestos ─────

do_scan() {
    print_header
    echo -e "${BOLD}  [ PUERTOS EXPUESTOS A INTERNET ]${RESET}\n"

    EXPOSED=$(get_exposed_ports)

    if [[ -z "$EXPOSED" ]]; then
        print_success "No se detectaron puertos expuestos públicamente."
        press_enter
        return
    fi

    printf "  %-8s %-8s %-22s %-20s %-8s %s\n" "Proto" "Estado" "Dirección:Puerto" "Servicio" "Riesgo" "Proceso"
    echo "  ─────────────────────────────────────────────────────────────────────────────────"

    while IFS= read -r line; do
        PROTO=$(echo "$line" | awk '{print $1}')
        STATE=$(echo "$line" | awk '{print $2}')
        ADDR=$(echo "$line" | awk '{print $5}')
        PORT=$(echo "$ADDR" | rev | cut -d: -f1 | rev)
        PROCESS=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo "—")
        SERVICE=$(describe_port "$PORT")
        RISK=$(risk_port "$PORT")
        RCOLOR=$(risk_color "$RISK")

        printf "  %-8s %-8s %-22s %-20s ${RCOLOR}%-8s${RESET} %s\n" \
            "$PROTO" "$STATE" "$ADDR" "$SERVICE" "$RISK" "$PROCESS"
    done <<< "$EXPOSED"

    echo ""
    echo -e "  ${DIM}Leyenda: ${GREEN}BAJO${RESET}${DIM} = normal  ${YELLOW}MEDIO${RESET}${DIM} = revisar  ${RED}ALTO${RESET}${DIM} = considerar cerrar${RESET}"

    press_enter
}

# ── Opción 2: Cerrar un puerto con UFW ───────

do_close_port() {
    print_header
    echo -e "${BOLD}  [ CERRAR PUERTO CON UFW ]${RESET}\n"

    EXPOSED=$(get_exposed_ports)

    if [[ -z "$EXPOSED" ]]; then
        print_success "No hay puertos expuestos públicamente."
        press_enter
        return
    fi

    echo -e "  Puertos expuestos detectados:\n"

    declare -a PORTS_LIST
    INDEX=1

    while IFS= read -r line; do
        ADDR=$(echo "$line" | awk '{print $5}')
        PORT=$(echo "$ADDR" | rev | cut -d: -f1 | rev)
        PROTO=$(echo "$line" | awk '{print $1}')
        SERVICE=$(describe_port "$PORT")
        RISK=$(risk_port "$PORT")
        RCOLOR=$(risk_color "$RISK")

        echo -e "  ${CYAN}[$INDEX]${RESET} Puerto ${BOLD}$PORT/$PROTO${RESET} — $SERVICE  ${RCOLOR}[$RISK]${RESET}"
        PORTS_LIST+=("$PORT/$PROTO")
        ((INDEX++))
    done <<< "$EXPOSED"

    echo ""
    read -rp "  Selecciona el número del puerto a cerrar (0 para cancelar): " CHOICE

    if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then
        print_info "Operación cancelada."
        press_enter
        return
    fi

    SELECTED="${PORTS_LIST[$((CHOICE-1))]}"
    PORT_NUM=$(echo "$SELECTED" | cut -d/ -f1)

    if [[ -z "$SELECTED" ]]; then
        print_error "Selección inválida."
        press_enter
        return
    fi

    echo ""
    print_warn "Vas a bloquear el puerto $SELECTED con UFW."
    read -rp "  ¿Confirmas? (s/N): " CONFIRM

    if [[ "$CONFIRM" == "s" || "$CONFIRM" == "S" ]]; then
        ufw deny "$SELECTED" > /dev/null 2>&1
        print_success "Regla agregada: deny $SELECTED"
        echo ""
        print_info "Verifica con: sudo ufw status numbered"
    else
        print_info "Operación cancelada."
    fi

    press_enter
}

# ── Opción 3: Ver todos los puertos (local + expuesto) ──

do_all_ports() {
    print_header
    echo -e "${BOLD}  [ TODOS LOS PUERTOS EN USO ]${RESET}\n"

    printf "  %-8s %-10s %-28s %-20s %s\n" "Proto" "Estado" "Dirección:Puerto" "Servicio" "Proceso"
    echo "  ──────────────────────────────────────────────────────────────────────────────────"

    ss -tulnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        PROTO=$(echo "$line" | awk '{print $1}')
        STATE=$(echo "$line" | awk '{print $2}')
        ADDR=$(echo "$line" | awk '{print $5}')
        PORT=$(echo "$ADDR" | rev | cut -d: -f1 | rev)
        PROCESS=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo "—")
        SERVICE=$(describe_port "$PORT")

        # Colorear según si es local o expuesto
        if echo "$ADDR" | grep -qE '^127\.|^\[::1\]'; then
            COLOR="${DIM}"
            LABEL="local"
        else
            COLOR="${CYAN}"
            LABEL="expuesto"
        fi

        printf "  ${COLOR}%-8s %-10s %-28s %-20s %s${RESET}\n" \
            "$PROTO" "$STATE" "$ADDR" "$SERVICE ($LABEL)" "$PROCESS"
    done

    echo ""
    echo -e "  ${DIM}Blanco = expuesto a internet   Tenue = solo localhost${RESET}"

    press_enter
}

# ── Opción 4: Ver qué proceso usa un puerto ──

do_find_process() {
    print_header
    echo -e "${BOLD}  [ BUSCAR PROCESO POR PUERTO ]${RESET}\n"

    read -rp "  Ingresa el número de puerto a consultar: " PORT

    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        print_error "Puerto inválido."
        press_enter
        return
    fi

    echo ""
    print_info "Resultado de ss:"
    ss -tulnp | grep ":$PORT" || echo "  No encontrado en ss."

    echo ""
    print_info "Resultado de lsof:"
    lsof -i :"$PORT" 2>/dev/null || echo "  No encontrado en lsof."

    press_enter
}

# ── Opción 5: Resumen de riesgo ──────────────

do_risk_summary() {
    print_header
    echo -e "${BOLD}  [ RESUMEN DE RIESGO ]${RESET}\n"

    ALTO=0
    MEDIO=0
    BAJO=0

    while IFS= read -r line; do
        ADDR=$(echo "$line" | awk '{print $5}')
        PORT=$(echo "$ADDR" | rev | cut -d: -f1 | rev)
        RISK=$(risk_port "$PORT")
        case $RISK in
            "ALTO")  ((ALTO++)) ;;
            "MEDIO") ((MEDIO++)) ;;
            "BAJO")  ((BAJO++)) ;;
        esac
    done <<< "$(get_exposed_ports)"

    echo -e "  Puertos expuestos clasificados:\n"
    echo -e "  ${RED}⚠  ALTO riesgo:  $ALTO puerto(s)${RESET}   — considera cerrarlos"
    echo -e "  ${YELLOW}▲  MEDIO riesgo: $MEDIO puerto(s)${RESET}   — monitorear"
    echo -e "  ${GREEN}✔  BAJO riesgo:  $BAJO puerto(s)${RESET}   — normales (HTTP/HTTPS/SSH)"

    TOTAL=$((ALTO + MEDIO + BAJO))
    echo ""
    echo -e "  Total de puertos expuestos: ${BOLD}$TOTAL${RESET}"

    if [[ $ALTO -gt 0 ]]; then
        echo ""
        print_warn "Tienes $ALTO puerto(s) de ALTO riesgo expuestos. Usa la opción [2] para cerrarlos."
    elif [[ $MEDIO -gt 0 ]]; then
        echo ""
        print_info "Tienes $MEDIO puerto(s) de riesgo MEDIO. Verifica que sean necesarios."
    else
        echo ""
        print_success "Tu configuración de puertos se ve segura."
    fi

    press_enter
}

# ── Menú principal ───────────────────────────

main_menu() {
    check_root

    while true; do
        print_header
        echo -e "  ${BOLD}Selecciona una opción:${RESET}\n"
        echo -e "  ${CYAN}[1]${RESET} Escanear puertos expuestos a internet"
        echo -e "  ${CYAN}[2]${RESET} Cerrar un puerto expuesto con UFW"
        echo -e "  ${CYAN}[3]${RESET} Ver todos los puertos (locales + expuestos)"
        echo -e "  ${CYAN}[4]${RESET} Buscar qué proceso usa un puerto"
        echo -e "  ${CYAN}[5]${RESET} Resumen de riesgo"
        echo -e "  ${CYAN}[0]${RESET} Salir"
        echo ""
        read -rp "  Opción: " OPT

        case $OPT in
            1) do_scan         ;;
            2) do_close_port   ;;
            3) do_all_ports    ;;
            4) do_find_process ;;
            5) do_risk_summary ;;
            0) echo -e "\n  ${GREEN}¡Hasta luego!${RESET}\n"; exit 0 ;;
            *) print_error "Opción inválida."; sleep 1 ;;
        esac
    done
}

main_menu
