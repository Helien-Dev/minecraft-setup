# make-test-layout.ps1
#
# Arma un layout tipo R2 en una carpeta local para probar install.ps1 con serve-test.ps1.
# Herramienta de DESARROLLO (no se publica).
#
#   # Layout falso y pequeño (pruebas rápidas): modpack "fakepack" con perfiles high/low,
#   # otro "hugepack" y un launcher falso diminuto.
#   .\make-test-layout.ps1 -Out C:\tmp\r2-falso
#
#   # Layout real: usa el catalog.json del repo, el sk-portable\ real (-> sk-portable.zip)
#   # y NeoLowProfile\ real (-> neofresh/low). Solo se arma la gama baja.
#   .\make-test-layout.ps1 -Out C:\tmp\r2-real -SkPortable D:\...\sk-portable -NeoLow D:\...\NeoLowProfile
#
# Opción -LongEntry: agrega al perfil "high" una ruta muy larga (prueba del límite de 260).
param(
  [Parameter(Mandatory)][string]$Out,
  [string]$SkPortable,
  [string]$NeoLow,
  [switch]$LongEntry
)
$ErrorActionPreference = 'Stop'
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("layout-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function New-RandomFile($path, $bytes) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  $b = New-Object byte[] $bytes; (New-Object Random).NextBytes($b); [IO.File]::WriteAllBytes($path, $b)
}

