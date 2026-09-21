# Hallazgos de Windows (Fase 0 y Fase 1)

Estado: **Fases 0 a 4 completas.** `install.ps1` está escrito y probado (70 comprobaciones
automáticas sin fallos, más una corrida real de punta a punta con el juego). No se hizo
`git push` ni se publicó nada a R2. El contenido de las Fases 0 y 1 (verificación de
supuestos) sigue abajo; las Fases 2 a 4 están desde "Fase 2: `install.ps1`".

Convenciones de este documento: las rutas usan `%APPDATA%`, `%LOCALAPPDATA%` y
`<launcher>` (la carpeta del launcher portable). Las pruebas se hicieron con una
**copia** de `sk-portable\` en una carpeta temporal, para no ensuciar el original
(que debe seguir sin `data\`). No se guardó ningún dato de cuentas, token ni contenido de
`accounts.json` en este documento ni en el repo.

## Resumen ejecutivo

| # | Punto de la Fase 1 | Resultado |
|---|---|---|
| 1 | El portable escribe en `<launcher>\data\` y no en el `%APPDATA%\.sklauncher` real | **Confirmado** |
| 2 | Dónde y cómo crea `instances.json` | **Confirmado** (formato abajo) |
| 3 | Registro manual de una instancia | **Funciona** (`custom` y `modpack`) |
| 4 | Descarga de Minecraft, NeoForge y Java | **Automática** al primer Jugar; no hay que pre-instalar nada |
| 5 | El launcher reescribe `instances.json` con el archivo abierto | **Sí: un cambio externo se pierde**; hay que detectar el launcher |
| 6 | Versión real de la gama baja | **NeoForge 21.1.251** funciona (ver matiz) |
| 7 | `.lnk` visible en la búsqueda y sin parpadeo | **Confirmado** (ver matiz del nombre) |
| 8 | Instancia fuera de `data\` | **No**: el launcher ignora `directory` |

Los puntos 3 y 4, que podían cambiar el diseño, **pasaron**. El diseño del contrato no
necesita cambios estructurales; sí hay ajustes de implementación (sección "Implicaciones").

## Fase 0: entorno

| Dato | Valor |
|---|---|
| Windows | 11 Pro 10.0.26200 |
| PowerShell | 5.1.26100.8457 |
| Espacio libre en C: | ~185 GB |
| `curl.exe` | `C:\WINDOWS\system32\curl.exe` |
| Java en el `PATH` | No hay (el launcher descarga el suyo) |
| `sklauncher.exe` oficial | Instalado (`%LOCALAPPDATA%\Programs\sklauncher\`), con datos en `%APPDATA%\.sklauncher` |
| Accesos del Menú Inicio | `SKlauncher.lnk` y `SKlauncher 4.0.lnk`, ambos apuntan al `.exe` oficial |
| Portable original | `sk-portable\`: 408,5 MB, sin `data\`; `NeoLowProfile\`: `config`, `defaultconfigs`, `kubejs`, `mods` (331 `.jar`), `scripts` |

**`tar.exe` ambiguo.** `Get-Command tar.exe` resuelve a `C:\Program Files\Git\usr\bin\tar.exe`
(GNU tar de Git) porque Git va primero en el `PATH`. El de Windows es
`%SystemRoot%\System32\tar.exe` (bsdtar 3.8.4, existe en esta PC). `install.ps1` debe
llamar al de `System32` por ruta absoluta, para no depender del orden del `PATH`.

**Estado inicial del launcher.** Al empezar había un `sklauncher.exe` corriendo desde la
carpeta `sk-portable\` de prueba, **sin pasar por el `.bat`** (línea de comando sin
argumentos; sus procesos hijos usaban `--user-data-dir=%APPDATA%\.sklauncher\bin`). Es
decir, ejecutar el `.exe` directamente usa la carpeta de datos **real**; solo el `.bat`
(que redefine `APPDATA`) aísla los datos. Ese launcher se cerró solo a las 19:07:03 (su log
dice `Application quitting… Shutting down`), antes de que empezaran mis pruebas; no lo
cerré yo.

Además, la carpeta real ya tenía una instancia `neofresh` (`custom`,
`1.21.1-neoforge-21.1.251`, `directory` absoluto en `%APPDATA%\.sklauncher\instances\`),
con la misma forma que en Linux. Probablemente se creó desde la interfaz, así que no se
tomó como prueba del registro manual.

## Punto 1: aislamiento de datos

Se lanzó `SKLauncher-Portable.bat` de la copia. Los procesos nuevos llevaban
`--user-data-dir=<launcher>\data\electron`, y el launcher creó `<launcher>\data\`:

```
data\electron\lockfile
data\.sklauncher\{bin, cache, instances, logs}\
data\.sklauncher\{instances.json, settings.json, settings.json.bak,
                  updater-state.bin, window-state.json, .custom-clients-backfilled}
