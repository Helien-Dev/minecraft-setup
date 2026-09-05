#!/usr/bin/env bash
# package-instance.sh
#
# Herramienta de DESARROLLO (la corres tú, no tus amigos).
#
# Toma una instancia real de SKLauncher, le quita todo lo "personal"
# (partidas guardadas, screenshots, logs, lista de servidores, cachés
# regenerables), opcionalmente le mete mods extra dentro de mods/, y la
# empaqueta en un .tar.gz listo para subir a Cloudflare R2.
#
# Uso:
#   ./scripts/package-instance.sh
#   INSTANCE_DIR=~/.sklauncher/instances/all-the-mods-10-atm10 \
#     OUT=dist/atm10.tar.gz ./scripts/package-instance.sh
#
# Variables de entorno:
#   INSTANCE_DIR   Carpeta de la instancia a empaquetar (default: ATM10 To the Sky)
#   OUT            Ruta del .tar.gz de salida (default: dist/<id>-instance.tar.gz)
#   EXTRA_MODS_DIR Carpeta local con .jar extra que se copian a mods/ antes de empaquetar

set -euo pipefail

INSTANCE_DIR="${INSTANCE_DIR:-$HOME/.sklauncher/instances/all-the-mods-10-to-the-sky-atm10sky}"
INSTANCE_ID="$(basename "$INSTANCE_DIR")"
OUT="${OUT:-dist/${INSTANCE_ID}-instance.tar.gz}"
EXTRA_MODS_DIR="${EXTRA_MODS_DIR:-}"

# Carpetas/archivos que NO se distribuyen: son personales o se regeneran solas.
EXCLUDES=(
  --exclude="saves"
  --exclude="screenshots"
  --exclude="logs"
  --exclude="crash-reports"
  --exclude="servers.dat"
  --exclude="servers.dat_old"
  --exclude="command_history.txt"
  --exclude="downloads"
  --exclude="bin"                       # caché interna del propio launcher (Chromium/Crashpad)
  --exclude="natives"                   # nativos LWJGL, se regeneran por arquitectura
  --exclude=".mixin.out"
  --exclude="fancymenu_data"
  --exclude="dynamic-resource-pack-cache"
  --exclude="server-resource-packs"
  --exclude="observable_announce"
  --exclude="ESM"                       # estado del mod Observable ligado a tus mundos
)

if [ ! -d "$INSTANCE_DIR" ]; then
  echo "❌ No existe la carpeta de instancia: $INSTANCE_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "📦 Copiando '$INSTANCE_ID' a staging (excluyendo datos personales)..."
rsync -a "${EXCLUDES[@]}" "$INSTANCE_DIR"/ "$STAGE"/

if [ -n "$EXTRA_MODS_DIR" ]; then
  if [ ! -d "$EXTRA_MODS_DIR" ]; then
    echo "❌ EXTRA_MODS_DIR no existe: $EXTRA_MODS_DIR" >&2
    exit 1
  fi
  n=$(find "$EXTRA_MODS_DIR" -maxdepth 1 -name '*.jar' | wc -l)
  echo "➕ Copiando $n mod(s) extra desde $EXTRA_MODS_DIR a mods/..."
  mkdir -p "$STAGE/mods"
  cp -v "$EXTRA_MODS_DIR"/*.jar "$STAGE/mods/"
fi

echo "🗜️  Comprimiendo -> $OUT"
tar -czf "$OUT" -C "$STAGE" .

SIZE_HUMAN="$(du -h "$OUT" | cut -f1)"
SHA256="$(sha256sum "$OUT" | cut -d' ' -f1)"

echo
echo "✅ Listo: $OUT ($SIZE_HUMAN)"
echo "   sha256: $SHA256"
echo
echo "Siguiente paso: subí este archivo a tu bucket R2 y copiá la URL pública"
echo "en MODPACK_URL dentro de install.sh (o expórtala como variable de entorno"
echo "al correr install.sh)."
