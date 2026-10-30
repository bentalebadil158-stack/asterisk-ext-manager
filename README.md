# Gestor de extensiones PJSIP para Asterisk

Script interactivo en Bash para administrar extensiones de un laboratorio Asterisk mediante `whiptail`. Mantiene las extensiones gestionadas en `pjsip_lab_extensions.conf`, separado de la configuración principal.

Incluye alta y baja de extensiones, listado, consulta del estado de registros y recarga de PJSIP y dialplan. La contraseña SIP se guarda en el archivo de extensiones con permisos restringidos.

## Requisitos

- Asterisk con PJSIP
- Bash, `whiptail` y `openssl`
- Acceso `root` o ejecución con `sudo`

En Debian/Ubuntu, instala `whiptail` y OpenSSL si hacen falta:

```bash
sudo apt install whiptail openssl
```

## Uso

```bash
sudo ./asterisk-ext-manager.sh
```

Al crear la primera extensión, el script puede añadir el `#include` a `pjsip.conf` y crear el contexto de dialplan configurado. Por defecto, usa el contexto `internos` y el patrón `_1XXX`. Las opciones `AST_DIR`, `CONTEXTO`, `PATRON` y `SERVER_IP` pueden configurarse mediante variables de entorno.

Usa este gestor solo en un entorno que administres. Protege las copias de seguridad y el archivo de extensiones, ya que contienen credenciales SIP. Para acceso remoto, limita SIP/RTP a una red de confianza, por ejemplo mediante WireGuard, y no expongas SIP directamente a Internet.
