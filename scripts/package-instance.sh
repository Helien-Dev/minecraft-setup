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
# Además genera un manifest.json (nombre + sha256 + tamaño de cada mod) y,
# si hay un remote de rclone configurado, publica todo a R2:
#   - el .tar.gz completo (para instalaciones nuevas)
#   - cada mod como objeto individual bajo <prefix>/mods/
#   - el manifest.json bajo <prefix>/manifest.json
# Esto es lo que permite que install.sh, en corridas posteriores, actualice
# solo los mods que cambiaron en vez de bajar todo de nuevo.
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
#   R2_REMOTE      Nombre del remote de rclone (default: r2)
#   R2_BUCKET      Bucket de R2 (default: minecraft-data)
#   R2_PREFIX      Prefijo dentro del bucket para manifest.json y mods/ (default: atm10sky)
#   SKIP_UPLOAD    Si es "1", solo arma los archivos localmente, no publica a R2

set -euo pipefail

INSTANCE_DIR="${INSTANCE_DIR:-$HOME/.sklauncher/instances/all-the-mods-10-to-the-sky-atm10sky}"
INSTANCE_ID="$(basename "$INSTANCE_DIR")"
OUT="${OUT:-dist/${INSTANCE_ID}-instance.tar.gz}"
EXTRA_MODS_DIR="${EXTRA_MODS_DIR:-}"
MANIFEST_OUT="$(dirname "$OUT")/manifest.json"
R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-minecraft-data}"
R2_PREFIX="${R2_PREFIX:-atm10sky}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"

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

echo "🧾 Generando manifest.json de mods/ (hash de cada mod, para updates incrementales)..."
python3 - "$STAGE/mods" "$MANIFEST_OUT" <<'PYEOF'
import sys, os, hashlib, json, datetime

mods_dir, out_path = sys.argv[1], sys.argv[2]
mods = {}
for fname in sorted(os.listdir(mods_dir)):
    fpath = os.path.join(mods_dir, fname)
    if not os.path.isfile(fpath):
        continue
    h = hashlib.sha256()
    with open(fpath, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    mods[fname] = {"sha256": h.hexdigest(), "size": os.path.getsize(fpath)}

manifest = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "mods": mods,
}
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
print(f"   {len(mods)} mods en el manifest")
PYEOF

echo
echo "✅ Listo: $OUT ($SIZE_HUMAN)"
echo "   sha256: $SHA256"
echo "   manifest: $MANIFEST_OUT"

if [ "$SKIP_UPLOAD" = "1" ] || ! command -v rclone >/dev/null 2>&1 || ! rclone listremotes 2>/dev/null | grep -q "^${R2_REMOTE}:$"; then
  echo
  echo "ℹ️  No se publicó a R2 automáticamente (SKIP_UPLOAD=1, o no hay un remote de rclone"
  echo "   llamado '$R2_REMOTE' configurado). Subí manualmente $OUT y $MANIFEST_OUT,"
  echo "   y sincronizá $STAGE/mods a <bucket>/$R2_PREFIX/mods/ antes de que termine este script"
  echo "   (esa carpeta temporal se borra al salir)."
  exit 0
fi

echo
echo "☁️  Publicando a R2 ($R2_REMOTE:$R2_BUCKET)..."
echo "  -> $(basename "$OUT")"
rclone copyto "$OUT" "$R2_REMOTE:$R2_BUCKET/$(basename "$OUT")" --s3-no-check-bucket
echo "  -> $R2_PREFIX/manifest.json"
rclone copyto "$MANIFEST_OUT" "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX/manifest.json" --s3-no-check-bucket
echo "  -> $R2_PREFIX/mods/ (solo sube lo nuevo/cambiado, borra lo que ya no está)"
rclone sync "$STAGE/mods" "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX/mods" --s3-no-check-bucket --progress

echo
echo "✅ Publicado. Los amigos que ya instalaron antes solo necesitan volver a"
echo "   correr install.sh para recibir estos mods nuevos/actualizados."
