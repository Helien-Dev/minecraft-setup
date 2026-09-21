#!/bin/sh
# install.sh
#
# Instalador de un click de SKLauncher + modpacks. Pensado para correr así:
#
#   curl -sSL https://TU-DOMINIO/install.sh | sh
#
# Qué hace:
#   1. Descarga el catálogo (catalog.json) y pregunta qué modpack quieres y,
#      si el modpack tiene perfiles de gama, cuál perfil.
#   2. Instala SKLauncher (un solo launcher global; si ya está en la versión
#      del catálogo, no lo vuelve a bajar) y lo deja visible en el menú de
#      aplicaciones.
#   3. Primera vez: descarga el paquete completo del perfil elegido y lo
#      coloca en ~/.sklauncher/instances/<id>/.
#   4. Corridas siguientes: NO vuelve a bajar el paquete completo. Compara un
#      manifest.json remoto (lista de mods + hash) contra el que guardó la
#      última vez y baja/borra solo los mods que cambiaron.
#   5. Registra la instancia en instances.json para que aparezca en
#      SKLauncher sin que el usuario tenga que tocar nada.
#
# Nombres de instancia: la primera vez, el modpack se llama solo por su nombre
# ("NeoFresh"). Si después instalas OTRO perfil del mismo modpack, la instancia
# nueva lleva el perfil en el nombre ("NeoFresh Gama Baja") y la primera no se
# toca. Volver a correr con el mismo perfil actualiza esa instancia en sitio.
#
# Para saltarte el menú (o si no hay terminal):
#   curl -sSL https://TU-DOMINIO/install.sh | MODPACK=neofresh PROFILE=low sh
#
# Es POSIX sh a propósito (sin bashismos) para que funcione igual con
# `sh`, `dash` o `bash`.
#
# Se puede re-ejecutar sin problema. Nunca toca partidas guardadas de una
# instalación previa (no vienen en el paquete que se descarga).

set -eu

# ---------------------------------------------------------------------------
# Configuración. Todo lo demás (URLs de launcher/modpacks, versiones, memoria)
# sale del catálogo, relativo a la URL del catálogo.
# ---------------------------------------------------------------------------
CATALOG_URL="${CATALOG_URL:-https://minecraft-data.alvaroavila.dev/catalog.json}"
ICON_URL="${ICON_URL:-}"    # opcional: PNG del ícono; si se deja vacío, se extrae del AppImage
# ---------------------------------------------------------------------------

SKL_DIR="$HOME/.sklauncher"
APP_DIR="$HOME/.local/share/sklauncher"
BIN_PATH="$APP_DIR/SKlauncher.AppImage"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/sklauncher.desktop"
ICON_PATH="$APP_DIR/sklauncher.png"
STATE_DIR="$APP_DIR/state"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# --- chequeos previos ---
[ "$(uname -s)" = "Linux" ] || die "Este instalador solo funciona en Linux (en Windows usa install.ps1)."
case "$(uname -m)" in
  x86_64) ;;
  *) die "El AppImage de SKLauncher es x86_64 y esta máquina reporta $(uname -m)." ;;
esac
command -v curl    >/dev/null 2>&1 || die "Necesitas curl instalado."
command -v tar     >/dev/null 2>&1 || die "Necesitas tar instalado."
command -v python3 >/dev/null 2>&1 || die "Necesitas python3 instalado (viene por defecto en casi toda distro de escritorio)."

if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
  warn "No se detectó FUSE. Los AppImage lo necesitan para ejecutarse."
  warn "Si al abrir SKLauncher ves un error de FUSE, instala libfuse2, por ejemplo:"
  warn "  Ubuntu/Debian: sudo apt install libfuse2t64 || sudo apt install libfuse2"
  warn "  Fedora:        sudo dnf install fuse-libs"
  warn "  Arch:          sudo pacman -S fuse2"
fi

mkdir -p "$APP_DIR" "$DESKTOP_DIR" "$SKL_DIR/instances" "$STATE_DIR"

# --- 1) Catálogo + elección de modpack/perfil ---
CATALOG_FILE="$(mktemp)"
trap 'rm -f "$CATALOG_FILE"' EXIT
log "Descargando catálogo..."
curl -fL --retry 3 -s -o "$CATALOG_FILE" "$CATALOG_URL" || die "No se pudo descargar el catálogo desde $CATALOG_URL"

# El menú se lee de /dev/tty porque con `curl | sh` el stdin es el propio script.
# Se asigna aparte de `eval` porque `eval "$(...)"` ignora el error de python.
PLAN="$(python3 - "$CATALOG_FILE" "$CATALOG_URL" "$STATE_DIR" <<'PYEOF'
import sys, os, json, glob, shlex
from urllib.parse import urljoin

