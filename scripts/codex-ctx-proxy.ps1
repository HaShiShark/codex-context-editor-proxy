param(
  [Parameter(Position = 0)]
  [string] $Command = "status",

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Rest = @()
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$defaultHome = Join-Path $env:USERPROFILE ".hash-context-codex"
$shimDir = if ($env:HASH_CONTEXT_SHIM_DIR) { $env:HASH_CONTEXT_SHIM_DIR } else { Join-Path $defaultHome "bin" }
$statePath = if ($env:HASH_CONTEXT_PROXY_SWITCH_STATE) { $env:HASH_CONTEXT_PROXY_SWITCH_STATE } else { Join-Path $defaultHome "codex-ctx-proxy.json" }
$skipPathUpdate = ($env:HASH_CONTEXT_SKIP_PATH_UPDATE -eq "1")
$proxyPort = if ($env:HASH_CONTEXT_PROXY_PORT) { $env:HASH_CONTEXT_PROXY_PORT } else { "8787" }
$loopbackHost = if ($env:HASH_CONTEXT_HOST) { $env:HASH_CONTEXT_HOST } else { "localhost" }

function ConvertTo-FullPath {
  param([string] $Path)
  if (-not $Path) {
    return ""
  }
  try {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
  } catch {
    return $Path.TrimEnd("\")
  }
}

function Test-PathUnder {
  param(
    [string] $Path,
    [string] $Parent
  )
  $fullPath = ConvertTo-FullPath $Path
  $fullParent = ConvertTo-FullPath $Parent
  if (-not $fullPath -or -not $fullParent) {
    return $false
  }
  return $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
    $fullPath.StartsWith("$fullParent\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ManagedShimPath {
  param([string] $Path)

  if (-not $Path) {
    return $false
  }

  if (Test-PathUnder -Path $Path -Parent $shimDir) {
    return $true
  }

  $defaultShimDir = Join-Path $defaultHome "bin"
  if (Test-PathUnder -Path $Path -Parent $defaultShimDir) {
    return $true
  }

  try {
    if ((Test-Path $Path) -and -not (Get-Item -LiteralPath $Path).PSIsContainer) {
      $shimText = Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue
      return ($shimText -match "codex-ctx-proxy\.ps1")
    }
  } catch {
    return $false
  }

  return $false
}

function Read-SwitchState {
  if (-not (Test-Path $statePath)) {
    return $null
  }
  try {
    return (Get-Content -Raw -Path $statePath | ConvertFrom-Json)
  } catch {
    Write-Host "[hash-context] ignoring invalid switch state: $statePath" -ForegroundColor DarkYellow
    return $null
  }
}

function Save-SwitchState {
  param(
    [bool] $Enabled,
    [string] $RealCodex
  )
  $stateDir = Split-Path -Parent $statePath
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
  $now = (Get-Date).ToUniversalTime().ToString("o")
  $existing = Read-SwitchState
  $createdAt = if ($existing -and $existing.created_at) { [string] $existing.created_at } else { $now }
  $payload = [ordered]@{
    version = 1
    enabled = $Enabled
    project_root = $projectRoot.Path
    real_codex = $RealCodex
    shim_dir = (ConvertTo-FullPath $shimDir)
    created_at = $createdAt
    updated_at = $now
  }
  $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding UTF8
}

function Get-CommandPath {
  param([object] $CommandInfo)
  if ($CommandInfo.Source) {
    return [string] $CommandInfo.Source
  }
  if ($CommandInfo.Definition) {
    return [string] $CommandInfo.Definition
  }
  return ""
}

function Find-RealCodex {
  param([string] $Preferred)

  if ($Preferred -and (Test-Path $Preferred) -and -not (Test-ManagedShimPath -Path $Preferred)) {
    return (ConvertTo-FullPath $Preferred)
  }

  $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
  foreach ($commandInfo in $commands) {
    $candidate = Get-CommandPath $commandInfo
    if (-not $candidate) {
      continue
    }
    if (Test-ManagedShimPath -Path $candidate) {
      continue
    }
    if (Test-Path $candidate) {
      return (ConvertTo-FullPath $candidate)
    }
  }

  throw "Could not find the real Codex command. Install the official Codex CLI first, then run this command again."
}

function Add-ShimDirToPath {
  if ($skipPathUpdate) {
    return
  }

  $fullShimDir = ConvertTo-FullPath $shimDir
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $entries = @()
  if ($userPath) {
    $entries = @($userPath -split ";" | Where-Object { $_ })
  }

  $exists = $false
  foreach ($entry in $entries) {
    if ((ConvertTo-FullPath $entry).Equals($fullShimDir, [System.StringComparison]::OrdinalIgnoreCase)) {
      $exists = $true
      break
    }
  }

  if (-not $exists) {
    $newPath = if ($userPath) { "$fullShimDir;$userPath" } else { $fullShimDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  }

  $processEntries = @($env:Path -split ";" | Where-Object { $_ })
  $processHasShim = $false
  foreach ($entry in $processEntries) {
    if ((ConvertTo-FullPath $entry).Equals($fullShimDir, [System.StringComparison]::OrdinalIgnoreCase)) {
      $processHasShim = $true
      break
    }
  }
  if (-not $processHasShim) {
    $env:Path = "$fullShimDir;$env:Path"
  }
}

function Remove-ShimDirFromPath {
  if ($skipPathUpdate) {
    return
  }

  $fullShimDir = ConvertTo-FullPath $shimDir
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath) {
    $entries = @($userPath -split ";" | Where-Object {
      $_ -and -not (ConvertTo-FullPath $_).Equals($fullShimDir, [System.StringComparison]::OrdinalIgnoreCase)
    })
    [Environment]::SetEnvironmentVariable("Path", ($entries -join ";"), "User")
  }

  $processEntries = @($env:Path -split ";" | Where-Object {
    $_ -and -not (ConvertTo-FullPath $_).Equals($fullShimDir, [System.StringComparison]::OrdinalIgnoreCase)
  })
  $env:Path = ($processEntries -join ";")
}

function Write-Shims {
  New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
  $managerScript = (Join-Path $projectRoot.Path "scripts\codex-ctx-proxy.ps1")
  $escapedManagerScript = $managerScript.Replace("'", "''")

  $psShim = @"
`$ErrorActionPreference = "Stop"
`$manager = '$escapedManagerScript'
& powershell -NoProfile -ExecutionPolicy Bypass -File `$manager __dispatch @args
exit `$LASTEXITCODE
"@
  Set-Content -Path (Join-Path $shimDir "codex.ps1") -Value $psShim -Encoding UTF8

  $cmdShim = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$managerScript" __dispatch %*
exit /b %ERRORLEVEL%
"@
  Set-Content -Path (Join-Path $shimDir "codex.cmd") -Value $cmdShim -Encoding ASCII
}

function Ensure-Installed {
  param([bool] $Enabled)

  $state = Read-SwitchState
  $preferred = if ($state -and $state.real_codex) { [string] $state.real_codex } else { "" }
  $realCodex = Find-RealCodex -Preferred $preferred
  Write-Shims
  Save-SwitchState -Enabled $Enabled -RealCodex $realCodex
  Add-ShimDirToPath
  return $realCodex
}

function Ensure-ControlShimInstalled {
  param([bool] $Enabled)

  $state = Read-SwitchState
  $preferred = if ($state -and $state.real_codex) { [string] $state.real_codex } else { "" }
  $realCodex = ""
  try {
    $realCodex = Find-RealCodex -Preferred $preferred
  } catch {
    Write-Host "[hash-context] official Codex CLI was not found yet; control commands were installed anyway." -ForegroundColor DarkYellow
    Write-Host "[hash-context] install the official Codex CLI before running: codex ctx proxy on" -ForegroundColor DarkYellow
  }
  Write-Shims
  Save-SwitchState -Enabled $Enabled -RealCodex $realCodex
  Add-ShimDirToPath
  return $realCodex
}

function Show-Status {
  $state = Read-SwitchState
  $enabled = $false
  $realCodex = ""
  if ($state) {
    $enabled = [bool] $state.enabled
    $realCodex = [string] $state.real_codex
  }

  $firstCodex = Get-Command codex -ErrorAction SilentlyContinue
  $firstCodexPath = if ($firstCodex) { Get-CommandPath $firstCodex } else { "" }

  Write-Host "[hash-context] proxy switch: $(if ($enabled) { 'on' } else { 'off' })"
  Write-Host "[hash-context] shim dir: $shimDir"
  Write-Host "[hash-context] state: $statePath"
  if ($realCodex) {
    Write-Host "[hash-context] real codex: $realCodex"
  }
  if ($firstCodexPath) {
    Write-Host "[hash-context] current codex resolves to: $firstCodexPath"
  }
}

function Write-PathRefreshHint {
  if (-not $skipPathUpdate) {
    Write-Host "[hash-context] open a new terminal for bare 'codex' commands to pick up the shim." -ForegroundColor DarkYellow
  }
}

function Invoke-RealCodex {
  param([string[]] $ForwardArgs)
  $state = Read-SwitchState
  $preferred = if ($state -and $state.real_codex) { [string] $state.real_codex } else { "" }
  $realCodex = Find-RealCodex -Preferred $preferred
  & $realCodex @ForwardArgs
  exit $LASTEXITCODE
}

function Test-DesktopHookConfigInstalled {
  $desktopConfigPath = if ($env:HASH_CONTEXT_DESKTOP_CONFIG) { $env:HASH_CONTEXT_DESKTOP_CONFIG } else { Join-Path $env:USERPROFILE ".codex\config.toml" }
  if (-not (Test-Path $desktopConfigPath)) {
    return $false
  }

  try {
    $configText = Get-Content -Raw -Path $desktopConfigPath
    return (
      $configText.Contains("# BEGIN HASH_CONTEXT_DESKTOP_TOP") -and
      $configText.Contains("hooks.UserPromptSubmit") -and
      $configText.Contains("codex-context-hook.cmd")
    )
  } catch {
    return $false
  }
}

function Get-HashContextCodexArgs {
  $hookCommand = (Join-Path $projectRoot.Path "scripts\codex-context-hook.cmd").Replace("\", "/")
  $hookConfig = "hooks.UserPromptSubmit=[{matcher='*',hooks=[{type='command',command='$hookCommand',timeout=10,statusMessage='HashContext'}]}]"

  $configArgs = @(
    "-c", "model_providers.hash-context.name=Hash Context",
    "-c", "model_providers.hash-context.base_url=http://${loopbackHost}:$proxyPort/v1",
    "-c", "model_providers.hash-context.requires_openai_auth=true",
    "-c", "model_providers.hash-context.wire_api=responses",
    "-c", "model_providers.hash-context.supports_websockets=false",
    "-c", "model_provider=hash-context"
  )

  if (-not (Test-DesktopHookConfigInstalled)) {
    $configArgs += @(
      "-c", "features.hooks=true",
      "-c", $hookConfig
    )
  }

  $autoCompactTokenLimit = $env:HASH_CONTEXT_AUTO_COMPACT_TOKEN_LIMIT
  if ($autoCompactTokenLimit) {
    $autoCompactTokenLimit = $autoCompactTokenLimit.Trim()
    if ($autoCompactTokenLimit -notmatch '^\d+$') {
      throw "HASH_CONTEXT_AUTO_COMPACT_TOKEN_LIMIT must be an integer token count."
    }
    $configArgs += @("-c", "model_auto_compact_token_limit=$autoCompactTokenLimit")
  }

  return $configArgs
}

function Invoke-DesktopProxyCommand {
  param([string] $DesktopCommand)

  $desktopScript = Join-Path $projectRoot.Path "scripts\codex-desktop-proxy.ps1"
  $process = Start-Process `
    -FilePath "powershell" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $desktopScript, $DesktopCommand) `
    -NoNewWindow `
    -Wait `
    -PassThru

  if ($null -eq $process.ExitCode) {
    return 0
  }
  return [int] $process.ExitCode
}

function Invoke-HashContextCodex {
  param([string[]] $ForwardArgs)
  $state = Read-SwitchState
  $preferred = if ($state -and $state.real_codex) { [string] $state.real_codex } else { "" }
  $realCodex = Find-RealCodex -Preferred $preferred
  $configArgs = Get-HashContextCodexArgs

  $localNoProxy = "$loopbackHost,localhost,127.0.0.1,::1"
  $previousNoProxy = $env:NO_PROXY
  $previousLowerNoProxy = $env:no_proxy
  $env:NO_PROXY = if ($env:NO_PROXY) { "$localNoProxy,$env:NO_PROXY" } else { $localNoProxy }
  $env:no_proxy = if ($env:no_proxy) { "$localNoProxy,$env:no_proxy" } else { $localNoProxy }
  try {
    & $realCodex @configArgs @ForwardArgs
    exit $LASTEXITCODE
  } finally {
    if ($null -eq $previousNoProxy) {
      Remove-Item Env:\NO_PROXY -ErrorAction SilentlyContinue
    } else {
      $env:NO_PROXY = $previousNoProxy
    }
    if ($null -eq $previousLowerNoProxy) {
      Remove-Item Env:\no_proxy -ErrorAction SilentlyContinue
    } else {
      $env:no_proxy = $previousLowerNoProxy
    }
  }
}

function Invoke-Dispatch {
  param([string[]] $ForwardArgs)

  if ($ForwardArgs.Count -ge 3 -and $ForwardArgs[0] -eq "ctx" -and $ForwardArgs[1] -eq "proxy") {
    switch ($ForwardArgs[2]) {
      "on" {
        $realCodex = Ensure-Installed -Enabled $true
        $desktopExitCode = Invoke-DesktopProxyCommand -DesktopCommand "on"
        if ($desktopExitCode -ne 0) {
          exit $desktopExitCode
        }
        Write-Host "[hash-context] codex ctx proxy on"
        Write-Host "[hash-context] persistent proxy services are running"
        Write-Host "[hash-context] real codex: $realCodex"
        exit 0
      }
      "off" {
        $realCodex = Ensure-Installed -Enabled $false
        $desktopExitCode = Invoke-DesktopProxyCommand -DesktopCommand "off"
        if ($desktopExitCode -ne 0) {
          exit $desktopExitCode
        }
        Write-Host "[hash-context] codex ctx proxy off"
        Write-Host "[hash-context] persistent proxy services are stopped"
        Write-Host "[hash-context] codex now passes through to: $realCodex"
        exit 0
      }
      "status" {
        Show-Status
        exit 0
      }
      "uninstall" {
        Invoke-DesktopProxyCommand -DesktopCommand "off" | Out-Null
        Remove-Item -Path $shimDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $statePath -Force -ErrorAction SilentlyContinue
        Remove-ShimDirFromPath
        Write-Host "[hash-context] codex ctx proxy shim removed"
        exit 0
      }
      default {
        Write-Host "Usage: codex ctx proxy <on|off|status|uninstall>" -ForegroundColor Red
        exit 2
      }
    }
  }

  if ($ForwardArgs.Count -ge 3 -and $ForwardArgs[0] -eq "ctx" -and $ForwardArgs[1] -eq "desktop") {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot.Path "scripts\codex-desktop-proxy.ps1") $ForwardArgs[2]
    exit $LASTEXITCODE
  }

  $state = Read-SwitchState
  if ($state -and [bool] $state.enabled) {
    Invoke-HashContextCodex -ForwardArgs $ForwardArgs
  }

  Invoke-RealCodex -ForwardArgs $ForwardArgs
}

switch ($Command) {
  "install" {
    $state = Read-SwitchState
    $enabled = if ($state) { [bool] $state.enabled } else { $false }
    $realCodex = Ensure-ControlShimInstalled -Enabled $enabled
    Write-Host "[hash-context] installed codex ctx proxy shim"
    if ($realCodex) {
      Write-Host "[hash-context] real codex: $realCodex"
    }
    Write-Host "[hash-context] after opening a new terminal, run: codex ctx proxy on"
    Write-Host "[hash-context] proxy stays off until you enable it."
    Write-PathRefreshHint
    break
  }
  "on" {
    $realCodex = Ensure-Installed -Enabled $true
    $desktopExitCode = Invoke-DesktopProxyCommand -DesktopCommand "on"
    if ($desktopExitCode -ne 0) {
      exit $desktopExitCode
    }
    Write-Host "[hash-context] codex ctx proxy on"
    Write-Host "[hash-context] persistent proxy services are running"
    Write-Host "[hash-context] real codex: $realCodex"
    Write-PathRefreshHint
    break
  }
  "off" {
    $realCodex = Ensure-Installed -Enabled $false
    $desktopExitCode = Invoke-DesktopProxyCommand -DesktopCommand "off"
    if ($desktopExitCode -ne 0) {
      exit $desktopExitCode
    }
    Write-Host "[hash-context] codex ctx proxy off"
    Write-Host "[hash-context] persistent proxy services are stopped"
    Write-Host "[hash-context] codex now passes through to: $realCodex"
    break
  }
  "status" {
    Show-Status
    break
  }
  "uninstall" {
    Invoke-DesktopProxyCommand -DesktopCommand "off" | Out-Null
    Remove-Item -Path $shimDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $statePath -Force -ErrorAction SilentlyContinue
    Remove-ShimDirFromPath
    Write-Host "[hash-context] codex ctx proxy shim removed"
    break
  }
  "__dispatch" {
    Invoke-Dispatch -ForwardArgs $Rest
    break
  }
  default {
    Write-Host "Usage: codex-ctx-proxy.ps1 <install|on|off|status|uninstall>" -ForegroundColor Red
    Write-Host "After install, use: codex ctx proxy <on|off|status|uninstall>"
    exit 2
  }
}
