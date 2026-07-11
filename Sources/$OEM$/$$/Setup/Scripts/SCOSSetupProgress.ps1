param(
    [string]$ScriptsRoot = $PSScriptRoot,
    [string]$Edition = "Standard",
    [int]$Lockdown = 1
)

# Normalize SCOS edition/lockdown one last time for safety.
# Standard  = Lockdown 1
# Developer = Lockdown 0

if ($Edition -and $Edition.Trim().Equals("Developer", [System.StringComparison]::OrdinalIgnoreCase)) {
    $Edition = "Developer"
    $Lockdown = 0
}
elseif ($Edition -and $Edition.Trim().Equals("Standard", [System.StringComparison]::OrdinalIgnoreCase)) {
    $Edition = "Standard"
    $Lockdown = 1
}
elseif ($Lockdown -eq 0) {
    $Edition = "Developer"
    $Lockdown = 0
}
else {
    $Edition = "Standard"
    $Lockdown = 1
}

# SCOS Setup Progress UI
# SCOS v0.3.6.5 Production Installer
# Called by SetupComplete.cmd
#
# Production behavior:
# - Production mode only, no demo/simulation behavior
# - Downloads third-party installers from official servers during setup
# - Checks that the setup UI is running as administrator
# - Installs Visual C++ Redistributable x64 + x86 before Steam/EA/Unified Remote
# - Downloads, installs, and verifies Steam, EA App, and Unified Remote
# - Applies SCOS settings and shell
# - Restores temporary UAC changes before finishing or failing
# - Reboots after countdown
# - Clean failure handling without ugly WinForms unhandled exception popup

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# App Settings
# -----------------------------

$AppVersion = "v0.3.6.5"
$LogPath = "C:\SCOS\Logs\SCOSSetup.log"
$SetupCompleteLog = "C:\SetupComplete.log"

$StepDelaySeconds = 2
$RestartCountdownSeconds = 10

$IsStandardLockdown = ($Lockdown -eq 1)

$script:SetupExitCode = 0
$script:AllowFormClose = $false
$script:SetupHasFailed = $false
$script:UACRestored = $false
$script:RestartButton = $null
$script:ShowDetailsButton = $null
$script:MainDetailsButton = $null

# -----------------------------
# Paths
# -----------------------------

$SteamExe = "C:\Program Files (x86)\Steam\Steam.exe"
$EAExe = "C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe"

# SCOS v0.3.6:
# Third-party installers are downloaded during setup instead of being bundled in the ISO.
# This keeps SCOS cleaner for beta distribution and avoids redistributing third-party installers.
$SCOSDownloadsFolder = "C:\SCOS\Downloads"

$SteamInstaller = Join-Path $SCOSDownloadsFolder "SteamSetup.exe"
$EAInstaller = Join-Path $SCOSDownloadsFolder "EAappInstaller.exe"
$UnifiedRemoteInstaller = Join-Path $SCOSDownloadsFolder "UnifiedRemoteSetup.exe"

$SteamInstallerUrl = "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
$EAInstallerUrl = "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe"
$UnifiedRemoteInstallerUrl = "https://www.unifiedremote.com/download/windows-setup"

$DisableControllerAudioScript = Join-Path $ScriptsRoot "disable-controller-audio.ps1"
$SteamCursorGuard = Join-Path $ScriptsRoot "SteamCursorGuard.exe"

# SCOS Recovery Environment payload
# The Builder/ISO source should provide:
# C:\Windows\Setup\Scripts\Recovery\SCOSRecovery.wim
$SCOSRecoverySourceFolder = Join-Path $ScriptsRoot "Recovery"
$SCOSRecoverySourceWim = Join-Path $SCOSRecoverySourceFolder "SCOSRecovery.wim"
$SCOSRecoveryFallbackSourceWim = Join-Path $ScriptsRoot "SCOSRecovery.wim"
$SCOSRecoveryTargetFolder = "C:\SCOS\Recovery"
$SCOSRecoveryTargetWim = Join-Path $SCOSRecoveryTargetFolder "SCOSRecovery.wim"
$SCOSRecoveryTargetBootSdi = Join-Path $SCOSRecoveryTargetFolder "boot.sdi"


# Visual C++ Redistributable
# If vc_redist.x64.exe / vc_redist.x86.exe are bundled in C:\Windows\Setup\Scripts, SCOS uses them.
# Otherwise, SCOS downloads the latest supported versions from Microsoft.
$VCRedistX64BundledInstaller = Join-Path $ScriptsRoot "vc_redist.x64.exe"
$VCRedistX86BundledInstaller = Join-Path $ScriptsRoot "vc_redist.x86.exe"

$VCRedistX64DownloadedInstaller = "C:\SCOS\Downloads\vc_redist.x64.exe"
$VCRedistX86DownloadedInstaller = "C:\SCOS\Downloads\vc_redist.x86.exe"

$VCRedistX64Url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
$VCRedistX86Url = "https://aka.ms/vs/17/release/vc_redist.x86.exe"

# UAC backup files created by SetupComplete.cmd
$UACConsentBackup = "C:\SCOS\Setup\UAC_ConsentPromptBehaviorAdmin.old"
$UACSecureDesktopBackup = "C:\SCOS\Setup\UAC_PromptOnSecureDesktop.old"

# Local SCOS account security
# Autounattend.xml uses a temporary bootstrap password.
# SCOS v0.3.6.5 replaces it with a unique generated password during final setup.
$SCOSLocalUserName = "SCOS"
$SCOSGeneratedPasswordPath = "C:\SCOS\Setup\SCOS_LocalPassword.generated"
$SCOSGeneratedPasswordLogPath = "C:\SCOS\Logs\SCOS_LocalPassword.generated.txt"


# -----------------------------
# Folders
# -----------------------------

New-Item -ItemType Directory -Path "C:\SCOS" -Force | Out-Null
New-Item -ItemType Directory -Path $SCOSDownloadsFolder -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SCOS\Downloads" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SCOS\Logs" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SCOS\Scripts" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SCOS\Recovery" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SteamShell" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SteamConsole" -Force | Out-Null

# -----------------------------
# Logging
# -----------------------------

function Write-SCOSLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message

    Add-Content -Path $LogPath -Value $line
    Add-Content -Path $SetupCompleteLog -Value $line
}

function Wait-ForPath {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 120,
        [string]$Description = "file"
    )

    Add-UILog "Waiting for $Description..."

    $elapsed = 0

    while ($elapsed -lt $TimeoutSeconds) {
        if (Test-Path $Path) {
            Add-UILog "$Description found: $Path"
            return $true
        }

        Start-Sleep -Seconds 2
        $elapsed += 2

        $currentStepLabel.Text = "Waiting for $Description... $elapsed / $TimeoutSeconds seconds"
        [System.Windows.Forms.Application]::DoEvents()
    }

    return $false
}

function Invoke-LoggedProcess {
    param(
        [string]$FilePath,
        [string]$Arguments = "",
        [string]$Description = "",
        [int[]]$AcceptableExitCodes = @(0, 3010, 1641),
        [int]$TimeoutSeconds = 0
    )

    if ($Description) {
        Add-UILog $Description
    }

    if (-not (Test-Path $FilePath)) {
        throw "Installer not found: $FilePath"
    }

    Add-UILog "Running: $FilePath $Arguments"

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -PassThru

    if ($TimeoutSeconds -gt 0) {
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            Add-UILog "WARN: Process timed out after $TimeoutSeconds seconds: $FilePath"

            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                Add-UILog "Timed-out process was terminated."
            }
            catch {
                Add-UILog "WARN: Failed to terminate timed-out process: $($_.Exception.Message)"
            }

            return 999
        }
    }
    else {
        $process.WaitForExit()
    }

    Add-UILog "Process exited with code: $($process.ExitCode)"

    if ($AcceptableExitCodes -notcontains $process.ExitCode) {
        throw "Installer returned unexpected exit code: $($process.ExitCode)"
    }

    return $process.ExitCode
}


function Invoke-SCOSDownload {
    param(
        [string]$Name,
        [string]$Url,
        [string]$OutputPath
    )

    if (Test-Path $OutputPath) {
        try {
            $existingItem = Get-Item -Path $OutputPath -ErrorAction Stop
            if ($existingItem.Length -gt 0) {
                Add-UILog "$Name installer already downloaded: $OutputPath"
                return $OutputPath
            }
        }
        catch {
            Add-UILog "WARN: Could not inspect existing $Name installer. It will be downloaded again."
        }
    }

    Add-UILog "Downloading $Name from official server..."
    Add-UILog "Source: $Url"

    New-Item -ItemType Directory -Path (Split-Path -Path $OutputPath -Parent) -Force | Out-Null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to download ${Name}: $($_.Exception.Message)"
    }

    if (-not (Test-Path $OutputPath)) {
        throw "$Name download failed. Installer was not found: $OutputPath"
    }

    $downloadedItem = Get-Item -Path $OutputPath -ErrorAction SilentlyContinue
    if (-not $downloadedItem -or $downloadedItem.Length -le 0) {
        throw "$Name download failed. Installer file is empty: $OutputPath"
    }

    $sizeMb = [Math]::Round(($downloadedItem.Length / 1MB), 2)
    Add-UILog "$Name downloaded successfully: $OutputPath ($sizeMb MB)"

    return $OutputPath
}