cat_path, cat_url, state_dir = sys.argv[1:4]
want_pack, want_prof = os.environ.get("MODPACK", ""), os.environ.get("PROFILE", "")
cat = json.load(open(cat_path))


def ask(title, labels):
    try:
        tty = open("/dev/tty")
    except OSError:
        sys.exit("No hay terminal para mostrar el menú. Usa MODPACK=<id> PROFILE=<id> (ver catalog.json).")
    while True:
        print("\n" + title, file=sys.stderr)
        for i, label in enumerate(labels, 1):
            print("  %d) %s" % (i, label), file=sys.stderr)
        sys.stderr.write("Elige una opción [1-%d]: " % len(labels))
        sys.stderr.flush()
        line = tty.readline()
        if not line:
            sys.exit("Instalación cancelada.")
        if line.strip().isdigit() and 1 <= int(line) <= len(labels):
            return int(line) - 1


def choose(kind, items, want, label_of):
    if want:
        hit = next((x for x in items if x["id"] == want), None)
        if not hit:
            sys.exit("%s '%s' no existe. Disponibles: %s" % (kind, want, ", ".join(x["id"] for x in items)))
        return hit
    if len(items) == 1:
        return items[0]
    return items[ask("¿Qué %s quieres instalar?" % kind.lower(), [label_of(x) for x in items])]


pack = choose("Modpack", cat["modpacks"], want_pack, lambda m: m["name"])
prof = choose("Perfil", pack["profiles"], want_prof, lambda p: p.get("label") or p["id"])
label = prof.get("label") or prof["id"]

# Qué instancias hay ya instaladas (un state/<id>.json por instancia; los de
# instalaciones anteriores a los perfiles no traen modpack/profile: el id es el modpack).
installed = {}
for f in glob.glob(os.path.join(state_dir, "*.json")):
    try:
        d = json.load(open(f))
    except ValueError:
        continue
    installed[os.path.basename(f)[:-5]] = (d.get("modpack"), d.get("profile"))

same = [i for i, (m, p) in installed.items()
        if (m or i) == pack["id"] and p in (None, prof["id"])]
if same:
    iid = same[0]                                   # mismo perfil: actualizar en sitio
elif any((m or i) == pack["id"] for i, (m, _) in installed.items()):
    iid = "%s-%s" % (pack["id"], prof["id"])        # otro perfil ya instalado: instancia aparte
else:
    iid = pack["id"]                                # primera instalación de este modpack
name = pack["name"] if iid == pack["id"] else "%s %s" % (pack["name"], label)

launcher = cat["launcher"]["linux"]
out = {
    "MODPACK_ID": pack["id"], "PROFILE_ID": prof["id"],
    "INSTANCE_ID": iid, "INSTANCE_NAME": name,
    "INSTANCE_TYPE": pack.get("type", "modpack"), "INSTANCE_ICON": pack.get("icon", ""),
    "MC_VERSION": pack["minecraft"], "LOADER": pack["loader"],
    "LOADER_VERSION": pack["loaderVersion"], "VERSION_ID": pack["versionId"],
    "MEMORY_MAX": os.environ.get("MEMORY_MAX") or str(pack["memoryMax"]),
    "MODPACK_URL": urljoin(cat_url, prof["tar"]),
    "MANIFEST_URL": urljoin(cat_url, prof["manifest"]),
    "MOD_BASE_URL": urljoin(cat_url, pack["prefix"] + "/mods"),
    "SKLAUNCHER_URL": urljoin(cat_url, launcher["url"]),
    "LAUNCHER_VERSION": launcher["version"],
}
for k, v in out.items():
    print("%s=%s" % (k, shlex.quote(v)))
PYEOF
)"
eval "$PLAN"

INSTANCE_DIR="$SKL_DIR/instances/$INSTANCE_ID"
LOCAL_MANIFEST="$STATE_DIR/$INSTANCE_ID.json"
ok "Instalando: $INSTANCE_NAME"

# SKLauncher reescribe instances.json completo mientras está abierto y pisa los cambios
# externos (verificado en Windows): registrar la instancia con el launcher abierto se pierde.
if [ -f "$BIN_PATH" ] && pgrep -f "$BIN_PATH" >/dev/null 2>&1; then
  die "SKLauncher está abierto. Ciérralo (también en la bandeja del sistema) y vuelve a ejecutar el script."
fi

# --- 2) SKLauncher (global: una sola vez por máquina) ---
if [ -x "$BIN_PATH" ] && [ "$(cat "$STATE_DIR/launcher.version" 2>/dev/null)" = "$LAUNCHER_VERSION" ]; then
  ok "SKLauncher $LAUNCHER_VERSION ya está instalado."
