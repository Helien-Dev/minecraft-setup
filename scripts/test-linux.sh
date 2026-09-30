#!/usr/bin/env bash
# Prueba de punta a punta sin internet: publish.py contra un R2 local y install.sh en un HOME aislado.
set -euo pipefail

WORK="$(mktemp -d)"
ROOT="$WORK/repo"  # copia del repo: publish.py escribe profiles/ y no debe tocar el real
mkdir -p "$ROOT/scripts"
cp "$(dirname "$0")/../catalog.json" "$(dirname "$0")/../install.sh" "$(dirname "$0")/../install.ps1" "$ROOT/"
cp "$(dirname "$0")/publish.py" "$ROOT/scripts/"
python3 -c "import json, sys; c = json.load(open(sys.argv[1])); c['modpacks'] = [m for m in c['modpacks'] if m['id'] == 'neocozy']; json.dump(c, open(sys.argv[1], 'w'))" "$ROOT/catalog.json"
PORT=8765
export R2_BUCKET="$WORK/r2"
SRC="$WORK/instance"
PERF="$WORK/instance-perf"
FAILS=0
SERVER=""
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT

check() { if eval "$1"; then echo "  PASS $2"; else echo "  FAIL $2"; FAILS=$((FAILS + 1)); fi; }
publish() { python3 "$ROOT/scripts/publish.py" "$@" <<<s >"$WORK/publish.log" 2>&1; }
jar() { mkdir -p "$SRC/mods"; head -c 20000 /dev/urandom > "$SRC/mods/$1"; }
# Instala el perfil $1 en el HOME $2 (por defecto home), con un launcher falso ya "instalado".
install() {
  local home="$WORK/${2:-home}" state="$WORK/${2:-home}/.local/share/sklauncher"
  mkdir -p "$state/state"
  printf '#!/bin/sh\nexit 0\n' > "$state/SKlauncher.AppImage" && chmod +x "$state/SKlauncher.AppImage"
  python3 -c "import json; print(json.load(open('$ROOT/catalog.json'))['launcher']['linux']['version'], end='')" > "$state/state/launcher.version"
  HOME="$home" CATALOG_URL="http://localhost:$PORT/catalog.json" MODPACK=neocozy PROFILE="$1" sh "$ROOT/install.sh" >"$WORK/install.log" 2>&1
}
INST="$WORK/home/.sklauncher/instances/neocozy"
STATE="$WORK/home/.local/share/sklauncher/state/neocozy.json"

jar a.jar; jar b.jar; jar "c mod+[x].jar"; jar x-client.jar
mkdir -p "$SRC/config/sub" "$SRC/saves/w" "$SRC/logs"
echo "v = 1" > "$SRC/config/a.toml"; echo paquete > "$SRC/options.txt"; echo mundo > "$SRC/saves/w/level.dat"; echo log > "$SRC/logs/latest.log"
printf 'a.jar\nb.jar\nc mod+[x].jar\n' > "$WORK/keep.txt"

echo "== publicar"
publish standard neocozy "$SRC"; check '[ -f "$R2_BUCKET/neocozy/base.zip" ] && [ -f "$R2_BUCKET/neocozy/mods/c mod+[x].jar" ]' "standard publicado"
check '! python3 -m zipfile -l "$R2_BUCKET/neocozy/base.zip" | grep -qE "saves|logs|mods/"' "el base no trae saves, logs ni mods"
publish profile neocozy performance "$WORK/keep.txt"; check 'grep -q x-client.jar "$R2_BUCKET/neocozy/profiles/performance.json"' "performance excluye x-client.jar"
publish site; check '[ -f "$R2_BUCKET/install.sh" ] && [ -f "$R2_BUCKET/catalog.json" ]' "site publicado"
python3 -m http.server "$PORT" --directory "$R2_BUCKET" >"$WORK/server.log" 2>&1 &
SERVER=$!
sleep 1

echo "== instalación limpia de performance"
install performance; check '[ $(ls "$INST/mods" | wc -l) -eq 3 ] && [ ! -e "$INST/mods/x-client.jar" ]' "3 mods, sin el excluido"
check 'grep -q "v = 1" "$INST/config/a.toml" && [ ! -e "$INST/saves" ]' "config instalada, sin saves"
check 'grep -q "\"base\"" "$STATE"' "estado guardado con base"

echo "== segunda corrida"
: > "$WORK/server.log"; install performance
check 'grep -q "al día" "$WORK/install.log" && ! grep -qE "base.zip|/mods/" "$WORK/server.log"' "no baja nada"

