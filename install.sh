#!/bin/sh
# Instalador de SKLauncher + modpacks para Linux (uso: curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | sh).
set -eu

CATALOG_URL="${CATALOG_URL:-https://minecraft-data.alvaroavila.dev/catalog.json}"
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

[ "$(uname -s)" = "Linux" ] || die "Este instalador solo funciona en Linux (en Windows usa install.ps1)."
[ "$(uname -m)" = "x86_64" ] || die "SKLauncher para Linux es x86_64 y esta computadora es $(uname -m)."
for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Necesitas tener $cmd instalado."
done
if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
  warn "No se detectó FUSE, que SKLauncher necesita. Si no abre, instala libfuse2 (Ubuntu/Debian: libfuse2t64, Fedora: fuse-libs, Arch: fuse2)."
fi

mkdir -p "$APP_DIR" "$DESKTOP_DIR" "$SKL_DIR/instances" "$STATE_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Descargando catálogo..."
curl -fsSL --retry 3 -o "$WORK_DIR/catalog.json" "$CATALOG_URL" || die "No se pudo descargar el catálogo desde $CATALOG_URL"

# Asignado aparte de `eval`: `eval "$(...)"` ignoraría un error de python.
PLAN="$(python3 - "$WORK_DIR/catalog.json" "$CATALOG_URL" "$STATE_DIR" <<'PYEOF'
import glob, json, os, shlex, sys
from urllib.parse import urljoin

catalog_path, catalog_url, state_dir = sys.argv[1:4]
catalog = json.load(open(catalog_path, encoding="utf-8"))


def ask(title, labels):
    try:
        tty = open("/dev/tty")  # con `curl | sh` la entrada estándar es el propio script
    except OSError:
        sys.exit("No hay terminal para mostrar el menú. Usa MODPACK=<id> PROFILE=<id> (ver catalog.json).")
    while True:
        print("\n" + title, file=sys.stderr)
        for i, label in enumerate(labels, 1):
            print(f"  {i}) {label}", file=sys.stderr)
        sys.stderr.write(f"Elige una opción [1-{len(labels)}]: ")
        sys.stderr.flush()
        line = tty.readline()
        if not line:
            sys.exit("Instalación cancelada.")
        if line.strip().isdigit() and 1 <= int(line) <= len(labels):
            return int(line) - 1


def choose(kind, items, wanted, label_of):
    if wanted:
        hit = next((x for x in items if x["id"] == wanted), None)
        return hit or sys.exit(f"{kind} '{wanted}' no existe. Disponibles: {', '.join(x['id'] for x in items)}")
    if len(items) == 1:
        return items[0]
    return items[ask(f"¿Qué {kind.lower()} quieres instalar?", [label_of(x) for x in items])]


pack = choose("Modpack", catalog["modpacks"], os.environ.get("MODPACK", ""), lambda m: m["name"])
profile = choose("Perfil", pack["profiles"], os.environ.get("PROFILE", ""), lambda p: p.get("label", p["id"]))

# Un state/<id>.json por instancia; los de versiones viejas no traen modpack/profile (el id es el modpack).
installed = {}
for path in glob.glob(os.path.join(state_dir, "*.json")):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except ValueError:
        continue
    installed[os.path.basename(path)[:-5]] = (data.get("modpack") or os.path.basename(path)[:-5], data.get("profile"))

same = sorted(i for i, (m, p) in installed.items() if m == pack["id"] and p in (None, profile["id"]))
if same:
    instance_id = same[0]
elif any(m == pack["id"] for m, _ in installed.values()):
    instance_id = f"{pack['id']}-{profile['id']}"  # otro perfil del mismo modpack: instancia aparte
else:
    instance_id = pack["id"]
name = pack["name"] if instance_id == pack["id"] else f"{pack['name']} {profile.get('label', profile['id'])}"

launcher = catalog["launcher"]["linux"]
plan = {
    "MODPACK_ID": pack["id"], "PROFILE_ID": profile["id"], "INSTANCE_ID": instance_id, "INSTANCE_NAME": name,
    "INSTANCE_TYPE": pack.get("type", "modpack"), "INSTANCE_ICON": pack.get("icon", ""),
    "MC_VERSION": pack["minecraft"], "LOADER": pack["loader"], "LOADER_VERSION": pack["loaderVersion"],
    "VERSION_ID": pack["versionId"], "MEMORY_MAX": os.environ.get("MEMORY_MAX") or str(pack["memoryMax"]),
    "PACK_URL": urljoin(catalog_url, pack["prefix"] + "/"),
    "PROFILE_FILE": "" if profile is pack["profiles"][0] else f"profiles/{profile['id']}.json",
    "SKLAUNCHER_URL": urljoin(catalog_url, launcher["url"]), "LAUNCHER_VERSION": launcher["version"],
}
for key, value in plan.items():
    print(f"{key}={shlex.quote(value)}")
