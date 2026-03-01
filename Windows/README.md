# Windows Scripts

## Convert-HybridToEntraManaged.ps1

Converts a Hybrid Azure AD Joined, co-managed (SCCM + Intune) Windows device to Entra ID Joined only, managed exclusively by Microsoft Intune.

### What It Does

1. **Validates privileges** - Confirms the script is running as a local administrator
2. **Checks join status** - Verifies the device is currently Hybrid Azure AD Joined
3. **Removes SCCM/ConfigMgr** - Uninstalls the SCCM client, removes services, files, registry keys, WMI namespaces, scheduled tasks, and certificates
4. **Removes Group Policy** - Deletes cached GPOs, policy registry keys, GP scripts, and policy history
5. **Disjoins from Active Directory** - Removes the device from the on-premises domain and cleans up cached domain credentials
6. **Prepares for Entra ID / Intune** - Configures MDM enrollment settings, enables device registration tasks, and removes co-management authority keys

### Prerequisites

- **PowerShell 7+** (PowerShell Core) - [Install PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
- **Local administrator** privileges on the target device
- The device must already be **Hybrid Azure AD Joined** (registered in Entra ID and joined to an on-premises AD domain)
- A **local administrator account** should exist on the device as a safety net (domain accounts will no longer work after disjoin)
- **Entra ID credentials** (Microsoft 365 account) ready for sign-in after reboot
- Intune auto-enrollment should be configured in your Entra ID tenant (via MDM scope in Azure Portal)

### Usage

1. Open PowerShell 7 **as Administrator**

2. Run the script interactively:
   ```powershell
   .\Convert-HybridToEntraManaged.ps1
   ```

3. Or skip the confirmation prompt:
   ```powershell
   .\Convert-HybridToEntraManaged.ps1 -Force
   ```

4. Review the summary of changes and type `YES` to proceed (if not using `-Force`)

5. **Reboot** when prompted

### After Reboot

1. Sign in with your **Entra ID (Microsoft 365) credentials**
2. Open **Settings > Accounts > Access work or school** and verify the device shows as connected to your organization's Azure AD
3. Intune enrollment will happen automatically if your tenant has auto-enrollment configured
4. Run `dsregcmd /status` in a command prompt to verify:
   - `AzureAdJoined: YES`
   - `DomainJoined: NO`

### Logs

A detailed log file is written to:
```
%TEMP%\Convert-HybridToEntraManaged.log
```

### Important Notes

- **Back up critical data** before running this script
- Domain-based network resources (file shares, printers mapped via GPO) may need to be reconfigured
- Any software deployed via SCCM will remain installed, but future SCCM deployments will not occur
- Applications that depend on Group Policy settings may need manual reconfiguration or Intune policy equivalents
- If BitLocker is enabled, ensure recovery keys are backed up to Entra ID before proceeding