```

Comparación con la carpeta real (línea base tomada antes de lanzar):

- SHA-256 de `instances.json`, `accounts.json` y `settings.json` reales: **idénticos**.
- Sin carpetas ni archivos nuevos en `%APPDATA%\.sklauncher` (el único cambio,
  `window-state.json`, es de las 19:07:03, anterior al lanzamiento).
- Al final de todas las pruebas los hashes seguían iguales.

Matiz: el launcher real ya estaba cerrado cuando empezó la prueba, así que no compitió
por esos archivos.

## Punto 2: formato de `instances.json`

- Ruta: `<launcher>\data\.sklauncher\instances.json` (se crea en el primer arranque).
- Estructura: `{"instances": [ ... ]}` (una sola clave raíz). Al inicio trae
  `latest-release` y `latest-snapshot` (vanilla), y se crea `instances\` con una carpeta
  para cada una.
- El campo `directory` de cada entrada es **absoluto** y lo genera el launcher a partir de
  `data\.sklauncher\instances\<id>`.
- Las entradas creadas por el propio launcher traen `playTime: 0` y `sessionCount: 0`.
- El launcher escribe con sangría de 2 espacios. Leyó sin problema un archivo escrito con
  `ConvertTo-Json` de PowerShell 5.1 (sangría de 4 espacios).
- Primer arranque: pide iniciar sesión (Microsoft o cuenta sin conexión "SKlauncher", que
  solo pide un nombre) y muestra dos avisos: "Ayuda a mejorar SKlauncher" (analíticas) y
  "Acceso anticipado". `settings.json` nuevo trae `analyticsConsentChosen: false` y
  `welcomeCompleted: true`. Esto no bloquea el diseño; el usuario los cierra a mano.

## Punto 3: registro manual

Con el launcher **cerrado** se copió `NeoLowProfile\` a
`data\.sklauncher\instances\neofresh\` (331 mods) y se registraron 4 variantes; el log
mostró `Instance manager initialized: 6 instance(s)` y todas aparecieron en la biblioteca
como NeoForge 1.21.1:

| Variante | Campos | En la biblioteca | Se jugó |
|---|---|---|---|
| A `neofresh` | `custom`, completo (§3) | Sí | **Sí, llegó al menú** |
| B `t-minimal` | `custom` con solo `id, name, type, installComplete, versionId, gameType, minecraftVersion, loaderVersion, directory` | Sí (ícono genérico) | **Sí, llegó al menú** |
| C `t-modpack` | `type: "modpack"`, completo, sin `modpackInfo` | Sí | No probado |
| D `t-noflag` | `custom` sin `installComplete` | Sí | No probado |

Conclusiones:

- El conjunto mínimo **verificado** que funciona es el de la variante B. No se probó quitar
  cada campo por separado, así que no se puede afirmar que todos sean obligatorios.
- Sin `memoryMax` el launcher elige una memoria por su cuenta (`-Xmx6656M` en esta PC):
  hay que escribirlo explícitamente.
- Sin `playTime` el launcher escribió `"playTime": null` tras la primera sesión. Registrar
  siempre `playTime: 0` y `sessionCount: 0` en instancias nuevas.
- `icon: "Furnace_On"` da el ícono de horno; sin `icon` sale el genérico.
- Se recomienda `type: "custom"` (igual que Linux). No se necesita `modpackInfo`.

## Punto 4: descargas del primer Jugar

En `data\.sklauncher\` no existían `versions\` (solo la de 26.3 de fábrica), `libraries\`,
`runtime\` ni `assets\`. Al darle Jugar a la instancia A, el launcher descargó **solo**:

1. El instalador de NeoForge 21.1.251 desde `maven.neoforged.net` (7 MB) y lo ejecutó
   (`installertools`).
2. El cliente `1.21.1` y `1.21.1-neoforge-21.1.251` en `versions\`.
3. Un JRE Temurin 21.0.12.1 (49 MB) como `runtime\java-runtime-delta`.
4. Librerías (90 resueltas) y assets (4027 archivos).

Tamaño tras el primer arranque: `versions` 35 MB, `libraries` 153 MB, `runtime` 145 MB,
`assets` 787 MB, es decir **~1,1 GB**. Tiempos en esta red: ~2 min 20 s hasta lanzar el
proceso del juego y unos minutos más hasta el menú (primer arranque, 331 mods).

Resultado: el juego llegó al **menú principal** con la gama baja (`Minecraft 1.21.1`,
`NeoForge 21.1.251 (431 mods)`), 0 errores fatales en `latest.log`. **No hace falta
pre-instalar nada**, pero el primer Jugar exige internet y ~1,5 GB libres, además de los
mods.

## Punto 5: escritura de `instances.json` con el launcher abierto

- **No lo bloquea**: se pudo abrir en exclusiva con `FileShare.None`.
- Lo **reescribe completo** cada vez que cambia algo propio (al iniciar el juego añade
  `lastPlayed`; al cerrarlo, `playTime` y `sessionCount`) y deja `instances.json.bak` con
  la versión anterior.
- **No vigila el archivo**: una entrada añadida a mano con el launcher abierto no aparece
  en la interfaz (seguía diciendo "6 encontradas").
- **Pisa los cambios externos**: al guardar `lastPlayed`, el archivo volvió a tener solo
  las 6 instancias de su memoria y mi entrada `t-external` desapareció.

Por eso `install.ps1` debe **detectar si el launcher está en ejecución y detenerse con un
aviso** antes de tocar `instances.json`. Detalles para la detección:

- El launcher puede estar en la bandeja del sistema sin ventana (`minimizeToTray: true`),
  así que no sirve buscar una ventana. Usar procesos `sklauncher.exe` filtrando por
  `ExecutablePath` dentro de `<launcher>` (`Get-CimInstance Win32_Process`).
- Un launcher **oficial** abierto (otra ruta) no interfiere y no debe bloquear.
- `data\electron\lockfile` existe mientras corre y desaparece al terminar.
- El juego (`javaw`) lo lanza el launcher; con el launcher cerrado un juego huérfano no
  toca `instances.json`.

## Punto 6: versión real de la gama baja

El juego corrió con `NeoForge 21.1.251` (pantalla de carga `1.21.1-21.1.251`, menú
principal, `neoforge-21.1.251-universal.jar` en el log, Java 21.0.12.1). Matiz: esto
demuestra que la gama baja **funciona** con 21.1.251, no que se construyó con ella; sigue
sin haber ningún archivo que registre la versión original. "431 mods" del menú cuenta
mods internos; los `.jar` son 331.

## Punto 7: acceso directo

`.lnk` creado con `WScript.Shell` en `%APPDATA%\Microsoft\Windows\Start Menu\Programs\`
con destino el `.bat`, directorio de trabajo `<launcher>`, icono `<launcher>\sklauncher.exe,0`
y estilo 7:

- Al escribir "SKLauncher" en la búsqueda de Inicio apareció bajo **Aplicaciones**, junto
  al oficial `SKlauncher 4.0`.
- Al abrirlo desde la búsqueda arrancó `<launcher>\sklauncher.exe` con
  `--user-data-dir=<launcher>\data\electron`.
- A los 0,7 s no había ventana de consola (el `cmd.exe` no tenía ventana visible, ni
  en pantalla ni en la barra de tareas). Es una sola muestra, no una medición continua.
- Se abrió Inicio con clic y se escribió (no con la tecla Windows literal).

**Nombre del `.lnk`.** El sistema de archivos no distingue mayúsculas: `SKLauncher.lnk`
**chocaría** con el oficial `SKlauncher.lnk` que ya existe. Usar un nombre distinto, por
ejemplo `SKLauncher Portable.lnk`. Este documento no prueba el escritorio ni Aplicaciones.
El `.lnk` de prueba se eliminó al terminar.

## Punto 8: instancia fuera de `data\`

**No es posible mediante `directory`.** Se registró una instancia con `directory` en una
carpeta fuera de `data\` y el launcher la aceptó, pero al jugarla usó
`--gameDir <launcher>\data\.sklauncher\instances\<id>` (creó esa carpeta) y **reescribió**
el `directory` del JSON con esa ruta. El launcher ignora `directory` y deriva la carpeta
del `id`. Con `memoryMax: 4096` el juego arrancó con `-Xmx4096M`, o sea que ese campo sí
se respeta.

Consecuencia: la instancia vive en `<launcher>\data\.sklauncher\instances\<id>\`. Un enlace
simbólico o *junction* en esa ruta no se probó.

## Implicaciones para `install.ps1`

1. Llamar a `%SystemRoot%\System32\tar.exe` por ruta absoluta.
2. Carpeta de la instancia = `<launcher>\data\.sklauncher\instances\<id>`; escribir
   `directory` con esa ruta absoluta generada en tiempo de instalación.
3. Registrar con `type: "custom"` e incluir `installComplete: true`, `icon`, `createdAt`,
   `memoryMax`, `playTime: 0`, `sessionCount: 0`, `customLaunchHooks: false`.
4. Detener la ejecución si hay un `sklauncher.exe` del portable en marcha antes de
   escribir `instances.json`.
5. Escribir JSON en UTF-8 **sin BOM** (`[IO.File]::WriteAllText` con
   `New-Object Text.UTF8Encoding($false)`); `Set-Content -Encoding UTF8` de PS 5.1 agrega
   BOM. No se probó si el launcher tolera BOM.
6. En `ConvertTo-Json` de PS 5.1 usar `-Depth` suficiente y no depender de arreglos de un
   solo elemento (se desenrollan); envolver con `@()`.
7. Comprobar espacio libre: ~410 MB (launcher) + ~1,1 GB (primer arranque) + mods.
8. Avisar al usuario de que el primer Jugar descarga ~1,1 GB y necesita internet, y de los
   avisos de primer arranque del launcher.
9. Nombre del `.lnk`: no chocar, sin distinguir mayúsculas, con `SKlauncher.lnk` ni
   `SKlauncher 4.0.lnk`.

---

# Fase 2: `install.ps1`

Archivo: `install.ps1` (raíz del repo). Implementa el contrato de `windows-context.md` §5 y
los ajustes de §8, tomando `install.sh` como especificación. PowerShell 5.1, sin
dependencias, mensajes en español neutro. Flujo: chequeos → abortar si el launcher está
abierto → catálogo → menús → launcher global → accesos directos → modpack (completo o
incremental) → registro en `instances.json`.

## Decisiones de diseño y por qué

| Decisión | Motivo |
|---|---|
| Todo dentro de `& { ... }` con `try/catch` | Bajo `irm \| iex` el código corre en la sesión del usuario: un `exit` cerraría su terminal y `$ErrorActionPreference` cambiaría su sesión. Un error imprime `[ERROR] mensaje` (sin traza); como archivo (`-File`) devuelve código 1. |
| Descargas con `curl.exe` de `System32` | Trae barra de progreso, reintentos y **reanudación** (`-C -`) sin depender de la versión de .NET/TLS de PowerShell. El `.part` se conserva en `<launcher>\state\dl\`. |
| `tar.exe` y `curl.exe` por ruta absoluta de `System32` | `tar.exe` a secas puede resolver al GNU tar de Git (no lee `.zip`). |
| Rutas solo con `LOCALAPPDATA`, `APPDATA`, `USERPROFILE` | Cumple la regla de no fijar usuarios y permite simular "usuarios limpios" en las pruebas cambiando esas tres variables, sin tocar el perfil real. |
| Comprobar el launcher **antes** del catálogo | §8 pide abortar antes de descargar o tocar nada (`install.sh` lo hace después de elegir; aquí se evita que el usuario elija y luego se le pida cerrar). Solo cuenta `sklauncher.exe` con `ExecutablePath` dentro de `<launcher>`; el oficial no bloquea. |
| Actualizar el launcher con una carpeta de preparación (`SKLauncher-Portable.new`) | Se extrae completo y solo entonces se reemplaza todo menos `data\` y `state\`; una extracción fallida no deja el launcher roto. |
| Antes de extraer: `tar -tf` | Valida que el archivo esté completo (si no, lo borra y pide reintentar) y calcula la ruta más larga para el límite de 260 (§8). Sin `LongPathsEnabled` aborta con un mensaje claro y sin extraer nada. |
| Espacio libre por `HEAD` + `Content-Length` | Exige `2 × tamaño + 100 MB` antes de bajar el launcher y el modpack. Si el servidor no informa el tamaño, no bloquea. |
| Hash SHA-256 de cada mod bajado (`Get-FileHash`) | `install.sh` no lo verifica; aquí un mod dañado no llega a `mods\`. La comparación no distingue mayúsculas (`Get-FileHash` da mayúsculas; el manifest, minúsculas). |
| Estado guardado solo si todo salió bien | Igual que Linux. En la actualización incremental, un fallo es un aviso (los mods quedan como estaban, se puede reintentar); en la primera instalación es un error. |
| No pisar archivos personales al reextraer | Si el estado se pierde y se vuelve a extraer el paquete, `options.txt`, `optionsof.txt`, `optionsshaders.txt`, `servers.dat` y `servers.dat_old` que ya existan **no se sobrescriben** (`--exclude=^archivo$`). El `^…$` es necesario: sin anclar, `bsdtar` excluye también `config\…\options.txt`. Linux no hace esto. |
| Acceso directo en el Escritorio opcional | Pregunta `[s/N]` solo en modo interactivo; `DESKTOP_SHORTCUT=1/0` lo fuerza. |
| Nombre del `.lnk`: `SKLauncher Portable.lnk` | Evita chocar (sin distinguir mayúsculas) con `SKlauncher.lnk` y `SKlauncher 4.0.lnk` del launcher oficial. |
| `SKL_TEST_NO_LONGPATHS=1` | Interruptor **solo para pruebas** que simula un Windows sin rutas largas. En esta PC `LongPathsEnabled=1` y no soy administrador, así que no podía apagarlo para probar el aborto. |

Variables de entorno: `MODPACK`, `PROFILE`, `MEMORY_MAX`, `CATALOG_URL`, `DESKTOP_SHORTCUT`
(y `SKL_TEST_NO_LONGPATHS`, solo pruebas).

## Errores encontrados al construirlo (útiles para quien lo mantenga)

- `[IO.File]::Replace($tmp, $ruta, $null)` falla en PS 5.1 ("la ruta de acceso no tiene un
  formato válido"): un `$null` suelto llega como cadena vacía. Hay que usar
  `[NullString]::Value`. Solo se manifiesta al **reescribir** un `instances.json` existente.
- `"$variable: texto"` en PowerShell se interpreta como variable con ámbito (`$variable:`);
  se escribe `${variable}:`.
- `foreach (...) {}` no se puede canalizar (`| ...`) en PS 5.1; usar `ForEach-Object`.
- `bsdtar --exclude=nombre` es *no anclado* (coincide con cualquier tramo de la ruta);
  `^nombre$` ancla.
- `Read-Host` no imprime su texto de pregunta cuando la salida está redirigida (no afecta
  a una consola real, pero sí a las pruebas que capturan la salida).
- Codificación (probado con un archivo de prueba): con `irm \| iex`, **UTF-8 sin BOM y
  `Content-Type: text/plain; charset=utf-8`** se decodifica bien; un **BOM rompe** el primer
  comando aunque haya `charset`; sin `charset` salen acentos rotos. Con `-File` ocurre lo
  contrario (pide BOM). Por eso `install.ps1` se guarda sin BOM y las pruebas lo corren por
  `-File` usando una copia con BOM.
- Zips: los creados con `Compress-Archive` y con `[IO.Compression.ZipFile]` en PS 5.1, y el
  hecho con `tar -a`, se extraen bien con `tar.exe` de `System32`.

# Fase 3: pruebas de aceptación

Cómo repetirlas:

```powershell
.\scripts\windows\test-install.ps1            # usa C:\mct (ruta corta a propósito)
```

Crea un layout falso de R2 (`scripts\windows\make-test-layout.ps1`), lo sirve con
`scripts\windows\serve-test.ps1` (`HttpListener`, con `Range`) y corre `install.ps1` como
usuarios simulados. Resultado: **70 comprobaciones, 0 fallos**. `Remove-Item` no puede
borrar `C:\mct` desde la herramienta que usé, pero el propio script lo recrea al empezar.

| # | Prueba | Resultado |
|---|---|---|
| 1 | Usuario limpio: comando → menú → NeoFresh → Gama baja | **Pasa con datos reales** (ver abajo) |
| 2 | Mismo perfil otra vez: no duplica; `saves\prueba` y `options.txt` marcados intactos | **Pasa.** Además se conservan `name`, `playTime` y `memoryMax` cambiados por el usuario, y no se vuelve a bajar nada |
| 2b | Reinstalar sin estado: el paquete no pisa `options.txt` | **Pasa** (`options.txt` anidado del paquete sí se aplica) |
| 2c | Estado antiguo sin `modpack/profile` | **Pasa**: reutiliza la instancia y completa el estado |
| 3 | Otro perfil: segunda instancia con el perfil en el nombre, la primera intacta | **Pasa** (`FakePack` / `FakePack Gama Alta`, id `fakepack-high`) |
| 4 | Un mod cambiado en el servidor: solo se baja ese | **Pasa**: se piden solo el mod cambiado y el nuevo (con espacio y `+` en el nombre, bien codificados); el quitado se borra |
| 5a | Usuario con espacio y acento en el nombre | **Pasa** (`Usuário Pérez`; `curl.exe`, `tar.exe` y el `.lnk` aceptan la ruta) |
| 5b | Nombre de usuario largo | **Pasa**: con `SKL_TEST_NO_LONGPATHS=1` aborta con mensaje claro, sin carpeta de instancia ni registro. Con el registro real (`LongPathsEnabled=1`) la misma ruta de ~295 caracteres se instala bien |
| 6 | Launcher abierto | **Pasa**: aborta (código 1, menciona la bandeja) sin cambiar `instances.json`; un `sklauncher.exe` de otra ruta no bloquea. También verificado con el launcher real abierto |
| 7 | Descarga interrumpida | **Pasa**: el servidor corta la descarga; la primera corrida falla con mensaje claro y deja el `.part`; el reintento reanuda con `Range` y termina bien |
| — | Sin internet / sin espacio / menú por stdin / `irm \| iex` con acentos | **Pasan** |

**Prueba 1 con datos reales (en el perfil real de esta PC).** Layout de R2 armado con el
`catalog.json` del repo, el `sk-portable.zip` real (170 MB) y la gama baja real (331 mods,
1,1 GB, ruta más larga del tar: 88 caracteres). Flujo exacto del amigo:
`irm http://localhost/install.ps1 | iex` → menú (NeoFresh, Gama Baja) →