PYEOF
)"
eval "$PLAN"

INSTANCE_DIR="$SKL_DIR/instances/$INSTANCE_ID"
STATE_FILE="$STATE_DIR/$INSTANCE_ID.json"
ok "Instalando: $INSTANCE_NAME"
log "Carpeta de la instancia: $INSTANCE_DIR"

# Con SKLauncher abierto, reescribe instances.json y se pierde el registro de la instancia.
if [ -f "$BIN_PATH" ] && pgrep -f "$BIN_PATH" >/dev/null 2>&1; then
  die "SKLauncher está abierto. Ciérralo (también en la bandeja del sistema) y vuelve a ejecutar el script."
fi

if [ -x "$BIN_PATH" ] && [ "$(cat "$STATE_DIR/launcher.version" 2>/dev/null)" = "$LAUNCHER_VERSION" ]; then
  ok "SKLauncher $LAUNCHER_VERSION ya está instalado."
else
  log "Descargando SKLauncher $LAUNCHER_VERSION..."
  curl -fL --retry 3 --progress-bar -o "$BIN_PATH.tmp" "$SKLAUNCHER_URL"
  chmod +x "$BIN_PATH.tmp"
  mv "$BIN_PATH.tmp" "$BIN_PATH"
  printf '%s' "$LAUNCHER_VERSION" > "$STATE_DIR/launcher.version"
  ok "SKLauncher instalado en $BIN_PATH"
fi

if [ ! -f "$ICON_PATH" ]; then
  EXTRACT_DIR="$(mktemp -d)"
  (cd "$EXTRACT_DIR" && { "$BIN_PATH" --appimage-extract 'usr/share/icons/hicolor/*/apps/*.png' || "$BIN_PATH" --appimage-extract '*.png'; } >/dev/null 2>&1 || true)
  FOUND_ICON="$(find -L "$EXTRACT_DIR" -iname '*.png' -type f 2>/dev/null | sort -r | head -n1)"
  [ -n "$FOUND_ICON" ] && cp "$FOUND_ICON" "$ICON_PATH"
  rm -rf "$EXTRACT_DIR"
fi

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
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
ok "SKLauncher aparece en el menú de aplicaciones."

# Mismo proceso para instalar y actualizar: base (config, kubejs...) si cambió y luego mods/ igual al perfil.
python3 - "$PACK_URL" "$PROFILE_FILE" "$INSTANCE_DIR" "$STATE_FILE" "$WORK_DIR" "$MODPACK_ID" "$PROFILE_ID" <<'PYEOF' || die "No se pudo completar la instalación. Vuelve a ejecutar el script para reintentar."
import hashlib, json, os, shutil, subprocess, sys, zipfile
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

pack_url, profile_file, instance_dir, state_file, work_dir, modpack, profile = sys.argv[1:8]
PERSONAL = ("options.txt", "optionsof.txt", "optionsshaders.txt", "servers.dat", "servers.dat_old")


def download(url, dest):
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", dest, url], check=True)


def get_json(url):
    dest = os.path.join(work_dir, "download.json")
    download(url, dest)
    return json.load(open(dest, encoding="utf-8"))


def fetch_verified(url, meta, dest):
    download(url, dest)
    if sha256(dest) != meta["sha256"]:
        sys.exit(f"{url} se descargó dañado.")
    return dest


def extract(zip_path, skip):
    # Nunca pisa los archivos personales que el jugador ya tiene (opciones, servidores).
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            dest = os.path.join(instance_dir, *info.filename.split("/"))
            personal = info.filename in PERSONAL and os.path.exists(dest)
            if info.is_dir() or info.filename in skip or personal or ".." in info.filename.split("/"):
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with zf.open(info) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


manifest = get_json(pack_url + "manifest.json")
variant = get_json(pack_url + profile_file) if profile_file else {"exclude": [], "include": {}, "skip": []}
exclude = set(variant["exclude"])
target = {n: m for n, m in {**manifest["mods"], **variant["include"]}.items() if n not in exclude}
try:
    state = json.load(open(state_file, encoding="utf-8"))
except (OSError, ValueError):
    state = {}
known = state.get("mods", {})
mods_dir = os.path.join(instance_dir, "mods")

