#!/bin/sh
# install.sh
#
# Instalador de un click para el modpack "ATM10 To the Sky" + SKLauncher.
# Pensado para correr así:
#
#   curl -sSL https://TU-DOMINIO/install.sh | sh
#
# Qué hace:
#   1. Descarga el AppImage de SKLauncher y lo deja ejecutable + visible
#      en el menú de aplicaciones (entrada .desktop).
#   2. Primera vez: descarga el paquete completo de la instancia (modpack +
#      mods ya incluidos) y lo coloca en ~/.sklauncher/instances/<id>/.
#   3. Corridas siguientes: NO vuelve a bajar el paquete completo. Compara
#      un manifest.json remoto (lista de mods + hash) contra el que guardó
#      la última vez y baja/borra solo los mods que cambiaron.
#   4. Registra la instancia en instances.json para que aparezca en
#      SKLauncher sin que el usuario tenga que tocar nada.
#
# Es POSIX sh a propósito (sin bashismos) para que funcione igual con
# `sh`, `dash` o `bash`.
#
# Se puede re-ejecutar sin problema: la primera vez instala todo, las
# siguientes solo actualiza los mods que hayan cambiado (o no hace nada si
# ya está todo al día). Nunca toca partidas guardadas de una instalación
# previa (no vienen en el paquete que se descarga).

set -eu

# ---------------------------------------------------------------------------
# Configuración — EDITAR con las URLs reales de tu bucket R2 antes de publicar
# ---------------------------------------------------------------------------
SKLAUNCHER_URL="${SKLAUNCHER_URL:-https://minecraft-data.alvaroavila.dev/SKlauncher-4.0.46-x86_64.AppImage}"
MODPACK_URL="${MODPACK_URL:-https://minecraft-data.alvaroavila.dev/atm10sky-instance.tar.gz}"
MANIFEST_URL="${MANIFEST_URL:-https://minecraft-data.alvaroavila.dev/atm10sky/manifest.json}"
MOD_BASE_URL="${MOD_BASE_URL:-https://minecraft-data.alvaroavila.dev/atm10sky/mods}"
ICON_URL="${ICON_URL:-}"    # opcional: PNG del ícono; si se deja vacío, se extrae del AppImage

INSTANCE_ID="all-the-mods-10-to-the-sky-atm10sky"
INSTANCE_NAME="ATM10 To the Sky"
MC_VERSION="1.21.1"
LOADER="neoforge"
LOADER_VERSION="21.1.221"
VERSION_ID="1.21.1-neoforge-21.1.221"
MEMORY_MAX="${MEMORY_MAX:-8192}"
# ---------------------------------------------------------------------------

SKL_DIR="$HOME/.sklauncher"
APP_DIR="$HOME/.local/share/sklauncher"
BIN_PATH="$APP_DIR/SKlauncher.AppImage"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/sklauncher.desktop"
ICON_PATH="$APP_DIR/sklauncher.png"
INSTANCE_DIR="$SKL_DIR/instances/$INSTANCE_ID"
STATE_DIR="$APP_DIR/state"
LOCAL_MANIFEST="$STATE_DIR/$INSTANCE_ID.json"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

case "$SKLAUNCHER_URL $MODPACK_URL" in
  *TU-BUCKET*) die "install.sh todavía tiene las URLs de ejemplo (TU-BUCKET). Editá SKLAUNCHER_URL y MODPACK_URL antes de publicarlo." ;;
esac

# --- chequeos previos ---
[ "$(uname -s)" = "Linux" ] || die "Este instalador solo funciona en Linux (SKLauncher se distribuye como AppImage)."
case "$(uname -m)" in
  x86_64) ;;
  *) die "El AppImage de SKLauncher es x86_64 y esta máquina reporta $(uname -m)." ;;
esac
command -v curl    >/dev/null 2>&1 || die "Necesitás curl instalado."
command -v tar     >/dev/null 2>&1 || die "Necesitás tar instalado."
command -v python3 >/dev/null 2>&1 || die "Necesitás python3 instalado (viene por defecto en casi toda distro de escritorio)."

