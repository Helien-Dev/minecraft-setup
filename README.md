# mine-script

Instalador de un click para que tus amigos terminen con **SKLauncher + el
modpack que elijan (con su perfil de gama, si tiene)** ya instalados, sin
tocar nada más que el ícono del launcher.

```
curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | sh        # Linux
irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex            # Windows (PowerShell)
```

El script pregunta qué modpack quieres y, si tiene perfiles de gama (alta,
baja...), cuál. Hay **un solo SKLauncher por máquina**; cada modpack/perfil
es una instancia dentro de él.

## Cómo funciona

Los binarios pesados (launcher, modpacks, mods) **no viven en este repo**: se
suben a un bucket de Cloudflare R2. Lo único que el script conoce es la URL de
`catalog.json`, que describe qué hay disponible.

```
R2 (minecraft-data)
├─ catalog.json                       <- modpacks, perfiles, versiones, rutas (este repo: catalog.json)
├─ SKlauncher-4.0.46-x86_64.AppImage  <- launcher Linux
├─ sk-portable.zip                    <- launcher Windows (carpeta completa, sin data\)
├─ atm10sky-instance.tar.gz           <- un .tar.gz por perfil (instalación nueva)
├─ atm10sky/manifest.json             <- un manifest por perfil (hash de cada mod)
├─ atm10sky/mods/*.jar                <- los mods, una sola vez por modpack
└─ neofresh/{high,low}/{instance.tar.gz,manifest.json}, neofresh/mods/*.jar
```

Agregar un modpack nuevo = empaquetarlo, subirlo y añadir una entrada a
`catalog.json`. Los scripts de instalación no cambian.

**Nombres de instancia.** La primera vez, el modpack se llama solo por su
nombre (`NeoFresh`). Si después instalas **otro perfil** del mismo modpack, la
instancia nueva lleva el perfil en el nombre (`NeoFresh Gama Baja`) y la
primera no se toca. Correr de nuevo con el mismo perfil actualiza esa
instancia en sitio. El script recuerda qué perfil tiene cada instancia en
`~/.local/share/sklauncher/state/<id>.json` (en Windows, `%LOCALAPPDATA%\Programs\SKLauncher-Portable\state\<id>.json`).

**Actualizaciones incrementales.** La primera vez se baja el `.tar.gz` del
perfil. Después, el script solo compara el `manifest.json` y baja/borra los
mods que cambiaron. Si no cambió nada, no descarga nada de mods. Tampoco
vuelve a bajar el launcher si ya tiene la versión del catálogo.

> Hoy solo `mods/` se actualiza de forma incremental. Los cambios en
> `config/`, `kubejs/`, etc. solo llegan en la instalación inicial.

## 1. Empaquetar y publicar un perfil

```bash
./scripts/package-instance.sh <modpack-id> <perfil-id>
# ej.: INSTANCE_DIR=~/Downloads/Neo-lowprofile/NeoLowProfile ./scripts/package-instance.sh neofresh low
```

Los ids salen de `catalog.json`. Por defecto toma
`~/.sklauncher/instances/<modpack-id>`; usa `INSTANCE_DIR` para otra carpeta.
Excluye lo personal (`saves/`, `screenshots/`, `logs/`, `journeymap/`,
`usercache.json`, cachés...) y deja en `dist/` los archivos con la misma ruta
que tendrán en R2.

Si tienes un remote de `rclone` llamado `r2` (ver paso 2), **publica solo**: el
`.tar.gz`, el `manifest.json` y los mods nuevos (`rclone copy`, no `sync`: los
perfiles de un mismo modpack comparten `mods/`). Usa `SKIP_UPLOAD=1` para no
publicar. `EXTRA_MODS_DIR=<carpeta>` copia `.jar` extra a `mods/` antes de
empaquetar.

Después de publicar los perfiles, **publica el catálogo** (aparte, para no listar
un perfil que todavía no subiste):

```bash
rclone copyto catalog.json r2:minecraft-data/catalog.json --s3-no-check-bucket
```

