# mine-script

Instalador de un click para que tus amigos terminen con **SKLauncher +
el modpack ATM10 To the Sky + mods extra** ya instalados, sin tocar nada
más que el ícono del launcher.

```
curl -sSL https://TU-DOMINIO/install.sh | sh
```

## Cómo funciona

Los binarios pesados (el AppImage, el modpack) **no viven en este repo** ni
en el script: se suben a un bucket de Cloudflare R2 y `install.sh` solo
tiene las URLs. Así el script que corren tus amigos es liviano y rápido de
descargar.

```
tú (una sola vez por cambio)              tus amigos (cada uno)
────────────────────────────              ─────────────────────
scripts/package-instance.sh   →   R2
        │                              ├─ atm10sky-instance.tar.gz (completo)
        ├── genera .tar.gz             ├─ atm10sky/manifest.json (hash de c/mod)
        ├── genera manifest.json       └─ atm10sky/mods/<cada-mod>.jar
        └── publica todo con rclone           │
                                               ▼
                                     curl install.sh | sh
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    ▼                          ▼                          ▼
            instala AppImage           entrada en el menú          ¿primera vez?
            (~/.local/share/           de aplicaciones             ├─ sí: baja el .tar.gz completo
             sklauncher/)              (~/.local/share/            └─ no: compara manifest.json local
                                        applications/)                 vs remoto, baja/borra SOLO
                                                                        los mods que cambiaron
                                                                                │
                                                                                ▼
                                                            se registra en instances.json
                                                            para que aparezca en SKLauncher
```

**Actualizaciones incrementales:** la primera vez que un amigo corre el
script, se baja el modpack completo. Cada vez después de esa, `install.sh`
descarga un `manifest.json` chiquito (nombre + hash de cada mod), lo
compara contra el estado que guardó la última vez
(`~/.local/share/sklauncher/state/<instancia>.json`), y baja/borra
**únicamente** los mods que cambiaron — nunca vuelve a bajar el `.tar.gz`
completo salvo que sea una instalación nueva. Si no cambió nada, el script
lo detecta y no descarga absolutamente nada de mods.

## 1. Empaquetar y publicar (cada vez que cambies mods)

```bash
./scripts/package-instance.sh
```

Por defecto toma `~/.sklauncher/instances/all-the-mods-10-to-the-sky-atm10sky`,
excluye lo personal (`saves/`, `screenshots/`, `logs/`, `crash-reports/`,
`servers.dat`, cachés que se regeneran solas), y genera en `dist/`:
- el `.tar.gz` completo de la instancia
- `manifest.json` (hash + tamaño de cada mod)

Si tenés un remote de `rclone` llamado `r2` configurado (ver más abajo),
**publica todo automáticamente**: el `.tar.gz`, el `manifest.json`, y cada
mod como objeto individual en R2 (sincronizado con `rclone sync`, así solo
sube lo que cambió). Si no querés que publique solo, usá `SKIP_UPLOAD=1`.

Para meterle mods extra que no vienen en el modpack de CurseForge, dejalos
en una carpeta y pasala por variable de entorno — se copian a `mods/`
antes de empaquetar/publicar:

```bash
EXTRA_MODS_DIR=~/mods-extra ./scripts/package-instance.sh
```

Para empaquetar otra instancia, o publicar a otro prefijo/bucket:

```bash
INSTANCE_DIR=~/.sklauncher/instances/all-the-mods-10-atm10 \
OUT=dist/atm10.tar.gz \
R2_PREFIX=atm10 \
  ./scripts/package-instance.sh
```

## 2. Configurar `rclone` (una vez)

```bash
sudo dnf install -y rclone   # o el gestor de paquetes de tu distro
rclone config                # remote nuevo, nombre "r2", tipo s3, provider Cloudflare
```
Necesitás el Access Key ID, Secret Access Key y endpoint de un token de API
de R2 (Cloudflare dashboard → R2 → Gestionar tokens de API).

## 3. Configurar `install.sh` (una vez)

Editá el bloque de configuración al inicio de `install.sh` con las URLs
reales de tu bucket:

```sh
SKLAUNCHER_URL="https://<tu-dominio>/SKlauncher-4.0.46-x86_64.AppImage"
MODPACK_URL="https://<tu-dominio>/atm10sky-instance.tar.gz"
MANIFEST_URL="https://<tu-dominio>/atm10sky/manifest.json"
MOD_BASE_URL="https://<tu-dominio>/atm10sky/mods"
```

El script se niega a correr si detecta que quedaron las URLs de ejemplo
(`TU-BUCKET`), así no se te escapa sin configurar.

También podés pisar esos valores sin tocar el archivo, por variable de
entorno (útil para probar antes de publicar):

```bash
SKLAUNCHER_URL=file:///ruta/local/SKlauncher.AppImage \
MODPACK_URL=file:///ruta/local/instance.tar.gz \
  sh install.sh
```

## 4. Publicar `install.sh`

Subí `install.sh` a GitHub Pages (o cualquier hosting estático) en la raíz,
para que quede accesible como `https://tu-usuario.github.io/tu-repo/install.sh`
o en tu dominio propio. Solo este archivo necesita ser público y liviano;
los archivos pesados quedan en R2.

## 5. Lo que corren tus amigos

```bash
curl -sSL https://TU-DOMINIO/install.sh | sh
```

Al terminar: abren SKLauncher desde el menú de aplicaciones, inician
sesión y la instancia **"ATM10 To the Sky"** ya está ahí, con todos los
mods (incluidos los extra) listos para jugar.

Re-correr el script después de que agregues/actualices mods (paso 1) les
baja solo lo que cambió — no vuelve a descargar el paquete completo, y
nunca toca las partidas guardadas de cada uno.

### Notas

- Solo soporta Linux x86_64 (SKLauncher se distribuye como AppImage).
- Los AppImage necesitan FUSE para ejecutarse; `install.sh` avisa si no lo
  detecta e indica el paquete a instalar según la distro
  (`libfuse2`/`fuse-libs`/`fuse2`).
- Requisitos en la máquina del amigo: `curl`, `tar` y `python3` (presentes
  por defecto en casi toda distro de escritorio). `python3` se usa tanto
  para fusionar la instancia en `instances.json` como para la lógica de
  actualización incremental de mods.
- El estado de "qué mods tengo instalados" vive en
  `~/.local/share/sklauncher/state/<id>.json` en la máquina del amigo. Si
  se borra ese archivo (o la carpeta `mods/`), el script vuelve a hacer
  una instalación completa desde cero la próxima vez, sin romper nada.