if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
  warn "No se detectó FUSE. Los AppImage lo necesitan para ejecutarse."
  warn "Si al abrir SKLauncher ves un error de FUSE, instalá libfuse2, por ejemplo:"
  warn "  Ubuntu/Debian: sudo apt install libfuse2t64 || sudo apt install libfuse2"
  warn "  Fedora:        sudo dnf install fuse-libs"
  warn "  Arch:          sudo pacman -S fuse2"
fi

mkdir -p "$APP_DIR" "$DESKTOP_DIR" "$SKL_DIR/instances"

# --- 1) SKLauncher ---
log "Descargando SKLauncher..."
curl -fL --retry 3 --progress-bar -o "$BIN_PATH.tmp" "$SKLAUNCHER_URL"
mv "$BIN_PATH.tmp" "$BIN_PATH"
chmod +x "$BIN_PATH"
ok "SKLauncher instalado en $BIN_PATH"

# --- 2) Ícono para el menú de aplicaciones ---
if [ -n "$ICON_URL" ]; then
  log "Descargando ícono..."
  curl -fL --retry 3 -o "$ICON_PATH" "$ICON_URL" || warn "No se pudo descargar el ícono, se usará uno genérico."
fi
if [ ! -f "$ICON_PATH" ]; then
  log "Extrayendo ícono del AppImage..."
  EXTRACT_DIR="$(mktemp -d)"
  ( cd "$EXTRACT_DIR" \
      && "$BIN_PATH" --appimage-extract 'usr/share/icons/hicolor/*/apps/*.png' >/dev/null 2>&1 \
      || "$BIN_PATH" --appimage-extract '*.png' >/dev/null 2>&1 \
      || true )
  FOUND_ICON="$(find -L "$EXTRACT_DIR" -iname '*.png' -type f 2>/dev/null | sort -r | head -n1)"
  [ -n "$FOUND_ICON" ] && cp "$FOUND_ICON" "$ICON_PATH"
  rm -rf "$EXTRACT_DIR"
fi

# --- 3) Entrada en el menú de aplicaciones ---
log "Creando acceso directo en el menú de aplicaciones..."
{
  echo "[Desktop Entry]"
  echo "Type=Application"
  echo "Name=SKlauncher"
  echo "Comment=Launcher de Minecraft"
  echo "Exec=\"$BIN_PATH\" %U"
  [ -f "$ICON_PATH" ] && echo "Icon=$ICON_PATH"
  echo "Terminal=false"
  echo "Categories=Game;"
} > "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
ok "SKLauncher ya aparece en el menú de aplicaciones."

# --- 4) Modpack: instalación completa (primera vez) o actualización
#         incremental de mods (corridas siguientes) ---
mkdir -p "$STATE_DIR"

ALREADY_INSTALLED=0
if [ -s "$LOCAL_MANIFEST" ] && [ -d "$INSTANCE_DIR/mods" ] && [ -n "$(ls -A "$INSTANCE_DIR/mods" 2>/dev/null)" ]; then
  ALREADY_INSTALLED=1
fi

if [ "$ALREADY_INSTALLED" = "1" ]; then
  log "Instancia ya instalada. Comprobando mods nuevos o actualizados..."
  REMOTE_MANIFEST="$(mktemp)"
  if ! curl -fL --retry 3 -s -o "$REMOTE_MANIFEST" "$MANIFEST_URL"; then
    warn "No se pudo comprobar actualizaciones (¿sin internet?). Se deja el modpack como está."
    rm -f "$REMOTE_MANIFEST"
  else
    if python3 - "$LOCAL_MANIFEST" "$REMOTE_MANIFEST" "$INSTANCE_DIR/mods" "$MOD_BASE_URL" <<'PYEOF'
import sys, os, json, urllib.request, urllib.parse, tempfile, shutil

local_path, remote_path, mods_dir, base_url = sys.argv[1:5]

with open(remote_path) as f:
    remote = json.load(f).get("mods", {})
try:
    with open(local_path) as f:
        local = json.load(f).get("mods", {})
