#!/bin/bash

# =============================================
#   UFW Backup & Restore - by Claude
# =============================================

BACKUP_DIR="$HOME/ufw_backups"
DATE=$(date +"%Y%m%d_%H%M%S")
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║       UFW Backup & Restore Tool      ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_success() { echo -e "${GREEN}✔ $1${RESET}"; }
print_error()   { echo -e "${RED}✘ $1${RESET}"; }
print_info()    { echo -e "${YELLOW}➜ $1${RESET}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script requiere permisos de superusuario."
        echo "Ejecuta: sudo $0"
        exit 1
    fi
}

press_enter() {
    echo ""
    read -rp "  Presiona Enter para continuar..."
}

# ── Opción 1: Backup ─────────────────────────

do_backup() {
    print_header
    echo -e "${BOLD}  [ BACKUP DE REGLAS UFW ]${RESET}\n"

    mkdir -p "$BACKUP_DIR"

    BACKUP_PATH="$BACKUP_DIR/ufw_backup_$DATE"
    mkdir -p "$BACKUP_PATH"

    # Copiar archivos de configuración
    cp -r /etc/ufw/*.rules "$BACKUP_PATH/" 2>/dev/null
    cp /etc/ufw/ufw.conf   "$BACKUP_PATH/" 2>/dev/null

    # Guardar también el status legible
    ufw status verbose > "$BACKUP_PATH/ufw_status.txt" 2>/dev/null

    # Crear archivo tar
    TAR_FILE="$BACKUP_DIR/ufw_backup_$DATE.tar.gz"
    tar -czf "$TAR_FILE" -C "$BACKUP_DIR" "ufw_backup_$DATE" 2>/dev/null
    rm -rf "$BACKUP_PATH"

    if [[ -f "$TAR_FILE" ]]; then
        print_success "Backup creado exitosamente:"
        echo -e "  ${CYAN}$TAR_FILE${RESET}"
        echo ""
        print_info "Contenido del backup:"
        tar -tzf "$TAR_FILE" | sed 's/^/    /'
    else
        print_error "Error al crear el backup."
    fi

    press_enter
}

# ── Opción 2: Restaurar ──────────────────────

do_restore() {
    print_header
    echo -e "${BOLD}  [ RESTAURAR REGLAS UFW ]${RESET}\n"

    # Listar backups disponibles
    BACKUPS=("$BACKUP_DIR"/ufw_backup_*.tar.gz)

    if [[ ! -e "${BACKUPS[0]}" ]]; then
        print_error "No se encontraron backups en $BACKUP_DIR"
        press_enter
        return
    fi

    echo -e "  Backups disponibles:\n"
    INDEX=1
    for f in "${BACKUPS[@]}"; do
        FILENAME=$(basename "$f")
        SIZE=$(du -sh "$f" | cut -f1)
        echo -e "  ${CYAN}[$INDEX]${RESET} $FILENAME ${YELLOW}($SIZE)${RESET}"
        ((INDEX++))
    done

    echo ""
    read -rp "  Selecciona el número del backup a restaurar (0 para cancelar): " CHOICE

    if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then
        print_info "Operación cancelada."
        press_enter
        return
    fi

    SELECTED="${BACKUPS[$((CHOICE-1))]}"

    if [[ ! -f "$SELECTED" ]]; then
        print_error "Selección inválida."
        press_enter
        return
    fi

    echo ""
    print_info "Backup seleccionado: $(basename "$SELECTED")"
    read -rp "  ¿Confirmas la restauración? Esto sobreescribirá las reglas actuales. (s/N): " CONFIRM

    if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
        print_info "Operación cancelada."
        press_enter
        return
    fi

    # Hacer backup de seguridad antes de restaurar
    print_info "Creando backup de seguridad de las reglas actuales..."
    SAFETY_PATH="$BACKUP_DIR/pre_restore_$DATE.tar.gz"
    tar -czf "$SAFETY_PATH" -C /etc/ufw . 2>/dev/null
    print_success "Backup de seguridad: $SAFETY_PATH"

    # Extraer y restaurar
    TEMP_DIR=$(mktemp -d)
    tar -xzf "$SELECTED" -C "$TEMP_DIR" 2>/dev/null

    EXTRACTED=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)

    cp "$EXTRACTED"/*.rules /etc/ufw/ 2>/dev/null
    [[ -f "$EXTRACTED/ufw.conf" ]] && cp "$EXTRACTED/ufw.conf" /etc/ufw/
    rm -rf "$TEMP_DIR"

    # Recargar UFW
    ufw reload > /dev/null 2>&1

    print_success "Reglas restauradas y UFW recargado correctamente."
    echo ""
    print_info "Estado actual de UFW:"
    ufw status numbered

    press_enter
}

# ── Opción 3: Ver backups ────────────────────

do_list() {
    print_header
    echo -e "${BOLD}  [ BACKUPS DISPONIBLES ]${RESET}\n"

    BACKUPS=("$BACKUP_DIR"/ufw_backup_*.tar.gz)

    if [[ ! -e "${BACKUPS[0]}" ]]; then
        print_error "No se encontraron backups en $BACKUP_DIR"
        press_enter
        return
    fi

    printf "  %-45s %s\n" "Archivo" "Tamaño"
    echo "  ──────────────────────────────────────────────────────"
    for f in "${BACKUPS[@]}"; do
        FILENAME=$(basename "$f")
        SIZE=$(du -sh "$f" | cut -f1)
        printf "  ${CYAN}%-45s${RESET} ${YELLOW}%s${RESET}\n" "$FILENAME" "$SIZE"
    done

    echo ""
    print_info "Directorio: $BACKUP_DIR"

    press_enter
}

# ── Opción 4: Ver reglas actuales ────────────

do_status() {
    print_header
    echo -e "${BOLD}  [ REGLAS UFW ACTUALES ]${RESET}\n"
    ufw status verbose
    press_enter
}

# ── Opción 5: Eliminar backup ────────────────

do_delete() {
    print_header
    echo -e "${BOLD}  [ ELIMINAR BACKUP ]${RESET}\n"

    BACKUPS=("$BACKUP_DIR"/ufw_backup_*.tar.gz)

    if [[ ! -e "${BACKUPS[0]}" ]]; then
        print_error "No se encontraron backups en $BACKUP_DIR"
        press_enter
        return
    fi

    echo -e "  Backups disponibles:\n"
    INDEX=1
    for f in "${BACKUPS[@]}"; do
        FILENAME=$(basename "$f")
        SIZE=$(du -sh "$f" | cut -f1)
        echo -e "  ${CYAN}[$INDEX]${RESET} $FILENAME ${YELLOW}($SIZE)${RESET}"
        ((INDEX++))
    done

    echo ""
    read -rp "  Selecciona el número a eliminar (0 para cancelar): " CHOICE

    if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then
        print_info "Operación cancelada."
        press_enter
        return
    fi

    SELECTED="${BACKUPS[$((CHOICE-1))]}"

    if [[ ! -f "$SELECTED" ]]; then
        print_error "Selección inválida."
        press_enter
        return
    fi

    read -rp "  ¿Eliminar $(basename "$SELECTED")? (s/N): " CONFIRM
    if [[ "$CONFIRM" == "s" || "$CONFIRM" == "S" ]]; then
        rm -f "$SELECTED"
        print_success "Backup eliminado."
    else
        print_info "Operación cancelada."
    fi

    press_enter
}

# ── Menú principal ───────────────────────────

main_menu() {
    check_root

    while true; do
        print_header
        echo -e "  ${BOLD}Selecciona una opción:${RESET}\n"
        echo -e "  ${CYAN}[1]${RESET} Crear backup de reglas UFW"
        echo -e "  ${CYAN}[2]${RESET} Restaurar backup"
        echo -e "  ${CYAN}[3]${RESET} Ver backups disponibles"
        echo -e "  ${CYAN}[4]${RESET} Ver reglas UFW actuales"
        echo -e "  ${CYAN}[5]${RESET} Eliminar un backup"
        echo -e "  ${CYAN}[0]${RESET} Salir"
        echo ""
        read -rp "  Opción: " OPT

        case $OPT in
            1) do_backup  ;;
            2) do_restore ;;
            3) do_list    ;;
            4) do_status  ;;
            5) do_delete  ;;
            0) echo -e "\n  ${GREEN}¡Hasta luego!${RESET}\n"; exit 0 ;;
            *) print_error "Opción inválida."; sleep 1 ;;
        esac
    done
}

main_menu