# Empaqueta $stage como $tarRel y escribe el manifest de su mods\ (mismo formato que package-instance.sh).
function Publish-Profile($stage, $tarRel, $manifestRel, $modsRel) {
  $tarPath = Join-Path $Out $tarRel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tarPath) | Out-Null
  & $Tar -czf $tarPath -C $stage .
  if ($LASTEXITCODE) { throw "tar falló empaquetando $stage" }
  $mods = [ordered]@{}
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $stage 'mods') -File | Sort-Object Name) {
    $mods[$f.Name] = [ordered]@{ sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(); size = $f.Length }
    $dst = Join-Path $Out "$modsRel\$($f.Name)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
  }
  $manifest = Join-Path $Out $manifestRel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
  $json = ConvertTo-Json -InputObject ([ordered]@{ generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z'); mods = $mods }) -Depth 5
  [IO.File]::WriteAllText($manifest, $json, (New-Object Text.UTF8Encoding($false)))
}

if ($SkPortable) {
  # --- layout real ---
  Copy-Item (Join-Path $Repo 'catalog.json') (Join-Path $Out 'catalog.json') -Force
  Write-Host 'Comprimiendo sk-portable.zip (contenido en la raíz, sin data\)...'
  $items = Get-ChildItem -LiteralPath $SkPortable -Force | Where-Object Name -ne 'data' | ForEach-Object { $_.Name }
  & $Tar -a -cf (Join-Path $Out 'sk-portable.zip') -C $SkPortable @items
  if ($LASTEXITCODE) { throw 'tar falló creando sk-portable.zip' }
  if ($NeoLow) { Write-Host 'Empaquetando neofresh/low...'; Publish-Profile $NeoLow 'neofresh/low/instance.tar.gz' 'neofresh/low/manifest.json' 'neofresh/mods' }
} else {
  # --- layout falso: launcher diminuto ---
  $fl = Join-Path $work 'launcher'
  New-Item -ItemType Directory -Force -Path $fl | Out-Null
  Copy-Item (Join-Path $env:SystemRoot 'System32\ping.exe') (Join-Path $fl 'sklauncher.exe')   # exe cualquiera, sirve de launcher falso
  Set-Content -LiteralPath (Join-Path $fl 'SKLauncher-Portable.bat') -Value '@echo off'
  New-RandomFile (Join-Path $fl 'resources\app.asar') 50000
  New-RandomFile (Join-Path $fl 'locales\es.pak') 20000
  & $Tar -a -cf (Join-Path $Out 'sk-portable.zip') -C $fl .
  if ($LASTEXITCODE) { throw 'tar falló creando sk-portable.zip' }

  # --- modpack falso: mods compartidos (uno con espacio, "+" y corchetes), 2 perfiles ---
  $names = 'alpha-1.0.jar', 'beta mod+2.1 [neoforge].jar', 'gamma-1.0.jar', 'delta-extra-1.0.jar', 'epsilon-extra-1.0.jar'
  foreach ($p in 'low', 'high') {
    $st = Join-Path $work "stage-$p"
    $use = if ($p -eq 'low') { $names[0..2] } else { $names }
    foreach ($n in $use) { New-RandomFile (Join-Path $st "mods\$n") 1500000 }
    Set-Content -LiteralPath (Join-Path (New-Item -ItemType Directory -Force (Join-Path $st 'config')) 'a.toml') -Value "perfil = `"$p`""
    Set-Content -LiteralPath (Join-Path (New-Item -ItemType Directory -Force (Join-Path $st 'kubejs')) 'x.js') -Value '// kubejs'
    # archivos "personales" que un paquete mal armado podría traer (prueba de que no se pisan)
    Set-Content -LiteralPath (Join-Path $st 'options.txt') -Value 'DEL-PAQUETE'
    Set-Content -LiteralPath (Join-Path (New-Item -ItemType Directory -Force (Join-Path $st 'config\sub')) 'options.txt') -Value 'DEL-PAQUETE-ANIDADO'
    if ($p -eq 'high' -and $LongEntry) {
      $seg = 'a' * 60      # ruta de ~139 caracteres, parecida a la del shader de la gama alta real
      New-RandomFile (Join-Path $st "shaderpacks\$seg\$seg\x.txt") 10
    }
  }
  # mismos bytes para los mods compartidos entre perfiles
  foreach ($n in $names[0..2]) { Copy-Item (Join-Path $work "stage-high\mods\$n") (Join-Path $work "stage-low\mods\$n") -Force }
  Publish-Profile (Join-Path $work 'stage-low')  'fakepack/low/instance.tar.gz'  'fakepack/low/manifest.json'  'fakepack/mods'
  Publish-Profile (Join-Path $work 'stage-high') 'fakepack/high/instance.tar.gz' 'fakepack/high/manifest.json' 'fakepack/mods'

  # --- hugepack: real y diminuto, pero serve-test.ps1 -HugePath hugepack anuncia ~1 TB ---
  $hs = Join-Path $work 'stage-huge'
  New-RandomFile (Join-Path $hs 'mods\h-1.0.jar') 1000
  Publish-Profile $hs 'hugepack/default/instance.tar.gz' 'hugepack/default/manifest.json' 'hugepack/mods'

  $catalog = [ordered]@{
    launcher = [ordered]@{ linux = [ordered]@{ url = 'x.AppImage'; version = '0' }; windows = [ordered]@{ url = 'sk-portable.zip'; version = '4.0.51' } }
    modpacks = @(
      [ordered]@{ id = 'fakepack'; name = 'FakePack'; type = 'custom'; icon = 'Furnace_On'; minecraft = '1.21.1'; loader = 'neoforge'
                  loaderVersion = '21.1.251'; versionId = '1.21.1-neoforge-21.1.251'; memoryMax = 6144; prefix = 'fakepack'
                  profiles = @([ordered]@{ id = 'high'; label = 'Gama Alta'; tar = 'fakepack/high/instance.tar.gz'; manifest = 'fakepack/high/manifest.json' },
                               [ordered]@{ id = 'low';  label = 'Gama Baja'; tar = 'fakepack/low/instance.tar.gz';  manifest = 'fakepack/low/manifest.json' }) },
      [ordered]@{ id = 'hugepack'; name = 'HugePack'; minecraft = '1.21.1'; loader = 'neoforge'; loaderVersion = '21.1.251'
                  versionId = '1.21.1-neoforge-21.1.251'; memoryMax = 4096; prefix = 'hugepack'
                  profiles = @([ordered]@{ id = 'default'; tar = 'hugepack/default/instance.tar.gz'; manifest = 'hugepack/default/manifest.json' }) }
    )
  }
  [IO.File]::WriteAllText((Join-Path $Out 'catalog.json'), (ConvertTo-Json -InputObject $catalog -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Layout listo en $Out"
