# install.ps1
#
# Instalador de un click de SKLauncher + modpacks para Windows. Pensado para correr así
# (PowerShell 5.1 o superior, sin permisos de administrador):
#
#   irm https://TU-DOMINIO/install.ps1 | iex
#
# Es el equivalente de install.sh (que es la especificación de comportamiento):
#   1. Descarga el catálogo (catalog.json) y pregunta qué modpack quieres y, si el
#      modpack tiene perfiles de gama, cuál perfil.
#   2. Instala UN SKLauncher portable global en %LOCALAPPDATA%\Programs\SKLauncher-Portable
#      (si ya está en la versión del catálogo, no lo vuelve a bajar) y crea el acceso
#      directo "SKLauncher Portable" en el Menú Inicio.
#   3. Primera vez: descarga el paquete del perfil y lo extrae en la carpeta de la instancia.
#      Corridas siguientes: compara el manifest remoto contra el que guardó y baja/borra
#      solo los mods que cambiaron.
#   4. Registra la instancia en instances.json para que aparezca en SKLauncher.
#
# Nombres de instancia: la primera vez el modpack se llama solo por su nombre ("NeoFresh").
# Si después instalas OTRO perfil del mismo modpack, la instancia nueva lleva el perfil en el
# nombre ("NeoFresh Gama Baja") y la primera no se toca. Volver a correr con el mismo perfil
# actualiza esa instancia en sitio.
#
# Para saltarte el menú, define variables de entorno antes de correrlo:
#   $env:MODPACK='neofresh'; $env:PROFILE='low'; irm https://TU-DOMINIO/install.ps1 | iex
# Otras: $env:MEMORY_MAX (MB), $env:CATALOG_URL, $env:DESKTOP_SHORTCUT ('1' o '0').
#
# Se puede re-ejecutar sin problema. Nunca borra la carpeta de una instancia ni sus datos
# (partidas, options.txt, screenshots, servers.dat).
#
# Publicación: este archivo debe servirse como UTF-8 con "Content-Type: text/plain; charset=utf-8"
# (ver docs/windows-findings.md), o `irm` decodifica mal los acentos.