function Set-RegDword {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegString {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Load-DefaultUserHive {
    reg.exe LOAD HKU\DefUser "C:\Users\Default\NTUSER.DAT" *> $null
}

function Unload-DefaultUserHive {
    reg.exe UNLOAD HKU\DefUser *> $null
}

function Find-UnifiedRemoteExe {
    $possiblePaths = @(
        "C:\Program Files (x86)\Unified Remote\RemoteServerWin.exe",
        "C:\Program Files\Unified Remote\RemoteServerWin.exe",
        "C:\Program Files (x86)\Unified Remote 3\RemoteServerWin.exe",
        "C:\Program Files\Unified Remote 3\RemoteServerWin.exe"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Convert-RegistryDwordTextToInt {
    param(
        [string]$Text,
        [int]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $DefaultValue
    }

    $clean = $Text.Trim()

    try {
        if ($clean.StartsWith("0x")) {
            return [Convert]::ToInt32($clean, 16)
        }

        return [int]$clean
    }
    catch {
        return $DefaultValue
    }
}

function Restore-UACSettings {
    if ($script:UACRestored) {
        return
    }

    $script:UACRestored = $true

    try {
        Add-UILog "Restoring UAC prompt settings..."

        $consentValue = 5
        $secureDesktopValue = 1

        if (Test-Path $UACConsentBackup) {
            $consentRaw = Get-Content -Path $UACConsentBackup -ErrorAction SilentlyContinue | Select-Object -First 1
            $consentValue = Convert-RegistryDwordTextToInt -Text $consentRaw -DefaultValue 5
        }

        if (Test-Path $UACSecureDesktopBackup) {
            $secureRaw = Get-Content -Path $UACSecureDesktopBackup -ErrorAction SilentlyContinue | Select-Object -First 1
            $secureDesktopValue = Convert-RegistryDwordTextToInt -Text $secureRaw -DefaultValue 1
        }

        Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ConsentPromptBehaviorAdmin" $consentValue
        Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "PromptOnSecureDesktop" $secureDesktopValue

        Add-UILog "UAC settings restored. ConsentPromptBehaviorAdmin=$consentValue, PromptOnSecureDesktop=$secureDesktopValue"
    }
    catch {
        Add-UILog "WARN: Failed to restore UAC settings: $($_.Exception.Message)"
    }
}

# -----------------------------
# Screen
# -----------------------------

$ScreenBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$ScreenWidth = $ScreenBounds.Width
$ScreenHeight = $ScreenBounds.Height

# -----------------------------
# Colors / Fonts
# -----------------------------

$ColorBackground = [System.Drawing.Color]::FromArgb(6, 15, 28)
$ColorPanel = [System.Drawing.Color]::FromArgb(10, 28, 50)
$ColorPanel2 = [System.Drawing.Color]::FromArgb(7, 22, 39)
$ColorAccent = [System.Drawing.Color]::FromArgb(0, 132, 255)
$ColorText = [System.Drawing.Color]::White
$ColorMuted = [System.Drawing.Color]::FromArgb(190, 205, 220)
$ColorSuccess = [System.Drawing.Color]::FromArgb(80, 220, 140)
$ColorWarning = [System.Drawing.Color]::FromArgb(255, 190, 90)
$ColorCountdownBack = [System.Drawing.Color]::FromArgb(45, 10, 15)
$ColorCountdownFill = [System.Drawing.Color]::FromArgb(220, 40, 55)

$FontLogo = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
$FontTitle = New-Object System.Drawing.Font("Segoe UI", 26, [System.Drawing.FontStyle]::Bold)
$FontSubtitle = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular)
$FontStep = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$FontSmall = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
$FontLog = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Regular)

# -----------------------------
# Main Form
# -----------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "SCOS $Edition Setup"
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(0, 0)
$form.Size = New-Object System.Drawing.Size($ScreenWidth, $ScreenHeight)
$form.FormBorderStyle = "None"
$form.WindowState = "Maximized"
$form.TopMost = $true
$form.BackColor = $ColorBackground
$form.KeyPreview = $true

$form.Add_FormClosing({
    if (-not $script:AllowFormClose -and $_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $_.Cancel = $true
    }
})

# -----------------------------
# Header
# -----------------------------

$logo = New-Object System.Windows.Forms.Label
$logo.Text = "SCOS"
$logo.Location = New-Object System.Drawing.Point(70, 55)
$logo.Size = New-Object System.Drawing.Size(240, 60)
$logo.ForeColor = $ColorText
$logo.Font = $FontLogo
$form.Controls.Add($logo)

$editionLabel = New-Object System.Windows.Forms.Label
$editionLabel.Text = "$($Edition.ToUpper()) SETUP"
$editionLabel.Location = New-Object System.Drawing.Point(78, 112)
$editionLabel.Size = New-Object System.Drawing.Size(300, 28)
$editionLabel.ForeColor = [System.Drawing.Color]::FromArgb(130, 190, 255)
$editionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($editionLabel)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Installing SCOS $Edition"
$title.Location = New-Object System.Drawing.Point(70, 185)
$title.Size = New-Object System.Drawing.Size(800, 55)
$title.ForeColor = $ColorText
$title.Font = $FontTitle
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Please do not turn off your computer. SCOS is configuring the console environment."
$subtitle.Location = New-Object System.Drawing.Point(74, 242)
$subtitle.Size = New-Object System.Drawing.Size(900, 35)
$subtitle.ForeColor = $ColorMuted
$subtitle.Font = $FontSubtitle
$form.Controls.Add($subtitle)

$version = New-Object System.Windows.Forms.Label
$version.Text = "SCOS $Edition`n$AppVersion"
$version.Location = New-Object System.Drawing.Point(($ScreenWidth - 260), 65)
$version.Size = New-Object System.Drawing.Size(190, 60)
$version.ForeColor = $ColorMuted
$version.Font = $FontSmall
$form.Controls.Add($version)

# -----------------------------
# Progress Panel
# -----------------------------

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(70, 310)
$panel.Size = New-Object System.Drawing.Size(($ScreenWidth - 140), 150)
$panel.BackColor = $ColorPanel
$form.Controls.Add($panel)

$currentStepLabel = New-Object System.Windows.Forms.Label
$currentStepLabel.Text = "Preparing setup..."
$currentStepLabel.Location = New-Object System.Drawing.Point(35, 25)
$currentStepLabel.Size = New-Object System.Drawing.Size(($panel.Width - 70), 35)
$currentStepLabel.ForeColor = $ColorText
$currentStepLabel.Font = $FontStep
$panel.Controls.Add($currentStepLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(35, 75)
$progressBar.Size = New-Object System.Drawing.Size(($panel.Width - 70), 28)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$panel.Controls.Add($progressBar)

$percentLabel = New-Object System.Windows.Forms.Label
$percentLabel.Text = "0%"
$percentLabel.Location = New-Object System.Drawing.Point(35, 112)
$percentLabel.Size = New-Object System.Drawing.Size(150, 25)
$percentLabel.ForeColor = $ColorMuted
$percentLabel.Font = $FontSmall
$panel.Controls.Add($percentLabel)

# -----------------------------
# Restart Countdown Bar
# -----------------------------

$countdownPanel = New-Object System.Windows.Forms.Panel
$countdownPanel.Location = New-Object System.Drawing.Point(70, 468)
$countdownPanel.Size = New-Object System.Drawing.Size(($ScreenWidth - 140), 14)
$countdownPanel.BackColor = $ColorCountdownBack
$countdownPanel.Visible = $false
$form.Controls.Add($countdownPanel)

$countdownFill = New-Object System.Windows.Forms.Panel
$countdownFill.Location = New-Object System.Drawing.Point(0, 0)
$countdownFill.Size = New-Object System.Drawing.Size(0, 14)
$countdownFill.BackColor = $ColorCountdownFill
$countdownPanel.Controls.Add($countdownFill)

# -----------------------------
# Step List
# -----------------------------

$stepsPanel = New-Object System.Windows.Forms.Panel
$stepsPanel.Location = New-Object System.Drawing.Point(70, 500)
$stepsPanel.Size = New-Object System.Drawing.Size(470, ($ScreenHeight - 585))
$stepsPanel.BackColor = $ColorPanel2
$form.Controls.Add($stepsPanel)

$stepsTitle = New-Object System.Windows.Forms.Label
$stepsTitle.Text = "Installation Steps"
$stepsTitle.Location = New-Object System.Drawing.Point(25, 20)
$stepsTitle.Size = New-Object System.Drawing.Size(300, 30)
$stepsTitle.ForeColor = $ColorText
$stepsTitle.Font = $FontStep
$stepsPanel.Controls.Add($stepsTitle)

$stepLabels = @()

$StepNames = @(
    "Prepare online installers",
    "Apply early protection",
    "Check internet connection",
    "Install Visual C++ Runtime",
    "Install Steam",
    "Install EA App",
    "Install Unified Remote",
    "Apply SCOS system settings",
    "Configure Steam shell",
    "Apply Standard lockdown",
    "Finalize installation"
)

for ($i = 0; $i -lt $StepNames.Count; $i++) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "[ ] " + $StepNames[$i]
    $label.Location = New-Object System.Drawing.Point(30, (65 + ($i * 34)))
    $label.Size = New-Object System.Drawing.Size(410, 28)
    $label.ForeColor = $ColorMuted
    $label.Font = $FontSmall
    $stepsPanel.Controls.Add($label)
    $stepLabels += $label
}

# -----------------------------
# Log Panel
# -----------------------------

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Location = New-Object System.Drawing.Point(565, 500)
$logPanel.Size = New-Object System.Drawing.Size(($ScreenWidth - 635), ($ScreenHeight - 585))
$logPanel.BackColor = $ColorPanel2
$form.Controls.Add($logPanel)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "Setup Log"
$logTitle.Location = New-Object System.Drawing.Point(25, 20)
$logTitle.Size = New-Object System.Drawing.Size(300, 30)
$logTitle.ForeColor = $ColorText
$logTitle.Font = $FontStep
$logPanel.Controls.Add($logTitle)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(25, 60)
$logBox.Size = New-Object System.Drawing.Size(($logPanel.Width - 50), ($logPanel.Height - 85))
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.BackColor = [System.Drawing.Color]::FromArgb(3, 10, 20)
$logBox.ForeColor = $ColorMuted
$logBox.Font = $FontLog
$logPanel.Controls.Add($logBox)

# In Standard edition, hide the detailed setup log by default for a cleaner console-style setup screen.
# Developer edition keeps the log visible by default for debugging.
$logPanel.Visible = (-not $IsStandardLockdown)

$mainDetailsButton = New-Object System.Windows.Forms.Button
if ($logPanel.Visible) {
    $mainDetailsButton.Text = "Hide Details"
}
else {
    $mainDetailsButton.Text = "Show Details"
}
$mainDetailsButton.Size = New-Object System.Drawing.Size(180, 38)
$mainDetailsButton.Location = New-Object System.Drawing.Point(($ScreenWidth - 250), ($ScreenHeight - 95))
$mainDetailsButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$mainDetailsButton.BackColor = $ColorPanel2
$mainDetailsButton.ForeColor = [System.Drawing.Color]::White
$mainDetailsButton.FlatStyle = "Flat"
$mainDetailsButton.Add_Click({
    $logPanel.Visible = -not $logPanel.Visible

    if ($logPanel.Visible) {
        $script:MainDetailsButton.Text = "Hide Details"
    }
    else {
        $script:MainDetailsButton.Text = "Show Details"
    }

    [System.Windows.Forms.Application]::DoEvents()
})
$form.Controls.Add($mainDetailsButton)
$script:MainDetailsButton = $mainDetailsButton


# -----------------------------
# Footer
# -----------------------------

$footer = New-Object System.Windows.Forms.Label
$footer.Text = "SCOS setup is running. The system may restart automatically when finished."
$footer.Location = New-Object System.Drawing.Point(70, ($ScreenHeight - 55))
$footer.Size = New-Object System.Drawing.Size(($ScreenWidth - 140), 30)
$footer.ForeColor = $ColorMuted
$footer.Font = $FontSmall
$form.Controls.Add($footer)

# -----------------------------
# UI Helpers
# -----------------------------

function Add-UILog {
    param([string]$Message)

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"

    $logBox.AppendText($line + [Environment]::NewLine)
    Write-SCOSLog $Message

    [System.Windows.Forms.Application]::DoEvents()
}

function Set-StepStatus {
    param(
        [int]$Index,
        [string]$Status
    )

    if ($Status -eq "Running") {
        $stepLabels[$Index].Text = "[*] " + $StepNames[$Index]
        $stepLabels[$Index].ForeColor = $ColorAccent
    }
    elseif ($Status -eq "Done") {
        $stepLabels[$Index].Text = "[OK] " + $StepNames[$Index]
        $stepLabels[$Index].ForeColor = $ColorSuccess
    }
    elseif ($Status -eq "Warning") {
        $stepLabels[$Index].Text = "[!] " + $StepNames[$Index]
        $stepLabels[$Index].ForeColor = $ColorWarning
    }
    elseif ($Status -eq "Skipped") {
        $stepLabels[$Index].Text = "[-] " + $StepNames[$Index]
        $stepLabels[$Index].ForeColor = $ColorMuted
    }
    else {
        $stepLabels[$Index].Text = "[ ] " + $StepNames[$Index]
        $stepLabels[$Index].ForeColor = $ColorMuted
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress {
    param(
        [int]$Value,
        [string]$Text
    )

    if ($Value -lt 0) { $Value = 0 }
    if ($Value -gt 100) { $Value = 100 }

    $progressBar.Value = $Value
    $percentLabel.Text = "$Value%"
    $currentStepLabel.Text = $Text

    [System.Windows.Forms.Application]::DoEvents()
}


function Enter-SCOSErrorLayout {
    param(
        [string]$MainMessage,
        [string]$FooterMessage = ""
    )

    # Fatal/error state:
    # The setup cannot continue, so the progress UI must disappear completely.
    # This prevents action buttons from visually colliding with the progress bar.
    try {
        $progressBar.Visible = $false
        $percentLabel.Visible = $false

        if ($panel.Controls.Contains($progressBar)) {
            $panel.Controls.Remove($progressBar)
        }

        if ($panel.Controls.Contains($percentLabel)) {
            $panel.Controls.Remove($percentLabel)
        }
    }
    catch {
        Add-UILog "WARN: Failed to remove progress controls from error layout: $($_.Exception.Message)"
    }

    $currentStepLabel.Location = New-Object System.Drawing.Point(35, 22)
    $currentStepLabel.Size = New-Object System.Drawing.Size(($panel.Width - 70), 56)
    $currentStepLabel.Text = $MainMessage

    if (-not [string]::IsNullOrWhiteSpace($FooterMessage)) {
        $footer.Text = $FooterMessage
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Fail-SCOSSetup {
    param(
        [string]$Message
    )

    if ($script:SetupHasFailed) {
        return
    }

    $script:SetupHasFailed = $true
    $script:SetupExitCode = 1

    Add-UILog "SETUP FAILED: $Message"

    Restore-UACSettings

    Enter-SCOSErrorLayout `
        -MainMessage "SCOS setup failed." `
        -FooterMessage "Setup stopped. Check C:\SCOS\Logs\SCOSSetup.log and C:\SetupComplete.log."

    [System.Windows.Forms.Application]::DoEvents()

    Start-Sleep -Seconds 30

    $script:AllowFormClose = $true
    $form.Close()
}


function Stop-SCOSSetupForNetworkRequired {
    param(
        [string]$Message = "Internet connection was not detected."
    )

    if ($script:SetupHasFailed) {
        return
    }

    $script:SetupHasFailed = $true
    $script:SetupExitCode = 2

    Add-UILog "SETUP STOPPED: Network connection required."
    Add-UILog $Message
    Add-UILog "Please connect this console using an Ethernet cable, then restart the installation."

    Restore-UACSettings

    Set-Progress -Value 0 -Text "SCOS setup cannot continue."

    $title.Text = "SCOS Setup Cannot Continue"
    $subtitle.Text = "An internet connection is required to download required setup components."

    Enter-SCOSErrorLayout `
        -MainMessage "Please connect this console using an Ethernet cable.`r`nAfter connecting Ethernet, restart the installation." `
        -FooterMessage "Wi-Fi setup is not available in this version of SCOS."

    $logBox.AppendText([Environment]::NewLine)
    $logBox.AppendText("SCOS Setup Cannot Continue" + [Environment]::NewLine)
    $logBox.AppendText("An internet connection is required to download required setup components." + [Environment]::NewLine)
    $logBox.AppendText("Please connect this console using an Ethernet cable." + [Environment]::NewLine)
    $logBox.AppendText("After connecting Ethernet, restart the installation." + [Environment]::NewLine)
    $logBox.AppendText("Wi-Fi setup is not available in this version of SCOS." + [Environment]::NewLine)

    # Keep the error screen simple by hiding logs until the user asks for details.
    $logPanel.Visible = $false

    if (-not $script:RestartButton) {
        $restartButton = New-Object System.Windows.Forms.Button
        $restartButton.Text = "Restart Installation"
        $restartButton.Size = New-Object System.Drawing.Size(250, 48)
        $restartButton.Location = New-Object System.Drawing.Point(35, 92)
        $restartButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $restartButton.BackColor = $ColorAccent
        $restartButton.ForeColor = [System.Drawing.Color]::White
        $restartButton.FlatStyle = "Flat"

        $restartButton.Add_Click({
            Add-UILog "Restart Installation button clicked. Restarting system..."
            Start-Process "shutdown.exe" -ArgumentList "/r /t 0" -WindowStyle Hidden
        })

        $panel.Controls.Add($restartButton)
        $script:RestartButton = $restartButton
    }

    if (-not $script:ShowDetailsButton) {
        $showDetailsButton = New-Object System.Windows.Forms.Button
        $showDetailsButton.Text = "Show Details"
        $showDetailsButton.Size = New-Object System.Drawing.Size(190, 48)
        $showDetailsButton.Location = New-Object System.Drawing.Point(305, 92)
        $showDetailsButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $showDetailsButton.BackColor = $ColorPanel2
        $showDetailsButton.ForeColor = [System.Drawing.Color]::White
        $showDetailsButton.FlatStyle = "Flat"

        $showDetailsButton.Add_Click({
            $logPanel.Visible = -not $logPanel.Visible

            if ($logPanel.Visible) {
                $script:ShowDetailsButton.Text = "Hide Details"
            }
            else {
                $script:ShowDetailsButton.Text = "Show Details"
            }

            [System.Windows.Forms.Application]::DoEvents()
        })

        $panel.Controls.Add($showDetailsButton)
        $script:ShowDetailsButton = $showDetailsButton
    }

    $script:RestartButton.Visible = $true
    $script:RestartButton.BringToFront()

    $script:ShowDetailsButton.Visible = $true
    $script:ShowDetailsButton.BringToFront()

    [System.Windows.Forms.Application]::DoEvents()

    while ($script:SetupHasFailed -and -not $script:AllowFormClose) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    }
}

function Run-Step {
    param(
        [int]$Index,
        [int]$Progress,
        [string]$Message,
        [scriptblock]$Action
    )

    Set-StepStatus -Index $Index -Status "Running"
    Set-Progress -Value $Progress -Text $Message
    Add-UILog $Message

    try {
        & $Action

        if ($script:SetupHasFailed) {
            return
        }

        Set-StepStatus -Index $Index -Status "Done"
        Add-UILog "Completed: $($StepNames[$Index])"
    }
    catch {
        Set-StepStatus -Index $Index -Status "Warning"
        Fail-SCOSSetup "Error in $($StepNames[$Index]): $($_.Exception.Message)"
        return
    }

    Start-Sleep -Seconds $StepDelaySeconds
}

function Start-RestartCountdown {
    param(
        [int]$Seconds = 10
    )

    $countdownPanel.Visible = $true
    $countdownFill.Width = 0

    for ($i = $Seconds; $i -ge 1; $i--) {
        $elapsed = $Seconds - $i + 1
        $progressRatio = $elapsed / $Seconds
        $countdownFill.Width = [int]($countdownPanel.Width * $progressRatio)

        $currentStepLabel.Text = "SCOS setup complete. Restarting in $i seconds..."
        $footer.Text = "Setup complete. The system will restart automatically in $i seconds."

        Add-UILog "Restarting in $i seconds..."

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
    }

    $countdownFill.Width = $countdownPanel.Width
    [System.Windows.Forms.Application]::DoEvents()
}

# -----------------------------
# SCOS Install Functions
# -----------------------------

function Check-SCOSSetupResources {
    Add-UILog "Preparing SCOS online installer system..."
    Add-UILog "Third-party installers will be downloaded during setup from official servers."

    New-Item -ItemType Directory -Path $SCOSDownloadsFolder -Force | Out-Null
    Add-UILog "Download folder ready: $SCOSDownloadsFolder"

    Add-UILog "Steam installer source: $SteamInstallerUrl"
    Add-UILog "EA App installer source: $EAInstallerUrl"
    Add-UILog "Unified Remote installer source: $UnifiedRemoteInstallerUrl"
    Add-UILog "Visual C++ x64 source: $VCRedistX64Url"
    Add-UILog "Visual C++ x86 source: $VCRedistX86Url"

    $optionalFiles = @(
        "disable-controller-audio.ps1",
        "SteamCursorGuard.exe"
    )

    foreach ($file in $optionalFiles) {
        $source = Join-Path $ScriptsRoot $file
        if (Test-Path $source) {
            Add-UILog "Found optional SCOS script/tool: $source"
        }
        else {
            Add-UILog "WARN: Optional SCOS script/tool missing: $file"
        }
    }

    if (Test-Path $SCOSRecoverySourceWim) {
        Add-UILog "Found SCOS Recovery image: $SCOSRecoverySourceWim"
    }
    elseif (Test-Path $SCOSRecoveryFallbackSourceWim) {
        Add-UILog "Found SCOS Recovery image using fallback path: $SCOSRecoveryFallbackSourceWim"
    }
    else {
        Add-UILog "WARN: SCOS Recovery image missing. Recovery integration will be skipped for this build."
        Add-UILog "Expected primary: $SCOSRecoverySourceWim"
        Add-UILog "Expected fallback: $SCOSRecoveryFallbackSourceWim"
    }
}



function Test-SCOSInternetConnection {
    Add-UILog "Checking internet connection..."

    $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq "Up" -and
            $_.InterfaceDescription -notmatch "Bluetooth|Loopback|Virtual|VMware|Hyper-V|Tailscale|WireGuard|VPN"
        }

    $ethernetAdapter = $activeAdapters |
        Where-Object {
            $_.NdisPhysicalMedium -eq 14 -or
            $_.Name -match "Ethernet" -or
            $_.InterfaceDescription -match "Ethernet|Realtek|Intel|LAN|GbE|2.5G"
        } |
        Select-Object -First 1

    if ($ethernetAdapter) {
        Add-UILog "Active Ethernet adapter detected: $($ethernetAdapter.Name) - $($ethernetAdapter.InterfaceDescription)"
    }
    elseif ($activeAdapters) {
        $firstAdapter = $activeAdapters | Select-Object -First 1
        Add-UILog "Active network adapter detected: $($firstAdapter.Name) - $($firstAdapter.InterfaceDescription)"
        Add-UILog "WARN: Ethernet-specific adapter could not be confirmed. Internet reachability will still be tested."
    }
    else {
        Add-UILog "WARN: No active network adapter detected."
    }

    $testTargets = @(
        "aka.ms",
        "store.steampowered.com",
        "www.ea.com"
    )

    foreach ($target in $testTargets) {
        try {
            Add-UILog "Testing internet reachability: $target"

            $result = Test-NetConnection `
                -ComputerName $target `
                -Port 443 `
                -InformationLevel Quiet `
                -WarningAction SilentlyContinue

            if ($result) {
                Add-UILog "Internet connection confirmed using: $target"
                return $true
            }
        }
        catch {
            Add-UILog "WARN: Internet test failed for ${target}: $($_.Exception.Message)"
        }
    }

    Add-UILog "WARN: Internet connection could not be confirmed."
    return $false
}

function Confirm-SCOSInternetConnection {
    if (Test-SCOSInternetConnection) {
        Add-UILog "Network check passed."
        return
    }

    Stop-SCOSSetupForNetworkRequired -Message "Internet connection was not detected."
}

function Test-VCRuntimeInstalled {
    $runtimePaths = @(
        "$env:SystemRoot\System32\vcruntime140.dll",
        "$env:SystemRoot\SysWOW64\vcruntime140.dll"
    )

    foreach ($path in $runtimePaths) {
        if (-not (Test-Path $path)) {
            Add-UILog "Missing VC++ runtime file: $path"
            return $false
        }
    }

    return $true
}

function Get-VCRedistInstaller {
    param(
        [string]$Architecture,
        [string]$BundledInstaller,
        [string]$DownloadedInstaller,
        [string]$DownloadUrl
    )

    if (Test-Path $BundledInstaller) {
        Add-UILog "Using bundled Visual C++ Redistributable ${Architecture}: $BundledInstaller"
        return $BundledInstaller
    }

    Add-UILog "Downloading Visual C++ Redistributable $Architecture from Microsoft..."

    New-Item -ItemType Directory -Path $SCOSDownloadsFolder -Force | Out-Null
New-Item -ItemType Directory -Path "C:\SCOS\Downloads" -Force | Out-Null

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $DownloadedInstaller -UseBasicParsing
    }
    catch {
        throw "Failed to download Visual C++ Redistributable ${Architecture}: $($_.Exception.Message)"
    }

    if (-not (Test-Path $DownloadedInstaller)) {
        throw "Visual C++ Redistributable $Architecture download failed. Installer not found."
    }

    Add-UILog "Downloaded Visual C++ Redistributable $Architecture to: $DownloadedInstaller"
    return $DownloadedInstaller
}

function Install-VCRedist {
    Add-UILog "Checking Visual C++ Runtime..."

    if (Test-VCRuntimeInstalled) {
        Add-UILog "Visual C++ Runtime already present."
        return
    }

    $x64Installer = Get-VCRedistInstaller `
        -Architecture "x64" `
        -BundledInstaller $VCRedistX64BundledInstaller `
        -DownloadedInstaller $VCRedistX64DownloadedInstaller `
        -DownloadUrl $VCRedistX64Url

    Invoke-LoggedProcess `
        -FilePath $x64Installer `
        -Arguments "/install /quiet /norestart" `
        -Description "Installing Visual C++ Redistributable x64..." `
        -AcceptableExitCodes @(0, 3010, 1641, 1638)

    $x86Installer = Get-VCRedistInstaller `
        -Architecture "x86" `
        -BundledInstaller $VCRedistX86BundledInstaller `
        -DownloadedInstaller $VCRedistX86DownloadedInstaller `
        -DownloadUrl $VCRedistX86Url

    Invoke-LoggedProcess `
        -FilePath $x86Installer `
        -Arguments "/install /quiet /norestart" `
        -Description "Installing Visual C++ Redistributable x86..." `
        -AcceptableExitCodes @(0, 3010, 1641, 1638)

    Start-Sleep -Seconds 3

    if (-not (Test-VCRuntimeInstalled)) {
        throw "Visual C++ Runtime installation failed. vcruntime140.dll was not found in both System32 and SysWOW64."
    }

    Add-UILog "Visual C++ Runtime x64 and x86 installed successfully."
}

function Install-Steam {
    if (Test-Path $SteamExe) {
        Add-UILog "Steam already present."
        return
    }

    Add-UILog "Steam is not installed yet."
    $installer = Invoke-SCOSDownload `
        -Name "Steam" `
        -Url $SteamInstallerUrl `
        -OutputPath $SteamInstaller

    Invoke-LoggedProcess -FilePath $installer -Arguments "/S" -Description "Installing Steam silently..."

    if (-not (Wait-ForPath -Path $SteamExe -TimeoutSeconds 120 -Description "Steam.exe")) {
        throw "Steam installation did not complete successfully. Steam.exe was not found."
    }

    Add-UILog "Steam installed successfully."
}

function Install-EAApp {
    if (Test-Path $EAExe) {
        Add-UILog "EA App already present."
        return
    }

    Add-UILog "EA App is not installed yet."
    $installer = Invoke-SCOSDownload `
        -Name "EA App" `
        -Url $EAInstallerUrl `
        -OutputPath $EAInstaller

    Invoke-LoggedProcess -FilePath $installer -Arguments "/quiet" -Description "Installing EA App silently..."

    if (-not (Wait-ForPath -Path $EAExe -TimeoutSeconds 180 -Description "EA Desktop executable")) {
        throw "EA App installation did not complete successfully. EADesktop.exe was not found."
    }

    Add-UILog "EA App installed successfully."
}

function Install-UnifiedRemote {
    $existingUR = Find-UnifiedRemoteExe

    if ($existingUR) {
        Add-UILog "Unified Remote already present: $existingUR"
        Configure-UnifiedRemote -UnifiedRemoteExe $existingUR
        return
    }

    $installer = Invoke-SCOSDownload `
        -Name "Unified Remote" `
        -Url $UnifiedRemoteInstallerUrl `
        -OutputPath $UnifiedRemoteInstaller

    Add-UILog "Starting Unified Remote installer..."
    Add-UILog "Running: $installer /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"

    $process = Start-Process `
        -FilePath $installer `
        -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" `
        -PassThru

    $urExe = $null
    $elapsed = 0
    $timeout = 120

    while ($elapsed -lt $timeout) {
        $urExe = Find-UnifiedRemoteExe

        if ($urExe) {
            Add-UILog "Unified Remote detected: $urExe"
            break
        }

        if ($process.HasExited) {
            Add-UILog "Unified Remote installer exited with code: $($process.ExitCode)"
        }

        Start-Sleep -Seconds 2
        $elapsed += 2

        $currentStepLabel.Text = "Installing Unified Remote... $elapsed / $timeout seconds"
        [System.Windows.Forms.Application]::DoEvents()
    }

    if (-not $urExe) {
        Add-UILog "Unified Remote was not detected after $timeout seconds."

        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                Add-UILog "Unified Remote installer was terminated."
            }
        }
        catch {
            Add-UILog "WARN: Failed to terminate Unified Remote installer: $($_.Exception.Message)"
        }

        throw "Unified Remote installation did not complete successfully. RemoteServerWin.exe was not found."
    }

    try {
        if (-not $process.HasExited) {
            Add-UILog "Unified Remote is installed, but installer is still running. Terminating installer..."
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Add-UILog "Unified Remote installer terminated after successful detection."
        }
    }
    catch {
        Add-UILog "WARN: Failed to terminate Unified Remote installer after detection: $($_.Exception.Message)"
    }

    Configure-UnifiedRemote -UnifiedRemoteExe $urExe
    Add-UILog "Unified Remote installed and configured successfully."
}

function Configure-UnifiedRemote {
    param(
        [string]$UnifiedRemoteExe
    )

    if (-not (Test-Path $UnifiedRemoteExe)) {
        throw "Unified Remote executable not found: $UnifiedRemoteExe"
    }

    Add-UILog "Configuring Unified Remote startup reliability..."

    # SCOS v0.3.4.2:
    # Unified Remote must start inside the active SCOS user session.
    # Instead of scheduling RemoteServerWin.exe directly, SCOS creates its own launcher
    # with a short delay and the correct working directory.
    $unifiedRemoteFolder = Split-Path -Path $UnifiedRemoteExe -Parent
    $unifiedRemoteLauncher = "C:\SCOS\Scripts\StartUnifiedRemote.cmd"
    $quotedLauncher = "`"$unifiedRemoteLauncher`""

    try {
        Add-UILog "Creating SCOS Unified Remote launcher: $unifiedRemoteLauncher"

        $launcherContent = @"
@echo off
setlocal

set "LOG=C:\SCOS\Logs\UnifiedRemoteStartup.log"
set "UR_EXE=$UnifiedRemoteExe"
set "UR_DIR=$unifiedRemoteFolder"

echo [%date% %time%] SCOS Unified Remote startup launcher started.>>"%LOG%"

timeout /t 10 /nobreak >nul

tasklist /FI "IMAGENAME eq RemoteServerWin.exe" | find /I "RemoteServerWin.exe" >nul
if "%ERRORLEVEL%"=="0" (
  echo [%date% %time%] RemoteServerWin.exe already running.>>"%LOG%"
  exit /b 0
)

if not exist "%UR_EXE%" (
  echo [%date% %time%] ERROR: RemoteServerWin.exe not found at "%UR_EXE%".>>"%LOG%"
  exit /b 1
)

echo [%date% %time%] Starting Unified Remote from "%UR_DIR%".>>"%LOG%"
start "" /D "%UR_DIR%" "%UR_EXE%"

timeout /t 3 /nobreak >nul

tasklist /FI "IMAGENAME eq RemoteServerWin.exe" | find /I "RemoteServerWin.exe" >nul
if "%ERRORLEVEL%"=="0" (
  echo [%date% %time%] RemoteServerWin.exe started successfully.>>"%LOG%"
  exit /b 0
)

echo [%date% %time%] WARN: RemoteServerWin.exe was not detected after launch.>>"%LOG%"
exit /b 2
"@

        Set-Content -Path $unifiedRemoteLauncher -Value $launcherContent -Encoding ASCII -Force

        if (-not (Test-Path $unifiedRemoteLauncher)) {
            throw "Unified Remote launcher was not created: $unifiedRemoteLauncher"
        }

        Add-UILog "Unified Remote launcher created."
    }
    catch {
        Add-UILog "WARN: Failed to create Unified Remote launcher: $($_.Exception.Message)"
    }

    try {
        Add-UILog "Removing older SCOS Unified Remote startup tasks..."
        schtasks.exe /Delete /TN "SCOS\UnifiedRemote" /F >> $SetupCompleteLog 2>&1
        schtasks.exe /Delete /TN "SCOS\UnifiedRemoteUser" /F >> $SetupCompleteLog 2>&1
        schtasks.exe /Delete /TN "SCOS\StartUnifiedRemote" /F >> $SetupCompleteLog 2>&1
    }
    catch {
        Add-UILog "WARN: Failed to remove old Unified Remote scheduled tasks: $($_.Exception.Message)"
    }

    try {
        Add-UILog "Removing duplicate Unified Remote Run startup entries..."

        Remove-ItemProperty `
            -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name "SCOS Unified Remote" `
            -ErrorAction SilentlyContinue

        Remove-ItemProperty `
            -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
            -Name "SCOS Unified Remote" `
            -ErrorAction SilentlyContinue

        Load-DefaultUserHive
        reg.exe DELETE "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Run" /v "SCOS Unified Remote" /f *> $null
        Unload-DefaultUserHive
    }
    catch {
        Add-UILog "WARN: Failed to clean Unified Remote Run startup entries: $($_.Exception.Message)"
        try { Unload-DefaultUserHive } catch {}
    }

    try {
        Add-UILog "Creating Unified Remote user-session ONLOGON launcher task..."

        # This task launches SCOS' own CMD wrapper at user logon.
        # The wrapper waits briefly and starts RemoteServerWin.exe from its own folder.
        schtasks.exe /Create `
            /TN "SCOS\StartUnifiedRemote" `
            /SC ONLOGON `
            /TR $quotedLauncher `
            /RL HIGHEST `
            /F >> $SetupCompleteLog 2>&1

        Add-UILog "Unified Remote ONLOGON launcher task created."
    }
    catch {
        Add-UILog "WARN: Failed to create Unified Remote ONLOGON launcher task: $($_.Exception.Message)"
    }

    try {
        Add-UILog "Adding Unified Remote firewall rule..."
        netsh advfirewall firewall delete rule name="Unified Remote" program="$UnifiedRemoteExe" >> $SetupCompleteLog 2>&1
        netsh advfirewall firewall add rule name="Unified Remote" dir=in action=allow program="$UnifiedRemoteExe" enable=yes >> $SetupCompleteLog 2>&1
    }
    catch {
        Add-UILog "WARN: Failed to add Unified Remote firewall rule: $($_.Exception.Message)"
    }

    try {
        Add-UILog "Starting Unified Remote server immediately with correct working directory..."
        Start-Process -FilePath $UnifiedRemoteExe -WorkingDirectory $unifiedRemoteFolder -WindowStyle Hidden
        Start-Sleep -Seconds 3

        $remoteProcess = Get-Process -Name "RemoteServerWin" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($remoteProcess) {
            Add-UILog "Unified Remote server is running. PID: $($remoteProcess.Id)"
        }
        else {
            Add-UILog "RemoteServerWin.exe not detected after direct start. Running SCOS launcher once..."
            Start-Process -FilePath $unifiedRemoteLauncher -WindowStyle Hidden
            Start-Sleep -Seconds 5

            $remoteProcess = Get-Process -Name "RemoteServerWin" -ErrorAction SilentlyContinue | Select-Object -First 1

            if ($remoteProcess) {
                Add-UILog "Unified Remote server is running after launcher start. PID: $($remoteProcess.Id)"
            }
            else {
                Add-UILog "WARN: Unified Remote server process was not detected after direct start or launcher start."
            }
        }
    }
    catch {
        Add-UILog "WARN: Failed to start Unified Remote immediately: $($_.Exception.Message)"
    }

    New-Item -ItemType File -Path "C:\SteamShell\UnifiedRemote.installed" -Force | Out-Null

    Add-UILog "Unified Remote launcher/task startup configuration completed."
}