echo "== el exclude es sagrado"
cp "$SRC/mods/x-client.jar" "$INST/mods/"; install performance
check '[ ! -e "$INST/mods/x-client.jar" ]' "x-client.jar se borró"

echo "== perfil con configuración propia"
cp -r "$SRC" "$PERF"; rm "$PERF/mods/x-client.jar" "$PERF/options.txt"; echo "perf = 1" > "$PERF/config/perf.toml"; echo "v = perf" > "$PERF/config/a.toml"
publish profile neocozy performance "$PERF"
check '[ -f "$R2_BUCKET/neocozy/profiles/performance.zip" ] && grep -q options.txt "$R2_BUCKET/neocozy/profiles/performance.json"' "config propia publicada y options.txt en skip"
install performance fresh
FRESH="$WORK/fresh/.sklauncher/instances/neocozy"
check 'grep -q "perf = 1" "$FRESH/config/perf.toml" && grep -q "v = perf" "$FRESH/config/a.toml" && [ ! -e "$FRESH/options.txt" ]' "instalación nueva: config del perfil encima del base y sin el options.txt del standard"
install performance
check '[ -e "$INST/config/perf.toml" ] && grep -q "v = 1" "$INST/config/a.toml" && [ -e "$INST/options.txt" ]' "instalación existente: recibe perf.toml nuevo y no toca su a.toml ni su options.txt"

echo "== config y mod nuevos en el standard"
echo "v = 2" > "$SRC/config/a.toml"; echo "nuevo" > "$SRC/config/b.toml"; mkdir -p "$SRC/kubejs"; echo "k2" > "$SRC/kubejs/k.js"
echo jugador > "$INST/options.txt"; echo mio > "$INST/config/propio.toml"; jar b.jar; rm "$SRC/mods/a.jar"
publish standard neocozy "$SRC"
: > "$WORK/server.log"; install performance
check 'grep -q "v = 1" "$INST/config/a.toml" && grep -q nuevo "$INST/config/b.toml" && grep -q k2 "$INST/kubejs/k.js" && grep -q jugador "$INST/options.txt" && grep -q mio "$INST/config/propio.toml"' "config existente intacta (ni la propia del jugador se borra); llegan config nueva y kubejs"
check '[ $(grep -c "/mods/" "$WORK/server.log") -eq 1 ] && [ ! -e "$INST/mods/a.jar" ]' "solo bajó b.jar y borró a.jar"

echo "== estado de una versión anterior (sin base)"
python3 -c "import json, sys; d = json.load(open(sys.argv[1])); del d['base']; json.dump(d, open(sys.argv[1], 'w'))" "$STATE"
: > "$WORK/server.log"; install performance
check 'grep -q base.zip "$WORK/server.log" && ! grep -q "/mods/" "$WORK/server.log" && grep -q "\"base\"" "$STATE"' "recibe la configuración sin volver a bajar mods"

echo "== exclude desactualizado"
mv "$SRC/mods/x-client.jar" "$SRC/mods/x-client-2.jar"
check '! publish standard neocozy "$SRC" && grep -q "x-client.jar" "$WORK/publish.log"' "publish se niega y nombra el mod"
mv "$SRC/mods/x-client-2.jar" "$SRC/mods/x-client.jar"

echo "== mod prohibido"
python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1], 'w').writestr('META-INF/neoforge.mods.toml', '[[mods]]\nmodId = \"treechop\"')" "$SRC/mods/arboles.jar"
check '! publish standard neocozy "$SRC" && grep -q "prohíbe" "$WORK/publish.log"' "publish se niega aunque el jar se llame distinto"
rm "$SRC/mods/arboles.jar"

echo "== mod repetido"
for v in 1 2; do python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1], 'w').writestr('META-INF/neoforge.mods.toml', '[[mods]]\nmodId = \"libx\"')" "$SRC/mods/libx-$v.jar"; done
check '! publish standard neocozy "$SRC" && grep -q "repetidos" "$WORK/publish.log"' "publish se niega con dos versiones del mismo mod"
rm "$SRC/mods/libx-"*.jar

echo "== limpieza"
publish clean; check '[ ! -e "$R2_BUCKET/neocozy/mods/a.jar" ] && [ -e "$R2_BUCKET/neocozy/mods/b.jar" ] && [ -e "$R2_BUCKET/neocozy/profiles/performance.zip" ]' "borró a.jar huérfano y conservó el resto"

echo
[ "$FAILS" -eq 0 ] && echo "TODAS LAS PRUEBAS PASARON" || { echo "$FAILS prueba(s) fallaron (logs en $WORK)"; trap - EXIT; kill "$SERVER"; exit 1; }
