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
tú (una sola vez)                    tus amigos (cada uno)
─────────────────                    ─────────────────────
scripts/package-instance.sh   →   R2 (archivos pesados)
        │                              │
        └── genera .tar.gz             │
                                        ▼
                              curl install.sh | sh
                                        │
                    ┌───────────────────┼────────────────────┐
                    ▼                   ▼                    ▼
            instala AppImage    entrada en el menú    instala modpack +
            (~/.local/share/    de aplicaciones        mods extra en
             sklauncher/)       (~/.local/share/       ~/.sklauncher/
                                 applications/)         instances/<id>/
                                                                │
                                                                ▼
                                            se registra en instances.json
                                            para que aparezca en SKLauncher
```

## 1. Empaquetar la instancia (una vez, o cada vez que actualices mods)

```bash
./scripts/package-instance.sh
```

Por defecto toma `~/.sklauncher/instances/all-the-mods-10-to-the-sky-atm10sky`,
excluye lo personal (`saves/`, `screenshots/`, `logs/`, `crash-reports/`,
`servers.dat`, cachés que se regeneran solas) y genera
`dist/all-the-mods-10-to-the-sky-atm10sky-instance.tar.gz`.

Para meterle mods extra que no vienen en el modpack de CurseForge, dejalos
en una carpeta y pasala por variable de entorno — se copian a `mods/`
antes de comprimir:

```bash
EXTRA_MODS_DIR=~/mods-extra ./scripts/package-instance.sh
```

Para empaquetar otra instancia (por ejemplo si cambian de modpack):

```bash
INSTANCE_DIR=~/.sklauncher/instances/all-the-mods-10-atm10 \
OUT=dist/atm10.tar.gz \
  ./scripts/package-instance.sh
```

## 2. Subir a R2

Subí a tu bucket:

- `src/SKlauncher-4.0.46-x86_64.AppImage`
- `dist/<id>-instance.tar.gz`

y hacé públicas ambas URLs (o generá un enlace firmado de larga duración).

## 3. Configurar `install.sh`

Editá el bloque de configuración al inicio de `install.sh` con las URLs
reales:

```sh
SKLAUNCHER_URL="https://<tu-bucket>.r2.dev/SKlauncher-4.0.46-x86_64.AppImage"
MODPACK_URL="https://<tu-bucket>.r2.dev/atm10sky-instance.tar.gz"
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

Re-correr el script más adelante actualiza el AppImage y el contenido del
modpack sin borrar las partidas guardadas de cada uno (no vienen incluidas
en el paquete que se descarga).

### Notas

- Solo soporta Linux x86_64 (SKLauncher se distribuye como AppImage).
- Los AppImage necesitan FUSE para ejecutarse; `install.sh` avisa si no lo
  detecta e indica el paquete a instalar según la distro
  (`libfuse2`/`fuse-libs`/`fuse2`).
- El único requisito además de `curl`/`tar` (presentes en cualquier
  distro) es `python3`, usado para fusionar la instancia nueva dentro de
  `instances.json` sin pisar otras instancias que el amigo ya tenga.