function Stage-SCOSRecoveryEnvironment {
    Add-UILog "Staging SCOS Recovery Environment..."

    New-Item -ItemType Directory -Path $SCOSRecoveryTargetFolder -Force | Out-Null

    $selectedRecoverySource = $null

    if (Test-Path $SCOSRecoverySourceWim) {
        $selectedRecoverySource = $SCOSRecoverySourceWim
        Add-UILog "Using SCOS Recovery image from primary path: $selectedRecoverySource"
    }
    elseif (Test-Path $SCOSRecoveryFallbackSourceWim) {
        $selectedRecoverySource = $SCOSRecoveryFallbackSourceWim
        Add-UILog "Using SCOS Recovery image from fallback path: $selectedRecoverySource"
    }
    else {
        Add-UILog "WARN: SCOS Recovery image not found at setup source. Skipping recovery staging."
        Add-UILog "Expected primary: $SCOSRecoverySourceWim"
        Add-UILog "Expected fallback: $SCOSRecoveryFallbackSourceWim"
        return
    }

    Copy-Item -Path $selectedRecoverySource -Destination $SCOSRecoveryTargetWim -Force

    if (-not (Test-Path $SCOSRecoveryTargetWim)) {
        throw "SCOS Recovery image copy failed. Target file was not created: $SCOSRecoveryTargetWim"
    }

    $sizeMb = [Math]::Round(((Get-Item $SCOSRecoveryTargetWim).Length / 1MB), 2)
    Add-UILog "SCOS Recovery image staged: $SCOSRecoveryTargetWim ($sizeMb MB)"

    Add-UILog "SCOS Recovery image staging completed."
}