- Launcher instalado en `%LOCALAPPDATA%\Programs\SKLauncher-Portable` (409 MB); instancia con
  1891 archivos y 331 mods; instalación completa en 10 s (todo es local).
- `SKLauncher Portable` aparece al buscar "SKLauncher" en Inicio, junto a `SKlauncher 4.0`, y
  abre el launcher con `--user-data-dir=<launcher>\data\electron`.
- El launcher conservó `neofresh` y **agregó** `latest-release` y `latest-snapshot` por su
  cuenta. La instancia sale como "NeoFresh", `NeoForge 1.21.1`.
- Primer Jugar: descargas automáticas y juego en el menú principal
  (`NeoForge 21.1.251 (431 mods)`, 0 errores fatales). ~2 min hasta lanzar el juego y ~6 min
  hasta el motor de sonido en el primer arranque. El juego muestra antes la pantalla de
  bienvenida de Minecraft (narrador/accesibilidad), normal en un primer arranque.
- Segunda corrida (con el launcher cerrado): solo pidió `catalog.json` y `manifest.json`;
  conservó `lastPlayed`, `playTime` y `sessionCount` que escribió el launcher; el `options.txt`
  creado por el juego quedó intacto.
- La carpeta de datos del launcher **oficial** (`%APPDATA%\.sklauncher`) mantuvo los mismos
  hashes en `instances.json`, `accounts.json` y `settings.json` durante todo el proceso.