else
  log "Descargando SKLauncher $LAUNCHER_VERSION..."
  curl -fL --retry 3 --progress-bar -o "$BIN_PATH.tmp" "$SKLAUNCHER_URL"
  mv "$BIN_PATH.tmp" "$BIN_PATH"
  chmod +x "$BIN_PATH"
  printf '%s' "$LAUNCHER_VERSION" > "$STATE_DIR/launcher.version"
  ok "SKLauncher instalado en $BIN_PATH"
fi

# --- 3) Ícono para el menú de aplicaciones ---
if [ -n "$ICON_URL" ] && [ ! -f "$ICON_PATH" ]; then
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

# --- 4) Entrada en el menú de aplicaciones ---
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

# --- 5) Modpack: instalación completa (primera vez) o actualización
#         incremental de mods (corridas siguientes) ---

# Guarda el manifest aplicado junto con a qué modpack/perfil pertenece esta instancia.
save_state() {
  python3 - "$1" "$LOCAL_MANIFEST" "$MODPACK_ID" "$PROFILE_ID" <<'PYEOF'
import sys, json
src, dst, modpack, profile = sys.argv[1:5]
d = json.load(open(src))
d["modpack"], d["profile"] = modpack, profile
with open(dst, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
}

ALREADY_INSTALLED=0
if [ -s "$LOCAL_MANIFEST" ] && [ -d "$INSTANCE_DIR/mods" ] && [ -n "$(ls -A "$INSTANCE_DIR/mods" 2>/dev/null)" ]; then
  ALREADY_INSTALLED=1
fi

REMOTE_MANIFEST="$(mktemp)"
trap 'rm -f "$CATALOG_FILE" "$REMOTE_MANIFEST"' EXIT

if [ "$ALREADY_INSTALLED" = "1" ]; then
  log "Instancia ya instalada. Comprobando mods nuevos o actualizados..."
  if ! curl -fL --retry 3 -s -o "$REMOTE_MANIFEST" "$MANIFEST_URL"; then
    warn "No se pudo comprobar actualizaciones (¿sin internet?). Se deja el modpack como está."
  elif python3 - "$LOCAL_MANIFEST" "$REMOTE_MANIFEST" "$INSTANCE_DIR/mods" "$MOD_BASE_URL" <<'PYEOF'
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
    save_state "$REMOTE_MANIFEST"
    ok "Mods al día."
  else
    warn "Falló la actualización de mods (quedaron como estaban). Puedes reintentar corriendo el script de nuevo."
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

  if curl -fL --retry 3 -s -o "$REMOTE_MANIFEST" "$MANIFEST_URL"; then
    save_state "$REMOTE_MANIFEST"
    ok "Estado guardado: la próxima vez solo se van a bajar los mods que cambien."
  else
    warn "No se pudo guardar el estado inicial; la próxima corrida hará una instalación completa de nuevo."
  fi
fi

# --- 6) Registrar la instancia en instances.json ---
log "Registrando la instancia en SKLauncher..."
python3 - "$SKL_DIR/instances.json" "$INSTANCE_ID" "$INSTANCE_NAME" "$INSTANCE_TYPE" "$INSTANCE_ICON" \
  "$VERSION_ID" "$LOADER" "$MC_VERSION" "$LOADER_VERSION" "$INSTANCE_DIR" "$MEMORY_MAX" <<'PYEOF'
import json, os, shutil, sys, datetime

path, iid, name, type_, icon, version_id, loader, mc_version, loader_version, directory, memory_max = sys.argv[1:12]

if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    data = {"instances": []}
data.setdefault("instances", [])

new = {
    "id": iid,
    "name": name,
    "type": type_,
    "installComplete": True,
    "versionId": version_id,
    "gameType": loader,
    "minecraftVersion": mc_version,
    "loaderVersion": loader_version,
    "directory": directory,
    "memoryMax": int(memory_max),
}
if icon:
    new["icon"] = icon

old = next((i for i in data["instances"] if i.get("id") == iid), None)
if old:
    # Conserva lo que el usuario ya cambió o generó (nombre, memoria, tiempo jugado...).
    merged = {**old, **new}
    for k in ("name", "memoryMax"):
        if k in old:
            merged[k] = old[k]
    data["instances"][data["instances"].index(old)] = merged
else:
    # Sin playTime el launcher escribe null tras la primera sesión.
    new.update(playTime=0, sessionCount=0, customLaunchHooks=False,
               createdAt=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
    data["instances"].append(new)

if os.path.exists(path):
    shutil.copy2(path, path + ".bak.pre-install")
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
os.replace(path + ".tmp", path)
PYEOF
ok "Instancia \"$INSTANCE_NAME\" registrada."

echo
ok "¡Listo! Abre SKLauncher desde el menú de aplicaciones, inicia sesión y"
ok "selecciona la instancia \"$INSTANCE_NAME\"."
warn "La primera vez que la juegues, SKLauncher puede descargar Minecraft, NeoForge y Java (~1 GB): necesitas internet."
