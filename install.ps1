$ErrorActionPreference = "Stop"

# Default repo is rewritten by CI from HUBBOUND_RELEASES_REPOSITORY when published.
$Repo = if ($env:HUBBOUND_REPO) { $env:HUBBOUND_REPO } else { "KodastrDevelopment/hubbound-releases" }
$InstallDir = if ($env:HUBBOUND_INSTALL_DIR) { $env:HUBBOUND_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Hubbound\bin" }
$InstallAgent = if ($env:HUBBOUND_INSTALL_AGENT) { $env:HUBBOUND_INSTALL_AGENT } else { "1" }
$BaseUrl = "https://github.com/$Repo/releases/latest/download"

$Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  "AMD64" { "amd64" }
  "ARM64" { "arm64" }
  default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$Archive = "hubbound_windows_$Arch.zip"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  Write-Host "Downloading $Archive"
  Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile (Join-Path $Tmp $Archive)
  Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile (Join-Path $Tmp "checksums.txt")

  $Line = Get-Content (Join-Path $Tmp "checksums.txt") | Where-Object { $_ -match "\s+$([regex]::Escape($Archive))$" } | Select-Object -First 1
  if (-not $Line) { throw "Checksum not found for $Archive" }
  $Expected = ($Line -split "\s+")[0].ToLowerInvariant()
  $Actual = (Get-FileHash -Algorithm SHA256 (Join-Path $Tmp $Archive)).Hash.ToLowerInvariant()
  if ($Expected -ne $Actual) { throw "Checksum mismatch for $Archive" }

  Expand-Archive -Path (Join-Path $Tmp $Archive) -DestinationPath $Tmp -Force
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

  foreach ($Bin in @("hubbound.exe", "hubbound-agent.exe", "hubbound-helper.exe")) {
    $Source = Get-ChildItem -Path $Tmp -Recurse -Filter $Bin | Select-Object -First 1
    if (-not $Source) { throw "Archive missing $Bin" }
    Copy-Item $Source.FullName (Join-Path $InstallDir $Bin) -Force
  }

  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (($UserPath -split ";") -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable("Path", ($UserPath.TrimEnd(";") + ";" + $InstallDir), "User")
    Write-Host "Added $InstallDir to User PATH. Open a new terminal."
  }

  if ($InstallAgent -eq "1") {
    $Action = New-ScheduledTaskAction -Execute (Join-Path $InstallDir "hubbound-agent.exe") -Argument "run"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "HubboundAgent" -Action $Action -Trigger $Trigger -Principal $Principal -Description "Hubbound user agent" -Force | Out-Null
    Start-ScheduledTask -TaskName "HubboundAgent" -ErrorAction SilentlyContinue
    Write-Host "Installed Scheduled Task: HubboundAgent"
  }

  Write-Host "hubbound installed at $InstallDir\hubbound.exe"
  Write-Host "Try: hubbound version"
}
finally {
  Remove-Item -Path $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
