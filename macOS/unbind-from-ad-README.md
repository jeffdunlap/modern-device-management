# macOS Scripts

## unbind-from-ad.sh

Unbinds a macOS device from Active Directory and performs thorough cleanup of all AD-related configuration, cached credentials, and directory service artifacts. Designed for Jamf-managed environments migrating away from AD binding.

### What It Does

1. **Validates privileges** - Confirms the script is running as root
2. **Checks AD binding** - Detects the current Active Directory domain via `dsconfigad`
3. **Unbinds from AD** - Runs `dsconfigad -remove -force` with a manual fallback if needed
4. **Cleans search policy** - Removes AD references from the Directory Services search path and resets to local-only
5. **Flushes Kerberos** - Destroys all Kerberos tickets, clears ticket caches, and backs up/removes AD-specific `krb5.conf`
6. **Removes cached AD accounts** - Deletes cached AD mobile account records from the local directory (home folders are preserved)
7. **Removes AD config files** - Cleans up OpenDirectory configurations, AD plists, and directory service caches
8. **Checks configuration profiles** - Warns if AD binding profiles are present (these should be removed via Jamf)
9. **Restarts directory services** - Restarts `opendirectoryd` and flushes DNS
10. **Verifies unbind** - Confirms the device is no longer bound to AD

### Prerequisites

- **macOS 12 (Monterey)** or later
- **Root access** (run with `sudo`)
- The device should be **bound to Active Directory** via Directory Services
- Ensure a **local admin account** exists on the device before running (AD accounts will no longer work after unbind)

### Usage

1. Copy the script to the target Mac or run it via Jamf

2. Run interactively:
   ```bash
   sudo ./unbind-from-ad.sh
   ```

3. Or skip the confirmation prompt:
   ```bash
   sudo ./unbind-from-ad.sh --force
   ```

4. Review the summary of changes and type `YES` to proceed (if not using `--force`)

### Running via Jamf

The script can be uploaded to Jamf Pro and deployed as a policy:

1. Upload `unbind-from-ad.sh` to **Settings > Scripts** in Jamf Pro
2. Set **Parameter 4** label to "Force (true/false)" if you want to parameterize the `--force` flag
3. Create a policy scoped to the target devices
4. Add the script and pass `--force` as the parameter (Jamf runs scripts as root, so no `sudo` needed)

### After Running

- AD network accounts **can no longer log in** to this Mac
- Home folders for AD accounts are **not deleted** (preserving user data)
- If a Jamf configuration profile handles AD binding, **remove the device from that profile's scope** to prevent re-binding
- A **reboot is recommended** but not strictly required
- Verify with: `dsconfigad -show` (should return nothing or an error)

### Logs

A detailed log is written to:
```
/var/log/unbind-from-ad.log
```

### Important Notes

- If the device has an AD binding configuration profile deployed via Jamf, the profile may re-bind the device on next check-in. Remove the device from the profile's scope in Jamf Pro first, or remove the profile entirely.
- Cached AD mobile account home directories (`/Users/<ad-username>`) are intentionally preserved. Delete them manually if no longer needed.
- Network resources authenticated via AD (file shares, printers) will require alternative credentials after unbinding.
