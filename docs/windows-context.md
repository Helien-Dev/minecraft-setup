# Contexto para la instancia de Claude en Windows

Lee este archivo completo antes de tocar nada. Responde siempre en español
neutro (nada de voseo ni jerga: "tú", "puedes", "necesitas"; sin "vos/che/dale").

## 1. Qué es este proyecto

`mine-script` reparte modpacks de Minecraft a amigos del dueño. Hoy existe
`install.sh` (Linux) que instala **un SKLauncher global** y registra una
instancia de modpack en él. Se está ampliando a:

1. **Varios modpacks**, cada uno con **perfiles de gama** (alta/baja) cuando aplique.
2. **Windows**, con un `install.ps1` equivalente.

Experiencia objetivo: un amigo ejecuta **un solo comando**, en Linux o en Windows:

```
curl -sSL https://<dominio>/install.sh | sh          # Linux
irm https://<dominio>/install.ps1 | iex              # Windows (PowerShell)
```

El script muestra un menú (modpack → perfil, solo si el modpack tiene más de
uno), instala SKLauncher si no está, instala la instancia elegida y deja todo
listo para abrir el launcher e iniciar sesión.

## 2. Reglas de diseño ya decididas (no las re-discutas)

- **Un solo SKLauncher global por máquina.** NO un launcher por modpack ni por perfil.
  Cada modpack/perfil es una **instancia** dentro de ese único launcher.
- **Ejecutar el script otra vez no duplica el launcher ni rompe nada**: todo queda
  en el mismo lugar; solo se actualiza lo que cambió.
- **Nombres de instancia:**
  - La primera instalación de un modpack se llama solo por su nombre (p. ej. `NeoFresh`).
  - Si el usuario instala **otro perfil del mismo modpack**, la instancia nueva se
    diferencia con el perfil: `NeoFresh Gama Baja` / id `neofresh-low`. La primera no
    se toca ni se renombra. (Convención propuesta; si ves un problema, repórtalo.)
  - Volver a correr el script con el **mismo** perfil = actualizar en sitio, no crear otra.
  - Para saber qué perfil tiene cada instancia hay que guardar un estado por instancia
    (ver §5).
- **Nunca borrar datos del jugador**: `saves/`, `options.txt`, `screenshots/`,
  `servers.dat`, `resourcepacks/` ajenos. Una reinstalación NO puede borrar la carpeta
  de la instancia entera.
- **SKLauncher portable = la carpeta `sk-portable/` COMPLETA** (sklauncher.exe + DLLs +
  `.pak` + `resources/` + `locales/` + `SKLauncher-Portable.bat`, ~409 MB). Llevar solo
  el `.exe` falla. Al actualizar el launcher se reemplaza todo **excepto `data\`**.
- Nunca rutas con un usuario concreto: siempre `$env:LOCALAPPDATA`, `$env:APPDATA`,
  `$env:USERPROFILE`. Debe funcionar con usuarios con espacios o acentos.
- No usar dependencias externas (nada de Python, Git, 7-Zip, winget). Solo lo que trae
  Windows 10/11.

## 3. Hechos verificados del entorno del dueño (Linux)

Instancia de referencia `fresh-neo` (nombre visible `NeoFresh`), tal como la guarda
SKLauncher en `~/.sklauncher/instances.json`:

```json
{"id": "fresh-neo", "name": "NeoFresh", "type": "custom", "installComplete": true,
 "icon": "Furnace_On", "versionId": "1.21.1-neoforge-21.1.251", "gameType": "neoforge",
 "minecraftVersion": "1.21.1", "loaderVersion": "21.1.251",
 "directory": "/home/dev/.sklauncher/instances/fresh-neo",
 "createdAt": "2026-09-19T20:11:56.732Z", "memoryMax": 24064, "customLaunchHooks": false}