function Get-BcdEntryIdsByDescription {
    param(
        [string]$Description
    )

    $ids = @()

    try {
        $bcdOutput = bcdedit.exe /enum all 2>&1
        $text = ($bcdOutput | Out-String)

        $blocks = $text -split "(\r?\n){2,}"

        foreach ($block in $blocks) {
            if ($block -match "(?im)^\s*description\s+$([regex]::Escape($Description))\s*$") {
                if ($block -match "(?im)^\s*identifier\s+(\{[^}]+\})\s*$") {
                    $ids += $matches[1]
                }
            }
        }
    }
    catch {
        Add-UILog "WARN: Failed to enumerate BCD entries: $($_.Exception.Message)"
    }

    return $ids
}

function Get-CurrentBootLoaderPath {
    try {
        $currentOutput = bcdedit.exe /enum "{current}" 2>&1
        $currentText = ($currentOutput | Out-String)

        if ($currentText -match "(?im)^\s*path\s+(.+?)\s*$") {
            $path = $matches[1].Trim()

            if (-not [string]::IsNullOrWhiteSpace($path)) {
                return $path
            }
        }
    }
    catch {
        Add-UILog "WARN: Failed to detect current boot loader path: $($_.Exception.Message)"
    }

    return "\Windows\System32\Boot\winload.efi"
}

