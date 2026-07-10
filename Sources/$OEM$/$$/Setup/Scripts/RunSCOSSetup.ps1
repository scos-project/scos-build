param(
    [string]$ScriptsRoot = "C:\Windows\Setup\Scripts",
    [string]$Edition = "Standard",
    [int]$Lockdown = 1
)

$LogPath = "C:\SCOS\Logs\SCOSLauncher.log"
$SetupCompleteLog = "C:\SetupComplete.log"
$SetupUi = "C:\SCOS\Setup\SCOSSetupProgress.ps1"

$EditionFile = "C:\SCOS\Setup\SCOS_EDITION.txt"
$LockdownFile = "C:\SCOS\Setup\SCOS_LOCKDOWN.txt"

# SCOS Builder writes the selected Windows time zone ID into this file.
$InstalledTimeZoneFile = "C:\SCOS\Setup\SCOS_TIMEZONE.txt"
$ScriptsTimeZoneFile = Join-Path $ScriptsRoot "SCOS_TIMEZONE.txt"

New-Item -ItemType Directory -Path "C:\SCOS\Logs" -Force | Out-Null

function Write-LauncherLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message

    Add-Content -Path $LogPath -Value $line

    try {
        Add-Content -Path $SetupCompleteLog -Value $line -ErrorAction Stop
    }
    catch {
        # Ignore access denied on C:\SetupComplete.log when running as normal user.
    }
}