```

Perfiles de NeoFresh (comparados byte a byte en Linux):

| | Gama baja (`NeoLowProfile`) | Gama alta (`fresh-neo`) |
|---|---|---|
| Mods | 331 | 371 |
| Mods exclusivos de baja | 0 (es subconjunto exacto de alta) | |
| `kubejs/`, `scripts/`, `defaultconfigs/` | idénticos | |
| Archivos de `config/` distintos | 44 | |
| `shaderpacks/` `resourcepacks/` | no trae | sí (~100 MB) |

Los 40 mods extra de alta son visuales/de cliente (iris, entity_model_features,
EuphoriaPatcher, etc.). **La versión de Minecraft/NeoForge de la gama baja NO está
escrita en ningún archivo**; se asume 1.21.1 + NeoForge 21.1.251. Verifícalo.

`SKLauncher-Portable.bat` (portable actual):

```bat
@echo off
set "APPDATA=%~dp0data"
start "" "%~dp0sklauncher.exe" --user-data-dir="%~dp0data\electron"
```

Es decir, el launcher guarda TODO (cuentas, `instances.json`, `versions/`,
`libraries/`, `assets/`, instancias) bajo `sk-portable\data\`, redirigiendo `APPDATA`.

Datos de la instalación oficial de SKLauncher 4.0.51 en la PC de Windows del dueño
(es una instalación por usuario, sin admin):

| Qué | Valor |
|---|---|
| Programa | `%LOCALAPPDATA%\Programs\sklauncher\sklauncher.exe` |
| Datos | `%APPDATA%\.sklauncher` |
| Acceso directo Menú Inicio | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\` (esto hace que aparezca al buscar) |
| Nombre del `.lnk` | debe contener "SKLauncher"; usar uno distinto al oficial ("SKlauncher 4.0") para no chocar |
| Destino del `.lnk` | el `SKLauncher-Portable.bat`, NO el `.exe` (el `.bat` redirige la carpeta de datos) |
| Directorio de trabajo | la carpeta del launcher portable |
| Icono | `<launcher>\sklauncher.exe,0` |
| Estilo de ventana | 7 (minimizada, para que no parpadee la consola) |
| Acceso directo Escritorio | `%USERPROFILE%\Desktop` (opcional) |
| Entrada en Aplicaciones | opcional, fuera de la v1 |

Ojo: en esa PC ya puede existir la instalación oficial; el portable no debe pisarla
ni leer/escribir su `%APPDATA%\.sklauncher` real.

## 4. Estructura objetivo en Windows

```
%LOCALAPPDATA%\Programs\SKLauncher-Portable\     <- launcher GLOBAL (contenido de sk-portable\)
  SKLauncher-Portable.bat, sklauncher.exe, *.dll, *.pak, locales\, resources\ ...
  data\                                          <- lo crea el launcher; NUNCA se borra ni se publica
    .sklauncher\instances.json
    .sklauncher\instances\<id>\                  <- una carpeta por instancia (mods\, config\, saves\ ...)
```

Dónde viven las instancias (`data\.sklauncher\instances\<id>` por defecto) es algo
a **confirmar en la Fase 1**; el campo `directory` de `instances.json` es una ruta
absoluta y debe generarse en tiempo de instalación, no fijarse.

## 5. Contrato con la instancia de Linux (implementado y probado)

La instancia de Linux ya terminó su parte: `catalog.json` (raíz del repo),
`scripts/package-instance.sh` e `install.sh` (implementación de referencia; se probó de
punta a punta con un R2 falso: primera instalación, reinstalación, segundo perfil,
actualización incremental, instalación antigua de ATM10 y menú interactivo).
**`install.sh` es la especificación de comportamiento: replícalo en PowerShell.** Tú eres
dueño de `install.ps1`, `docs/windows-findings.md` y scripts específicos de Windows. No
edites lo demás sin avisar; si algo del contrato no funciona en Windows, documéntalo en
`windows-findings.md`.

Lee `catalog.json` (raíz del repo) tal cual; es el catálogo real que se publica en R2.
Campos: `launcher.{linux,windows}.{url,version}`; por modpack `id`, `name`, `type`
(opcional, default `modpack`), `icon` (opcional), `minecraft`, `loader`, `loaderVersion`,
`versionId`, `memoryMax`, `prefix` y `profiles[]` con `id`, `label` (opcional), `tar`,
`manifest`. Todas las rutas del catálogo (`url`, `tar`, `manifest`, `<prefix>/mods`) son
relativas a la URL del propio catálogo (equivale a `urljoin`).

- **Launcher Windows:** `launcher.windows.url` es `sk-portable.zip`, con el **contenido de
  `sk-portable/` en la raíz del zip** (sin carpeta envolvente) y **sin `data\`**. Se extrae con
  `tar.exe -xf` dentro de la carpeta del launcher. Actualizar el launcher = reemplazar todo
  menos `data\`. Guarda la versión instalada (`<launcher>\state\launcher.version`) y no vuelvas
  a bajarlo si coincide con `launcher.windows.version`.
- **`manifest.json` de cada perfil:** `{"mods": {"<archivo>.jar": {"sha256": "...", "size": N}}}`.
  Los `.jar` viven una sola vez en `<prefix>/mods/` (compartidos entre perfiles).
- **Primera instalación:** bajar el `tar` del perfil y extraerlo con `tar.exe` en la carpeta
  de la instancia. **Siguientes:** comparar manifest local vs remoto; bajar los mods nuevos o
  con otro sha256 (o cuyo archivo falte), borrar los que ya no están, y guardar el estado
  solo si todo salió bien (si falla, dejar el estado como estaba y avisar).
- **Estado por instancia:** `<launcher>\state\<instance-id>.json` = el manifest remoto ya
  aplicado **más** las claves `"modpack"` y `"profile"`. Es lo que decide la regla de nombres.
- **Regla de nombres (copia la lógica del bloque `PLAN` de `install.sh`):**
  1. Existe una instancia del mismo modpack con el mismo perfil (o un estado antiguo sin
     `profile`, donde el id del estado es el id del modpack) → reutilizarla, actualizar en sitio.
  2. Si no, y ya hay otra instancia de ese modpack (otro perfil) → id `<modpack>-<perfil>`,
     nombre `<name> <label>` (p. ej. `NeoFresh Gama Baja`).
  3. Si no hay ninguna → id `<modpack>`, nombre `<name>`.
- **Registro en `instances.json`:** fusionar sin pisar otras instancias; al re-registrar una
  instancia existente conservar lo que el usuario ya tocó (`name`, `memoryMax`, `createdAt`,
  `playTime`, `lastPlayed`...) y actualizar el resto; copia `.bak` antes de escribir y
  escritura atómica (archivo temporal + reemplazo).
- **Elección:** un modpack con un solo perfil no pregunta perfil; con un solo modpack
  tampoco pregunta modpack. Overrides no interactivos: `$env:MODPACK`, `$env:PROFILE`,
  `$env:MEMORY_MAX`, `$env:CATALOG_URL`.
- Los mensajes van en español neutro. Bajo `irm | iex` el script sí puede usar `Read-Host`
  para el menú (a diferencia de `curl | sh`, donde stdin es el pipe).
- **Para probar sin R2:** sirve una carpeta con el mismo layout que R2 y apunta
  `$env:CATALOG_URL` ahí. Python normalmente NO está en Windows: escribe un servidor
  estático mínimo en PowerShell (`System.Net.HttpListener`, en `scripts/windows/serve-test.ps1`)
  o usa `python -m http.server` solo si ya lo tienes. Haz las pruebas rápidas con un modpack
  falso diminuto (unos pocos `.jar` de mentira) y una sola corrida completa con `NeoLowProfile` real.
  `Invoke-WebRequest` no soporta `file://`. El layout de R2 se genera con
  `scripts/package-instance.sh` (Linux) o, para pruebas, a mano: catálogo, `sk-portable.zip`,
  `neofresh/{high,low}/{instance.tar.gz,manifest.json}` y `neofresh/mods/*.jar`.