function Invoke-BcdEditLogged {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    Add-UILog ("Running: bcdedit " + ($Arguments -join " "))

    $output = & bcdedit.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Add-UILog "bcdedit: $line"
        }
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "bcdedit failed with exit code $exitCode. Command: bcdedit $($Arguments -join ' ')"
    }

    return @{
        ExitCode = $exitCode
        Output = ($output | Out-String)
    }
}

function Configure-SCOSRecoveryBootEntry {
    Add-UILog "Configuring SCOS Recovery boot entry..."

    if (-not (Test-Path $SCOSRecoveryTargetWim)) {
        Add-UILog "WARN: SCOS Recovery WIM is not staged. Skipping boot entry creation."
        Add-UILog "Expected: $SCOSRecoveryTargetWim"
        return
    }

    $possibleBootSdiPaths = @(
        "C:\Windows\Boot\DVD\EFI\boot.sdi",
        "C:\Windows\Boot\DVD\PCAT\boot.sdi"
    )

    $bootSdiSource = $null

    foreach ($path in $possibleBootSdiPaths) {
        if (Test-Path $path) {
            $bootSdiSource = $path
            break
        }
    }

    if ($bootSdiSource) {
        Copy-Item -Path $bootSdiSource -Destination $SCOSRecoveryTargetBootSdi -Force
        Add-UILog "SCOS Recovery boot.sdi copied from: $bootSdiSource"
    }
    else {
        Add-UILog "WARN: boot.sdi was not found in Windows boot folders. Skipping boot entry creation."
        return
    }

    if (-not (Test-Path $SCOSRecoveryTargetBootSdi)) {
        Add-UILog "WARN: boot.sdi copy failed. Skipping boot entry creation."
        return
    }

    try {
        Invoke-BcdEditLogged -Arguments @("/set", "{current}", "description", "SCOS") | Out-Null

        Invoke-BcdEditLogged -Arguments @("/create", "{ramdiskoptions}", "/d", "SCOS Recovery Ramdisk Options") -AllowFailure | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", "{ramdiskoptions}", "ramdisksdidevice", "partition=C:") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", "{ramdiskoptions}", "ramdisksdipath", "\SCOS\Recovery\boot.sdi") | Out-Null

        $existingRecoveryEntries = Get-BcdEntryIdsByDescription -Description "SCOS Recovery Environment"

        foreach ($entryId in $existingRecoveryEntries) {
            Add-UILog "Removing existing SCOS Recovery boot entry: $entryId"
            Invoke-BcdEditLogged -Arguments @("/delete", $entryId, "/f") -AllowFailure | Out-Null
        }

        $createResult = Invoke-BcdEditLogged -Arguments @("/create", "/d", "SCOS Recovery Environment", "/application", "osloader")
        $createText = [string]$createResult.Output

        if ($createText -notmatch "(\{[0-9a-fA-F-]+\})") {
            Add-UILog "WARN: Could not parse new SCOS Recovery boot entry ID. Skipping boot entry configuration."
            return
        }

        $recoveryEntryId = $matches[1]
        Add-UILog "Created SCOS Recovery boot entry: $recoveryEntryId"

        $bootLoaderPath = Get-CurrentBootLoaderPath
        Add-UILog "Using boot loader path for SCOS Recovery: $bootLoaderPath"

        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "device", "ramdisk=[C:]\SCOS\Recovery\SCOSRecovery.wim,{ramdiskoptions}") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "osdevice", "ramdisk=[C:]\SCOS\Recovery\SCOSRecovery.wim,{ramdiskoptions}") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "path", $bootLoaderPath) | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "systemroot", "\Windows") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "winpe", "yes") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/set", $recoveryEntryId, "detecthal", "yes") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/displayorder", $recoveryEntryId, "/addlast") | Out-Null
        Invoke-BcdEditLogged -Arguments @("/timeout", "5") | Out-Null

        Add-UILog "SCOS Recovery boot entry configured successfully."
    }
    catch {
        Add-UILog "WARN: Failed to configure SCOS Recovery boot entry: $($_.Exception.Message)"
    }
}