config = variant.get("config", {}).get("sha256")
if state.get("base") != manifest["base"]["sha256"] or state.get("config") != config or not os.path.isdir(mods_dir):
    print("[*] Descargando la configuración del modpack...", flush=True)
    extract(fetch_verified(pack_url + "base.zip", manifest["base"], os.path.join(work_dir, "base.zip")), set(variant["skip"]))
    if config:
        extract(fetch_verified(pack_url + profile_file[:-5] + ".zip", variant["config"], os.path.join(work_dir, "config.zip")), set())
    print("[OK] Configuración al día (tus partidas y opciones no se tocaron).")
os.makedirs(mods_dir, exist_ok=True)


def outdated(name):
    path = os.path.join(mods_dir, name)
    if not os.path.isfile(path):
        return True
    return (known.get(name, {}).get("sha256") or sha256(path)) != target[name]["sha256"]


to_fetch = sorted(n for n in target if outdated(n))
to_remove = sorted(n for n in (set(known) - set(target)) | exclude if os.path.exists(os.path.join(mods_dir, n)))
if to_fetch:
    size = sum(target[n]["size"] for n in to_fetch) / 1e6
    print(f"[*] Descargando {len(to_fetch)} mod(s) ({size:.0f} MB)...", flush=True)
    staging = os.path.join(instance_dir, ".mods-download")  # mismo disco que mods/ (y no en /tmp, que puede ser RAM)
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)

    def fetch(name):
        dest = os.path.join(staging, name)
        download(pack_url + "mods/" + quote(name), dest)
        if sha256(dest) != target[name]["sha256"]:
            raise RuntimeError(f"{name} se descargó dañado")

    with ThreadPoolExecutor(8) as pool:
        list(pool.map(fetch, to_fetch))
    for name in to_fetch:
        if known:
            print(f"  + {name}")
        os.replace(os.path.join(staging, name), os.path.join(mods_dir, name))
    os.rmdir(staging)
for name in to_remove:
    print(f"  - {name}")
    os.remove(os.path.join(mods_dir, name))

# Doble verificación: ningún mod excluido queda y todos los del perfil están.
leftover = sorted(n for n in exclude if os.path.exists(os.path.join(mods_dir, n)))
missing = sorted(n for n in target if not os.path.isfile(os.path.join(mods_dir, n)))
if leftover or missing:
    sys.exit(f"La carpeta mods/ quedó incorrecta. Sobran: {leftover}. Faltan: {missing}.")
if not (to_fetch or to_remove):
    print("[OK] Mods al día, nada que hacer.")

with open(state_file + ".tmp", "w", encoding="utf-8") as f:
    json.dump({"modpack": modpack, "profile": profile, "base": manifest["base"]["sha256"], "config": config, "mods": target}, f, indent=2)
os.replace(state_file + ".tmp", state_file)
PYEOF

log "Registrando la instancia en SKLauncher..."
python3 - "$SKL_DIR/instances.json" "$INSTANCE_ID" "$INSTANCE_NAME" "$INSTANCE_TYPE" "$INSTANCE_ICON" \
  "$VERSION_ID" "$LOADER" "$MC_VERSION" "$LOADER_VERSION" "$INSTANCE_DIR" "$MEMORY_MAX" <<'PYEOF'
import datetime, json, os, shutil, sys

path, iid, name, type_, icon, version_id, loader, mc_version, loader_version, directory, memory_max = sys.argv[1:12]
data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
instances = data.setdefault("instances", [])
new = {
    "id": iid, "name": name, "type": type_, "installComplete": True, "versionId": version_id, "gameType": loader,
    "minecraftVersion": mc_version, "loaderVersion": loader_version, "directory": directory, "memoryMax": int(memory_max),
}
if icon:
    new["icon"] = icon

old = next((i for i in instances if i.get("id") == iid), None)
if old:
    # Conserva lo que el jugador cambió (nombre, memoria) y lo que generó el launcher (tiempo jugado...).
    old.update({k: v for k, v in new.items() if k not in ("name", "memoryMax") or k not in old})
else:
    # Sin playTime el launcher escribe null tras la primera sesión.
    new.update(playTime=0, sessionCount=0, customLaunchHooks=False,
               createdAt=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
    instances.append(new)

if os.path.exists(path):
    shutil.copy2(path, path + ".bak.pre-install")
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
os.replace(path + ".tmp", path)
PYEOF
ok "Instancia \"$INSTANCE_NAME\" registrada."

echo
ok "¡Listo! Abre SKLauncher desde el menú de aplicaciones, inicia sesión y elige la instancia \"$INSTANCE_NAME\"."
ok "Instalada en: $INSTANCE_DIR"
warn "La primera vez que la juegues, SKLauncher descarga Minecraft, NeoForge y Java (~1 GB): necesitas internet."
