param(
  [Parameter(Mandatory = $true)]
  [string]$Binary,
  [int]$Port = 4400
)

$ErrorActionPreference = "Stop"
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path
& $resolvedBinary maintenance meta
if ($LASTEXITCODE -ne 0) { throw "maintenance meta failed with exit code $LASTEXITCODE" }

$env:PASEO_RELAY_HOST = "127.0.0.1"
$env:PASEO_RELAY_PORT = [string]$Port
$env:PASEO_RELAY_MIN_CLUSTER_SIZE = "1"
$logPath = Join-Path $PWD "standalone-smoke.log"
$errorLogPath = Join-Path $PWD "standalone-smoke-error.log"
$process = Start-Process -FilePath $resolvedBinary -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath

try {
  $ready = $false
  foreach ($attempt in 1..300) {
    if ($process.HasExited) {
      Get-Content -ErrorAction SilentlyContinue $logPath, $errorLogPath | Write-Error
      throw "standalone relay exited before becoming healthy"
    }
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
      if ($health.status -eq "ok") { $ready = $true; break }
    } catch {
      Start-Sleep -Milliseconds 200
    }
  }
  if (-not $ready) { throw "standalone relay did not become healthy" }
  $readiness = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/ready" -TimeoutSec 2
  if ($readiness.status -ne "ready") { throw "standalone relay was not ready" }
} finally {
  if (-not $process.HasExited) {
    & taskkill.exe /PID $process.Id /T /F | Out-Null
  }
  $process.WaitForExit()
}