function Apply-DefaultProfileSettings {
    Add-UILog "Applying Default User settings..."

    Load-DefaultUserHive

    reg.exe ADD "HKU\DefUser\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f *> $null
    reg.exe ADD "HKU\DefUser\Control Panel\Desktop" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f *> $null
    reg.exe ADD "HKU\DefUser\Control Panel\Desktop" /v ScreenSaveTimeOut /t REG_SZ /d 0 /f *> $null

    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Run" /v SteamConsole /t REG_SZ /d "`"$SteamExe`" -gamepadui -silent" /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Run" /v EAApp /t REG_SZ /d "`"$EAExe`"" /f *> $null

    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v HideFastUserSwitching /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /t REG_DWORD /d 1 /f *> $null

    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v ApplyNoLockOnResume /t REG_SZ /d "cmd /c reg add ""HKCU\Control Panel\Desktop"" /v ScreenSaveActive /t REG_SZ /d 0 /f & reg add ""HKCU\Control Panel\Desktop"" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f & reg add ""HKCU\Control Panel\Desktop"" /v ScreenSaveTimeOut /t REG_SZ /d 0 /f" /f *> $null

    Unload-DefaultUserHive
}


function Apply-SCOSEarlyProtection {
    Add-UILog "Applying early SCOS protection before downloads and dependencies..."

    # Important:
    # This runs before online downloads and dependency installation.
    # It reduces the time window where a user could access normal Windows tools
    # before the main SCOS installation is finished.
    Apply-SCOSSystemSettings

    if ($IsStandardLockdown) {
        Apply-StandardLockdown
        Add-UILog "Early Standard lockdown applied."
    }
    else {
        Add-UILog "Developer build: early full lockdown skipped. Debug access remains available."
    }

    Add-UILog "Early SCOS protection completed."
}

