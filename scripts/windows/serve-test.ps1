# Servidor estático con el layout de R2 para probar install.ps1 (uso: -Root <carpeta> y $env:CATALOG_URL='http://localhost:8099/catalog.json').
param(
  [Parameter(Mandatory)][string]$Root,
  [int]$Port = 8099,
  [string]$LogFile,
  [string]$DropPath,           # corta a mitad la descarga de las rutas que contengan este texto...
  [int]$DropAfter = 300000,    # ...tras enviar estos bytes...
  [int]$DropCount = 0,         # ...las primeras N veces
  [switch]$NoCharset          # sirve .ps1 sin charset (prueba la decodificación de `irm`)
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
      $res.ContentLength64 = $size
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