## 6. Qué debes hacer

### Fase 0: preparación

Necesitas llevar a esta PC: este repo, la carpeta `sk-portable/` completa (con
`SKLauncher-Portable.bat`) y `NeoLowProfile/` (config/kubejs/mods de prueba). Si falta
algo, pídeselo al dueño; no lo reconstruyas.
Anota: versión de Windows, `$PSVersionTable.PSVersion`, si existe `tar.exe`, y si
`sklauncher.exe` oficial ya está instalado.

### Fase 1: verificar los supuestos (lo más riesgoso; nada está probado)

Responde cada punto con evidencia (rutas, contenido de archivos), sin suponer:

1. Ejecutando `SKLauncher-Portable.bat`, ¿el launcher escribe en `sk-portable\data\`
   y **no** en el `%APPDATA%\.sklauncher` real? Compara ambas carpetas antes/después.
2. ¿Dónde crea `instances.json` y cómo queda el formato? ¿Crea una carpeta `instances\`?
3. Registra a mano una entrada como la de §3 (con `directory` absoluto) en ese
   `instances.json` con el launcher cerrado. ¿La instancia aparece en el launcher? ¿Con
   `type: custom` y con `type: modpack`? ¿Qué campos son obligatorios?
4. Al darle Jugar, ¿el launcher descarga solo Minecraft 1.21.1, NeoForge 21.1.251 y el
   Java necesario, o hay que pre-instalarlos? Si hay que pre-instalar, ¿cómo (archivos
   en `versions\`, `libraries\`)? Comprueba que el juego llega al menú principal con
   la gama baja.
5. ¿El launcher reescribe/bloquea `instances.json` mientras está abierto? El script
   debe detectar si SKLauncher está en ejecución y avisar antes de tocar el archivo.
6. ¿La versión real de la gama baja coincide con NeoForge 21.1.251 (log del juego)?
7. Confirma que un `.lnk` creado con `WScript.Shell` (§3) aparece al buscar
   "SKLauncher" con la tecla Windows y abre el launcher sin parpadeo de consola.
8. ¿Puede la instancia estar fuera de `data\`? (solo para decidir el mejor sitio.)

Guarda los resultados en `docs/windows-findings.md` y **detente a informar** si el
punto 3 o 4 falla: cambia el diseño.

### Fase 2: escribir `install.ps1`

Requisitos: PowerShell 5.1 (sin sintaxis de PS7), sin dependencias externas, español
neutro, `$ErrorActionPreference = 'Stop'`, TLS 1.2 forzado, `$ProgressPreference =
'SilentlyContinue'` (o `curl.exe`) para descargas rápidas, hashes con `Get-FileHash`,
JSON con `ConvertFrom-Json`. Debe:

1. Leer el catálogo, mostrar menú de modpack y de perfil (si aplica).
2. Instalar el launcher global si falta (descargar `sk-portable.zip`, extraer con
   `tar.exe`, sin tocar `data\`); si ya está y la versión coincide, no volver a bajarlo.
3. Crear el `.lnk` (Menú Inicio, y Escritorio opcional) según §3.
4. Aplicar la regla de nombres de §2 y guardar el estado por instancia.
5. Primera vez: bajar el tar del perfil y extraerlo en la carpeta de la instancia.
   Siguientes: actualización incremental **solo de `mods\`** por manifest. Los cambios de
   `config\`, `kubejs\`, etc. NO se propagan en la v1 (ver §7); no toques esas carpetas
   después de la primera instalación.
6. Registrar la instancia en `instances.json` según §5.
7. Fallar con un mensaje claro (no con una traza) si no hay internet o falta espacio.

### Fase 3: pruebas de aceptación

1. Usuario limpio: comando → menú → NeoFresh → Gama baja → launcher instalado, `.lnk`
   encontrable, instancia `NeoFresh` visible y el juego llega al menú.
2. Correr de nuevo con el mismo perfil: no duplica nada. Antes de correrlo, crea
   `saves\prueba\` y un `options.txt` marcado; deben seguir intactos.
3. Correr eligiendo el otro perfil: aparece una segunda instancia con el perfil en el
   nombre y la primera queda intacta.
4. Actualización: cambia un mod en el servidor de prueba local; solo ese mod se baja.
5. Usuario de Windows con espacio/acento en el nombre.
6. Launcher abierto durante la ejecución: el script lo detecta y avisa.
7. Descarga interrumpida a la mitad: al reintentar se recupera.

### Fase 4: entrega

Completa `docs/windows-findings.md` (hechos verificados, decisiones tomadas y por qué,
diferencias respecto a este contrato, pendientes). No hagas `git push` ni publiques
nada a R2 sin confirmación explícita del dueño. No subas `accounts.json`, tokens ni
la carpeta `data\` al repo.

## 7. Pendiente / fuera de alcance de la v1

- Qué otros modpacks se agregan y sus perfiles (los define el dueño después; el
  catálogo es datos, agregar uno no debe requerir tocar los scripts).
- Propagar cambios de `config\`, `kubejs\`, `defaultconfigs\` y `scripts\` en las
  actualizaciones: hoy solo se actualizan los mods (igual que en Linux). Haría falta un
  paquete "overlay" con hash en el manifest; se decide cuando el dueño lo necesite.
- Entrada de desinstalación en Configuración > Aplicaciones (HKCU) y `uninstall.ps1`.

## 8. Ajustes tras la Fase 1 (cruce con Linux)

La Fase 1 quedó aprobada; no hay cambios de diseño. Para las Fases 2 a 4:

- **Se aceptan** todas las implicaciones de `docs/windows-findings.md` ("Implicaciones para
  `install.ps1`"), incluido `type: custom`, `tar.exe` de `%SystemRoot%\System32`, JSON UTF-8 sin BOM y
  el nombre `SKLauncher Portable.lnk`.
- **Launcher abierto = abortar** (no solo avisar), antes de descargar o tocar nada, con un mensaje que
  mencione la bandeja del sistema. `install.sh` ya hace lo mismo. Solo cuenta el `sklauncher.exe` cuyo
  `ExecutablePath` está dentro de `<launcher>`.
- **Instancia nueva** = `playTime: 0`, `sessionCount: 0`, `customLaunchHooks: false` (Linux ya lo hace).
  Al re-registrar una existente NO reiniciar esos campos: se conserva lo del launcher.
- **Rutas largas (riesgo real en la gama alta).** Con un usuario de 20 caracteres, el archivo más largo
  del perfil alto mide 252 caracteres (límite 260); con un usuario de ~28+ ya se pasa. El culpable es
  `shaderpacks\ComplementaryReimagined_r5.9.3 + EuphoriaPatches_1.10.5\shaders\...`. La gama baja llega
  a 202. Antes de extraer, `install.ps1` debe calcular `longitud de la ruta destino + ruta más larga del
  tar` (`tar -tf`) y, si es >= 260 y `LongPathsEnabled` no está activo
  (`HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem`), abortar con un mensaje claro en vez de dejar una
  extracción a medias. Incluye esto en la prueba 5 de la Fase 3 (usuario con nombre largo).
- **Primer Jugar** descarga ~1,1 GB (ya lo documentaste): avisa al final, como hace `install.sh`.
