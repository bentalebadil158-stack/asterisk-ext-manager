#!/usr/bin/env bash
# =============================================================================
# asterisk-ext-manager.sh
# Gestor de extensiones PJSIP para Asterisk con menús whiptail (laboratorio).
#
# Qué hace:
#   - Alta de extensiones (endpoint + auth + aor) con contraseña robusta
#   - Baja de extensiones
#   - Listado de extensiones gestionadas
#   - Estado de registros SIP (pjsip show contacts / endpoints)
#   - Recarga de PJSIP y del dialplan
#
# Cómo funciona:
#   Las extensiones se escriben SOLO en /etc/asterisk/pjsip_lab_extensions.conf
#   (un archivo aparte que se incluye desde pjsip.conf). Así nunca tocamos tu
#   pjsip.conf a mano y las bajas son limpias.
#
# Uso:  sudo bash asterisk-ext-manager.sh
#       Si Asterisk no está instalado, el script ofrece instalarlo (apt).
#       Modo prueba sin Asterisk: SKIP_INSTALL_CHECK=1 AST_DIR=/tmp/ast-test bash asterisk-ext-manager.sh
# =============================================================================

set -u

# ---- Configuración (puedes sobreescribirla con variables de entorno) --------
AST_DIR="${AST_DIR:-/etc/asterisk}"
EXT_FILE="$AST_DIR/pjsip_lab_extensions.conf"
PJSIP_CONF="$AST_DIR/pjsip.conf"
EXTENSIONS_CONF="$AST_DIR/extensions.conf"
CONTEXTO="${CONTEXTO:-internos}"      # contexto de dialplan de las extensiones
PATRON="${PATRON:-_1XXX}"             # patrón del dialplan (1001..1999). Ej: _XXX para 3 dígitos
SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
TITULO="Gestor de extensiones Asterisk"

# ---- Utilidades -------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

msg() {   # msg "texto" [alto] [ancho]
    whiptail --title "$TITULO" --msgbox "$1" "${2:-12}" "${3:-72}"
}