Launcher de Windows (contenido de `sk-portable/` en la raíz del zip, **sin** `data\`):

```bash
(cd ~/Downloads/Neo-lowprofile/sk-portable && zip -r /tmp/sk-portable.zip . -x 'data/*')
rclone copyto /tmp/sk-portable.zip r2:minecraft-data/sk-portable.zip --s3-no-check-bucket
```

Si cambias el zip, sube también `launcher.windows.version` en `catalog.json`: esa versión es la
que decide si los amigos vuelven a bajar el launcher. Las pruebas de Windows se hicieron con un
zip armado en Windows (`tar.exe -a`, ver `scripts/windows/make-test-layout.ps1`); uno hecho con
`zip` en Linux debería extraerse igual, pero pruébalo una vez antes de repartir.

## 2. Configurar `rclone` (una vez)

```bash
sudo dnf install -y rclone   # o el gestor de paquetes de tu distro
rclone config                # remote nuevo, nombre "r2", tipo s3, provider Cloudflare
```
Necesitas el Access Key ID, Secret Access Key y endpoint de un token de API
de R2 (Cloudflare dashboard → R2 → Gestionar tokens de API).

## 3. Publicar `install.sh` e `install.ps1`

Los dos instaladores se sirven desde el propio bucket, en el mismo dominio que el catálogo
(`https://minecraft-data.alvaroavila.dev/`), con UTF-8 explícito (sin el charset, `irm` rompe los acentos
de `install.ps1`). Si cambias uno, vuelve a subirlo:

```bash
rclone copyto install.sh  r2:minecraft-data/install.sh  --s3-no-check-bucket --header-upload "Content-Type: text/plain; charset=utf-8"
rclone copyto install.ps1 r2:minecraft-data/install.ps1 --s3-no-check-bucket --header-upload "Content-Type: text/plain; charset=utf-8"
```

Si tu bucket no es `minecraft-data.alvaroavila.dev`, cambia `CATALOG_URL` al inicio de ambos scripts.

Para probar antes de publicar, sirve una copia del layout de R2 y apunta a ella:

```bash
CATALOG_URL=file:///ruta/local/catalog.json sh install.sh
```

`install.ps1` debe ir **sin BOM** (con BOM, `irm | iex` falla). Después comprueba que llega bien (desde PowerShell; debe dar `True`):

```powershell
(irm https://minecraft-data.alvaroavila.dev/install.ps1) -match 'catálogo'
```

## 4. Lo que corren tus amigos

```bash
curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | sh
```

Eligen modpack y perfil, abren SKLauncher desde el menú de aplicaciones,
inician sesión y la instancia ya está ahí. Sin menú (o sin terminal):

```bash
curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | MODPACK=neofresh PROFILE=low sh
```

En Windows (PowerShell 5.1 o superior, sin permisos de administrador):

```powershell
irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex
```

Instala un SKLauncher **portable** en `%LOCALAPPDATA%\Programs\SKLauncher-Portable` y crea el
acceso "SKLauncher Portable" en el Menú Inicio (no toca un SKLauncher oficial que ya tengan). Sin
menú: `$env:MODPACK='neofresh'; $env:PROFILE='low'; irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex`
(esas variables quedan definidas en esa terminal; bórralas con
`Remove-Item Env:MODPACK,Env:PROFILE` si vas a correrlo de nuevo).

Re-correr el script después de que agregues/actualices mods les baja solo lo
que cambió, y nunca toca las partidas guardadas de cada uno.

### Notas

- Linux x86_64 (AppImage) y Windows 10 (1803 o posterior) / 11 con PowerShell 5.1. Detalles,
  hechos verificados y límites de lo probado en Windows: `docs/windows-findings.md`.
- En Windows, la primera vez que juegan una instancia SKLauncher descarga ~1,1 GB (Minecraft,
  NeoForge y Java): necesitan internet y espacio libre.
- La gama alta tiene rutas de hasta 252 caracteres (con un usuario de 20): si el usuario de
  Windows es muy largo y no tiene las rutas largas activadas, `install.ps1` aborta con un mensaje
  claro antes de extraer.
- Los AppImage necesitan FUSE; `install.sh` avisa si no lo detecta.
- Requisitos en Linux: `curl`, `tar` y `python3`. En Windows no hace falta instalar nada (usa `curl.exe` y `tar.exe` que trae el sistema).
- Si se borra `~/.local/share/sklauncher/state/<id>.json` (o la carpeta
  `mods/` de la instancia), el script hace una instalación completa de ese
  perfil la próxima vez, sin romper nada.
- `data/` lleva el seguimiento manual del estado de los mods (ver `data/README.md`).