function Apply-SCOSSystemSettings {
    Add-UILog "Applying SCOS power, privacy, and console settings..."

    powercfg.exe /setactive SCHEME_BALANCED *> $null
    powercfg.exe /change monitor-timeout-ac 30 *> $null
    powercfg.exe /change standby-timeout-ac 60 *> $null
    powercfg.exe /hibernate on *> $null

    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0E796BDB-100D-47D6-A2D5-F7D2DAA51F51" "ACSettingIndex" 0
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\0E796BDB-100D-47D6-A2D5-F7D2DAA51F51" "DCSettingIndex" 0

    powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 *> $null
    powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 *> $null
    powercfg.exe /SETACTIVE SCHEME_CURRENT *> $null

    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "InactivityTimeoutSecs" 0
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableLockWorkstation" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableChangePassword" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoLogoff" 1

    Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableConsumerFeatures" 1

    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoUpdate" 0
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "AUOptions" 2
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers" 1
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\UX\Settings" "ActiveHoursStart" 9
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\UX\Settings" "ActiveHoursEnd" 23

    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "EnableFirstLogonAnimation" 0

    Apply-SecurityScreenOnlyPolicies
    Apply-DefaultProfileSettings

    Add-UILog "SCOS common safety restrictions applied."
}


function Apply-SecurityScreenOnlyPolicies {
    Add-UILog "Applying security screen safety policies..."

    # Applies to both Standard and Developer.
    # Goal: prevent accidental Lock / Sign out / Change password.
    # This does NOT disable Task Manager, CMD, Win keys, power options, or debug access.
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableLockWorkstation" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableChangePassword" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoLogoff" 1

    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableLockWorkstation" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableChangePassword" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoLogoff" 1

    Add-UILog "Security screen safety policies applied."
}

function Configure-SteamShell {
    Add-UILog "Configuring Steam Big Picture shell..."

    if (-not (Test-Path $SteamExe)) {
        throw "Cannot configure Steam shell because Steam.exe was not found."
    }

    $steamShellValue = "`"$SteamExe`" -gamepadui"
    Set-RegString "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "Shell" $steamShellValue

    if (Test-Path $DisableControllerAudioScript) {
        Copy-Item $DisableControllerAudioScript "C:\SteamShell\disable-controller-audio.ps1" -Force

        Load-DefaultUserHive
        reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v DisableCtrlAudio /t REG_SZ /d "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\SteamShell\disable-controller-audio.ps1" /f *> $null
        Unload-DefaultUserHive

        Add-UILog "Controller audio fix staged."
    }
    else {
        Add-UILog "WARN: disable-controller-audio.ps1 missing. Skipping."
    }

    if (Test-Path $SteamCursorGuard) {
        Copy-Item $SteamCursorGuard "C:\SteamConsole\SteamCursorGuard.exe" -Force

        Load-DefaultUserHive
        reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Run" /v SteamCursorGuard /t REG_SZ /d "`"C:\SteamConsole\SteamCursorGuard.exe`"" /f *> $null
        Unload-DefaultUserHive

        Add-UILog "Steam cursor guard staged."
    }
    else {
        Add-UILog "WARN: SteamCursorGuard.exe missing. Skipping."
    }
}


function Apply-StandardControlPanelAndExplorerRestrictions {
    Add-UILog "Applying Standard Control Panel and Explorer restrictions..."

    # Control Panel policy:
    # Do not set NoControlPanel here because SCOS still needs the classic Sound panel.
    # RestrictCpl=1 allows only the Control Panel applets listed under RestrictCpl.
    # mmsys.cpl is the classic Sound control panel.
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "RestrictCpl" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "RestrictCpl" 1

    Set-RegString "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\RestrictCpl" "1" "mmsys.cpl"
    Set-RegString "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\RestrictCpl" "1" "mmsys.cpl"

    # Explorer/file browsing restrictions:
    # These reduce access to normal Windows browsing without blocking explorer.exe itself.
    # Blocking explorer.exe through IFEO is avoided because Windows still uses Explorer components internally.
    $allDrivesMask = 67108863

    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDrives" $allDrivesMask
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoViewOnDrive" $allDrivesMask
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoRun" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFind" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFolderOptions" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFileMenu" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoViewContextMenu" 1
    Set-RegDword "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoTrayContextMenu" 1

    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDrives" $allDrivesMask
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoViewOnDrive" $allDrivesMask
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoRun" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFind" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFolderOptions" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoFileMenu" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoViewContextMenu" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoTrayContextMenu" 1

    Add-UILog "Control Panel restricted to Sound only. Explorer browsing restrictions applied."
}

function Apply-StandardLockdown {
    if (-not $IsStandardLockdown) {
        Add-UILog "Developer build: full lockdown disabled. Debug access remains available."
        return
    }

    Add-UILog "Standard build: applying console lockdown..."

    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "HideFastUserSwitching" 1
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "shutdownwithoutlogon" 0
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableCAD" 1
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableTaskMgr" 1
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableLockWorkstation" 1
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableChangePassword" 1

    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DontDisplayNetworkSelectionUI" 1
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" "NoLockScreen" 1

    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoLogoff" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoWinKeys" 1
    Set-RegDword "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoClose" 1

    # SCOS v0.3.6.1:
    # Restrict Control Panel to Sound only and reduce Explorer/file browsing access.
    Apply-StandardControlPanelAndExplorerRestrictions

    # SCOS v0.3.5.1 CMD policy fix:
    # DisableCMD=2 blocks interactive Command Prompt but still allows CMD/batch scripts.
    # This is safer than blocking cmd.exe through IFEO because SCOS still needs internal .cmd scripts.
    Set-RegDword "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "DisableCMD" 2
    Set-RegDword "HKCU:\Software\Policies\Microsoft\Windows\System" "DisableCMD" 2
    Add-UILog "Interactive Command Prompt restriction applied for HKLM and HKCU."

    # SCOS v0.3.5 lockdown hardening:
    # Block registry editing and Microsoft Management Console in Standard edition.
    # gpedit.msc is an MMC snap-in, so blocking mmc.exe also blocks Local Group Policy Editor.
    $blockedSystemTools = @(
        "taskmgr.exe",
        "regedit.exe",
        "regedt32.exe",
        "mmc.exe"
    )

    foreach ($tool in $blockedSystemTools) {
        reg.exe ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$tool" /v Debugger /t REG_SZ /d "%SystemRoot%\System32\rundll32.exe" /f *> $null
        reg.exe ADD "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$tool" /v Debugger /t REG_SZ /d "%SystemRoot%\System32\rundll32.exe" /f *> $null
        Add-UILog "Blocked Standard system tool: $tool"
    }

    foreach ($tool in @("utilman.exe", "osk.exe", "narrator.exe", "magnify.exe", "atbroker.exe")) {
        reg.exe ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$tool" /v Debugger /t REG_SZ /d "%SystemRoot%\System32\rundll32.exe" /f *> $null
    }

    Load-DefaultUserHive

    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v HideFastUserSwitching /t REG_DWORD /d 1 /f *> $null

    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoClose /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoWinKeys /t REG_DWORD /d 1 /f *> $null

    # SCOS v0.3.6.1 default profile lockdown:
    # Restrict Control Panel to Sound only and reduce Explorer/file browsing access for future users.
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v RestrictCpl /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\RestrictCpl" /v 1 /t REG_SZ /d "mmsys.cpl" /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoDrives /t REG_DWORD /d 67108863 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoViewOnDrive /t REG_DWORD /d 67108863 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoRun /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoFind /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoFolderOptions /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoFileMenu /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoViewContextMenu /t REG_DWORD /d 1 /f *> $null
    reg.exe ADD "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoTrayContextMenu /t REG_DWORD /d 1 /f *> $null

    reg.exe ADD "HKU\DefUser\Software\Policies\Microsoft\Windows\System" /v DisableCMD /t REG_DWORD /d 2 /f *> $null
    reg.exe ADD "HKU\DefUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 506 /f *> $null

    Unload-DefaultUserHive

    gpupdate.exe /force *> $null

    Add-UILog "Standard lockdown applied. Registry Editor, MMC/Group Policy, Task Manager, interactive CMD, Control Panel, and Explorer browsing are restricted."
}




function New-SCOSRandomPassword {
    param(
        [int]$Length = 24
    )

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower = "abcdefghijkmnopqrstuvwxyz"
    $digits = "23456789"
    $symbols = "!#$%+-=?@_"
    $all = ($upper + $lower + $digits + $symbols).ToCharArray()

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    function Get-SecureRandomIndex {
        param([int]$Max)

        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        return [int]([BitConverter]::ToUInt32($bytes, 0) % $Max)
    }

    $chars = New-Object System.Collections.Generic.List[char]

    # Guarantee at least one character from each class.
    $chars.Add($upper[(Get-SecureRandomIndex -Max $upper.Length)])
    $chars.Add($lower[(Get-SecureRandomIndex -Max $lower.Length)])
    $chars.Add($digits[(Get-SecureRandomIndex -Max $digits.Length)])
    $chars.Add($symbols[(Get-SecureRandomIndex -Max $symbols.Length)])

    while ($chars.Count -lt $Length) {
        $chars.Add($all[(Get-SecureRandomIndex -Max $all.Length)])
    }

    # Fisher-Yates shuffle using the same secure RNG.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-SecureRandomIndex -Max ($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }

    $rng.Dispose()

    return -join $chars
}

