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
# Empaqueta UN perfil de UN modpack del catálogo (catalog.json). Los nombres
# de los archivos y las rutas en R2 salen del catálogo, así que el script no
# sabe nada de modpacks concretos.
#
# Además genera el manifest.json del perfil (nombre + sha256 + tamaño de cada
# mod) y, si hay un remote de rclone configurado, publica todo a R2:
#   - el .tar.gz del perfil (para instalaciones nuevas)
#   - cada mod como objeto individual bajo <prefix>/mods/ (compartido entre
#     perfiles del mismo modpack: el mismo archivo se sube una sola vez)
#   - el manifest.json del perfil
# Esto es lo que permite que install.sh, en corridas posteriores, actualice
# solo los mods que cambiaron en vez de bajar todo de nuevo.
#
# catalog.json NO se publica desde aquí (ver README, paso "Publicar el
# catálogo"): así no listas un perfil que todavía no subiste.
#
# Uso:
#   ./scripts/package-instance.sh <modpack-id> <perfil-id>
#   INSTANCE_DIR=~/Downloads/Neo-lowprofile/NeoLowProfile \
#     ./scripts/package-instance.sh neofresh low
#
# Variables de entorno:
#   INSTANCE_DIR   Carpeta de la instancia a empaquetar
#                  (default: ~/.sklauncher/instances/<modpack-id>)
#   EXTRA_MODS_DIR Carpeta local con .jar extra que se copian a mods/ antes de empaquetar
#   CATALOG        Ruta del catálogo (default: catalog.json en la raíz del repo)
#   R2_REMOTE      Nombre del remote de rclone (default: r2)
#   R2_BUCKET      Bucket de R2 (default: minecraft-data)
#   SKIP_UPLOAD    Si es "1", solo arma los archivos localmente, no publica a R2
#
# Los archivos locales quedan en dist/ con la misma ruta que tendrán en R2.

set -euo pipefail

[ $# -eq 2 ] || { echo "Uso: $0 <modpack-id> <perfil-id>   (ver catalog.json)" >&2; exit 1; }
MODPACK="$1"
PROFILE="$2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${CATALOG:-$ROOT/catalog.json}"
INSTANCE_DIR="${INSTANCE_DIR:-$HOME/.sklauncher/instances/$MODPACK}"
EXTRA_MODS_DIR="${EXTRA_MODS_DIR:-}"
R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-minecraft-data}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"

# Rutas del catálogo (prefix, tar, manifest) para este modpack/perfil.
PLAN="$(python3 - "$CATALOG" "$MODPACK" "$PROFILE" <<'PYEOF'
import sys, json, shlex
path, mid, pid = sys.argv[1:4]
cat = json.load(open(path))
pack = next((m for m in cat["modpacks"] if m["id"] == mid), None)
if not pack:
    sys.exit("Modpack '%s' no está en el catálogo. Disponibles: %s" % (mid, ", ".join(m["id"] for m in cat["modpacks"])))
prof = next((p for p in pack["profiles"] if p["id"] == pid), None)
if not prof:
    sys.exit("Perfil '%s' no existe en '%s'. Disponibles: %s" % (pid, mid, ", ".join(p["id"] for p in pack["profiles"])))
for k, v in (("PREFIX", pack["prefix"]), ("TAR_KEY", prof["tar"]), ("MANIFEST_KEY", prof["manifest"])):
    print("%s=%s" % (k, shlex.quote(v)))
PYEOF
)"
eval "$PLAN"   # aparte: `eval "$(...)"` ignora el error de python

OUT="dist/$TAR_KEY"
MANIFEST_OUT="dist/$MANIFEST_KEY"

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
  --exclude="dynamic-data-pack-cache"
  --exclude="server-resource-packs"
  --exclude="observable_announce"
  --exclude="ESM"                       # estado del mod Observable ligado a tus mundos
  # Estado personal / ligado a tus mundos (anclado con "/" a la raíz para no
  # excluir carpetas homónimas más adentro, p. ej. kubejs/data/.../gtceu):
  --exclude="/_backup-*"                 # respaldos manuales tuyos
  --exclude="/journeymap"                # mapas explorados (111 MB de tu progreso)
  --exclude="/simplebackups"
  --exclude="/usercache.json"            # UUID + nombre de tu cuenta
  --exclude="/usernamecache.json"
  --exclude="/local"                     # claims de FTB Chunks / kubejs de tus mundos
  --exclude="/confluence"
  --exclude="/blueprints"
  --exclude="/gtceu"
  --exclude="/cache"
  --exclude="/.cache"
  --exclude="/particular_cache"
  --exclude="/patchouli_data.json"       # progreso de libros
  --exclude="/.qmenu_opened.marker"
)

if [ ! -d "$INSTANCE_DIR" ]; then
  echo "❌ No existe la carpeta de instancia: $INSTANCE_DIR (usa INSTANCE_DIR=...)" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")" "$(dirname "$MANIFEST_OUT")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "📦 Copiando '$MODPACK/$PROFILE' ($INSTANCE_DIR) a staging (excluyendo datos personales)..."
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
  echo "   llamado '$R2_REMOTE' configurado). Sube manualmente $OUT y $MANIFEST_OUT,"
  echo "   y copia $STAGE/mods a <bucket>/$PREFIX/mods/ antes de que termine este script"
  echo "   (esa carpeta temporal se borra al salir)."
  exit 0
fi

echo
echo "☁️  Publicando a R2 ($R2_REMOTE:$R2_BUCKET)..."
# Orden: primero lo que el manifest referencia (mods, tar) y el manifest AL FINAL. Es lo que
# "publica" el cambio: quien actualice a mitad de la subida sigue viendo el manifest viejo
# (consistente) en vez de uno que apunta a mods que todavía no existen.
# copy, NO sync: los perfiles del mismo modpack comparten esta carpeta, y sync
# borraría los mods que el perfil actual no tiene (p. ej. los extra de gama alta).
# ponytail: los .jar viejos quedan huérfanos en R2; limpiar a mano con la unión de manifests si pesa.
echo "  -> $PREFIX/mods/ (solo sube lo nuevo/cambiado)"
rclone copy "$STAGE/mods" "$R2_REMOTE:$R2_BUCKET/$PREFIX/mods" --s3-no-check-bucket --progress
echo "  -> $TAR_KEY"
rclone copyto "$OUT" "$R2_REMOTE:$R2_BUCKET/$TAR_KEY" --s3-no-check-bucket
echo "  -> $MANIFEST_KEY"
rclone copyto "$MANIFEST_OUT" "$R2_REMOTE:$R2_BUCKET/$MANIFEST_KEY" --s3-no-check-bucket

echo
echo "✅ Publicado. Los amigos que ya instalaron este perfil solo necesitan volver a"
echo "   correr el script de instalación para recibir estos mods nuevos/actualizados."