try {
& {
  $ErrorActionPreference = 'Stop'          # solo dentro de este bloque: no cambia tu sesión
  $ProgressPreference = 'SilentlyContinue'

  # ---------------------------------------------------------------------------------------
  # Configuración. Todo lo demás (URLs, versiones, memoria) sale del catálogo, relativo a
  # la URL del propio catálogo.
  # ---------------------------------------------------------------------------------------
  $CatalogUrl = if ($env:CATALOG_URL) { $env:CATALOG_URL } else { 'https://minecraft-data.alvaroavila.dev/catalog.json' }

  function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
  function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
  function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

  # --- chequeos previos ---
  if ($env:OS -ne 'Windows_NT') { throw 'Este instalador solo funciona en Windows (en Linux usa install.sh).' }
  if (-not [Environment]::Is64BitOperatingSystem) { throw 'SKLauncher necesita un Windows de 64 bits.' }
  if (-not $env:LOCALAPPDATA -or -not $env:APPDATA -or -not $env:USERPROFILE) { throw 'No se encontraron las carpetas del usuario (LOCALAPPDATA/APPDATA/USERPROFILE).' }
  # Por ruta absoluta: `tar.exe` a secas puede resolver al GNU tar de Git, que no lee .zip.
  $Tar  = Join-Path $env:SystemRoot 'System32\tar.exe'
  $Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  foreach ($exe in $Tar, $Curl) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Falta $exe. Necesitas Windows 10 (1803 o posterior) o Windows 11." }
  }

  $LauncherDir = Join-Path $env:LOCALAPPDATA 'Programs\SKLauncher-Portable'
  $StateDir    = Join-Path $LauncherDir 'state'
  $DlDir       = Join-Path $StateDir 'dl'                 # descargas en curso (se reanudan)
  $SklDir      = Join-Path $LauncherDir 'data\.sklauncher'
  $InstancesJson = Join-Path $SklDir 'instances.json'
  $StartMenu   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

  # SKLauncher reescribe instances.json completo mientras está abierto y pisa los cambios
  # externos (verificado en Windows): registrar la instancia con el launcher abierto se pierde.
  # Solo cuenta el sklauncher.exe de ESTE launcher (el oficial, en otra ruta, no estorba).
  $abierto = @(Get-CimInstance Win32_Process -Filter "Name='sklauncher.exe'" | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($LauncherDir + '\', [StringComparison]::OrdinalIgnoreCase) })
  if ($abierto.Count -gt 0) {
    throw ('SKLauncher Portable está abierto. Ciérralo (también desde el ícono de la bandeja del sistema, ' +
           'junto al reloj: clic derecho > salir) y vuelve a ejecutar el script. No se cambió nada.')
  }

  # --- utilidades ---
  function Join-Url($rel) { ([Uri]::new([Uri]$CatalogUrl, $rel)).AbsoluteUri }

  # -Big: barra de progreso y descarga reanudable (queda un .part si se corta).
  function Get-Remote($url, $dest, [switch]$Big) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $part = "$dest.part"
    if (-not $Big) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    for ($try = 1; $try -le 2; $try++) {
      $a = @('-fL', '--retry', '3', '--connect-timeout', '30', '-o', $part)
      if ($Big) { $a += @('-C', '-', '--progress-bar') } else { $a += '-s' }
      & $Curl @a $url
      if ($LASTEXITCODE -eq 0) { Move-Item -LiteralPath $part -Destination $dest -Force; return }
      # 33/36: el .part ya estaba completo o no coincide con el servidor: empezar de cero.
      if (($LASTEXITCODE -eq 33 -or $LASTEXITCODE -eq 36) -and $try -eq 1) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue; continue }
      break
    }
    throw "No se pudo descargar $url (curl $LASTEXITCODE). Revisa tu conexión a internet e inténtalo de nuevo."
  }

  function Get-RemoteSize($url) {
    $h = & $Curl -sIL --max-time 30 $url
    $m = @($h | Select-String -Pattern '^Content-Length:\s*(\d+)') | Select-Object -Last 1
    if ($m) { [int64]$m.Matches[0].Groups[1].Value } else { 0 }
  }

  # Falla con un mensaje claro si no cabe: bajar + extraer ~ 2 veces el tamaño.
  function Assert-Space($url, $where, $what) {
    $size = Get-RemoteSize $url
    if ($size -le 0) { return }
    $need = 2 * $size + 100MB
    try { $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($where))).AvailableFreeSpace } catch { return }
    if ($free -lt $need) {
      throw ("No hay espacio suficiente para ${what}: hacen falta unos {0:N0} MB libres y hay {1:N0} MB. Libera espacio e inténtalo de nuevo." -f ($need / 1MB), ($free / 1MB))
    }
  }

  # Antes de extraer: el archivo debe estar completo y ninguna ruta debe pasar el límite de
  # 260 caracteres de Windows (salvo que LongPathsEnabled esté activo). Así no queda una
  # extracción a medias. Devuelve la lista de entradas.
  function Test-Archive($archive, $destDir) {
    $names = @(& $Tar -tf $archive)
    if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0) {
      Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
      throw 'El archivo descargado está dañado o incompleto. Vuelve a ejecutar el script para descargarlo de nuevo.'
    }
    $longest = ($names | ForEach-Object { $_ -replace '^\./', '' } | Measure-Object -Property Length -Maximum).Maximum
    $total = $destDir.Length + 1 + $longest
    # SKL_TEST_NO_LONGPATHS=1: solo para pruebas (simula un Windows sin rutas largas activas).
    $longPaths = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1) -and -not $env:SKL_TEST_NO_LONGPATHS
    if ($total -ge 260 -and -not $longPaths) {
      throw ("Con tu nombre de usuario, la ruta más larga del paquete mediría $total caracteres y Windows solo admite 259. " +
             "No se extrajo el modpack. Activa las rutas largas de Windows (clave LongPathsEnabled=1 en " +
             "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem, requiere administrador y reiniciar) o usa otra cuenta de usuario.")
    }
    $names
  }

  function Write-Json($path, $obj) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 10), (New-Object Text.UTF8Encoding($false)))
    # [NullString]::Value: en PS 5.1 un $null suelto llega como "" y Replace falla.
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { Move-Item -LiteralPath $tmp -Destination $path }
  }

  function Choose($kind, $items, $want, $labelOf) {
    $items = @($items)
    if ($want) {
      $hit = $items | Where-Object { $_.id -eq $want } | Select-Object -First 1
      if (-not $hit) { throw "$kind '$want' no existe. Disponibles: $(($items | ForEach-Object { $_.id }) -join ', ')" }
      return $hit
    }
    if ($items.Count -eq 1) { return $items[0] }
    for ($try = 0; $try -lt 5; $try++) {
      Write-Host ''
      Write-Host "¿Qué $($kind.ToLower()) quieres instalar?"
      for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), (& $labelOf $items[$i])) }
      $line = Read-Host "Elige una opción [1-$($items.Count)]"
      if ($null -eq $line) { break }
      $n = 0
      if ([int]::TryParse($line.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { return $items[$n - 1] }
    }
    throw 'Instalación cancelada.'
  }

  # --- 1) Catálogo + elección de modpack/perfil ---
  New-Item -ItemType Directory -Force -Path $DlDir | Out-Null
  $CatalogFile = Join-Path $DlDir 'catalog.json'
  Info 'Descargando catálogo...'
  Get-Remote $CatalogUrl $CatalogFile
  $cat = Get-Content -Raw -Encoding UTF8 -LiteralPath $CatalogFile | ConvertFrom-Json

  $pack = Choose 'Modpack' $cat.modpacks $env:MODPACK { param($m) $m.name }
  $prof = Choose 'Perfil' $pack.profiles $env:PROFILE { param($p) if ($p.label) { $p.label } else { $p.id } }
  $label = if ($prof.label) { $prof.label } else { $prof.id }

  # Qué instancias hay ya instaladas (un state\<id>.json por instancia; los de instalaciones
  # anteriores a los perfiles no traen modpack/profile: el id es el modpack).
  $installed = @{}
  Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File | ForEach-Object {
    try { $d = Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } catch { return }
    $installed[$_.BaseName] = @{ modpack = $d.modpack; profile = $d.profile }
  }
  function Pack-Of($id) { if ($installed[$id].modpack) { $installed[$id].modpack } else { $id } }
  $ids = @($installed.Keys | Sort-Object)
  $same = @($ids | Where-Object { (Pack-Of $_) -eq $pack.id -and ($null -eq $installed[$_].profile -or $installed[$_].profile -eq $prof.id) })
  $hasPack = @($ids | Where-Object { (Pack-Of $_) -eq $pack.id })
  if ($same.Count -gt 0)    { $InstanceId = $same[0] }                        # mismo perfil: actualizar en sitio
  elseif ($hasPack.Count -gt 0) { $InstanceId = "$($pack.id)-$($prof.id)" }   # otro perfil ya instalado: instancia aparte
  else                      { $InstanceId = $pack.id }                        # primera instalación de este modpack
  $InstanceName = if ($InstanceId -eq $pack.id) { $pack.name } else { "$($pack.name) $label" }

  $MemoryMax = if ($env:MEMORY_MAX) { $env:MEMORY_MAX } else { [string]$pack.memoryMax }
  if ($MemoryMax -notmatch '^[0-9]+$') { throw "MEMORY_MAX debe ser un número en MB (recibí '$MemoryMax')." }
  $Launcher = $cat.launcher.windows
  if (-not $Launcher -or -not $Launcher.url) { throw 'El catálogo todavía no incluye el launcher de Windows.' }
  $InstanceType = if ($pack.type) { $pack.type } else { 'modpack' }
  $InstanceDir  = Join-Path $SklDir "instances\$InstanceId"    # SKLauncher ignora otro `directory`
  $LocalManifest = Join-Path $StateDir "$InstanceId.json"

  # Acceso directo en el Escritorio: opcional (pregunta solo en modo interactivo).
  $wantDesktop = $env:DESKTOP_SHORTCUT -eq '1'
  if (-not $env:DESKTOP_SHORTCUT -and -not $env:MODPACK) {
    $wantDesktop = (Read-Host '¿Crear también un acceso directo en el Escritorio? [s/N]') -match '^[sSyY]'
  }

  Ok "Instalando: $InstanceName"

  # --- 2) SKLauncher portable (global: una sola vez por máquina) ---
  $VerFile = Join-Path $StateDir 'launcher.version'
  $curVer = if (Test-Path -LiteralPath $VerFile) { (Get-Content -Raw -LiteralPath $VerFile).Trim() } else { '' }
  if ((Test-Path -LiteralPath (Join-Path $LauncherDir 'sklauncher.exe')) -and $curVer -eq $Launcher.version) {
    Ok "SKLauncher $($Launcher.version) ya está instalado."
  } else {
    $zipUrl = Join-Url $Launcher.url
    $zip = Join-Path $DlDir 'sk-portable.zip'
    $stage = "$LauncherDir.new"
    Info "Descargando SKLauncher $($Launcher.version)..."
    Assert-Space $zipUrl $LauncherDir 'SKLauncher'
    Get-Remote $zipUrl $zip -Big
    $null = Test-Archive $zip $stage
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Info 'Instalando SKLauncher...'
    & $Tar -xf $zip -C $stage
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo extraer SKLauncher (¿falta espacio en disco?). Vuelve a ejecutar el script para reintentar.' }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'sklauncher.exe'))) { throw 'El paquete del launcher no tiene la estructura esperada (falta sklauncher.exe en la raíz).' }
    # Reemplaza todo menos data\ (cuentas, instancias) y state\ (nuestro estado).
    Get-ChildItem -LiteralPath $LauncherDir -Force | Where-Object { $_.Name -ne 'data' -and $_.Name -ne 'state' } | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $stage -Force | Where-Object { $_.Name -ne 'data' -and $_.Name -ne 'state' } | Move-Item -Destination $LauncherDir -Force
    Remove-Item -LiteralPath $stage -Recurse -Force
    Remove-Item -LiteralPath $zip -Force
    [IO.File]::WriteAllText($VerFile, [string]$Launcher.version)
    Ok "SKLauncher instalado en $LauncherDir"
  }

  # --- 3) Accesos directos (apuntan al .bat, que redirige la carpeta de datos; NUNCA al .exe) ---
  function New-Shortcut($lnkPath) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lnkPath) | Out-Null
    $l = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $l.TargetPath = Join-Path $LauncherDir 'SKLauncher-Portable.bat'
    $l.WorkingDirectory = $LauncherDir
    $l.IconLocation = (Join-Path $LauncherDir 'sklauncher.exe') + ',0'
    $l.WindowStyle = 7          # minimizada: sin parpadeo de consola
    $l.Description = 'SKLauncher (portable)'
    $l.Save()
  }
  Info 'Creando acceso directo en el Menú Inicio...'
  # Nombre distinto al del launcher oficial ("SKlauncher.lnk"): Windows no distingue mayúsculas.
  New-Shortcut (Join-Path $StartMenu 'SKLauncher Portable.lnk')
  if ($wantDesktop) {
    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not $desk -or -not $desk.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
    New-Shortcut (Join-Path $desk 'SKLauncher Portable.lnk')
  }
  Ok 'SKLauncher ya aparece al buscar "SKLauncher" en el Menú Inicio.'

  # --- 4) Modpack: instalación completa (primera vez) o actualización incremental de mods ---

  # Guarda el manifest aplicado junto con a qué modpack/perfil pertenece esta instancia.
  function Save-State($manifestFile) {
    $d = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestFile | ConvertFrom-Json
    $d | Add-Member -NotePropertyName modpack -NotePropertyValue $pack.id -Force
    $d | Add-Member -NotePropertyName profile -NotePropertyValue $prof.id -Force
    Write-Json $LocalManifest $d
  }

  $ModsDir = Join-Path $InstanceDir 'mods'
  $already = (Test-Path -LiteralPath $LocalManifest) -and (Test-Path -LiteralPath $ModsDir) -and
             ($null -ne (Get-ChildItem -LiteralPath $ModsDir -Force | Select-Object -First 1))
  $ManifestUrl = Join-Url $prof.manifest
  $RemoteManifest = Join-Path $DlDir 'manifest.json'

  if ($already) {
    Info 'Instancia ya instalada. Comprobando mods nuevos o actualizados...'
    try {
      Get-Remote $ManifestUrl $RemoteManifest
      $remote = Get-Content -Raw -Encoding UTF8 -LiteralPath $RemoteManifest | ConvertFrom-Json
      $local  = Get-Content -Raw -Encoding UTF8 -LiteralPath $LocalManifest | ConvertFrom-Json
      $remoteMods = @{}; foreach ($p in $remote.mods.PSObject.Properties) { $remoteMods[$p.Name] = $p.Value.sha256 }
      $localMods  = @{}; foreach ($p in $local.mods.PSObject.Properties)  { $localMods[$p.Name]  = $p.Value.sha256 }
      $toFetch  = @($remoteMods.Keys | Where-Object { -not $localMods.ContainsKey($_) -or $localMods[$_] -ne $remoteMods[$_] -or
                                                       -not (Test-Path -LiteralPath (Join-Path $ModsDir $_)) } | Sort-Object)
      $toRemove = @($localMods.Keys | Where-Object { -not $remoteMods.ContainsKey($_) } | Sort-Object)
      if ($toFetch.Count -eq 0 -and $toRemove.Count -eq 0) {
        Write-Host 'Mods al día, nada que hacer.'
      } else {
        Write-Host "$($toFetch.Count) mod(s) nuevo(s)/actualizado(s), $($toRemove.Count) para quitar:"
        $modBase = (Join-Url ($pack.prefix + '/mods')).TrimEnd('/')
        foreach ($name in $toFetch) {
          Write-Host "  + $name"
          $tmp = Join-Path $DlDir "mod.$name"
          Get-Remote ($modBase + '/' + [Uri]::EscapeDataString($name)) $tmp
          $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
          if ($hash -ne $remoteMods[$name]) {
            Remove-Item -LiteralPath $tmp -Force
            throw "El mod $name se descargó dañado (el hash no coincide)."
          }
          Move-Item -LiteralPath $tmp -Destination (Join-Path $ModsDir $name) -Force
        }
        foreach ($name in $toRemove) {
          $f = Join-Path $ModsDir $name
          if (Test-Path -LiteralPath $f) { Write-Host "  - $name"; Remove-Item -LiteralPath $f -Force }
        }
      }
      Save-State $RemoteManifest
      Ok 'Mods al día.'
    } catch {
      Warn "Falló la actualización de mods (quedaron como estaban): $($_.Exception.Message)"
      Warn 'Puedes reintentar corriendo el script de nuevo.'
    }
  } else {
    $tarUrl = Join-Url $prof.tar
    $tarFile = Join-Path $DlDir "$InstanceId.tar.gz"
    Info "Descargando modpack ($InstanceName)... puede tardar según tu conexión."
    Assert-Space $tarUrl $InstanceDir 'el modpack'
    Get-Remote $tarUrl $tarFile -Big
    $names = @(Test-Archive $tarFile $InstanceDir)
    New-Item -ItemType Directory -Force -Path $InstanceDir | Out-Null
    # Si el paquete trae archivos personales que el jugador ya tiene, no se pisan.
    $skip = @()
    foreach ($f in 'options.txt', 'optionsof.txt', 'optionsshaders.txt', 'servers.dat', 'servers.dat_old') {
      if ((Test-Path -LiteralPath (Join-Path $InstanceDir $f)) -and ($names -contains "./$f" -or $names -contains $f)) { $skip += ('--exclude=^' + $f + '$') }   # ^...$ ancla: sin eso bsdtar también excluiría config\...\options.txt
    }
    Info "Instalando en $InstanceDir ..."
    & $Tar -xf $tarFile -C $InstanceDir @skip
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo extraer el modpack (¿falta espacio en disco?). Vuelve a ejecutar el script para reintentar.' }
    Remove-Item -LiteralPath $tarFile -Force
    Ok 'Modpack instalado (si ya jugabas antes, tus partidas guardadas no se tocaron).'
    try {
      Get-Remote $ManifestUrl $RemoteManifest
      Save-State $RemoteManifest
      Ok 'Estado guardado: la próxima vez solo se van a bajar los mods que cambien.'
    } catch {
      Warn 'No se pudo guardar el estado inicial; la próxima corrida hará una instalación completa de nuevo.'
    }
  }

  # --- 5) Registrar la instancia en instances.json ---
  Info 'Registrando la instancia en SKLauncher...'
  New-Item -ItemType Directory -Force -Path $SklDir | Out-Null
  if (Test-Path -LiteralPath $InstancesJson) {
    try { $data = Get-Content -Raw -Encoding UTF8 -LiteralPath $InstancesJson | ConvertFrom-Json }
    catch { throw "No se pudo leer $InstancesJson (¿archivo dañado?). No se modificó." }
  } else {
    $data = [pscustomobject]@{ instances = @() }
  }
  if (-not $data.PSObject.Properties['instances']) { $data | Add-Member -NotePropertyName instances -NotePropertyValue @() }

  $new = [ordered]@{
    id = $InstanceId; name = $InstanceName; type = $InstanceType; installComplete = $true
    versionId = $pack.versionId; gameType = $pack.loader; minecraftVersion = $pack.minecraft
    loaderVersion = $pack.loaderVersion; directory = $InstanceDir; memoryMax = [int]$MemoryMax
  }
  if ($pack.icon) { $new['icon'] = $pack.icon }

  $old = @($data.instances | Where-Object { $_.id -eq $InstanceId }) | Select-Object -First 1
  if ($old) {
    # Conserva lo que el usuario ya cambió o generó (nombre, memoria, tiempo jugado...).
    foreach ($k in $new.Keys) {
      $has = $null -ne $old.PSObject.Properties[$k]
      if ($has -and ($k -eq 'name' -or $k -eq 'memoryMax')) { continue }
      if ($has) { $old.$k = $new[$k] } else { $old | Add-Member -NotePropertyName $k -NotePropertyValue $new[$k] }
    }
  } else {
    # Sin playTime el launcher escribe null tras la primera sesión.
    $new['playTime'] = 0; $new['sessionCount'] = 0; $new['customLaunchHooks'] = $false
    $new['createdAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z')
    $data.instances = @($data.instances) + [pscustomobject]$new
  }
  if (Test-Path -LiteralPath $InstancesJson) { Copy-Item -LiteralPath $InstancesJson -Destination "$InstancesJson.bak.pre-install" -Force }
  Write-Json $InstancesJson $data
  Ok "Instancia `"$InstanceName`" registrada."

  Remove-Item -LiteralPath $DlDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host ''
  Ok '¡Listo! Busca "SKLauncher" en el Menú Inicio, inicia sesión y'
  Ok "selecciona la instancia `"$InstanceName`"."
  Warn 'La primera vez que la juegues, SKLauncher descarga Minecraft, NeoForge y Java (~1,1 GB): necesitas internet y espacio libre.'
}
} catch {
  Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
  if ($PSCommandPath) { exit 1 }     # como archivo: código de salida 1; bajo `irm | iex` no cierra tu terminal
}
