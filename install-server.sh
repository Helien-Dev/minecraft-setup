#!/bin/sh
# Instala o actualiza el server de un modpack (uso: curl -sSL https://minecraft-data.alvaroavila.dev/install-server.sh | MODPACK=<id> sh -s <carpeta>).
set -eu

CATALOG_URL="${CATALOG_URL:-https://minecraft-data.alvaroavila.dev/catalog.json}"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "El instalador del server solo funciona en Linux."
[ -n "${MODPACK:-}" ] || die "Indica el modpack: MODPACK=<id> (ver catalog.json)."
[ $# -eq 1 ] || die "Indica la carpeta del server: ... | MODPACK=$MODPACK sh -s <carpeta>"
for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Necesitas tener $cmd instalado."
done
mkdir -p "$1"
DIR="$(cd "$1" && pwd)"

# Un server encendido tiene los jars abiertos: actualizarlo en caliente lo corrompe.
for pid in $(pgrep java || true); do
  [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$DIR" ] && die "El server de $DIR está encendido: apágalo antes de actualizar."
done

java_major() { java -version 2>&1 | awk -F'"' '/version/ {split($2, v, "."); print v[1]}'; }
if ! command -v java >/dev/null 2>&1 || [ "$(java_major)" -lt 21 ]; then
  command -v apt-get >/dev/null 2>&1 || die "Necesitas Java 21 (instálalo y vuelve a correr el script)."
  log "Instalando Java 21 (openjdk-21-jre-headless)..."
  sudo apt-get update -qq && sudo apt-get install -y -qq openjdk-21-jre-headless >/dev/null || die "No se pudo instalar Java 21."
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
curl -fsSL --retry 3 -o "$WORK_DIR/catalog.json" "$CATALOG_URL" || die "No se pudo descargar el catálogo desde $CATALOG_URL"

LOADER="$(python3 - "$WORK_DIR/catalog.json" "$CATALOG_URL" "$DIR" "$WORK_DIR" "$MODPACK" <<'PYEOF'
import hashlib, json, os, shutil, sys, urllib.request, zipfile
from urllib.parse import urljoin

catalog_path, catalog_url, root, work, pack_id = sys.argv[1:6]
pack = next((m for m in json.load(open(catalog_path, encoding="utf-8"))["modpacks"] if m["id"] == pack_id), None)
pack or sys.exit(f"El modpack '{pack_id}' no existe en el catálogo.")
url = urljoin(catalog_url, pack["prefix"] + "/")


def fetch(key, dest, sha=None):
    with urllib.request.urlopen(url + key, timeout=120) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    if sha and sha256(dest) != sha:
        os.remove(dest)
        sys.exit(f"{key} llegó corrupto (sha256 distinto). Vuelve a ejecutar el script.")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


fetch("server/manifest.json", os.path.join(work, "manifest.json"))
manifest = json.load(open(os.path.join(work, "manifest.json"), encoding="utf-8"))
state_path = os.path.join(root, ".mine-server.json")
state = json.load(open(state_path, encoding="utf-8")) if os.path.exists(state_path) else {"base": None, "files": []}

# Base: los archivos versionados del server; se aplica completa y se borra lo que la versión nueva ya no trae.
if state["base"] != manifest["base"]["sha256"]:
    print(f"[*] Aplicando la base {manifest['release']['tag']}...", file=sys.stderr)
    base = os.path.join(work, "base.zip")
    fetch("server/base.zip", base, manifest["base"]["sha256"])
    with zipfile.ZipFile(base) as zf:
        files = zf.namelist()
        for gone in set(state["files"]) - set(files):
            if os.path.isfile(os.path.join(root, gone)):
                os.remove(os.path.join(root, gone))
        zf.extractall(root)
    for name in files:
        if name.endswith(".sh"):
            os.chmod(os.path.join(root, name), 0o755)
    state.update(base=manifest["base"]["sha256"], files=files)

# Mods: exactamente los del manifest, cada jar verificado.
mods_dir = os.path.join(root, "mods")
os.makedirs(mods_dir, exist_ok=True)
want = manifest["mods"]
for name in sorted(set(os.listdir(mods_dir)) - set(want)):
    if name.endswith(".jar"):
        os.remove(os.path.join(mods_dir, name))
todo = [n for n in sorted(want) if not os.path.exists(os.path.join(mods_dir, n)) or sha256(os.path.join(mods_dir, n)) != want[n]["sha256"]]
for i, name in enumerate(todo, 1):
    print(f"[*] Mod {i}/{len(todo)}: {name}", file=sys.stderr)
    tmp = os.path.join(work, "mod.jar")
    fetch("mods/" + urllib.request.quote(name), tmp, want[name]["sha256"])
    shutil.move(tmp, os.path.join(mods_dir, name))

rel = manifest["release"]
open(os.path.join(root, ".server-version"), "w").write(f"{rel['tag'].lstrip('v')} {rel['commit']}\n")
json.dump(state, open(state_path, "w", encoding="utf-8"))
print(f"[OK] {pack['name']} {rel['tag']} ({rel['commit']}): {len(want)} mods, {len(todo)} descargados", file=sys.stderr)
print(manifest["loaderVersion"])
PYEOF
)" || die "No se pudo completar la instalación. Vuelve a ejecutar el script para reintentar."

if [ ! -d "$DIR/libraries/net/neoforged/neoforge/$LOADER" ]; then
  log "Instalando NeoForge $LOADER..."
  INSTALLER="$WORK_DIR/neoforge-installer.jar"
  curl -fsSL --retry 3 -o "$INSTALLER" "https://maven.neoforged.net/releases/net/neoforged/neoforge/$LOADER/neoforge-$LOADER-installer.jar" \
    || die "No se pudo descargar NeoForge $LOADER."
  (cd "$DIR" && java -jar "$INSTALLER" --installServer >/dev/null) || die "Falló el instalador de NeoForge."
fi
[ -f "$DIR/eula.txt" ] || warn "Para arrancar hay que aceptar la EULA de Minecraft: crea $DIR/eula.txt con eula=true."
ok "Server listo en $DIR. Nunca se tocan world/, la whitelist, los OP, los baneos ni los archivos locales."