**Límites de lo probado.**

- Los perfiles alto/bajo y las actualizaciones incrementales se probaron con un modpack falso;
  con datos reales solo se probó `neofresh/low` (no hay copia local de la gama alta).
- El servidor de prueba es HTTP en `localhost`; no se probó contra R2 ni con HTTPS real.
- Solo Windows 11 (10.0.26200) con PowerShell 5.1; no se probó en Windows 10.
- La rama sin rutas largas se probó con el interruptor de pruebas, no con el registro real.
- No se probaron las variantes `modpack` y `custom` sin `installComplete` del punto 3 de la
  Fase 1 (solo se comprobó que aparecen), ni el modpack `atm10sky`.

# Fase 4: entrega

## Archivos nuevos (todos sin commit)

- `install.ps1`: el instalador.
- `docs/windows-findings.md`: este documento.
- `scripts/windows/serve-test.ps1`: servidor estático de prueba (`HttpListener`).
- `scripts/windows/make-test-layout.ps1`: arma un layout tipo R2 (falso, o real con
  `-SkPortable` y `-NeoLow`).
- `scripts/windows/test-install.ps1`: las pruebas de aceptación automáticas.

No se modificó `catalog.json`, `install.sh`, `scripts/package-instance.sh` ni el resto.
El commit `cd85ef3` (de Linux) actualizó `install.sh` con lo aprendido en la Fase 1 y
`install.ps1` ya coincide con ese comportamiento.

