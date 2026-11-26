$ErrorActionPreference = 'SilentlyContinue'
$Backend = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$Frontend = [IO.Path]::GetFullPath((Join-Path $Backend '..\frontend'))
$PidFile = Join-Path $Backend 'logs\launcher-pids.json'
$owned = @{}
$manifest = $null

function Get-ProcessCommand([int]$ProcessId) {
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
  if (-not $process) { return $null }
  $command = [string]$process.CommandLine
  if ($command -match '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
    try { $command += "`n" + [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) } catch { }
  }
  return [pscustomobject]@{ Process = $process; Command = $command }
}

if (Test-Path $PidFile) {
  try {
    $manifest = Get-Content $PidFile -Raw | ConvertFrom-Json
    foreach ($item in $manifest.launchers) {
      $entry = Get-ProcessCommand ([int]$item.pid)
      if (-not $entry) { continue }
      $command = $entry.Command
      $isOwned = $false
      if ($item.module -eq 'orchestrator') {
        $isOwned = $command -match '(?i)start-demo\.ps1'
      } elseif ($item.module -eq 'legacy') {
        $isOwned = $command -like "*$Backend*" -and $command -match '(?i)-pl\s+(service-registry|config-server|vehicule-service|client-service|location-service|api-gateway)\s+spring-boot:run'
      } elseif ($item.module -in @('service-registry','config-server','vehicule-service','client-service','location-service','api-gateway')) {
        $logPath = [regex]::Escape((Join-Path $Backend ("logs\{0}.log" -f $item.module)))
        $moduleArg = [regex]::Escape([string]$item.module)
        $isOwned = $command -like "*$Backend*" -and $command -match "-pl\s+$moduleArg\s+spring-boot:run" -and $command -match $logPath
      }
      if ($isOwned) { $owned[[int]$item.pid] = $true }
    }

    # Old manifests stored PID numbers only. Decode each launcher command before trusting it.
    foreach ($legacyId in @($manifest)) {
      if ($legacyId -isnot [int] -and $legacyId -isnot [long]) { continue }
      $entry = Get-ProcessCommand ([int]$legacyId)
      if (-not $entry -or $entry.Process.Name -ne 'powershell.exe') { continue }
      if ($entry.Command -like "*$Backend*" -and $entry.Command -match '(?i)-pl\s+(service-registry|config-server|vehicule-service|client-service|location-service|api-gateway)\s+spring-boot:run') {
        $owned[[int]$legacyId] = $true
      } elseif ($entry.Command -match '(?i)backend\\start-demo\.ps1') {
        $owned[[int]$legacyId] = $true
      }
    }
  } catch { }
}

# Stop only processes whose command lines point to this project's backend or frontend.
foreach ($process in (Get-CimInstance Win32_Process -Filter "Name='java.exe'")) {
  if ($process.CommandLine -like "*$Backend*") { $owned[[int]$process.ProcessId] = $true }
  elseif ($process.CommandLine -like '*zipkin-server-3.6.1-exec.jar*--server.port=9412*') { $owned[[int]$process.ProcessId] = $true }
}
foreach ($process in (Get-CimInstance Win32_Process -Filter "Name='node.exe'")) {
  if ($process.CommandLine -like "*$Frontend*") { $owned[[int]$process.ProcessId] = $true }
}

# Catch service processes launched directly from Run & Debug as well as through Maven.
$servicePorts = @{
  8761 = 'tn.driveeasy.registry.RegistryApplication'
  8889 = 'tn.driveeasy.config.ConfigServerApplication'
  8081 = 'tn.driveeasy.vehicule.VehiculeApplication'
  8082 = 'tn.driveeasy.client.ClientApplication'
  8083 = 'tn.driveeasy.location.LocationApplication'
  8080 = 'tn.driveeasy.gateway.GatewayApplication'
}
foreach ($port in $servicePorts.Keys) {
  foreach ($listener in (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
    $serviceProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
    if ($serviceProcess.CommandLine -like "*$($servicePorts[$port])*") { $owned[[int]$listener.OwningProcess] = $true }
  }
}

# Stop children before their monitor process so shutdown stays scoped to DriveEasy.
$orderedIds = @($owned.Keys | Where-Object { -not $manifest -or $_ -ne $manifest.monitorPid })
foreach ($processId in $orderedIds) { & taskkill.exe /PID $processId /T /F *> $null }
if ($manifest -and $manifest.monitorPid -and $owned.ContainsKey([int]$manifest.monitorPid)) {
  & taskkill.exe /PID ([int]$manifest.monitorPid) /T /F *> $null
}
& taskkill.exe /FI 'WINDOWTITLE eq DriveEasy Zipkin' /T /F *> $null
Remove-Item -LiteralPath $PidFile -Force
Write-Host 'DriveEasy backend, Angular, and standalone Zipkin stopped.'
