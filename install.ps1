# Instalador de SKLauncher + modpacks para Windows (uso: irm https://minecraft-data.alvaroavila.dev/install.ps1 | iex).
# Se sirve con "Content-Type: text/plain; charset=utf-8" o `irm` rompe los acentos (lo hace scripts/publish.py site).

try {
& {
  $ErrorActionPreference = 'Stop'          # solo dentro de este bloque: no cambia la sesión del usuario
  $ProgressPreference = 'SilentlyContinue'
  $CatalogUrl = if ($env:CATALOG_URL) { $env:CATALOG_URL } else { 'https://minecraft-data.alvaroavila.dev/catalog.json' }
  $Personal = 'options.txt', 'optionsof.txt', 'optionsshaders.txt', 'servers.dat', 'servers.dat_old'

  function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
  function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
  function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

  if ($env:OS -ne 'Windows_NT') { throw 'Este instalador solo funciona en Windows (en Linux usa install.sh).' }
  if (-not [Environment]::Is64BitOperatingSystem) { throw 'SKLauncher necesita un Windows de 64 bits.' }
  if (-not $env:LOCALAPPDATA -or -not $env:APPDATA -or -not $env:USERPROFILE) { throw 'No se encontraron las carpetas del usuario (LOCALAPPDATA/APPDATA/USERPROFILE).' }
  # Por ruta absoluta: `tar.exe` a secas puede resolver al GNU tar de Git, que no lee .zip.
  $Tar  = Join-Path $env:SystemRoot 'System32\tar.exe'
  $Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  foreach ($exe in $Tar, $Curl) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Falta $exe. Necesitas Windows 10 (1803 o posterior) o Windows 11." }
  }

  # Con el SKLauncher oficial instalado, la instancia va a ese; si no, se usa (o instala) el portable.
  $OfficialExe = Join-Path $env:LOCALAPPDATA 'Programs\sklauncher\sklauncher.exe'
  $UseOfficial = Test-Path -LiteralPath $OfficialExe
  if ($UseOfficial) {
    $LauncherDir = Split-Path -Parent $OfficialExe
    $SklDir      = Join-Path $env:APPDATA '.sklauncher'
    $StateDir    = Join-Path $SklDir 'mine-script-state'
  } else {
    $LauncherDir = Join-Path $env:LOCALAPPDATA 'Programs\SKLauncher-Portable'
    $SklDir      = Join-Path $LauncherDir 'data\.sklauncher'
    $StateDir    = Join-Path $LauncherDir 'state'
  }
  $DlDir         = Join-Path $StateDir 'dl'   # descargas en curso (las grandes se reanudan)
  $InstancesJson = Join-Path $SklDir 'instances.json'
  $StartMenu     = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

  # Con SKLauncher abierto, reescribe instances.json y se pierde el registro (solo cuenta el de $LauncherDir).
  $running = @(Get-CimInstance Win32_Process -Filter "Name='sklauncher.exe'" | Where-Object {
      $_.ExecutablePath -and $_.ExecutablePath.StartsWith($LauncherDir + '\', [StringComparison]::OrdinalIgnoreCase) })
  if ($running.Count -gt 0) {
    throw ('SKLauncher está abierto. Ciérralo (también desde el ícono de la bandeja del sistema, ' +
           'junto al reloj: clic derecho > salir) y vuelve a ejecutar el script. No se cambió nada.')
  }

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

  function Get-Json($url) {
    $f = Join-Path $DlDir 'download.json'
    Get-Remote $url $f
    Get-Content -Raw -Encoding UTF8 -LiteralPath $f | ConvertFrom-Json
  }

  function Get-Sha256($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

  function Get-RemoteSize($url) {
    $h = & $Curl -sIL --max-time 30 $url
    $m = @($h | Select-String -Pattern '^Content-Length:\s*(\d+)') | Select-Object -Last 1
    if ($m) { [int64]$m.Matches[0].Groups[1].Value } else { 0 }
  }

  # Falla con un mensaje claro si no caben $bytes en el disco de $where.
  function Assert-Space($bytes, $where, $what) {
    $need = $bytes + 100MB
    try { $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($where))).AvailableFreeSpace } catch { return }
    if ($free -lt $need) {
      throw ("No hay espacio suficiente para ${what}: hacen falta unos {0:N0} MB libres y hay {1:N0} MB. Libera espacio e inténtalo de nuevo." -f ($need / 1MB), ($free / 1MB))
    }
  }

  # Sin LongPathsEnabled, Windows no admite rutas de 260 caracteres o más: se comprueba antes de escribir nada.
  function Assert-PathLength($destDir, $names) {
    $longest = ($names | ForEach-Object { $_ -replace '^\./', '' } | Measure-Object -Property Length -Maximum).Maximum
    $total = $destDir.Length + 1 + $longest
    # SKL_TEST_NO_LONGPATHS=1: solo para pruebas (simula un Windows sin rutas largas activas).
    $longPaths = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1) -and -not $env:SKL_TEST_NO_LONGPATHS
    if ($total -ge 260 -and -not $longPaths) {
      throw ("Con tu nombre de usuario, la ruta más larga del modpack mediría $total caracteres y Windows solo admite 259. " +
             "No se instaló nada. Activa las rutas largas de Windows (clave LongPathsEnabled=1 en " +
             "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem, requiere administrador y reiniciar) o usa otra cuenta de usuario.")
    }
  }

  # Devuelve las entradas del archivo; si está dañado lo borra para que la próxima corrida lo baje de nuevo.
  function Get-ArchiveEntries($archive) {
    $names = @(& $Tar -tf $archive)
    if ($LASTEXITCODE -ne 0 -or $names.Count -eq 0) {
      Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
      throw 'El archivo descargado está dañado o incompleto. Vuelve a ejecutar el script para descargarlo de nuevo.'
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

  # Nunca pisa los archivos personales que el jugador ya tiene (opciones, servidores).
  function Expand-Config($zipFile, $skip) {
    $zip = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try {
      $entries = @($zip.Entries | Where-Object { $_.Name })   # sin las entradas de carpeta
      Assert-PathLength $InstanceDir @($entries | ForEach-Object { $_.FullName })
      foreach ($e in $entries) {
        $dest = Join-Path $InstanceDir ($e.FullName -replace '/', '\')
        if ($skip -contains $e.FullName -or ($e.FullName -split '/') -contains '..') { continue }
        if ($Personal -contains $e.FullName -and (Test-Path -LiteralPath $dest)) { continue }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
      }
    } finally { $zip.Dispose() }
  }

  function Get-Verified($rel, $meta) {
    $f = Join-Path $DlDir (Split-Path -Leaf $rel)
    Get-Remote ($PackUrl + $rel) $f -Big
    if ((Get-Sha256 $f) -ne $meta.sha256) { Remove-Item -LiteralPath $f -Force; throw 'La configuración se descargó dañada. Vuelve a ejecutar el script.' }
    $f
  }

  function Get-Map($obj) { $h = @{}; if ($obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }; $h }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  New-Item -ItemType Directory -Force -Path $DlDir | Out-Null
  Info 'Descargando catálogo...'
  $cat = Get-Json $CatalogUrl

  $pack = Choose 'Modpack' $cat.modpacks $env:MODPACK { param($m) $m.name }
  $prof = Choose 'Perfil' $pack.profiles $env:PROFILE { param($p) if ($p.label) { $p.label } else { $p.id } }
  $label = if ($prof.label) { $prof.label } else { $prof.id }
  $isStandard = $prof.id -eq @($pack.profiles)[0].id

  # Un state\<id>.json por instancia; los de versiones viejas no traen modpack/profile (el id es el modpack).
  $installed = @{}
  Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File | ForEach-Object {
    try { $d = Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json } catch { return }
    $installed[$_.BaseName] = @{ modpack = $(if ($d.modpack) { $d.modpack } else { $_.BaseName }); profile = $d.profile }
  }
  $ids = @($installed.Keys | Sort-Object)
  $same = @($ids | Where-Object { $installed[$_].modpack -eq $pack.id -and ($null -eq $installed[$_].profile -or $installed[$_].profile -eq $prof.id) })
  $hasPack = @($ids | Where-Object { $installed[$_].modpack -eq $pack.id })
  if ($same.Count -gt 0)        { $InstanceId = $same[0] }
  elseif ($hasPack.Count -gt 0) { $InstanceId = "$($pack.id)-$($prof.id)" }   # otro perfil del mismo modpack: instancia aparte
  else                          { $InstanceId = $pack.id }
  $InstanceName = if ($InstanceId -eq $pack.id) { $pack.name } else { "$($pack.name) $label" }

  $MemoryMax = if ($env:MEMORY_MAX) { $env:MEMORY_MAX } else { [string]$pack.memoryMax }
  if ($MemoryMax -notmatch '^[0-9]+$') { throw "MEMORY_MAX debe ser un número en MB (se recibió '$MemoryMax')." }
  $Launcher = $cat.launcher.windows
  $InstanceType = if ($pack.type) { $pack.type } else { 'modpack' }
  $InstanceDir  = Join-Path $SklDir "instances\$InstanceId"    # SKLauncher ignora otro `directory`
  $StateFile    = Join-Path $StateDir "$InstanceId.json"
  $ModsDir      = Join-Path $InstanceDir 'mods'
  $PackUrl      = Join-Url ($pack.prefix + '/')

  $wantDesktop = $env:DESKTOP_SHORTCUT -eq '1'
  if (-not $UseOfficial -and -not $env:DESKTOP_SHORTCUT -and -not $env:MODPACK) {
    $wantDesktop = (Read-Host '¿Crear también un acceso directo en el Escritorio? [s/N]') -match '^[sSyY]'
  }

  Ok "Instalando: $InstanceName"
  Info "Carpeta de la instancia: $InstanceDir"

  if ($UseOfficial) {
    Ok "Se usa el SKLauncher que ya tienes instalado ($LauncherDir): solo se agrega la instancia."
  } else {
    $VerFile = Join-Path $StateDir 'launcher.version'
    $curVer = if (Test-Path -LiteralPath $VerFile) { (Get-Content -Raw -LiteralPath $VerFile).Trim() } else { '' }
    if ((Test-Path -LiteralPath (Join-Path $LauncherDir 'sklauncher.exe')) -and $curVer -eq $Launcher.version) {
      Ok "SKLauncher $($Launcher.version) ya está instalado."
    } else {
      $zipUrl = Join-Url $Launcher.url
      $zip = Join-Path $DlDir 'sk-portable.zip'
      $stage = "$LauncherDir.new"
      Info "Descargando SKLauncher $($Launcher.version)..."
      Assert-Space (2 * (Get-RemoteSize $zipUrl)) $LauncherDir 'SKLauncher'
      Get-Remote $zipUrl $zip -Big
      Assert-PathLength $stage (Get-ArchiveEntries $zip)
      if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $stage | Out-Null
      Info 'Instalando SKLauncher...'
      & $Tar -xf $zip -C $stage
      if ($LASTEXITCODE -ne 0) { throw 'No se pudo extraer SKLauncher (¿falta espacio en disco?). Vuelve a ejecutar el script para reintentar.' }
      if (-not (Test-Path -LiteralPath (Join-Path $stage 'sklauncher.exe'))) { throw 'El paquete del launcher no tiene la estructura esperada (falta sklauncher.exe en la raíz).' }
      # Reemplaza todo menos data\ (cuentas, instancias) y state\ (el estado de este instalador).
      Get-ChildItem -LiteralPath $LauncherDir -Force | Where-Object { $_.Name -ne 'data' -and $_.Name -ne 'state' } | Remove-Item -Recurse -Force
      Get-ChildItem -LiteralPath $stage -Force | Where-Object { $_.Name -ne 'data' -and $_.Name -ne 'state' } | Move-Item -Destination $LauncherDir -Force
      Remove-Item -LiteralPath $stage -Recurse -Force
      Remove-Item -LiteralPath $zip -Force
      [IO.File]::WriteAllText($VerFile, [string]$Launcher.version)
      Ok "SKLauncher instalado en $LauncherDir"
    }

    # Los accesos directos apuntan al .bat (redirige la carpeta de datos), nunca al .exe.
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
    # Nombre distinto al del launcher oficial ("SKlauncher.lnk"): Windows no distingue mayúsculas.
    New-Shortcut (Join-Path $StartMenu 'SKLauncher Portable.lnk')
    if ($wantDesktop) {
      $desk = [Environment]::GetFolderPath('Desktop')
      if (-not $desk -or -not $desk.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
      New-Shortcut (Join-Path $desk 'SKLauncher Portable.lnk')
    }
    Ok 'SKLauncher aparece al buscar "SKLauncher" en el Menú Inicio.'
  }

  # Mismo proceso para instalar y actualizar: base (config, kubejs...) si cambió y luego mods\ igual al perfil.
  $manifest = Get-Json ($PackUrl + 'manifest.json')
  $variant = if ($isStandard) { $null } else { Get-Json ($PackUrl + "profiles/$($prof.id).json") }
  $exclude = @(if ($variant) { $variant.exclude })
  $target = Get-Map $manifest.mods
  if ($variant) { (Get-Map $variant.include).GetEnumerator() | ForEach-Object { $target[$_.Key] = $_.Value } }
  foreach ($n in $exclude) { $target.Remove($n) }
  $state = $null
  if (Test-Path -LiteralPath $StateFile) { try { $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $StateFile | ConvertFrom-Json } catch { } }
  $known = Get-Map $state.mods
  $config = if ($variant -and $variant.config) { $variant.config } else { $null }
  $needBase = -not (Test-Path -LiteralPath $ModsDir) -or $state.base -ne $manifest.base.sha256 -or $state.config -ne $config.sha256

  $toFetch = @($target.Keys | Where-Object {
      $f = Join-Path $ModsDir $_
      -not (Test-Path -LiteralPath $f) -or $(if ($known[$_]) { $known[$_].sha256 } else { Get-Sha256 $f }) -ne $target[$_].sha256 } | Sort-Object)
  $toRemove = @(@($known.Keys | Where-Object { -not $target.ContainsKey($_) }) + $exclude | Sort-Object -Unique |
      Where-Object { Test-Path -LiteralPath (Join-Path $ModsDir $_) })
  $fetchBytes = [int64]0; foreach ($n in $toFetch) { $fetchBytes += $target[$n].size }
  Assert-Space ($fetchBytes + $(if ($needBase) { 2 * ($manifest.base.size + $config.size) } else { 0 })) $InstanceDir 'el modpack'
  Assert-PathLength $ModsDir @($target.Keys)

  if ($needBase) {
    Info 'Descargando la configuración del modpack...'
    Expand-Config (Get-Verified 'base.zip' $manifest.base) @(if ($variant) { $variant.skip })
    if ($config) { Expand-Config (Get-Verified "profiles/$($prof.id).zip" $config) @() }
    Ok 'Configuración al día (tus partidas y opciones no se tocaron).'
  }
  New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null

  if ($toFetch.Count -gt 0) {
    Info ('Descargando {0} mod(s) ({1:N0} MB)...' -f $toFetch.Count, ($fetchBytes / 1MB))
    $staging = Join-Path $DlDir 'mods'
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    # Un solo curl para todos (reutiliza la conexión); rutas relativas para no depender del nombre de usuario.
    $curlConfig = foreach ($n in $toFetch) { "url = `"$($PackUrl)mods/$([Uri]::EscapeDataString($n))`""; "output = `"mods/$n`"" }
    [IO.File]::WriteAllLines((Join-Path $DlDir 'mods.cfg'), [string[]]$curlConfig)
    $parallel = if ((& $Curl --help all) -match '--parallel') { @('--parallel', '--parallel-max', '8') } else { @() }
    Push-Location -LiteralPath $DlDir
    try { & $Curl -fsSL --retry 3 --connect-timeout 30 @parallel -K mods.cfg } finally { Pop-Location }
    foreach ($n in $toFetch) {
      $f = Join-Path $staging $n
      if (-not (Test-Path -LiteralPath $f) -or (Get-Sha256 $f) -ne $target[$n].sha256) { throw "El mod $n no se descargó bien. Vuelve a ejecutar el script." }
    }
    foreach ($n in $toFetch) {
      if ($known.Count -gt 0) { Write-Host "  + $n" }
      Move-Item -LiteralPath (Join-Path $staging $n) -Destination (Join-Path $ModsDir $n) -Force
    }
  }
  foreach ($n in $toRemove) { Write-Host "  - $n"; Remove-Item -LiteralPath (Join-Path $ModsDir $n) -Force }

  # Doble verificación: ningún mod excluido queda y todos los del perfil están.
  $leftover = @($exclude | Where-Object { Test-Path -LiteralPath (Join-Path $ModsDir $_) })
  $missing = @($target.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ModsDir $_)) })
  if ($leftover.Count -or $missing.Count) { throw "La carpeta mods quedó incorrecta. Sobran: $($leftover -join ', '). Faltan: $($missing -join ', ')." }
  if ($toFetch.Count -eq 0 -and $toRemove.Count -eq 0) { Ok 'Mods al día, nada que hacer.' }
  Write-Json $StateFile ([ordered]@{ modpack = $pack.id; profile = $prof.id; base = $manifest.base.sha256; config = $config.sha256; mods = $target })

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
    # Conserva lo que el jugador cambió (nombre, memoria) y lo que generó el launcher (tiempo jugado...).
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
  Ok "¡Listo! Busca `"SKLauncher`" en el Menú Inicio, inicia sesión y elige la instancia `"$InstanceName`"."
  Ok "Instalada en: $InstanceDir"
  Warn 'La primera vez que la juegues, SKLauncher descarga Minecraft, NeoForge y Java (~1,1 GB): necesitas internet y espacio libre.'
}
} catch {
  Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
  if ($PSCommandPath) { exit 1 }     # como archivo: código de salida 1; bajo `irm | iex` no cierra la terminal
}
