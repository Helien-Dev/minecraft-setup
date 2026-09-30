# mine-script

Instalador de un solo comando: deja **SKLauncher** y el **modpack** que elijas listos para jugar.

```bash
curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | sh     # Linux
```

```powershell
irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex          # Windows (PowerShell)
```

## Qué hace

1. Pregunta qué modpack quieres y, si tiene varios perfiles (por ejemplo, Gama Alta y Gama Baja), cuál.
2. Instala SKLauncher si hace falta. Hay uno solo por computadora; cada modpack es una instancia dentro de él.
3. Instala o actualiza la instancia:
   - la configuración del modpack (`config/`, `kubejs/`, resourcepacks...) se baja solo si cambió;
   - de los mods, baja solo los nuevos o actualizados y borra los que el modpack ya no usa.
4. Registra la instancia en SKLauncher: al abrirlo, ya aparece.

Para actualizar, basta con volver a correr el mismo comando. Nunca se tocan las partidas guardadas, `options.txt`
(teclas, gráficos) ni la lista de servidores.

## Perfiles e instancias

- Si instalas **otro perfil** de un modpack que ya tienes, se crea una instancia aparte (`NeoFresh Gama Baja`) y la
  primera no se toca.
- Volver a correr el comando con el mismo perfil actualiza esa instancia.
- Los mods que agregues a mano a una instancia se respetan; los que un perfil excluye se quitan siempre.

## Sin menú

```bash
curl -sSL https://minecraft-data.alvaroavila.dev/install.sh | MODPACK=neofresh PROFILE=low sh
```

```powershell
$env:MODPACK='neofresh'; $env:PROFILE='low'; irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex
```

Los ids están en [`catalog.json`](catalog.json). Otras variables: `MEMORY_MAX` (MB de RAM para la instancia) y, en
Windows, `DESKTOP_SHORTCUT=1` (acceso directo en el Escritorio) y `SKL_INSTANCES_DIR` (carpeta de instancias, ver abajo).

## Requisitos

- **Linux** x86_64 con `curl` y `python3`. SKLauncher es un AppImage y necesita FUSE (el script avisa si falta).
- **Windows** 10 (1803 o posterior) u 11, sin permisos de administrador. Si ya tienes el SKLauncher oficial (en
  cualquier carpeta), la instancia se agrega a ese; si no, se instala un SKLauncher portable ("SKLauncher Portable" en el Menú Inicio).
  Si tu SKLauncher guarda las instancias en otra carpeta (por ejemplo `G:\juegos\maincra\instances`), el script la
  detecta y te la propone; puedes aceptarla con Enter o pegar otra ruta, incluso la de una instancia.
- La primera vez que juegas una instancia, SKLauncher descarga Minecraft, NeoForge y Java (~1 GB).

## Para quien mantiene los modpacks

- [Publicar modpacks, perfiles y el instalador](docs/publicar.md)
- [Hallazgos de la versión de Windows](docs/windows-findings.md)
- [Seguimiento de mods del servidor](data/README.md)
