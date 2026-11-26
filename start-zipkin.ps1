$ErrorActionPreference = 'Stop'
$Version = '3.6.1'
$Port = 9412
$ZipkinDir = Join-Path $PSScriptRoot '.tools\zipkin'
$Jar = Join-Path $ZipkinDir "zipkin-server-$Version-exec.jar"
$Stdout = Join-Path $PSScriptRoot 'logs\zipkin.log'
$Stderr = Join-Path $PSScriptRoot 'logs\zipkin-error.log'
New-Item -ItemType Directory -Force -Path $ZipkinDir,(Split-Path -Parent $Stdout) | Out-Null

try {
  Invoke-WebRequest "http://localhost:$Port/" -TimeoutSec 2 -UseBasicParsing | Out-Null
  Write-Host "Zipkin dashboard ready: http://localhost:$Port"
  exit 0
} catch { }

if (-not (Test-Path $Jar)) {
  Write-Host 'Downloading standalone Zipkin (first download is about 129 MB)...'
  $url = "https://repo.maven.apache.org/maven2/io/zipkin/zipkin-server/$Version/zipkin-server-$Version-exec.jar"
  Invoke-WebRequest -Uri $url -OutFile $Jar
}

$existing = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($existing) { throw "Port $Port is already occupied, and it is not responding as Zipkin." }

$process = Start-Process -FilePath 'java.exe' -ArgumentList @('-jar', $Jar, "--server.port=$Port") `
  -WorkingDirectory $ZipkinDir -WindowStyle Hidden -RedirectStandardOutput $Stdout `
  -RedirectStandardError $Stderr -PassThru
Write-Host "Starting standalone Zipkin (PID $($process.Id)); logs: backend/logs/zipkin*.log"

for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 1
  try {
    Invoke-WebRequest "http://localhost:$Port/" -TimeoutSec 2 -UseBasicParsing | Out-Null
    Write-Host "Zipkin dashboard ready: http://localhost:$Port"
    exit 0
  } catch {
    if ($process.HasExited) { throw "Zipkin exited during startup. Check backend/logs/zipkin-error.log." }
  }
}
throw 'Zipkin did not become ready within 90 seconds. Check backend/logs/zipkin*.log.'