## Para publicar (pendiente de tu confirmación; no lo hice)

Layout en R2 (relativo a la URL del catálogo):

```
install.ps1                        <- UTF-8 SIN BOM, Content-Type: text/plain; charset=utf-8
sk-portable.zip                    <- contenido de sk-portable\ EN LA RAÍZ, sin data\
catalog.json  <prefix>/mods/*.jar  <perfil>/instance.tar.gz  <perfil>/manifest.json   (como ya haces)
```

- `install.ps1` **debe** subirse con ese `Content-Type`. Con `application/octet-stream` (lo
  habitual si no se indica) `irm` sí lo devuelve como texto y funciona (probado), pero sin
  `charset` decodifica como Latin-1 y todos los acentos salen rotos (`catÃ¡logo`). Con rclone: `rclone copyto install.ps1 r2:minecraft-data/install.ps1
  --header-upload "Content-Type: text/plain; charset=utf-8"`. Ajusta bucket/remote a los tuyos.
- Armar `sk-portable.zip` desde Windows (no incluir `data\`):
  `tar.exe -a -cf sk-portable.zip -C <sk-portable> <cada elemento excepto data>` (el script
  `make-test-layout.ps1 -SkPortable` lo hace así), o `Compress-Archive` sobre la lista de
  elementos.
- El comando de los amigos: `irm https://<dominio>/install.ps1 | iex`.
- La versión del launcher de Windows (`launcher.windows.version`) decide si se vuelve a
  bajar: al cambiar el zip hay que subir también el número en el catálogo.

## Diferencias respecto al contrato (`windows-context.md`)

Ninguna que rompa el contrato. Precisiones y añadidos:

- La instancia no puede ubicarse fuera de `data\` (el launcher ignora `directory`).
- `memoryMax`, `playTime` y `sessionCount` se escriben explícitamente en instancias nuevas.
- El chequeo de launcher abierto va antes del catálogo, no después de elegir.
- Verifica el SHA-256 de cada mod y el espacio libre; `install.sh` no lo hace.
- Protege archivos personales al reextraer (Linux podría adoptar `--exclude` equivalente en
  `tar -xzf` si algún paquete llegara a traer `options.txt`).
- Actualiza el launcher por una carpeta de preparación en vez de extraer encima.
- Pregunta por el acceso en el Escritorio en modo interactivo.

## Pendiente / decisiones para ti

1. **Publicar** `install.ps1` y `sk-portable.zip` a R2 (con las cabeceras de arriba) y probar
   el comando real desde otra PC, idealmente Windows 10 y un usuario de nombre largo. Cuando
   empaquetes la gama alta, verifica con un `tar -tf` que su ruta más larga (§8: 252
   caracteres con un usuario de 20) sigue siendo la esperada.
2. **README**: no lo edité (no es mío). Falta mencionar el comando de Windows.
3. Primer arranque del launcher: pide iniciar sesión y muestra avisos ("Ayuda a mejorar",
   "Acceso anticipado") que el instalador no puede evitar. Se podría prellenar
   `settings.json` (`analyticsConsentChosen`), pero no lo hice por ser decisión de privacidad
   del usuario.
4. Fuera de la v1 (igual que en §7): propagar cambios de `config\`/`kubejs\`, entrada de
   desinstalación y `uninstall.ps1`.
5. Sigue sin verificarse: enlaces simbólicos/*junction* para instancias fuera de `data\`, BOM
   en `instances.json` y la necesidad real de cada campo del conjunto mínimo de la Fase 1.

## Qué dejé en esta PC

Para poder comprobar la prueba 1 de verdad, la instalación quedó **puesta** en tu perfil:

- `%LOCALAPPDATA%\Programs\SKLauncher-Portable` (2,9 GB, con el juego descargado, la
  instancia NeoFresh y una cuenta sin conexión de prueba llamada `PruebaWin`).
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\SKLauncher Portable.lnk`.
- `C:\mct`, carpeta vacía (la herramienta no me dejó borrarla).
- Archivos temporales en la carpeta temporal de sesión, fuera del repo.

Para dejar la PC como estaba:

```powershell
Remove-Item "$env:LOCALAPPDATA\Programs\SKLauncher-Portable" -Recurse -Force
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\SKLauncher Portable.lnk"
Remove-Item C:\mct
```

Tu SKLauncher oficial y sus datos no se tocaron.
