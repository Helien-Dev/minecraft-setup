# serve-test.ps1
#
# Servidor estático mínimo para probar install.ps1 sin R2 (solo System.Net.HttpListener,
# sin Python). Sirve una carpeta con el mismo layout que R2 y apunta $env:CATALOG_URL ahí:
#
#   .\scripts\windows\serve-test.ps1 -Root C:\ruta\r2-falso -Port 8099
#   $env:CATALOG_URL = 'http://localhost:8099/catalog.json'
#
# Soporta GET/HEAD y `Range: bytes=N-` (reanudar descargas, como R2). Se detiene con Ctrl+C.
#
# Opciones para pruebas:
#   -LogFile    archivo donde anota cada petición ("GET /ruta [Range]")
#   -DropPath   si la ruta contiene este texto, corta la conexión a mitad de la descarga...
#   -DropAfter  ...tras enviar estos bytes (default 300000)...
#   -DropCount  ...las primeras N veces (default 0 = nunca)
#   -HugePath   los HEAD a rutas que contengan este texto anuncian ~1 TB (prueba de falta de espacio)
#   -NoCharset  sirve .ps1 como "text/plain" sin charset (para probar la decodificación de `irm`)
param(
  [Parameter(Mandatory)][string]$Root,
  [int]$Port = 8099,
  [string]$LogFile,
  [string]$DropPath,
  [int]$DropAfter = 300000,
  [int]$DropCount = 0,
  [string]$HugePath,
  [switch]$NoCharset
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
$l.Start()
Write-Host "Sirviendo $Root en http://localhost:$Port/  (Ctrl+C para detener)"

while ($l.IsListening) {
  $ctx = $l.GetContext()
  $req = $ctx.Request; $res = $ctx.Response
  try {
    $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
    $range = $req.Headers['Range']
    # se anota la URL tal como llegó (con %20, %2B...) para poder comprobar la codificación
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value ("{0} {1}{2}" -f $req.HttpMethod, $req.RawUrl, $(if ($range) { " [$range]" } else { '' })) }
    $file = Join-Path $Root ($rel -replace '/', '\')
    if ($rel -match '\.\.' -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { $res.StatusCode = 404; $res.Close(); continue }

    $size = (Get-Item -LiteralPath $file).Length
    $ct = switch -Wildcard ($file) {
      '*.json' { 'application/json' }
      '*.ps1'  { if ($NoCharset) { 'text/plain' } else { 'text/plain; charset=utf-8' } }
      default  { 'application/octet-stream' }
    }
    $res.ContentType = $ct
    $res.Headers['Accept-Ranges'] = 'bytes'

    if ($req.HttpMethod -eq 'HEAD') {
      $res.ContentLength64 = $(if ($HugePath -and $rel.Contains($HugePath)) { 999999999999 } else { $size })
      $res.Close(); continue
    }

    $start = 0
    if ($range -match '^bytes=(\d+)-') {
      $start = [int64]$Matches[1]
      if ($start -ge $size) { $res.StatusCode = 416; $res.Headers['Content-Range'] = "bytes */$size"; $res.Close(); continue }
      $res.StatusCode = 206
      $res.Headers['Content-Range'] = "bytes $start-$($size - 1)/$size"
    }
    $res.ContentLength64 = $size - $start

    $drop = $DropPath -and $rel.Contains($DropPath) -and $DropCount -gt 0
    if ($drop) { $DropCount-- }
    $fs = [IO.File]::OpenRead($file)
    try {
      $fs.Position = $start
      $buf = New-Object byte[] 65536
      $sent = 0
      while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
        $res.OutputStream.Write($buf, 0, $n); $sent += $n
        if ($drop -and $sent -ge $DropAfter) { $res.Abort(); break }
      }
    } finally { $fs.Dispose() }
    if (-not $drop) { $res.Close() }
  } catch {
    # cliente que cortó (p. ej. curl reanudando): se ignora y se sigue sirviendo
    try { $res.Abort() } catch {}
  }
}
