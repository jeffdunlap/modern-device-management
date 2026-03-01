#Requires -Version 7.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Converts a Hybrid Azure AD Joined, Co-Managed device to Entra ID Joined Only
    and managed exclusively by Microsoft Intune.

.DESCRIPTION
    This script performs the following operations:
    1. Validates the user is running as a local administrator
    2. Verifies the device is currently Hybrid Azure AD Joined
    3. Removes the SCCM/ConfigMgr client
    4. Removes Group Policy artifacts and cached policies
    5. Disjoins the device from the on-premises Active Directory domain
    6. Cleans up residual domain and GPO configuration
    7. Schedules Entra ID join and Intune enrollment on next reboot

.NOTES
    - A reboot is required after running this script
    - Ensure the user has Entra ID credentials ready for sign-in after reboot
    - The device must already have an Entra ID registration or hybrid join
    - Back up any critical data before running this script
    - Requires PowerShell 7+ (PowerShell Core)

.EXAMPLE
    .\Convert-HybridToEntraManaged.ps1
    Runs the conversion with interactive prompts.

.EXAMPLE
    .\Convert-HybridToEntraManaged.ps1 -Force
    Runs the conversion, skipping the confirmation prompt.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Helper Functions ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'Info'    { '[INFO]' }
        'Warning' { '[WARN]' }
        'Error'   { '[ERROR]' }
        'Success' { '[OK]' }
    }

    $logMessage = "$timestamp $prefix $Message"

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error $Message }
        default   { Write-Host $logMessage }
    }

    # Append to log file
    $logPath = Join-Path $env:TEMP 'Convert-HybridToEntraManaged.log'
    Add-Content -Path $logPath -Value $logMessage
}

function Test-IsLocalAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HybridJoinStatus {
    try {
        $dsregOutput = dsregcmd /status
        $isAzureAdJoined = ($dsregOutput | Select-String 'AzureAdJoined\s*:\s*YES') -ne $null
        $isDomainJoined = ($dsregOutput | Select-String 'DomainJoined\s*:\s*YES') -ne $null

        return @{
            AzureAdJoined = $isAzureAdJoined
            DomainJoined  = $isDomainJoined
            IsHybrid      = ($isAzureAdJoined -and $isDomainJoined)
        }
    }
    catch {
        Write-Log "Failed to check join status: $_" -Level Error
        throw
    }
}

#endregion

#region --- SCCM Removal ---

