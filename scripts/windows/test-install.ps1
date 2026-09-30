# Pruebas de install.ps1 contra un R2 falso local, con un usuario de prueba aislado (uso: .\scripts\windows\test-install.ps1 [-Work D:\mct]).
param([string]$Work = 'C:\mct', [int]$Port = 8099)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Log = Join-Path $Work 'requests.log'
$Url = "http://localhost:$Port/catalog.json"
$script:fails = 0
$script:srv = $null

function Check($ok, $msg) {
  if ($ok) { Write-Host "    PASS  $msg" -ForegroundColor Green } else { Write-Host "    FAIL  $msg" -ForegroundColor Red; $script:fails++ }
}
function Section($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

function Stop-Srv { if ($script:srv -and -not $script:srv.HasExited) { Stop-Process -Id $script:srv.Id -Force }; $script:srv = $null }
function Start-Srv($extra = @()) {
  Stop-Srv
  $a = @('-NoProfile', '-File', "$Repo\scripts\windows\serve-test.ps1", '-Root', "$Work\r2", '-Port', $Port, '-LogFile', $Log) + $extra
  $script:srv = Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 20; $i++) {
    try { $null = Invoke-WebRequest -UseBasicParsing -Method Head $Url; return } catch { Start-Sleep -Milliseconds 300 }
  }
  throw 'El servidor de prueba no arrancó.'
}
function Log-Count { if (Test-Path $Log) { @(Get-Content $Log).Count } else { 0 } }
function Log-Since($n) { if (Test-Path $Log) { @(Get-Content $Log | Select-Object -Skip $n) } else { @() } }