function Set-SCOSComputerName {
    Add-UILog "Configuring SCOS computer name..."

    try {
        $currentName = $env:COMPUTERNAME

        if ($currentName -like "SCOS-*") {
            Add-UILog "Computer name already uses SCOS format: $currentName"
            return
        }

        $suffix = ([guid]::NewGuid().ToString("N").Substring(0, 6)).ToUpper()
        $newName = "SCOS-$suffix"

        # NetBIOS computer names must stay within 15 characters. SCOS-XXXXXX is 11.
        Add-UILog "Renaming computer from $currentName to $newName..."
        Rename-Computer -NewName $newName -Force

        Add-UILog "Computer name configured. New name will apply after restart: $newName"
    }
    catch {
        Add-UILog "WARN: Failed to configure SCOS computer name: $($_.Exception.Message)"
    }
}

function Set-SCOSLocalAccountPassword {
    Add-UILog "Generating unique password for local SCOS account..."

    try {
        $password = New-SCOSRandomPassword -Length 24
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

        $user = Get-LocalUser -Name $SCOSLocalUserName -ErrorAction SilentlyContinue

        if (-not $user) {
            Add-UILog "WARN: Local user '$SCOSLocalUserName' was not found. Password generation skipped."
            return
        }

        Set-LocalUser -Name $SCOSLocalUserName -Password $securePassword -PasswordNeverExpires $true
        Add-UILog "Local SCOS account password updated."

        # Keep console auto-login working with the generated per-install password.
        # Windows AutoAdminLogon stores this value in the registry, so this is still local-machine sensitive.
        Set-RegString "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "AutoAdminLogon" "1"
        Set-RegString "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultUserName" $SCOSLocalUserName
        Set-RegString "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultDomainName" "."
        Set-RegString "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" "DefaultPassword" $password

        # SCOS v0.3.6.5:
        # Public Standard builds should not create readable password recovery files.
        # Developer/internal builds may keep the readable recovery files for debugging and owner recovery.
        if ($IsStandardLockdown) {
            Remove-Item -Path $SCOSGeneratedPasswordPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $SCOSGeneratedPasswordLogPath -Force -ErrorAction SilentlyContinue

            Add-UILog "Generated SCOS account password successfully."
        }
        else {
            Set-Content -Path $SCOSGeneratedPasswordPath -Value $password -Encoding ASCII -Force
            Set-Content -Path $SCOSGeneratedPasswordLogPath -Value ("SCOS local account password for this installation: " + $password) -Encoding ASCII -Force

            Add-UILog "Generated SCOS account password successfully."
            Add-UILog "Developer details: password recovery file created at $SCOSGeneratedPasswordLogPath"
        }
    }
    catch {
        Add-UILog "WARN: Failed to generate or apply local SCOS account password: $($_.Exception.Message)"
    }
}


function Clear-SCOSDownloadedInstallers {
    Add-UILog "Cleaning downloaded installer cache..."

    try {
        if (Test-Path $SCOSDownloadsFolder) {
            Remove-Item -Path (Join-Path $SCOSDownloadsFolder "*.exe") -Force -ErrorAction SilentlyContinue
            Add-UILog "Downloaded installer cache cleaned."
        }
    }
    catch {
        Add-UILog "WARN: Failed to clean downloaded installer cache: $($_.Exception.Message)"
    }
}


function Finalize-SCOSInstall {
    Add-UILog "Reasserting no password on wake..."
    powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 *> $null
    powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 *> $null
    powercfg.exe /SETACTIVE SCHEME_CURRENT *> $null

    Add-UILog "Preventing local password expiration..."
    net.exe accounts /maxpwage:unlimited *> $null

    try {
        Set-LocalUser -Name "SCOS" -PasswordNeverExpires $true
    }
    catch {
        Add-UILog "Set-LocalUser skipped or failed: $($_.Exception.Message)"
    }

    Set-SCOSComputerName
    Set-SCOSLocalAccountPassword

    Add-UILog "Marking OOBE complete..."
    reg.exe ADD "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" /v ImageState /t REG_SZ /d IMAGE_STATE_COMPLETE /f *> $null
    reg.exe ADD "HKLM\SYSTEM\Setup" /v OOBEInProgress /t REG_DWORD /d 0 /f *> $null
    reg.exe ADD "HKLM\SYSTEM\Setup" /v SetupPhase /t REG_DWORD /d 0 /f *> $null
    reg.exe ADD "HKLM\SYSTEM\Setup\Status\ChildCompletion" /v setup.exe /t REG_DWORD /d 3 /f *> $null

    Add-UILog "Refreshing Defender signatures once, if available..."
    $defenderUpdater = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"

    if (Test-Path $defenderUpdater) {
        Start-Process -FilePath $defenderUpdater -ArgumentList "-SignatureUpdate" -Wait
    }

    Restore-UACSettings

    Clear-SCOSDownloadedInstallers

    Add-UILog "SCOS setup finished."
    New-Item -ItemType File -Path "C:\SetupComplete.done" -Force | Out-Null
}

# -----------------------------
# Installation Flow
# -----------------------------

function Start-SCOSSetup {
    Add-UILog "Starting SCOS $Edition setup $AppVersion..."
    Add-UILog "ScriptsRoot: $ScriptsRoot"
    Add-UILog "SCOSDownloadsFolder: $SCOSDownloadsFolder"
    Add-UILog "SteamInstaller: $SteamInstaller"
    Add-UILog "SteamInstallerUrl: $SteamInstallerUrl"
    Add-UILog "EAInstaller: $EAInstaller"
    Add-UILog "EAInstallerUrl: $EAInstallerUrl"
    Add-UILog "UnifiedRemoteInstaller: $UnifiedRemoteInstaller"
    Add-UILog "UnifiedRemoteInstallerUrl: $UnifiedRemoteInstallerUrl"
    Add-UILog "SCOSRecoverySourceWim: $SCOSRecoverySourceWim"
    Add-UILog "SCOSRecoveryFallbackSourceWim: $SCOSRecoveryFallbackSourceWim"
    Add-UILog "SCOSRecoveryTargetWim: $SCOSRecoveryTargetWim"
    Add-UILog "SCOSRecoveryTargetBootSdi: $SCOSRecoveryTargetBootSdi"
    Add-UILog "VCRedistX64BundledInstaller: $VCRedistX64BundledInstaller"
    Add-UILog "VCRedistX86BundledInstaller: $VCRedistX86BundledInstaller"
    Add-UILog "Lockdown: $Lockdown"
    Add-UILog "StepDelaySeconds: $StepDelaySeconds"
    Add-UILog "RestartCountdownSeconds: $RestartCountdownSeconds"
    if (-not (Test-IsAdmin)) {
        throw "SCOS setup UI is not running as administrator. The setup launcher must start it elevated."
    }
    else {
        Add-UILog "SCOS setup UI is running with administrator rights."
    }

    Run-Step -Index 0 -Progress 7 -Message "Preparing online installer downloads..." -Action {
        New-Item -ItemType Directory -Path "C:\SCOS\Logs" -Force | Out-Null
        New-Item -ItemType Directory -Path "C:\SCOS\Scripts" -Force | Out-Null
        New-Item -ItemType Directory -Path "C:\SCOS\Downloads" -Force | Out-Null
        New-Item -ItemType Directory -Path "C:\SteamShell" -Force | Out-Null
        New-Item -ItemType Directory -Path "C:\SteamConsole" -Force | Out-Null

        Check-SCOSSetupResources
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 1 -Progress 14 -Message "Applying early SCOS protection..." -Action {
        Apply-SCOSEarlyProtection
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 2 -Progress 20 -Message "Checking internet connection..." -Action {
        Confirm-SCOSInternetConnection
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 3 -Progress 28 -Message "Installing Visual C++ Runtime..." -Action {
        Install-VCRedist
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 4 -Progress 38 -Message "Installing Steam..." -Action {
        Install-Steam
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 5 -Progress 48 -Message "Installing EA App..." -Action {
        Install-EAApp
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 6 -Progress 58 -Message "Installing Unified Remote..." -Action {
        Install-UnifiedRemote
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 7 -Progress 72 -Message "Applying SCOS system settings..." -Action {
        Stage-SCOSRecoveryEnvironment
        Configure-SCOSRecoveryBootEntry
        Apply-SCOSSystemSettings
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 8 -Progress 84 -Message "Configuring Steam Big Picture shell..." -Action {
        Configure-SteamShell
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 9 -Progress 93 -Message "Applying Standard lockdown..." -Action {
        Apply-StandardLockdown
    }

    if ($script:SetupHasFailed) { return }

    Run-Step -Index 10 -Progress 100 -Message "Finalizing SCOS installation..." -Action {
        Finalize-SCOSInstall
    }

    if ($script:SetupHasFailed) { return }

    Set-Progress -Value 100 -Text "SCOS setup complete."

    Add-UILog "SCOS setup complete. Starting restart countdown..."
    Start-RestartCountdown -Seconds $RestartCountdownSeconds

    Add-UILog "Restarting system now..."
    $script:SetupExitCode = 0

    Start-Process "shutdown.exe" -ArgumentList "/r /t 0" -WindowStyle Hidden

    $script:AllowFormClose = $true
    $form.Close()
}

# -----------------------------
# Start after UI loads
# -----------------------------

$form.Add_Shown({
    Start-Sleep -Milliseconds 500

    try {
        Start-SCOSSetup
    }
    catch {
        Fail-SCOSSetup "Unexpected setup error: $($_.Exception.Message)"
    }
})

# -----------------------------
# Launch UI
# -----------------------------

[void]$form.ShowDialog()

exit $script:SetupExitCode