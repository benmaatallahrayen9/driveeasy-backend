$ErrorActionPreference = 'Stop'
$Backend = Split-Path -Parent $MyInvocation.MyCommand.Path
$MavenCache = [IO.Path]::GetFullPath((Join-Path $Backend '..\..\..\work\m2-repository'))
$Logs = Join-Path $Backend 'logs'
$PidFile = Join-Path $Logs 'launcher-pids.json'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$Launchers = [System.Collections.Generic.List[object]]::new()
$Mutex = [System.Threading.Mutex]::new($false, 'Local\DriveEasyBackend')
$OwnsMutex = $false

if (Test-Path $PidFile) {
  try {
    $saved = Get-Content $PidFile -Raw | ConvertFrom-Json
    foreach ($item in $saved.launchers) {
      if ($item.pid) { $Launchers.Add([pscustomobject]@{ pid = [int]$item.pid; module = [string]$item.module }) }
    }
    foreach ($legacyId in $saved) {
      if ($legacyId -is [int] -or $legacyId -is [long]) {
        $Launchers.Add([pscustomobject]@{ pid = [int]$legacyId; module = 'legacy' })
      }
    }
  } catch { }
}

function Test-DriveEasyUrl([string]$Url) {
  try {
    $response = Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
  } catch { return $false }
}

function Test-DriveEasyPort([int]$Port) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne(1000)) { return $false }
    $client.EndConnect($pending)
    return $true
  } catch { return $false }
  finally { $client.Dispose() }
}

function Wait-DriveEasyUrl([string]$Name, [string]$Url) {
  $deadline = (Get-Date).AddSeconds(240)
  while ((Get-Date) -lt $deadline) {
    if (Test-DriveEasyUrl $Url) { return }
    Start-Sleep -Seconds 2
  }
  throw ("Timed out waiting for {0} at {1}." -f $Name,$Url)
}

function Start-DriveEasyService([string]$Module, [string]$Name) {
  $log = Join-Path $Logs ($Name + '.log')
  $quotedBackend = $Backend.Replace("'", "''")
  $quotedLog = $log.Replace("'", "''")
  $command = "Set-Location -LiteralPath '$quotedBackend'; & mvn '-Dmaven.repo.local=$MavenCache' -pl $Module spring-boot:run *> '$quotedLog'"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WorkingDirectory $Backend -WindowStyle Hidden -PassThru
  $Launchers.Add([pscustomobject]@{ pid = $proc.Id; module = $Module })
  Write-Host ("Starting {0}; log: backend/logs/{0}.log" -f $Name)
}

function Ensure-DriveEasyService([string]$Module, [string]$Name, [string]$Url, [int]$Port) {
  if (Test-DriveEasyUrl $Url) { Write-Host ("Ready: {0}" -f $Name); return }
  if (Test-DriveEasyPort $Port) {
    Write-Host ("Port {0} is occupied; checking the existing service without launching another copy." -f $Port)
  } else {
    Start-DriveEasyService $Module $Name
  }
  $deadline = (Get-Date).AddSeconds(240)
  while ((Get-Date) -lt $deadline) {
    if (Test-DriveEasyUrl $Url) { Write-Host ("Ready: {0}" -f $Name); return }
    Start-Sleep -Seconds 2
  }
  throw ("Port {0} is in use, but {1} did not become ready. Check backend/logs/{2}.log and close any extra instance." -f $Port,$Name,$Name)
}

try {
  $OwnsMutex = $Mutex.WaitOne(0)
  if (-not $OwnsMutex) {
    Write-Host 'Another DriveEasy startup owns the lock; waiting for its services.'
    Wait-DriveEasyUrl 'Eureka' 'http://localhost:8761/'
    Wait-DriveEasyUrl 'Config Server' 'http://localhost:8889/actuator/info'
    Wait-DriveEasyUrl 'Vehicle service' 'http://localhost:8081/actuator/info'
    Wait-DriveEasyUrl 'Client service' 'http://localhost:8082/actuator/info'
    Wait-DriveEasyUrl 'Rental service' 'http://localhost:8083/actuator/info'
    Wait-DriveEasyUrl 'API Gateway' 'http://localhost:8080/actuator/info'
    Write-Host 'All backend services are ready. Eureka: http://localhost:8761; Gateway: http://localhost:8080.'
    exit 0
  }

  Write-Host 'Starting DriveEasy services (no Docker required)...'
  $Launchers.Add([pscustomobject]@{ pid = $PID; module = 'orchestrator' })
  Ensure-DriveEasyService 'service-registry' 'service-registry' 'http://localhost:8761/' 8761
  Ensure-DriveEasyService 'config-server' 'config-server' 'http://localhost:8889/actuator/info' 8889
  Ensure-DriveEasyService 'vehicule-service' 'vehicule-service' 'http://localhost:8081/actuator/info' 8081
  Ensure-DriveEasyService 'client-service' 'client-service' 'http://localhost:8082/actuator/info' 8082
  Ensure-DriveEasyService 'location-service' 'location-service' 'http://localhost:8083/actuator/info' 8083
  Ensure-DriveEasyService 'api-gateway' 'api-gateway' 'http://localhost:8080/actuator/info' 8080
  @{ launchers = $Launchers } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $PidFile
  Write-Host 'All backend services are ready. Eureka: http://localhost:8761; Gateway: http://localhost:8080.'
  Write-Host 'Backend services stay running. Use DriveEasy: Stop stack when finished.'
  while ($true) { Start-Sleep -Seconds 5 }
} finally {
  if ($OwnsMutex) { $Mutex.ReleaseMutex() }
  $Mutex.Dispose()
}