# Corre install.ps1 (copia con BOM, para `-File`) como un usuario de prueba aislado.
function Install($base, $vars = @{}, $stdin = $null) {
  New-Item -ItemType Directory -Force -Path "$base\Local", "$base\Roaming" | Out-Null
  $env = @{ LOCALAPPDATA = "$base\Local"; APPDATA = "$base\Roaming"; USERPROFILE = $base; CATALOG_URL = $Url
            MODPACK = $null; PROFILE = $null; MEMORY_MAX = $null; DESKTOP_SHORTCUT = $null; SKL_TEST_NO_LONGPATHS = $null; SKL_INSTANCES_DIR = $null }
  foreach ($k in $vars.Keys) { $env[$k] = $vars[$k] }
  $saved = @{}
  foreach ($k in $env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $env[$k], 'Process') }
  try {
    $ErrorActionPreference = 'Continue'
    $ps = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$Work\install-bom.ps1")
    $out = if ($null -ne $stdin) { $stdin | & powershell.exe @ps 2>&1 | Out-String } else { & powershell.exe @ps 2>&1 | Out-String }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = 'Stop'
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
  [pscustomobject]@{ Code = $code; Out = $out; Base = $base; L = "$base\Local\Programs\SKLauncher-Portable"; Inst = "$base\Local\Programs\SKLauncher-Portable\data\.sklauncher\instances" }
}
function Instances($r) { @((Get-Content -Raw -Encoding UTF8 "$($r.L)\data\.sklauncher\instances.json" | ConvertFrom-Json).instances) }
function Lnk($r) { Join-Path $r.Base 'Roaming\Microsoft\Windows\Start Menu\Programs\SKLauncher Portable.lnk' }
function Mods($r, $id) { @(Get-ChildItem "$($r.Inst)\$id\mods" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

# --- preparación ---
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work | Out-Null
& "$Repo\scripts\windows\make-test-layout.ps1" -Out "$Work\r2" -LongEntry | Out-Null
$src = Get-Content -Raw -Encoding UTF8 "$Repo\install.ps1"
[IO.File]::WriteAllText("$Work\install-bom.ps1", $src, (New-Object Text.UTF8Encoding($true)))
Copy-Item "$Repo\install.ps1" "$Work\r2\install.ps1"     # tal cual (sin BOM), para `irm | iex`
Start-Srv

try {
  Section '1. Instalación limpia (fakepack / Gama Baja, con variables)'
  $t1 = Install "$Work\t1" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t1.Code -eq 0) "termina sin error (código $($t1.Code))"
  Check (Test-Path "$($t1.L)\sklauncher.exe") 'launcher instalado en Programs\SKLauncher-Portable'
  Check (-not (Test-Path "$($t1.L)\data\*.zip")) 'no se dejó el zip en data\'
  Check (Test-Path (Lnk $t1)) 'acceso directo "SKLauncher Portable.lnk" creado'
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Lnk $t1))
  Check ($sc.TargetPath -eq "$($t1.L)\SKLauncher-Portable.bat" -and $sc.WindowStyle -eq 7) 'el .lnk apunta al .bat con estilo 7 (minimizado)'
  Check ((Mods $t1 'fakepack').Count -eq 3) 'la instancia tiene los 3 mods de la gama baja'
  Check ((Test-Path "$($t1.Inst)\fakepack\config\low.toml") -and -not (Test-Path "$($t1.Inst)\fakepack\resourcepacks\pack.zip")) 'low trae su configuración propia y no el archivo que salta'
  $i1 = @(Instances $t1)
  Check ($i1.Count -eq 1 -and $i1[0].id -eq 'fakepack' -and $i1[0].name -eq 'FakePack' -and $i1[0].type -eq 'custom') 'instances.json: una instancia "FakePack" (custom)'
  Check ($i1[0].playTime -eq 0 -and $i1[0].sessionCount -eq 0 -and $i1[0].customLaunchHooks -eq $false -and $i1[0].memoryMax -eq 6144) 'campos nuevos: playTime/sessionCount 0, customLaunchHooks false, memoryMax 6144'
  Check ($i1[0].directory -eq "$($t1.Inst)\fakepack") 'directory = ruta absoluta bajo data\.sklauncher\instances'
  Check ([IO.File]::ReadAllBytes("$($t1.L)\data\.sklauncher\instances.json")[0] -eq 123) 'instances.json sin BOM'
  $st = Get-Content -Raw "$($t1.L)\state\fakepack.json" | ConvertFrom-Json
  Check ($st.modpack -eq 'fakepack' -and $st.profile -eq 'low') 'estado por instancia con modpack/profile'
  Check (-not (Test-Path "$($t1.L)\state\dl")) 'sin restos de descargas'

  Section '2. Mismo perfil otra vez: no duplica nada, conserva datos del jugador y cambios del launcher'
  New-Item -ItemType Directory -Force "$($t1.Inst)\fakepack\saves\prueba" | Out-Null
  Set-Content "$($t1.Inst)\fakepack\saves\prueba\level.dat" 'partida'
  Set-Content "$($t1.Inst)\fakepack\options.txt" 'MARCA-DEL-JUGADOR'
  $j = Get-Content -Raw "$($t1.L)\data\.sklauncher\instances.json" | ConvertFrom-Json
  $j.instances[0].name = 'Mi nombre'; $j.instances[0].playTime = 123; $j.instances[0].memoryMax = 9999
  [IO.File]::WriteAllText("$($t1.L)\data\.sklauncher\instances.json", (ConvertTo-Json -InputObject $j -Depth 10), (New-Object Text.UTF8Encoding($false)))
  $n = Log-Count
  $t2 = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  $req = Log-Since $n
  Check ($t2.Code -eq 0) 'termina sin error'
  Check (@(Get-ChildItem $t1.Inst -Directory).Count -eq 1) 'sigue habiendo una sola carpeta de instancia'
  $i2 = @(Instances $t2)
  Check ($i2.Count -eq 1) 'sigue habiendo una sola instancia registrada'
  Check ($i2[0].name -eq 'Mi nombre' -and $i2[0].playTime -eq 123 -and $i2[0].memoryMax -eq 9999) 'se conservan name, playTime y memoryMax del usuario'
  Check ((Get-Content "$($t1.Inst)\fakepack\saves\prueba\level.dat") -eq 'partida') 'saves\prueba intacto'
  Check ((Get-Content "$($t1.Inst)\fakepack\options.txt") -eq 'MARCA-DEL-JUGADOR') 'options.txt intacto'
  Check (-not ($req -match 'sk-portable.zip|base.zip|/mods/')) 'no volvió a bajar el launcher, la configuración ni los mods'
  Check ($t2.Out -match 'ya está instalado' -and $t2.Out -match 'al día') 'avisa que el launcher y los mods ya están al día'
  Check (Test-Path "$($t1.L)\data\.sklauncher\instances.json.bak.pre-install") 'dejó copia .bak.pre-install'

  Section '2b. Reinstalación sin estado (se perdió state\): el paquete no pisa options.txt del jugador'
  $r = Install "$Work\t2b" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Set-Content "$($r.Inst)\fakepack\options.txt" 'MARCA-DEL-JUGADOR'
  Set-Content "$($r.Inst)\fakepack\config\sub\options.txt" 'VIEJO'
  Remove-Item -LiteralPath "$($r.L)\state\fakepack.json" -Force
  $r2 = Install "$Work\t2b" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($r2.Code -eq 0 -and (Mods $r2 'fakepack').Count -eq 3) 'reinstala sin error y los mods siguen'
  Check ((Get-Content "$($r.Inst)\fakepack\options.txt") -eq 'MARCA-DEL-JUGADOR') 'options.txt del jugador no se pisó'
  Check ((Get-Content "$($r.Inst)\fakepack\config\sub\options.txt") -eq 'VIEJO') 'la config que el jugador ya tenía no se pisó'
  Check (@(Instances $r2).Count -eq 1) 'sigue habiendo una sola instancia'

  Section '2c. Estado antiguo (sin modpack/profile): se reutiliza la instancia, no se crea otra'
  $r = Install "$Work\t2c" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  $stf = "$($r.L)\state\fakepack.json"
  $o = Get-Content -Raw $stf | ConvertFrom-Json
  $o.PSObject.Properties.Remove('modpack'); $o.PSObject.Properties.Remove('profile')
  [IO.File]::WriteAllText($stf, (ConvertTo-Json -InputObject $o -Depth 8), (New-Object Text.UTF8Encoding($false)))
  $r2 = Install "$Work\t2c" @{ MODPACK = 'fakepack'; PROFILE = 'high' }
  Check ($r2.Code -eq 0 -and @(Instances $r2).Count -eq 1 -and @(Instances $r2)[0].id -eq 'fakepack') 'con el estado antiguo actualiza "fakepack" en sitio (no crea fakepack-high)'
  Check ((Mods $r2 'fakepack').Count -eq 5) 'la instancia recibió los mods de la gama alta por actualización incremental'
  $o2 = Get-Content -Raw $stf | ConvertFrom-Json
  Check ($o2.modpack -eq 'fakepack' -and $o2.profile -eq 'high') 'el estado ya trae modpack/profile'

  Section '3. Otro perfil del mismo modpack: instancia aparte, la primera intacta'
  $shaState = Sha "$($t1.L)\state\fakepack.json"
  $t3 = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'high' }
  Check ($t3.Code -eq 0) "termina sin error (la ruta más larga del perfil alto pasa el límite)"
  $i3 = @(Instances $t3)
  Check ($i3.Count -eq 2) 'ahora hay dos instancias'
  $hi = $i3 | Where-Object id -eq 'fakepack-high'
  Check ($hi -and $hi.name -eq 'FakePack Gama Alta') 'la segunda es "FakePack Gama Alta" / fakepack-high'
  Check ((Mods $t3 'fakepack-high').Count -eq 5) 'la segunda tiene los 5 mods de la gama alta'
  Check ((Mods $t3 'fakepack').Count -eq 3 -and (Sha "$($t1.L)\state\fakepack.json") -eq $shaState) 'la primera no cambió (mods ni estado)'
  Check (($i3 | Where-Object id -eq 'fakepack').name -eq 'Mi nombre') 'la primera conserva su nombre'
  Check ((Get-Content "$($t1.Inst)\fakepack\options.txt") -eq 'MARCA-DEL-JUGADOR') 'options.txt de la primera intacto'

  Section '4. Actualización incremental: solo se baja el mod que cambió'
  $m = Get-Content -Raw "$Work\r2\fakepack\manifest.json" | ConvertFrom-Json
  $nb = New-Object byte[] 1500000; (New-Object Random).NextBytes($nb)
  [IO.File]::WriteAllBytes("$Work\r2\fakepack\mods\alpha-1.0.jar", $nb)             # alpha cambia
  [IO.File]::WriteAllBytes("$Work\r2\fakepack\mods\zeta nuevo+1.0.jar", $nb)        # zeta se agrega (con espacio y "+")
  $m.mods.PSObject.Properties.Remove('gamma-1.0.jar')                                # gamma se quita
  $hash = (Get-FileHash "$Work\r2\fakepack\mods\alpha-1.0.jar" -Algorithm SHA256).Hash.ToLower()
  $m.mods.'alpha-1.0.jar'.sha256 = $hash
  $m.mods | Add-Member -NotePropertyName 'zeta nuevo+1.0.jar' -NotePropertyValue ([pscustomobject]@{ sha256 = $hash; size = 1500000 })
  [IO.File]::WriteAllText("$Work\r2\fakepack\manifest.json", (ConvertTo-Json -InputObject $m -Depth 6), (New-Object Text.UTF8Encoding($false)))
  $n = Log-Count
  $t4 = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  $req = Log-Since $n | Where-Object { $_ -like 'GET*' }
  Check ($t4.Code -eq 0) 'termina sin error'
  $mods = @($req | Where-Object { $_ -like '*/mods/*' })
  Check ($mods.Count -eq 2 -and ($mods -join '|') -match 'alpha-1.0.jar' -and ($mods -join '|') -match 'zeta%20nuevo%2B1.0.jar') 'solo se descargaron alpha y zeta (nombre con espacio y "+" bien codificado)'
  Check (-not ($req -match 'base.zip|sk-portable.zip')) 'no se bajó la configuración ni el launcher'
  $names = Mods $t4 'fakepack'
  Check (($names -join ',') -eq 'alpha-1.0.jar,beta mod+2.1 [neoforge].jar,zeta nuevo+1.0.jar') 'gamma se borró, zeta se agregó, beta intacto'
  Check ((Sha "$($t1.Inst)\fakepack\mods\alpha-1.0.jar").ToLower() -eq $hash) 'alpha tiene el contenido nuevo'
  Check ((Get-Content "$($t1.Inst)\fakepack\saves\prueba\level.dat") -eq 'partida') 'saves\prueba sigue intacto'
  $st4 = Get-Content -Raw "$($t1.L)\state\fakepack.json" | ConvertFrom-Json
  Check ($st4.profile -eq 'low' -and $st4.mods.PSObject.Properties['zeta nuevo+1.0.jar'] -and -not $st4.mods.PSObject.Properties['gamma-1.0.jar']) 'el estado guardado refleja el manifest nuevo'

  Section '4b. El exclude es sagrado: un mod excluido que aparece en mods\ se borra'
  Copy-Item "$Work\r2\fakepack\mods\delta-extra-1.0.jar" "$($t1.Inst)\fakepack\mods\" -Force
  $t4b = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t4b.Code -eq 0 -and -not (Test-Path "$($t1.Inst)\fakepack\mods\delta-extra-1.0.jar")) 'delta (excluido en low) se borró'

  Section '4c. Configuración nueva en R2: kubejs y los config nuevos llegan; los config que ya tiene el jugador no se tocan'
  Copy-Item "$Work\r2\fakepack\base.zip", "$Work\r2\fakepack\manifest.json" $Work -Force   # se restauran al final (5b usa la ruta larga)
  $cfg = "$Work\cfg-v2"
  New-Item -ItemType Directory -Force "$cfg\config" | Out-Null
  Set-Content "$cfg\config\a.toml" 'version = 2'
  Set-Content "$cfg\config\nuevo.toml" 'nuevo = 1'
  New-Item -ItemType Directory -Force "$cfg\kubejs" | Out-Null
  Set-Content "$cfg\kubejs\x.js" '// v2'
  Set-Content "$cfg\options.txt" 'DEL-PAQUETE'
  Remove-Item "$Work\r2\fakepack\base.zip"; Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($cfg, "$Work\r2\fakepack\base.zip")
  $m = Get-Content -Raw "$Work\r2\fakepack\manifest.json" | ConvertFrom-Json
  $m.base.sha256 = (Sha "$Work\r2\fakepack\base.zip").ToLower(); $m.base.size = (Get-Item "$Work\r2\fakepack\base.zip").Length
  [IO.File]::WriteAllText("$Work\r2\fakepack\manifest.json", (ConvertTo-Json -InputObject $m -Depth 6), (New-Object Text.UTF8Encoding($false)))
  $t4c = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t4c.Code -eq 0 -and (Get-Content "$($t1.Inst)\fakepack\config\a.toml") -eq 'version = 1') 'config\a.toml existente no se tocó'
  Check ((Test-Path "$($t1.Inst)\fakepack\config\nuevo.toml") -and (Get-Content "$($t1.Inst)\fakepack\kubejs\x.js") -eq '// v2') 'llegan config\nuevo.toml y kubejs actualizado'
  Check ((Get-Content "$($t1.Inst)\fakepack\options.txt") -eq 'MARCA-DEL-JUGADOR') 'options.txt del jugador intacto'
  $t4d = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t4d.Out -notmatch 'Descargando la configuración') 'sin cambios en R2 no vuelve a bajar la configuración'
  Copy-Item "$Work\base.zip", "$Work\manifest.json" "$Work\r2\fakepack\" -Force

  Section '5a. Usuario con espacio y acento en el nombre'
  $t5 = Install "$Work\Usuário Pérez" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t5.Code -eq 0) "termina sin error (código $($t5.Code))"
  Check ((Mods $t5 'fakepack').Count -eq 3 -and (Test-Path "$($t5.L)\sklauncher.exe") -and (Test-Path (Lnk $t5))) 'launcher, .lnk y mods instalados en la ruta con espacio y acento'
  $i5 = @(Instances $t5)
  Check ($i5.Count -eq 1 -and $i5[0].directory -like '*Usuário Pérez*') 'directory conserva el espacio y el acento'

  Section '5b. Nombre de usuario largo: aborta con mensaje claro (sin extracción a medias)'
  $long = "$Work\" + ('p' * 70) + '\u'
  $t5b = Install $long @{ MODPACK = 'fakepack'; PROFILE = 'high'; SKL_TEST_NO_LONGPATHS = '1' }
  Check ($t5b.Code -eq 1) "termina con error (código $($t5b.Code))"
  Check ($t5b.Out -match 'rutas largas|LongPathsEnabled' -and $t5b.Out -match '\[ERROR\]') 'el mensaje habla de rutas largas y no hay traza'
  Check (-not (Test-Path "$($t5b.Inst)\fakepack-high") -and -not (Test-Path "$($t5b.Inst)\fakepack")) 'no se creó ninguna carpeta de instancia'
  Check (-not (Test-Path "$($t5b.L)\data\.sklauncher\instances.json")) 'no se registró ninguna instancia'
  $t5c = Install $long @{ MODPACK = 'fakepack'; PROFILE = 'high' }     # con rutas largas activas (como en esta PC) sí pasa
  Check ($t5c.Code -eq 0 -eq ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled -eq 1)) 'con LongPathsEnabled=1 (registro real) la misma ruta se instala'

  Section '6. Launcher abierto: aborta y avisa (solo el de esta carpeta cuenta)'
  $fake = Start-Process "$($t1.L)\sklauncher.exe" -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru   # ping.exe renombrado
  Start-Sleep 1
  $shaJson = Sha "$($t1.L)\data\.sklauncher\instances.json"
  $t6 = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t6.Code -eq 1 -and $t6.Out -match 'bandeja') 'aborta con código 1 y menciona la bandeja del sistema'
  Check ((Sha "$($t1.L)\data\.sklauncher\instances.json") -eq $shaJson) 'instances.json quedó exactamente igual'
  Stop-Process -Id $fake.Id -Force
  New-Item -ItemType Directory -Force "$Work\oficial" | Out-Null
  Copy-Item "$env:SystemRoot\System32\ping.exe" "$Work\oficial\sklauncher.exe" -Force
  $off = Start-Process "$Work\oficial\sklauncher.exe" -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
  Start-Sleep 1
  $t6b = Install "$($t1.Base)" @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Stop-Process -Id $off.Id -Force
  Check ($t6b.Code -eq 0) 'un sklauncher.exe de OTRA ruta (el oficial) no bloquea'

  Section '6b. SKLauncher oficial instalado en otra ruta: la instancia va a ese, sin portable'
  $c = "$Work\t6c"
  $exe = "$c\Juegos\SKlauncher\sklauncher.exe"
  New-Item -ItemType Directory -Force (Split-Path $exe), "$c\Roaming\Microsoft\Windows\Start Menu\Programs" | Out-Null
  Copy-Item "$env:SystemRoot\System32\ping.exe" $exe -Force
  $l = (New-Object -ComObject WScript.Shell).CreateShortcut("$c\Roaming\Microsoft\Windows\Start Menu\Programs\SKlauncher.lnk"); $l.TargetPath = $exe; $l.Save()
  $t6c = Install $c @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t6c.Code -eq 0 -and $t6c.Out -match [regex]::Escape("$c\Juegos\SKlauncher")) 'detecta el oficial en la ruta personalizada'
  Check ((Mods ([pscustomobject]@{ Inst = "$c\Roaming\.sklauncher\instances" }) 'fakepack').Count -eq 3) 'la instancia queda en %APPDATA%\.sklauncher (la del oficial)'
  Check (-not (Test-Path "$($t6c.L)\sklauncher.exe")) 'no instaló el portable'
  $run = Start-Process $exe -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
  Start-Sleep 1
  $t6d = Install $c @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Stop-Process -Id $run.Id -Force
  Check ($t6d.Code -eq 1 -and $t6d.Out -match 'bandeja') 'con ese oficial abierto, aborta'

  Section '6c. El oficial guarda sus instancias en otra unidad: la instancia va ahí y se registra con esa ruta'
  $g = "$c\G\juegos\maincra\instances"
  New-Item -ItemType Directory -Force "$g\otra" | Out-Null
  $ij = "$c\Roaming\.sklauncher\instances.json"
  $j = Get-Content -Raw -Encoding UTF8 $ij | ConvertFrom-Json
  $j.instances = @($j.instances | Where-Object id -ne 'fakepack') + [pscustomobject]@{ id = 'otra'; name = 'Otra'; directory = "$g\otra" }
  [IO.File]::WriteAllText($ij, (ConvertTo-Json -InputObject $j -Depth 10), (New-Object Text.UTF8Encoding($false)))
  Remove-Item "$c\Roaming\.sklauncher\mine-script-state" -Recurse -Force
  $t6e = Install $c @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t6e.Code -eq 0 -and (Mods ([pscustomobject]@{ Inst = $g }) 'fakepack').Count -eq 3) 'deduce la carpeta de instancias del launcher (G:\...\instances) e instala ahí'
  Check ((@((Get-Content -Raw -Encoding UTF8 $ij | ConvertFrom-Json).instances) | Where-Object id -eq 'fakepack').directory -eq "$g\fakepack") 'registrada con esa ruta'
  $t6f = Install $c @{ MODPACK = 'fakepack'; PROFILE = 'low' }
  Check ($t6f.Code -eq 0 -and $t6f.Out -match [regex]::Escape("$g\fakepack") -and $t6f.Out -match 'al día') 'la siguiente corrida usa la ruta registrada y solo actualiza'
  $t6g = Install $c @{ MODPACK = 'fakepack'; PROFILE = 'high'; SKL_INSTANCES_DIR = "$c\H\mc\instances\neocozy" }
  Check ($t6g.Code -eq 0 -and (Mods ([pscustomobject]@{ Inst = "$c\H\mc\instances" }) 'fakepack-high').Count -eq 5) 'pegar la ruta de una instancia usa su carpeta de instancias'

  Section '7. Descarga interrumpida: al reintentar se recupera'
  Start-Srv @('-DropPath', 'fakepack/base.zip', '-DropAfter', '1000000', '-DropCount', '10')
  $t7 = Install "$Work\t7" @{ MODPACK = 'fakepack'; PROFILE = 'high' }
  Check ($t7.Code -eq 1 -and $t7.Out -match 'No se pudo descargar') 'la primera corrida falla con un mensaje claro'
  $part = @(Get-ChildItem "$($t7.L)\state\dl" -Filter '*.part' -ErrorAction SilentlyContinue)
  Check ($part.Count -eq 1 -and $part[0].Length -gt 0 -and $part[0].Length -lt (Get-Item "$Work\r2\fakepack\base.zip").Length) "queda una descarga parcial reanudable ($($part[0].Length) bytes)"
  Check (-not (Test-Path "$($t7.Inst)\fakepack") -or @(Get-ChildItem "$($t7.Inst)\fakepack" -ErrorAction SilentlyContinue).Count -eq 0) 'no se extrajo nada a medias'
  Start-Srv
  $n = Log-Count
  $t7b = Install "$Work\t7" @{ MODPACK = 'fakepack'; PROFILE = 'high' }
  Check ($t7b.Code -eq 0 -and (Mods $t7b 'fakepack').Count -eq 5) 'el reintento termina bien con los 5 mods'
  Check ((Log-Since $n) -match 'GET /fakepack/base.zip \[bytes=[1-9]') 'el reintento reanudó con Range (no empezó de cero)'
  Check (@(Instances $t7b).Count -eq 1 -and (Mods $t7b 'fakepack').Count -eq 5) 'quedó una instancia con sus 5 mods'

  Section '8. Sin internet y sin espacio: errores claros'
  $t8 = Install "$Work\t8" @{ MODPACK = 'fakepack'; PROFILE = 'low'; CATALOG_URL = 'http://localhost:1/catalog.json' }
  Check ($t8.Code -eq 1 -and $t8.Out -match 'No se pudo descargar' -and $t8.Out -match 'conexión') 'sin internet: mensaje claro, código 1'
  Check (-not ($t8.Out -match 'CategoryInfo|En línea:|at <ScriptBlock>')) 'sin traza de PowerShell'
  $t8b = Install "$Work\t8b" @{ MODPACK = 'hugepack'; PROFILE = 'default' }
  Check ($t8b.Code -eq 1 -and $t8b.Out -match 'No hay espacio suficiente') 'falta de espacio: aborta antes de descargar el modpack'
  Check (-not (Test-Path "$($t8b.Inst)\hugepack")) 'sin carpeta de instancia'

  Section '9. Menú interactivo (stdin): modpack 1, perfil 2 (Gama Baja), sin acceso en el Escritorio'
  $t9 = Install "$Work\t9" @{} "1`n2`nn`n"
  Check ($t9.Code -eq 0) "termina sin error (código $($t9.Code))"
  Check ($t9.Out -match 'FakePack' -and $t9.Out -match '2\) Gama Baja') 'mostró el menú de modpack y el de perfil'
  $i9 = @(Instances $t9)
  Check ($i9.Count -eq 1 -and $i9[0].id -eq 'fakepack' -and (Mods $t9 'fakepack').Count -eq 3) 'instaló FakePack / Gama Baja'
  Check (-not (Test-Path "$($t9.Base)\Desktop\SKLauncher Portable.lnk")) 'no creó acceso en el Escritorio (respondí "n")'
  $t9b = Install "$Work\t9b" @{ MODPACK = 'fakepack'; PROFILE = 'low'; DESKTOP_SHORTCUT = '1' }
  Check (Test-Path "$($t9b.Base)\Desktop\SKLauncher Portable.lnk") 'con DESKTOP_SHORTCUT=1 sí crea el acceso en el Escritorio'

  Section '10. `irm | iex`: acentos bien decodificados'
  $env:CATALOG_URL = $Url; $env:MODPACK = 'fakepack'; $env:PROFILE = 'low'
  $env:LOCALAPPDATA = "$Work\t10\Local"; $env:APPDATA = "$Work\t10\Roaming"; $env:USERPROFILE = "$Work\t10"
  New-Item -ItemType Directory -Force "$Work\t10\Local", "$Work\t10\Roaming" | Out-Null
  $ErrorActionPreference = 'Continue'
  $o10 = & powershell.exe -NoProfile -Command "irm http://localhost:$Port/install.ps1 | iex" 2>&1 | Out-String
  $ErrorActionPreference = 'Stop'
  Check ($o10 -match 'Descargando catálogo' -and $o10 -match '¡Listo!') 'los mensajes salen con acentos (UTF-8 sin BOM + charset)'
  Check ($o10 -notmatch '\[ERROR\]') 'sin errores'
} finally {
  Stop-Srv
  Get-Process sklauncher -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Work*" } | Stop-Process -Force
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'TODAS LAS PRUEBAS PASARON' -ForegroundColor Green; exit 0 }
Write-Host "$($script:fails) comprobación(es) fallaron" -ForegroundColor Red; exit 1