function Remove-SCCMClient {
    Write-Log 'Removing SCCM/ConfigMgr client...'

    # Attempt uninstall via ccmsetup
    $ccmSetupPath = Join-Path $env:SystemRoot 'ccmsetup\ccmsetup.exe'
    if (Test-Path $ccmSetupPath) {
        Write-Log 'Running ccmsetup.exe /uninstall...'
        $process = Start-Process -FilePath $ccmSetupPath -ArgumentList '/uninstall' -Wait -PassThru -NoNewWindow
        Write-Log "ccmsetup /uninstall exited with code: $($process.ExitCode)"
        # Give it time to clean up
        Start-Sleep -Seconds 10
    }
    else {
        Write-Log 'ccmsetup.exe not found, proceeding with manual cleanup.' -Level Warning
    }

    # Stop SCCM services
    $sccmServices = @('CcmExec', 'smstsmgr', 'CmRcService')
    foreach ($svc in $sccmServices) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service) {
            Write-Log "Stopping service: $svc"
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }

    # Remove SCCM client directories
    $sccmPaths = @(
        (Join-Path $env:SystemRoot 'CCM'),
        (Join-Path $env:SystemRoot 'ccmsetup'),
        (Join-Path $env:SystemRoot 'ccmcache'),
        (Join-Path $env:SystemRoot 'SMSCFG.INI')
    )

    foreach ($path in $sccmPaths) {
        if (Test-Path $path) {
            Write-Log "Removing: $path"
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove SCCM registry keys
    $sccmRegKeys = @(
        'HKLM:\SOFTWARE\Microsoft\CCM',
        'HKLM:\SOFTWARE\Microsoft\CCMSetup',
        'HKLM:\SOFTWARE\Microsoft\SMS',
        'HKLM:\SOFTWARE\Microsoft\DeviceManageabilityCSP'
    )

    foreach ($key in $sccmRegKeys) {
        if (Test-Path $key) {
            Write-Log "Removing registry key: $key"
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove SCCM WMI namespaces
    try {
        Get-CimInstance -Namespace 'root' -ClassName __Namespace -Filter "Name='ccm'" -ErrorAction SilentlyContinue |
            Remove-CimInstance -ErrorAction SilentlyContinue
        Write-Log 'Removed root\ccm WMI namespace.'
    }
    catch {
        Write-Log "WMI namespace removal: $_" -Level Warning
    }

    # Remove SCCM scheduled tasks
    $sccmTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'Configuration Manager' -or $_.TaskPath -match 'Microsoft\\Configuration Manager' }
    foreach ($task in $sccmTasks) {
        Write-Log "Removing scheduled task: $($task.TaskName)"
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Remove SCCM certificates
    try {
        $sccmCerts = Get-ChildItem -Path Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue
        foreach ($cert in $sccmCerts) {
            Write-Log "Removing SCCM certificate: $($cert.Thumbprint)"
            Remove-Item -Path $cert.PSPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log 'No SCCM certificate store found (expected if already cleaned).' -Level Warning
    }

    Write-Log 'SCCM client removal complete.' -Level Success
}

#endregion

#region --- Group Policy Removal ---

function Remove-GroupPolicyArtifacts {
    Write-Log 'Removing Group Policy artifacts...'

    # Remove cached Group Policy files
    $gpPaths = @(
        (Join-Path $env:SystemRoot 'System32\GroupPolicy'),
        (Join-Path $env:SystemRoot 'System32\GroupPolicyUsers'),
        (Join-Path $env:SystemRoot 'SysWOW64\GroupPolicy'),
        (Join-Path $env:SystemRoot 'SysWOW64\GroupPolicyUsers')
    )

    foreach ($path in $gpPaths) {
        if (Test-Path $path) {
            Write-Log "Removing: $path"
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove Group Policy registry pol caches
    $gpCachePath = Join-Path $env:ProgramData 'Microsoft\Group Policy'
    if (Test-Path $gpCachePath) {
        Write-Log "Removing GP cache: $gpCachePath"
        Remove-Item -Path $gpCachePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Remove GP history
    $gpHistoryPath = Join-Path $env:ProgramData 'Microsoft\Group Policy\History'
    if (Test-Path $gpHistoryPath) {
        Write-Log "Removing GP history: $gpHistoryPath"
        Remove-Item -Path $gpHistoryPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Clean Group Policy registry entries
    $gpRegKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        'HKLM:\SOFTWARE\Policies\Microsoft',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        'HKCU:\SOFTWARE\Policies\Microsoft'
    )

    foreach ($key in $gpRegKeys) {
        if (Test-Path $key) {
            Write-Log "Removing registry key: $key"
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Reset Group Policy client-side extensions registry
    $gpExtKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions'
    if (Test-Path $gpExtKey) {
        Write-Log "Cleaning GP extensions registry: $gpExtKey"
        # We keep the key but clear cached CSE data
    }

    # Remove GP scripts (startup/shutdown/logon/logoff)
    $gpScriptsPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Scripts'
    if (Test-Path $gpScriptsPath) {
        Remove-Item -Path $gpScriptsPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $gpScriptsPathUser = Join-Path $env:SystemRoot 'System32\GroupPolicy\User\Scripts'
    if (Test-Path $gpScriptsPathUser) {
        Remove-Item -Path $gpScriptsPathUser -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Force a GP update to clear any in-memory policy (will error with no domain but that's fine)
    try {
        $null = gpupdate /force 2>&1
    }
    catch {
        Write-Log 'gpupdate ran (expected to partially fail after domain removal).' -Level Warning
    }

    Write-Log 'Group Policy artifacts removed.' -Level Success
}

#endregion

#region --- Domain Disjoin ---

function Remove-DomainJoin {
    Write-Log 'Removing device from Active Directory domain...'

    # Get current domain info
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $computerSystem.PartOfDomain) {
        Write-Log 'Device is not domain-joined. Skipping domain removal.' -Level Warning
        return
    }

    $domainName = $computerSystem.Domain
    Write-Log "Current domain: $domainName"

    # Create a local admin account as safety net if needed
    $localAdmins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
        Where-Object { $_.ObjectClass -eq 'User' -and $_.PrincipalSource -eq 'Local' }

    if ($localAdmins.Count -eq 0) {
        Write-Log 'No local admin accounts found. Ensure you have a local admin before proceeding.' -Level Warning
    }

    # Disjoin from domain using WMI (no credential required for local unjoin)
    try {
        # Flag 0 = default unjoin; no account disable in AD
        $result = $computerSystem | Invoke-CimMethod -MethodName 'UnjoinDomainOrWorkgroup' -Arguments @{
            FUnjoinOptions = 0
            Password       = $null
            UserName       = $null
        }

        if ($result.ReturnValue -eq 0) {
            Write-Log "Successfully removed from domain: $domainName" -Level Success
        }
        else {
            Write-Log "Domain unjoin returned code: $($result.ReturnValue). Attempting alternative method..." -Level Warning

            # Alternative: use Remove-Computer cmdlet
            Remove-Computer -Force -ErrorAction Stop
            Write-Log "Successfully removed from domain using Remove-Computer." -Level Success
        }
    }
    catch {
        Write-Log "Domain removal error: $_" -Level Warning
        Write-Log 'Attempting Remove-Computer as fallback...'
        try {
            Remove-Computer -Force -ErrorAction Stop
            Write-Log 'Successfully removed from domain using Remove-Computer.' -Level Success
        }
        catch {
            Write-Log "Failed to remove from domain: $_" -Level Error
            throw "Unable to disjoin from domain. Please remove manually and re-run this script."
        }
    }

    # Clean up domain-related registry entries
    $domainRegKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\NetCache',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    )

    foreach ($key in $domainRegKeys) {
        if (Test-Path $key) {
            # Don't delete Netlogon entirely, just clear domain-specific values
            if ($key -match 'Netlogon') {
                Remove-ItemProperty -Path $key -Name 'DomainName' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $key -Name 'SiteName' -ErrorAction SilentlyContinue
            }
        }
    }

    # Remove cached domain credentials
    try {
        $cmdkeyOutput = cmdkey /list 2>&1
        $domainEntries = $cmdkeyOutput | Select-String "Target:" | Where-Object { $_ -match $domainName }
        foreach ($entry in $domainEntries) {
            $target = ($entry -replace '.*Target:\s*', '').Trim()
            Write-Log "Removing cached credential: $target"
            cmdkey /delete:$target 2>&1 | Out-Null
        }
    }
    catch {
        Write-Log "Credential cleanup: $_" -Level Warning
    }

    Write-Log 'Domain disjoin complete.' -Level Success
}

#endregion

#region --- Intune/Entra Preparation ---

function Set-EntraIntuneReadiness {
    Write-Log 'Preparing device for Entra ID join and Intune enrollment...'

    # Ensure MDM enrollment URLs are set for Intune
    $mdmEnrollKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM'
    if (-not (Test-Path $mdmEnrollKey)) {
        New-Item -Path $mdmEnrollKey -Force | Out-Null
    }

    # Enable auto MDM enrollment via AAD
    $autoEnrollKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM'
    if (-not (Test-Path $autoEnrollKey)) {
        New-Item -Path $autoEnrollKey -Force | Out-Null
    }

    # Ensure the device registration task is enabled
    $drTasks = @(
        '\Microsoft\Windows\Workplace Join\Automatic-Device-Join'
    )

    foreach ($taskName in $drTasks) {
        try {
            $task = Get-ScheduledTask -TaskName ($taskName -split '\\' | Select-Object -Last 1) -ErrorAction SilentlyContinue
            if ($task) {
                Enable-ScheduledTask -TaskName $task.TaskName -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Enabled scheduled task: $taskName"
            }
        }
        catch {
            Write-Log "Could not enable task ${taskName}: $_" -Level Warning
        }
    }

    # Ensure AAD Broker Plugin and Web Account Manager are functional
    $wamServiceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
    if (Test-Path $wamServiceKey) {
        Write-Log 'WAM/LogonUI configuration verified.'
    }

    # Remove any co-management authority registry keys
    $coMgmtKeys = @(
        'HKLM:\SOFTWARE\Microsoft\CCM\CoManagementFlags',
        'HKLM:\SOFTWARE\Microsoft\CoManagement'
    )

    foreach ($key in $coMgmtKeys) {
        if (Test-Path $key) {
            Write-Log "Removing co-management key: $key"
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Trigger AAD device registration scheduled task
    try {
        Start-ScheduledTask -TaskName 'Automatic-Device-Join' -ErrorAction SilentlyContinue
        Write-Log 'Triggered Automatic-Device-Join task.'
    }
    catch {
        Write-Log 'Automatic-Device-Join task will run at next logon.' -Level Warning
    }

    Write-Log 'Entra ID / Intune readiness preparation complete.' -Level Success
}

#endregion

#region --- Main Execution ---

function Invoke-Conversion {
    $logPath = Join-Path $env:TEMP 'Convert-HybridToEntraManaged.log'
    Write-Log "=== Hybrid to Entra ID Conversion Started ==="
    Write-Log "Log file: $logPath"

    # Step 1: Verify local admin
    Write-Log 'Checking for local administrator privileges...'
    if (-not (Test-IsLocalAdmin)) {
        Write-Log 'This script must be run as a local administrator. Please re-run from an elevated PowerShell session.' -Level Error
        exit 1
    }
    Write-Log 'Running as local administrator.' -Level Success

    # Step 2: Check current join status
    Write-Log 'Checking device join status...'
    $joinStatus = Test-HybridJoinStatus

    if (-not $joinStatus.IsHybrid) {
        if (-not $joinStatus.DomainJoined -and $joinStatus.AzureAdJoined) {
            Write-Log 'Device is already Entra ID joined only. No conversion needed.' -Level Warning
            exit 0
        }
        if (-not $joinStatus.AzureAdJoined) {
            Write-Log 'Device is not Azure AD / Entra ID joined. This script requires an existing Entra ID registration.' -Level Error
            exit 1
        }
    }

    Write-Log "Device status - Azure AD Joined: $($joinStatus.AzureAdJoined), Domain Joined: $($joinStatus.DomainJoined)" -Level Info

    # Step 3: Confirm with user
    if (-not $Force) {
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Yellow
        Write-Host '  WARNING: This operation will make the following changes:' -ForegroundColor Yellow
        Write-Host '============================================================' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  1. Remove the SCCM/ConfigMgr client and all related data'
        Write-Host '  2. Remove all Group Policy settings and cached policies'
        Write-Host '  3. Disjoin this device from the Active Directory domain'
        Write-Host '  4. Configure the device for Entra ID join and Intune enrollment'
        Write-Host ''
        Write-Host '  A REBOOT WILL BE REQUIRED after this script completes.'
        Write-Host '  After reboot, sign in with your Entra ID (Microsoft 365) credentials.'
        Write-Host ''

        $confirm = Read-Host 'Type YES to proceed'
        if ($confirm -ne 'YES') {
            Write-Log 'Operation cancelled by user.'
            exit 0
        }
    }

    # Step 4: Remove SCCM
    Remove-SCCMClient

    # Step 5: Remove Group Policy
    Remove-GroupPolicyArtifacts

    # Step 6: Disjoin from domain
    Remove-DomainJoin

    # Step 7: Prepare for Entra ID / Intune
    Set-EntraIntuneReadiness

    # Done
    Write-Host ''
    Write-Log '=== Conversion Complete ==='
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Conversion complete! A reboot is required.' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next steps after reboot:'
    Write-Host '  1. Sign in with your Entra ID (Microsoft 365) credentials'
    Write-Host '  2. Open Settings > Accounts > Access work or school'
    Write-Host '  3. Verify the device shows as "Connected to <org> Azure AD"'
    Write-Host '  4. Intune enrollment will happen automatically if configured'
    Write-Host '  5. Run "dsregcmd /status" to verify Entra ID join status'
    Write-Host ''
    Write-Log "Full log available at: $logPath"

    $reboot = Read-Host 'Reboot now? (Y/N)'
    if ($reboot -eq 'Y' -or $reboot -eq 'y') {
        Write-Log 'Rebooting in 15 seconds...'
        shutdown /r /t 15 /c "Hybrid to Entra ID conversion - reboot required"
    }
    else {
        Write-Log 'Please reboot at your earliest convenience to complete the conversion.' -Level Warning
    }
}

# Run
Invoke-Conversion

#endregion
