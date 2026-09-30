# Arma en una carpeta local un R2 falso (formato de scripts/publish.py) para probar install.ps1 con serve-test.ps1.
param(
  [Parameter(Mandatory)][string]$Out,
  [switch]$LongEntry  # agrega una ruta muy larga al base (prueba del límite de 260 caracteres)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("layout-" + [Guid]::NewGuid().ToString('N'))

function New-RandomFile($path, $bytes) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  $b = New-Object byte[] $bytes; (New-Object Random).NextBytes($b); [IO.File]::WriteAllBytes($path, $b)
}
function Write-Utf8($path, $text) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Sha($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

function New-Zip($dir, $zip) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $zip) | Out-Null; [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip) }

# Publica $stage\base como <prefix>/base.zip y $stage\mods como <prefix>/mods + manifest; $fakeSize simula mods enormes.
function Publish-Pack($stage, $prefix, $fakeSize = 0) {
  $base = Join-Path $Out "$prefix\base.zip"
  New-Zip (Join-Path $stage 'base') $base
  $mods = [ordered]@{}
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $stage 'mods') -File | Sort-Object Name) {
    $mods[$f.Name] = [ordered]@{ sha256 = Sha $f.FullName; size = $(if ($fakeSize) { $fakeSize } else { $f.Length }) }
    $dst = Join-Path $Out "$prefix\mods\$($f.Name)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
  }
  $manifest = [ordered]@{ generatedAt = '2026-01-01T00:00:00Z'; base = [ordered]@{ sha256 = Sha $base; size = (Get-Item $base).Length }; mods = $mods }
  Write-Utf8 (Join-Path $Out "$prefix\manifest.json") (ConvertTo-Json -InputObject $manifest -Depth 5)
}

$fl = Join-Path $work 'launcher'
New-Item -ItemType Directory -Force -Path $fl | Out-Null
Copy-Item (Join-Path $env:SystemRoot 'System32\ping.exe') (Join-Path $fl 'sklauncher.exe')  # exe cualquiera como launcher falso
Set-Content -LiteralPath (Join-Path $fl 'SKLauncher-Portable.bat') -Value '@echo off'
New-RandomFile (Join-Path $fl 'resources\app.asar') 50000
& $Tar -a -cf (Join-Path $Out 'sk-portable.zip') -C $fl .
if ($LASTEXITCODE) { throw 'tar falló creando sk-portable.zip' }

# fakepack: standard (high) con 5 mods, uno con espacio, "+" y corchetes; low excluye los dos "extra".
$st = Join-Path $work 'fakepack'
foreach ($n in 'alpha-1.0.jar', 'beta mod+2.1 [neoforge].jar', 'gamma-1.0.jar', 'delta-extra-1.0.jar', 'epsilon-extra-1.0.jar') { New-RandomFile (Join-Path $st "mods\$n") 1500000 }
Write-Utf8 (Join-Path $st 'base\config\a.toml') 'version = 1'
Write-Utf8 (Join-Path $st 'base\kubejs\x.js') '// kubejs'
Write-Utf8 (Join-Path $st 'base\options.txt') 'DEL-PAQUETE'                    # no debe pisar el del jugador
Write-Utf8 (Join-Path $st 'base\config\sub\options.txt') 'DEL-PAQUETE-ANIDADO'  # este sí debe aplicarse
New-RandomFile (Join-Path $st 'base\resourcepacks\pack.zip') 3000000           # para poder cortar la descarga a mitad
if ($LongEntry) { New-RandomFile (Join-Path $st ("base\shaderpacks\" + ('a' * 60) + '\' + ('a' * 60) + '\x.txt')) 10 }
Publish-Pack $st 'fakepack'
Write-Utf8 (Join-Path $st 'low\config\low.toml') 'low = 1'                  # configuración propia de low
New-Zip (Join-Path $st 'low') (Join-Path $Out 'fakepack\profiles\low.zip')
$lowZip = Join-Path $Out 'fakepack\profiles\low.zip'
$low = [ordered]@{ exclude = @('delta-extra-1.0.jar', 'epsilon-extra-1.0.jar'); include = @{}; skip = @('resourcepacks/pack.zip')
                   config = [ordered]@{ sha256 = Sha $lowZip; size = (Get-Item $lowZip).Length } }
Write-Utf8 (Join-Path $Out 'fakepack\profiles\low.json') (ConvertTo-Json -InputObject $low -Depth 5)

# hugepack: diminuto, pero su manifest declara ~1 TB (prueba de falta de espacio).
$hs = Join-Path $work 'hugepack'
New-RandomFile (Join-Path $hs 'mods\h-1.0.jar') 1000
Write-Utf8 (Join-Path $hs 'base\config\h.toml') 'h = 1'
Publish-Pack $hs 'hugepack' 1TB

$catalog = [ordered]@{
  launcher = [ordered]@{ linux = [ordered]@{ url = 'x.AppImage'; version = '0' }; windows = [ordered]@{ url = 'sk-portable.zip'; version = '4.0.51' } }
  modpacks = @(
    [ordered]@{ id = 'fakepack'; name = 'FakePack'; type = 'custom'; icon = 'Furnace_On'; minecraft = '1.21.1'; loader = 'neoforge'
                loaderVersion = '21.1.251'; versionId = '1.21.1-neoforge-21.1.251'; memoryMax = 6144; prefix = 'fakepack'
                profiles = @([ordered]@{ id = 'high'; label = 'Gama Alta' }, [ordered]@{ id = 'low'; label = 'Gama Baja' }) },
    [ordered]@{ id = 'hugepack'; name = 'HugePack'; minecraft = '1.21.1'; loader = 'neoforge'; loaderVersion = '21.1.251'
                versionId = '1.21.1-neoforge-21.1.251'; memoryMax = 4096; prefix = 'hugepack'; profiles = @([ordered]@{ id = 'default' }) }
  )
}
Write-Utf8 (Join-Path $Out 'catalog.json') (ConvertTo-Json -InputObject $catalog -Depth 8)
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Layout listo en $Out"