backup() {   # copia de seguridad con fecha antes de modificar un archivo
    [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
}

fijar_permisos() {   # el archivo contiene contraseñas: solo asterisk/root
    if id asterisk >/dev/null 2>&1; then
        chown asterisk:asterisk "$EXT_FILE" 2>/dev/null
    fi
    chmod 640 "$EXT_FILE" 2>/dev/null
}

generar_password() {
    openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-16
}

existe_ext() {   # ¿ya está gestionada por este script?
    grep -qE "^; BEGIN $1 \|" "$EXT_FILE" 2>/dev/null
}

# ---- Preparación inicial ----------------------------------------------------
preparar_archivo() {
    if [[ ! -f "$EXT_FILE" ]]; then
        printf '; Extensiones gestionadas por asterisk-ext-manager.sh\n; NO editar los bloques BEGIN/END a mano.\n\n' > "$EXT_FILE"
        fijar_permisos
    fi
}

asegurar_include() {
    grep -qE '^#include[[:space:]]+"?pjsip_lab_extensions\.conf' "$PJSIP_CONF" 2>/dev/null && return 0
    if whiptail --title "$TITULO" --yesno \
        "pjsip.conf todavía no incluye las extensiones de este script.\n\n¿Añadir '#include pjsip_lab_extensions.conf' al final de pjsip.conf?\n(Se hace copia de seguridad antes.)" 12 72; then
        backup "$PJSIP_CONF"
        printf '\n#include pjsip_lab_extensions.conf\n' >> "$PJSIP_CONF"
        return 0
    fi
    return 1
}

asegurar_contexto() {
    grep -q "^\[$CONTEXTO\]" "$EXTENSIONS_CONF" 2>/dev/null && return 0
    if whiptail --title "$TITULO" --yesno \
        "No existe el contexto [$CONTEXTO] en extensions.conf.\n\n¿Crear un dialplan básico para llamadas internas con el patrón $PATRON?\n(Se hace copia de seguridad antes.)" 13 72; then
        backup "$EXTENSIONS_CONF"
        {
            printf '\n[%s]\n' "$CONTEXTO"
            printf 'exten => %s,1,NoOp(Llamada interna a ${EXTEN})\n' "$PATRON"
            printf ' same => n,Dial(PJSIP/${EXTEN},25)\n'
            printf ' same => n,Hangup()\n'
        } >> "$EXTENSIONS_CONF"
        return 0
    fi
    return 1
}

# ---- Escritura / borrado de bloques ----------------------------------------
escribir_bloque() {   # escribir_bloque EXT NOMBRE PASSWORD
    local ext="$1" nombre="$2" pass="$3"
    cat >> "$EXT_FILE" <<EOF
; BEGIN $ext | $nombre
[$ext]
type=endpoint
context=$CONTEXTO
disallow=all
allow=ulaw,alaw
auth=$ext
aors=$ext
callerid="$nombre" <$ext>
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes

[$ext]
type=auth
auth_type=userpass
username=$ext
password=$pass

[$ext]
type=aor
max_contacts=1
remove_existing=yes
qualify_frequency=30
; END $ext

EOF
}

borrar_bloque() {   # borrar_bloque EXT (EXT ya validada como numérica)
    sed -i "/^; BEGIN $1 |/,/^; END $1\$/d" "$EXT_FILE"
}

recargar_asterisk() {
    local salida
    if ! command -v asterisk >/dev/null 2>&1; then
        msg "No encuentro el comando 'asterisk'. Recarga a mano cuando esté instalado." 8
        return 1
    fi
    salida=$( { asterisk -rx "pjsip reload"; asterisk -rx "dialplan reload"; } 2>&1 )
    msg "Recarga ejecutada:\n\n${salida:-sin salida}" 16 72
}

# ---- Opciones del menú ------------------------------------------------------
alta_extension() {
    local ext nombre pass pass_generada=0

    ext=$(whiptail --title "$TITULO" --inputbox "Número de extensión (3 a 5 dígitos).\nDebe encajar con el patrón del dialplan: $PATRON" 11 64 "" 3>&1 1>&2 2>&3) || return
    [[ "$ext" =~ ^[0-9]{3,5}$ ]] || { msg "Extensión no válida. Solo dígitos, entre 3 y 5." 8; return; }

    if existe_ext "$ext"; then
        msg "La extensión $ext ya existe. Dala de baja primero si quieres recrearla." 9
        return
    fi
    if grep -qE "^\[$ext\]" "$PJSIP_CONF" 2>/dev/null; then
        msg "La extensión $ext ya está definida a mano en pjsip.conf.\nUsa otro número o elimínala de ahí para evitar conflictos." 10
        return
    fi

    nombre=$(whiptail --title "$TITULO" --inputbox "Nombre del usuario (aparece como identificador de llamada):" 10 64 "Extension $ext" 3>&1 1>&2 2>&3) || return
    nombre=${nombre//[^[:alnum:] ._-]/}
    [[ -n "$nombre" ]] || nombre="Extension $ext"

    pass=$(whiptail --title "$TITULO" --passwordbox "Contraseña SIP (mínimo 10 caracteres).\nDéjala vacía para generar una aleatoria de 16." 11 64 3>&1 1>&2 2>&3) || return
    if [[ -z "$pass" ]]; then
        pass=$(generar_password)
        pass_generada=1
    elif ! [[ "$pass" =~ ^[A-Za-z0-9._@%+=-]{10,}$ ]]; then
        msg "Contraseña no válida: mínimo 10 caracteres y solo letras, números y . _ @ % + = -" 9
        return
    fi

    preparar_archivo
    asegurar_include  || { msg "Sin el #include en pjsip.conf las extensiones no se cargarán. Operación cancelada." 9; return; }
    desactivar_chan_sip
    asegurar_transporte || { msg "Sin un transporte PJSIP los teléfonos no podrán registrarse. Operación cancelada." 9; return; }
    asegurar_contexto || { msg "Sin el contexto [$CONTEXTO] las llamadas no funcionarán. Operación cancelada." 9; return; }

    backup "$EXT_FILE"
    escribir_bloque "$ext" "$nombre" "$pass"
    fijar_permisos
    recargar_asterisk

    local aviso=""
    (( pass_generada )) && aviso="\n(Contraseña generada: anótala ahora, no se vuelve a mostrar.)"
    msg "Extensión creada. Datos para el softphone:\n\n  Usuario:     $ext\n  Contraseña:  $pass\n  Servidor:    ${SERVER_IP:-<IP del servidor>}\n  Puerto:      5060 / UDP\n  Transporte:  UDP$aviso\n\nComprueba el registro en 'Estado de registros'." 18 72
}

baja_extension() {
    local items=() ext nombre linea
    [[ -f "$EXT_FILE" ]] || { msg "Todavía no hay extensiones gestionadas." 7; return; }

    while IFS=$'\t' read -r ext nombre; do
        [[ -n "$ext" ]] && items+=("$ext" "$nombre")
    done < <(grep -E '^; BEGIN ' "$EXT_FILE" | sed -E 's/^; BEGIN ([0-9]+) \| (.*)$/\1\t\2/')

    (( ${#items[@]} )) || { msg "No hay extensiones que borrar." 7; return; }

    ext=$(whiptail --title "$TITULO" --menu "Elige la extensión a dar de baja:" 18 64 8 "${items[@]}" 3>&1 1>&2 2>&3) || return

    if whiptail --title "$TITULO" --yesno "¿Seguro que quieres borrar la extensión $ext?" 8 60; then
        backup "$EXT_FILE"
        borrar_bloque "$ext"
        fijar_permisos
        recargar_asterisk
    fi
}

listar_extensiones() {
    local lista
    lista=$(grep -E '^; BEGIN ' "$EXT_FILE" 2>/dev/null | sed -E 's/^; BEGIN ([0-9]+) \| (.*)$/  \1  -  \2/')
    if [[ -z "$lista" ]]; then
        msg "No hay extensiones gestionadas por este script." 7
    else
        msg "Extensiones configuradas:\n\n$lista" 18 64
    fi
}

estado_registros() {
    local tmp
    if ! command -v asterisk >/dev/null 2>&1; then
        msg "No encuentro el comando 'asterisk'." 7
        return
    fi
    tmp=$(mktemp)
    {
        echo "=== systemctl is-active asterisk: $(systemctl is-active asterisk 2>&1) ==="
        echo
        echo "=== pjsip show contacts ==="
        asterisk -rx "pjsip show contacts"
        echo
        echo "=== pjsip show endpoints ==="
        asterisk -rx "pjsip show endpoints"
    } > "$tmp" 2>&1
    whiptail --title "$TITULO" --scrolltext --textbox "$tmp" 24 100
    rm -f "$tmp"
}

# ---- Instalación de Asterisk (si no está) -----------------------------------
instalar_asterisk() {
    local log rc
    command -v apt-get >/dev/null 2>&1 || { msg "El instalador automático solo soporta Ubuntu/Debian (apt)." 8; return 1; }

    log=$(mktemp)
    whiptail --title "$TITULO" --infobox "Instalando Asterisk desde los repositorios...\nPuede tardar unos minutos." 8 56
    { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y asterisk; } >"$log" 2>&1
    rc=$?
    if (( rc != 0 )); then
        whiptail --title "$TITULO" --scrolltext --textbox "$log" 24 100
        rm -f "$log"
        return 1
    fi
    rm -f "$log"

    systemctl enable --now asterisk >/dev/null 2>&1
    sleep 2
    msg "Asterisk instalado.\n\nVersión:  $(asterisk -V 2>&1)\nServicio: $(systemctl is-active asterisk 2>&1)" 11
}

comprobar_asterisk() {
    [[ -n "${SKIP_INSTALL_CHECK:-}" ]] && return 0     # modo prueba (sin Asterisk real)
    if command -v asterisk >/dev/null 2>&1 && [[ -d "$AST_DIR" ]]; then
        return 0
    fi
    if whiptail --title "$TITULO" --yesno "Asterisk no está instalado en este equipo.\n\n¿Quieres instalarlo ahora con apt?" 10 64; then
        instalar_asterisk || return 1
        [[ -d "$AST_DIR" ]]
    else
        return 1
    fi
}

desactivar_chan_sip() {   # chan_sip (SIP antiguo) puede ocupar el 5060 y bloquear PJSIP
    local mc="$AST_DIR/modules.conf"
    command -v asterisk >/dev/null 2>&1 || return 0
    [[ -f "$mc" ]] || return 0
    grep -qE '^[[:space:]]*noload[[:space:]]*=>?[[:space:]]*chan_sip\.so' "$mc" && return 0
    asterisk -rx "module show like chan_sip" 2>/dev/null | grep -q 'chan_sip\.so' || return 0
    if whiptail --title "$TITULO" --yesno \
        "El módulo antiguo chan_sip está cargado y ocupa el puerto 5060, lo que impide que PJSIP cree su transporte.\n\n¿Desactivarlo (noload) y reiniciar Asterisk?\n(Se hace copia de seguridad de modules.conf.)" 14 72; then
        backup "$mc"
        if grep -q '^\[modules\]' "$mc"; then
            sed -i '/^\[modules\]/a noload = chan_sip.so' "$mc"
        else
            printf '\n[modules]\nnoload = chan_sip.so\n' >> "$mc"
        fi
        systemctl restart asterisk
        sleep 2
    fi
    return 0
}

asegurar_transporte() {   # PJSIP necesita al menos un transporte (UDP 5060) para registrar teléfonos
    grep -qEh '^[[:space:]]*type[[:space:]]*=[[:space:]]*transport' "$AST_DIR"/pjsip*.conf 2>/dev/null && return 0
    if whiptail --title "$TITULO" --yesno \
        "No hay ningún transporte PJSIP definido.\n\n¿Añadir [transport-udp] (UDP 5060) a pjsip.conf?\n(Se hace copia de seguridad antes.)" 12 66; then
        backup "$PJSIP_CONF"
        printf '\n[transport-udp]\ntype=transport\nprotocol=udp\nbind=0.0.0.0:5060\n' >> "$PJSIP_CONF"
        return 0
    fi
    return 1
}

# ---- Programa principal -----------------------------------------------------
menu_principal() {
    local op
    while true; do
        op=$(whiptail --title "$TITULO" --cancel-button "Salir" \
            --menu "Servidor: ${SERVER_IP:-?}   |   Archivo: $EXT_FILE" 18 78 6 \
            "1" "Alta de extensión" \
            "2" "Baja de extensión" \
            "3" "Listar extensiones" \
            "4" "Estado de registros (contacts / endpoints)" \
            "5" "Recargar PJSIP y dialplan" \
            "6" "Salir" 3>&1 1>&2 2>&3) || break
        case "$op" in
            1) alta_extension ;;
            2) baja_extension ;;
            3) listar_extensiones ;;
            4) estado_registros ;;
            5) recargar_asterisk ;;
            6) break ;;
        esac
    done
    clear
}

main() {
    [[ $EUID -eq 0 ]] || die "Ejecuta el script con sudo."
    command -v whiptail >/dev/null 2>&1 || die "Falta whiptail: sudo apt install whiptail"
    command -v openssl  >/dev/null 2>&1 || die "Falta openssl: sudo apt install openssl"
    comprobar_asterisk || die "Asterisk no está instalado. Instálalo y vuelve a ejecutar el script."
    [[ -d "$AST_DIR" ]] || die "No existe $AST_DIR."
    menu_principal
}

# Solo ejecuta main si el script se lanza directamente (permite hacer 'source' para pruebas)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