function Normalize-SCOSEdition {
    param(
        [string]$RawEdition,
        [int]$RawLockdown
    )

    $normalizedEdition = "Standard"
    $normalizedLockdown = 1

    if ($RawEdition -and $RawEdition.Trim().Equals("Developer", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedEdition = "Developer"
        $normalizedLockdown = 0
    }
    elseif ($RawEdition -and $RawEdition.Trim().Equals("Standard", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedEdition = "Standard"
        $normalizedLockdown = 1
    }
    elseif ($RawLockdown -eq 0) {
        $normalizedEdition = "Developer"
        $normalizedLockdown = 0
    }

    return @{
        Edition = $normalizedEdition
        Lockdown = $normalizedLockdown
    }
}

function Get-SCOSTimeZoneFile {
    if (Test-Path $InstalledTimeZoneFile) {
        return $InstalledTimeZoneFile
    }

    if (Test-Path $ScriptsTimeZoneFile) {
        return $ScriptsTimeZoneFile
    }

    return $null
}

function Set-SCOSTimeZone {
    $timeZoneFile = Get-SCOSTimeZoneFile

    if (-not $timeZoneFile) {
        Write-LauncherLog "INFO: SCOS timezone file not found. Keeping the current Windows time zone."
        return
    }

    Write-LauncherLog "Found SCOS timezone file: $timeZoneFile"

    try {
        $selectedTimeZone = (Get-Content -Path $timeZoneFile -Raw -ErrorAction Stop).Trim()
    }
    catch {
        Write-LauncherLog "WARN: Failed to read SCOS timezone file: $($_.Exception.Message)"
        return
    }

    if ([string]::IsNullOrWhiteSpace($selectedTimeZone)) {
        Write-LauncherLog "INFO: SCOS timezone file is empty. Keeping the current Windows time zone."
        return
    }

    Write-LauncherLog "Requested Windows time zone: $selectedTimeZone"

    $TzUtilExe = Join-Path $env:SystemRoot "System32\tzutil.exe"

    if (-not (Test-Path $TzUtilExe)) {
        Write-LauncherLog "WARN: tzutil.exe was not found. The selected time zone could not be applied."
        return
    }

    try {
        $validTimeZones = & $TzUtilExe /l 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-LauncherLog "WARN: Could not retrieve the Windows time zone list. tzutil exited with code $LASTEXITCODE."
            return
        }

        $timeZoneIsValid = $false

        foreach ($entry in $validTimeZones) {
            if (
                $entry -and
                $entry.Trim().Equals(
                    $selectedTimeZone,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $timeZoneIsValid = $true
                break
            }
        }

        if (-not $timeZoneIsValid) {
            Write-LauncherLog "WARN: '$selectedTimeZone' is not a recognized Windows time zone ID. Keeping the current time zone."
            return
        }

        $setTimeZoneOutput = & $TzUtilExe /s $selectedTimeZone 2>&1
        $setTimeZoneExitCode = $LASTEXITCODE

        if ($setTimeZoneExitCode -eq 0) {
            Write-LauncherLog "Windows time zone applied successfully: $selectedTimeZone"
        }
        else {
            $outputText = ($setTimeZoneOutput | Out-String).Trim()

            if ([string]::IsNullOrWhiteSpace($outputText)) {
                $outputText = "No additional output."
            }

            Write-LauncherLog "WARN: tzutil failed to apply '$selectedTimeZone' with exit code $setTimeZoneExitCode. $outputText"
        }
    }
    catch {
        Write-LauncherLog "WARN: Unexpected error while applying the selected time zone: $($_.Exception.Message)"
    }
}

function Enable-SCOSTimeSynchronization {
    Write-LauncherLog "Configuring Windows internet clock synchronization."

    try {
        Set-Service `
            -Name "w32time" `
            -StartupType Automatic `
            -ErrorAction Stop

        Write-LauncherLog "Windows Time service startup type set to Automatic."
    }
    catch {
        Write-LauncherLog "WARN: Could not set Windows Time service startup type: $($_.Exception.Message)"
    }

    try {
        $timeService = Get-Service -Name "w32time" -ErrorAction Stop

        if ($timeService.Status -ne "Running") {
            Start-Service -Name "w32time" -ErrorAction Stop
            Write-LauncherLog "Windows Time service started."
        }
        else {
            Write-LauncherLog "Windows Time service is already running."
        }
    }
    catch {
        Write-LauncherLog "WARN: Could not start Windows Time service: $($_.Exception.Message)"
    }

    $W32tmExe = Join-Path $env:SystemRoot "System32\w32tm.exe"

    if (-not (Test-Path $W32tmExe)) {
        Write-LauncherLog "WARN: w32tm.exe was not found. Internet clock synchronization was skipped."
        return
    }

    try {
        $configOutput = & $W32tmExe `
            /config `
            '/manualpeerlist:time.windows.com,0x9 pool.ntp.org,0x9' `
            /syncfromflags:manual `
            /reliable:no `
            /update 2>&1

        $configExitCode = $LASTEXITCODE

        if ($configExitCode -eq 0) {
            Write-LauncherLog "Windows Time peers configured successfully."
        }
        else {
            $outputText = ($configOutput | Out-String).Trim()

            if ([string]::IsNullOrWhiteSpace($outputText)) {
                $outputText = "No additional output."
            }

            Write-LauncherLog "WARN: Windows Time peer configuration exited with code $configExitCode. $outputText"
        }
    }
    catch {
        Write-LauncherLog "WARN: Failed to configure Windows Time peers: $($_.Exception.Message)"
    }

    try {
        Restart-Service -Name "w32time" -Force -ErrorAction Stop
        Write-LauncherLog "Windows Time service restarted."
    }
    catch {
        Write-LauncherLog "WARN: Could not restart Windows Time service: $($_.Exception.Message)"
    }

    try {
        $resyncOutput = & $W32tmExe /resync /force 2>&1
        $resyncExitCode = $LASTEXITCODE
        $resyncText = ($resyncOutput | Out-String).Trim()

        if ($resyncExitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($resyncText)) {
                Write-LauncherLog "Internet clock synchronization completed successfully."
            }
            else {
                Write-LauncherLog "Internet clock synchronization completed successfully: $resyncText"
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($resyncText)) {
                $resyncText = "The network or time server may not be available yet."
            }

            Write-LauncherLog "WARN: Internet clock synchronization could not be completed. Setup will continue. Exit code: $resyncExitCode. $resyncText"
        }
    }
    catch {
        Write-LauncherLog "WARN: Internet clock synchronization failed. Setup will continue. $($_.Exception.Message)"
    }
}

Write-LauncherLog "SCOS first-login setup launcher started."
Write-LauncherLog "Received ScriptsRoot parameter: $ScriptsRoot"
Write-LauncherLog "Received Edition parameter: $Edition"
Write-LauncherLog "Received Lockdown parameter: $Lockdown"

# Read SetupComplete state files as the trusted fallback/source of truth.
if (Test-Path $EditionFile) {
    try {
        $fileEdition = (Get-Content $EditionFile -Raw).Trim()

        if (-not [string]::IsNullOrWhiteSpace($fileEdition)) {
            Write-LauncherLog "Read edition from file: $fileEdition"
            $Edition = $fileEdition
        }
    }
    catch {
        Write-LauncherLog "WARN: Failed to read edition file: $($_.Exception.Message)"
    }
}
else {
    Write-LauncherLog "WARN: Edition file missing. Using current/default edition: $Edition"
}

if (Test-Path $LockdownFile) {
    try {
        $fileLockdownRaw = (Get-Content $LockdownFile -Raw).Trim()
        $fileLockdown = 1

        if ([int]::TryParse($fileLockdownRaw, [ref]$fileLockdown)) {
            Write-LauncherLog "Read lockdown from file: $fileLockdown"
            $Lockdown = $fileLockdown
        }
        else {
            Write-LauncherLog "WARN: Lockdown file contained an invalid value. Using current/default lockdown: $Lockdown"
        }
    }
    catch {
        Write-LauncherLog "WARN: Failed to read lockdown file: $($_.Exception.Message)"
    }
}
else {
    Write-LauncherLog "WARN: Lockdown file missing. Using current/default lockdown: $Lockdown"
}

$normalized = Normalize-SCOSEdition -RawEdition $Edition -RawLockdown $Lockdown
$Edition = $normalized.Edition
$Lockdown = $normalized.Lockdown

Write-LauncherLog "Final normalized Edition: $Edition"
Write-LauncherLog "Final normalized Lockdown: $Lockdown"
Write-LauncherLog "ScriptsRoot: $ScriptsRoot"
Write-LauncherLog "Setup UI: $SetupUi"

# Apply the SCOS Builder-selected time zone.
# All failures are non-fatal and setup continues.
Set-SCOSTimeZone

# Enable internet time and attempt an immediate synchronization.
# A missing network connection or unavailable time server must never fail setup.
Enable-SCOSTimeSynchronization

if (-not (Test-Path $SetupUi)) {
    Write-LauncherLog "ERROR: SCOS setup UI missing: $SetupUi"
    exit 1
}

$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

$ArgumentList = @(
    "-STA",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "`"$SetupUi`"",
    "-ScriptsRoot",
    "`"$ScriptsRoot`"",
    "-Edition",
    "`"$Edition`"",
    "-Lockdown",
    "$Lockdown"
)

try {
    Write-LauncherLog "Launching SCOS setup UI elevated in visible user session..."
    Write-LauncherLog "Passing Edition to UI: $Edition"
    Write-LauncherLog "Passing Lockdown to UI: $Lockdown"

    $process = Start-Process `
        -FilePath $PowerShellExe `
        -ArgumentList $ArgumentList `
        -Verb RunAs `
        -Wait `
        -PassThru

    Write-LauncherLog "SCOS setup UI exited with code $($process.ExitCode)."

    exit $process.ExitCode
}
catch {
    Write-LauncherLog "ERROR: Failed to launch elevated SCOS setup UI: $($_.Exception.Message)"
    exit 1
}