except (FileNotFoundError, json.JSONDecodeError):
    local = {}

to_fetch = []
for name, meta in remote.items():
    local_meta = local.get(name)
    needs = (
        local_meta is None
        or local_meta.get("sha256") != meta.get("sha256")
        or not os.path.isfile(os.path.join(mods_dir, name))
    )
    if needs:
        to_fetch.append(name)

to_remove = [name for name in local if name not in remote]

if not to_fetch and not to_remove:
    print("Mods al día, nada que hacer.")
    sys.exit(0)

print(f"{len(to_fetch)} mod(s) nuevo(s)/actualizado(s), {len(to_remove)} para quitar:")

for name in to_fetch:
    url = base_url.rstrip("/") + "/" + urllib.parse.quote(name)
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
    dest = os.path.join(mods_dir, name)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=mods_dir)
    success = False
    try:
        print(f"  + {name}")
        with urllib.request.urlopen(req, timeout=180) as resp, os.fdopen(tmp_fd, "wb") as out:
            shutil.copyfileobj(resp, out)
        os.replace(tmp_path, dest)
        success = True
    except Exception as e:
        print(f"ERROR descargando {name}: {e}", file=sys.stderr)
    finally:
        if not success and os.path.exists(tmp_path):
            os.remove(tmp_path)
    if not success:
        sys.exit(1)

for name in to_remove:
    p = os.path.join(mods_dir, name)
    if os.path.isfile(p):
        print(f"  - {name}")
        os.remove(p)
PYEOF
    then
      cp "$REMOTE_MANIFEST" "$LOCAL_MANIFEST"
      ok "Mods al día."
    else
      warn "Falló la actualización de mods (quedaron como estaban). Podés reintentar corriendo el script de nuevo."
    fi
    rm -f "$REMOTE_MANIFEST"
  fi
else
  log "Descargando modpack ($INSTANCE_NAME)... puede tardar según tu conexión."
  TMP_TAR="$(mktemp)"
  curl -fL --retry 3 --progress-bar -o "$TMP_TAR" "$MODPACK_URL"
  mkdir -p "$INSTANCE_DIR"
  log "Instalando en $INSTANCE_DIR ..."
  tar -xzf "$TMP_TAR" -C "$INSTANCE_DIR"
  rm -f "$TMP_TAR"
  ok "Modpack instalado (si ya jugabas antes, tus partidas guardadas no se tocaron)."

  if curl -fL --retry 3 -s -o "$LOCAL_MANIFEST" "$MANIFEST_URL"; then
    ok "Estado guardado: la próxima vez solo se van a bajar los mods que cambien."
  else
    warn "No se pudo guardar el estado inicial; la próxima corrida hará una instalación completa de nuevo."
  fi
fi

# --- 5) Registrar la instancia en instances.json ---
log "Registrando la instancia en SKLauncher..."
python3 - "$SKL_DIR/instances.json" "$INSTANCE_ID" "$INSTANCE_NAME" "$VERSION_ID" \
  "$LOADER" "$MC_VERSION" "$LOADER_VERSION" "$INSTANCE_DIR" "$MEMORY_MAX" <<'PYEOF'
import json, os, sys, datetime

path, iid, name, version_id, loader, mc_version, loader_version, directory, memory_max = sys.argv[1:10]

if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    data = {"instances": []}

data.setdefault("instances", [])
data["instances"] = [i for i in data["instances"] if i.get("id") != iid]
data["instances"].append({
    "id": iid,
    "name": name,
    "type": "modpack",
    "installComplete": True,
    "versionId": version_id,
    "gameType": loader,
    "minecraftVersion": mc_version,
    "loaderVersion": loader_version,
    "directory": directory,
    "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "memoryMax": int(memory_max),
})

if os.path.exists(path):
    os.replace(path, path + ".bak.pre-install")

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
ok "Instancia \"$INSTANCE_NAME\" registrada."

echo
ok "¡Listo! Abrí SKLauncher desde el menú de aplicaciones, iniciá sesión y"
ok "seleccioná la instancia \"$INSTANCE_NAME\"."
