# Publicar

Todo se publica con `scripts/publish.py` (necesita `python3` y `rclone`). Nada se sube sin mostrar antes un resumen
y pedir confirmación.

## Cómo está organizado R2

Bucket `minecraft-data`, servido en `https://minecraft-data.alvaroavila.dev/`.

```
catalog.json, install.sh, install.ps1       <- lo que corren los usuarios
sk-portable.zip                             <- launcher de Windows (el de Linux se baja de GitHub)
<prefix>/base.zip                           <- la instancia SIN mods/ ni datos personales: config, kubejs, resourcepacks...
<prefix>/manifest.json                      <- sha256 y tamaño del base y de cada mod del standard
<prefix>/mods/*.jar                         <- cada mod una sola vez, compartido por todos los perfiles
<prefix>/profiles/<perfil>.json             <- solo perfiles derivados: exclude, include, skip y config
<prefix>/profiles/<perfil>.zip              <- configuración propia del perfil (si tiene)
```

- **Standard:** el primer perfil de cada modpack en `catalog.json` es el standard. Es el único con base y manifest.
- **Perfil derivado:** es el standard menos los mods de `exclude` y más los de `include`. No tiene paquete propio.
  Si su configuración difiere, lleva un zip chico solo con los archivos distintos (`config`) y la lista de archivos
  del base que no instala (`skip`). Así hereda los cambios del standard, salvo en los archivos que redefine.
- **Qué hace el instalador:** vuelve a aplicar el base (y la configuración del perfil) solo cuando cambia su sha256.
  Nunca pisa `options.txt`, la lista de servidores ni ningún archivo de `config/` que el jugador ya tenga (solo agrega
  los nuevos); `kubejs/` y el resto sí se actualizan. Deja `mods/` igual al perfil y verifica que no
  quede ningún mod excluido.
- **Base determinista:** si nada cambió, el sha256 no cambia y nadie vuelve a bajar la configuración.

## Configurar rclone (una vez)

```bash
rclone config   # remote nuevo llamado "r2", tipo s3, provider Cloudflare, con un token de API de R2
```

Otro remote o bucket: `R2_BUCKET=otro:bucket ./scripts/publish.py ...`.

## Publicar el standard de un modpack

```bash
./scripts/publish.py standard neocozy ~/.sklauncher/instances/neocozy-standar
```

1. Calcula localmente el sha256 de cada mod y lo compara con el `manifest.json` publicado. No baja ningún jar.
2. Arma el `base.zip` sin `mods/` ni datos personales (partidas, logs, mapas, cachés, cuentas). La lista está
   en `ANYWHERE` y `AT_ROOT`, dentro de `publish.py`.
3. Verifica que cada exclude de los perfiles derivados siga existiendo en el standard. Si un mod excluido cambió de
   versión, se niega a publicar y te dice cuál: actualiza su nombre en `profiles/<prefix>/<perfil>.json` y repite.
4. Muestra los mods nuevos, actualizados y quitados, y si cambió el base. Después de confirmar, sube solo esos
   jars, luego el base (si cambió) y el manifest al final.

> **Cambios en `config/`:** a quien ya tiene la instancia solo le llegan los archivos de config **nuevos**. Si cambias
> uno que ya existía y el servidor lo necesita, avisa a los jugadores que borren ese archivo antes de volver a correr
> el instalador (o muévelo a `kubejs/`/`defaultconfigs/` si el mod lo permite).

## Publicar un perfil derivado

```bash
./scripts/publish.py profile neofresh low ~/ruta/instancia-gama-baja   # desde una instancia: mods y configuración
./scripts/publish.py profile neocozy performance lista.txt              # desde una lista de los mods que conserva
```

Si cambias la configuración del standard y el perfil tiene configuración propia, vuelve a publicar el perfil desde su
instancia cuando quieras que sus archivos redefinidos también cambien.

Desde una instancia, además compara su configuración con el base del standard publicado: los archivos distintos van
a `profiles/<prefix>/<perfil>.zip` y los que no tiene, a `skip`. Genera `profiles/<prefix>/<perfil>.json`, lo sube
y sube los jars que agrega. Haz commit de ese archivo: es la
fuente de verdad del perfil. Un perfil nuevo hay que agregarlo también a `catalog.json`.

## Publicar el servidor

Ver [servidor.md](servidor.md): `publish.py server` después del standard, desde el mismo tag.

> Si la instancia del cliente está en git, `publish.py standard` también exige un tag limpio y que `mods/` coincida con
> su `mods.lock`; guarda el tag y el commit en el manifest.

## Publicar el instalador y el catálogo

```bash
./scripts/publish.py site
```

Antes de subir, comprueba que todo lo que lista el catálogo ya esté en R2. Sube `install.sh`, `install.ps1` e `install-server.sh` con
`charset=utf-8` (sin eso, `irm` rompe los acentos) y `catalog.json` al final. Un modpack nuevo se publica así: primero
`standard`, después `profile` (si tiene), y al final `site`.

## Limpiar R2

```bash
./scripts/publish.py clean
```

Lista todo lo que ni el catálogo ni los manifests referencian: jars viejos, paquetes viejos. Si confirmas, lo borra.
Se niega a correr si el `catalog.json` de R2 no es el del repo.

## Launchers

- **Linux:** la URL del AppImage en `catalog.json` apunta directo a las releases del beta
  (`github.com/sklauncher/binaries`). Para actualizarlo, cambia la versión en la URL y en `version`, y publica con
  `site`.
- **Windows:** `sk-portable.zip` es la carpeta `sk-portable/` completa (con `SKLauncher-Portable.bat`) y sin `data\`.
  El beta solo ofrece un `setup.exe`, así que el zip se arma a mano:

  ```bash
  (cd sk-portable && zip -r /tmp/sk-portable.zip . -x 'data/*')
  rclone copyto /tmp/sk-portable.zip r2:minecraft-data/sk-portable.zip --s3-no-check-bucket
  ```

  Sube también `launcher.windows.version` en `catalog.json`: esa versión es la que decide si se vuelve a bajar.

## Probar

- `scripts/test-linux.sh` corre la prueba de punta a punta en Linux, sin internet: publica contra un R2 local e
  instala en un HOME aislado.
- En Windows: `scripts/windows/test-install.ps1`, que arma un R2 falso con `make-test-layout.ps1` y lo sirve con
  `serve-test.ps1`.
- Para probar un catálogo contra el R2 real sin afectar a nadie, súbelo con otro nombre y apunta a él:

  ```bash
  rclone copyto catalog.json r2:minecraft-data/catalog-next.json --s3-no-check-bucket
  CATALOG_URL=https://minecraft-data.alvaroavila.dev/catalog-next.json sh install.sh
  ```
