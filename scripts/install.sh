#!/bin/zsh
# Compila Bitácora, la firma (si hay un certificado de desarrollo) y la instala.
#
# Con una firma estable macOS reconoce cada versión nueva como el mismo programa y conserva
# los permisos de Grabación de pantalla y Accesibilidad. Sin certificado se firma ad hoc y
# macOS puede volver a pedirlos.
#
# Variables opcionales:
#   BITACORA_SIGN_IDENTITY  identidad de codesign (por defecto, la primera "Apple Development"
#                           o, si no hay, el certificado local "Bitacora Local Signing")
#   BITACORA_BIN_DIR        carpeta de instalación (por defecto ~/.local/bin)
set -euo pipefail

cd "$(dirname "$0")/.."
default_dir="$HOME/.local/bin"
dest="${BITACORA_BIN_DIR:-$default_dir}"
bin=.build/release/bitacora

swift build -c release

local_identity="Bitacora Local Signing"
identity="${BITACORA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$identity" ]] && security find-certificate -c "$local_identity" >/dev/null 2>&1; then
  identity="$local_identity"
fi
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --identifier local.bitacora "$bin"
  echo "Firmado con: $identity"
else
  echo "Aviso: no hay certificado de firma; macOS puede volver a pedir los permisos (ver README)." >&2
fi

# Reemplazo atómico: un proceso que esté grabando nunca ve un archivo a medio copiar.
mkdir -p "$dest"
cp "$bin" "$dest/.bitacora.new"
mv -f "$dest/.bitacora.new" "$dest/bitacora"
echo "Instalado en $dest/bitacora"

# Reinicia el arranque automático para que use la versión nueva.
if [[ "$dest" == "$default_dir" ]] && launchctl print "gui/$(id -u)/local.bitacora.record" >/dev/null 2>&1; then
  "$dest/bitacora" install
fi
