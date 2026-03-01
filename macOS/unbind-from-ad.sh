#!/bin/bash

###############################################################################
# unbind-from-ad.sh
#
# Unbinds a macOS device from Active Directory and performs cleanup of all
# AD-related configuration, cached credentials, and directory service artifacts.
#
# Intended for Jamf-managed macOS environments migrating away from AD binding.
#
# Requirements:
#   - macOS 12 (Monterey) or later
#   - Must be run as root (sudo)
#   - Device must be bound to Active Directory via Directory Services
#
# Usage:
#   sudo ./unbind-from-ad.sh
#   sudo ./unbind-from-ad.sh --force    # Skip confirmation prompt
###############################################################################

set -euo pipefail

# --- Configuration ---
LOG_FILE="/var/log/unbind-from-ad.log"
FORCE=false

# --- Parse Arguments ---
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: sudo $0 [--force]"
            echo ""
            echo "Unbinds this Mac from Active Directory and cleans up related artifacts."
            echo ""
            echo "Options:"
            echo "  --force, -f   Skip the confirmation prompt"
            echo "  --help, -h    Show this help message"
            exit 0
            ;;
    esac
done

# --- Logging ---
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="${timestamp} [${level}] ${message}"

    echo "$entry" | tee -a "$LOG_FILE"
}

log_info()    { log "INFO" "$@"; }
log_success() { log "OK" "$@"; }
log_warn()    { log "WARN" "$@"; }
log_error()   { log "ERROR" "$@"; }

# --- Preflight Checks ---

# Must be root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Use: sudo $0"
    exit 1
fi

log_info "=== Active Directory Unbind Started ==="
log_info "Log file: ${LOG_FILE}"

# Check macOS version
macos_version=$(sw_vers -productVersion)
log_info "macOS version: ${macos_version}"

# Check if the device is actually bound to AD
ad_domain=""
if dsconfigad -show &>/dev/null; then
    ad_domain=$(dsconfigad -show | awk '/Active Directory Domain/{print $NF}')
fi

if [[ -z "$ad_domain" ]]; then
    log_warn "This device does not appear to be bound to Active Directory."
    log_warn "Proceeding with cleanup of any residual AD artifacts."
else
    log_info "Currently bound to AD domain: ${ad_domain}"
fi

# --- Confirmation ---
if [[ "$FORCE" != true ]]; then
    echo ""
    echo "============================================================"
    echo "  WARNING: This will make the following changes:"
    echo "============================================================"
    echo ""
    echo "  1. Unbind this Mac from Active Directory (${ad_domain:-N/A})"
    echo "  2. Remove the AD search policy from Directory Services"
    echo "  3. Flush cached AD credentials and Kerberos tickets"
    echo "  4. Remove AD-related configuration profiles and preferences"
    echo "  5. Clean up directory service plugins and cached records"
    echo ""
    echo "  AD-based network accounts will no longer be able to log in."
    echo ""
    read -r -p "Type YES to proceed: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "Operation cancelled by user."
        exit 0
    fi
fi

# --- Step 1: Unbind from Active Directory ---
log_info "Unbinding from Active Directory..."

if [[ -n "$ad_domain" ]]; then
    # Attempt a clean unbind with dsconfigad
    if dsconfigad -remove -force 2>>"$LOG_FILE"; then
        log_success "Successfully unbound from AD domain: ${ad_domain}"
    else
        log_warn "dsconfigad -remove failed. Attempting manual cleanup..."

        # Fallback: remove the AD node directly from Directory Services
        ad_node=$(/usr/bin/dscl localhost -list /Search/Contacts 2>/dev/null | grep "Active Directory" || true)
        if [[ -n "$ad_node" ]]; then
            dscl localhost -delete "/Search/Contacts/${ad_node}" 2>/dev/null || true
            log_info "Removed AD node from search contacts."
        fi
    fi
else
    log_info "No active AD binding found. Skipping unbind command."
fi

# --- Step 2: Remove AD from Directory Services Search Policy ---
log_info "Cleaning Directory Services search policy..."

# Get the current search policy and remove any Active Directory references
current_search_path=$(dscl /Search -read / CSPSearchPath 2>/dev/null | grep -v "^CSPSearchPath:" || true)

needs_update=false
for node in $current_search_path; do
    if [[ "$node" == *"Active Directory"* ]]; then
        log_info "Removing AD node from search path: ${node}"
        dscl /Search -delete / CSPSearchPath "$node" 2>/dev/null || true
        dscl /Search/Contacts -delete / CSPSearchPath "$node" 2>/dev/null || true
        needs_update=true
    fi
done

if [[ "$needs_update" == true ]]; then
    log_success "AD references removed from search policy."
else
    log_info "No AD references found in search policy."
fi

# Reset search policy to local-only (Custom -> Automatic/Local)
dscl /Search -change / SearchPolicy CSPSearchPath NSPSearchPath 2>/dev/null || true
log_info "Search policy reset."

# --- Step 3: Flush Kerberos Tickets and Cached Credentials ---
log_info "Flushing Kerberos tickets and cached credentials..."

# Destroy all Kerberos tickets
if command -v kdestroy &>/dev/null; then
    kdestroy -A 2>/dev/null || true
    log_info "Kerberos tickets destroyed."
fi

# Remove Kerberos configuration that references the AD domain
kerberos_config="/etc/krb5.conf"
if [[ -f "$kerberos_config" ]]; then
    if grep -qi "${ad_domain:-YOURDOMAIN}" "$kerberos_config" 2>/dev/null; then
        log_info "Removing AD-specific Kerberos configuration..."
        mv "$kerberos_config" "${kerberos_config}.bak.$(date +%s)"
        log_info "Backed up and removed ${kerberos_config}"
    fi
fi

# Clear the Kerberos ticket cache directory
kerberos_cache_dir="/tmp/krb5cc_*"
rm -f $kerberos_cache_dir 2>/dev/null || true
log_info "Kerberos ticket caches cleared."

# --- Step 4: Remove Cached AD User Accounts ---
log_info "Removing cached AD mobile accounts..."

# Find and remove AD mobile account home directories are NOT deleted (data preservation)
# Just remove the cached directory records
ad_users=$(dscl . -list /Users OriginalNodeName 2>/dev/null | grep "Active Directory" | awk '{print $1}' || true)

if [[ -n "$ad_users" ]]; then
    while IFS= read -r ad_user; do
        log_info "Removing cached account record for: ${ad_user}"
        dscl . -delete "/Users/${ad_user}" 2>/dev/null || true
    done <<< "$ad_users"
    log_success "Cached AD account records removed."
else
    log_info "No cached AD mobile accounts found."
fi

# --- Step 5: Remove AD Plugin and Configuration Files ---
log_info "Cleaning up AD configuration files..."

ad_config_files=(
    "/Library/Preferences/OpenDirectory/Configurations/Active Directory"
    "/Library/Preferences/OpenDirectory/DynamicData/Active Directory"
    "/Library/Preferences/edu.mit.Kerberos"
    "/Library/Preferences/com.apple.DirectoryService.plist"
    "/Library/Preferences/DirectoryService/ActiveDirectory.plist"
    "/Library/Preferences/DirectoryService/DSLDAPv3PlugInConfig.plist"
)

for path in "${ad_config_files[@]}"; do
    if [[ -e "$path" ]]; then
        log_info "Removing: ${path}"
        rm -rf "$path" 2>/dev/null || true
    fi
done

# Clean up the DirectoryService cache
ds_cache="/Library/Caches/com.apple.opendirectoryd"
if [[ -d "$ds_cache" ]]; then
    log_info "Clearing OpenDirectory cache..."
    rm -rf "$ds_cache" 2>/dev/null || true
fi

log_success "AD configuration files cleaned up."

# --- Step 6: Remove AD-Related Configuration Profiles ---
log_info "Checking for AD-related configuration profiles..."

# List profiles and look for AD binding profiles
profiles_output=$(profiles list -output stdout-xml 2>/dev/null || true)
if echo "$profiles_output" | grep -qi "ActiveDirectory\|com.apple.DirectoryService.managed" 2>/dev/null; then
    log_warn "AD-related configuration profiles detected."
    log_warn "These should be removed via Jamf. If they persist, remove the AD binding profile from the Jamf scope."
else
    log_info "No AD-related configuration profiles found."
fi

# --- Step 7: Restart Directory Services ---
log_info "Restarting directory services..."

killall opendirectoryd 2>/dev/null || true
sleep 2
log_success "Directory services restarted."

# --- Step 8: Flush DNS Cache ---
log_info "Flushing DNS cache..."
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true
log_success "DNS cache flushed."

# --- Step 9: Verify Unbind ---
log_info "Verifying unbind status..."

if dsconfigad -show &>/dev/null; then
    remaining_domain=$(dsconfigad -show | awk '/Active Directory Domain/{print $NF}' || true)
    if [[ -n "$remaining_domain" ]]; then
        log_error "Device still appears bound to: ${remaining_domain}"
        log_error "Manual intervention may be required."
        exit 1
    fi
fi

log_success "Device is no longer bound to Active Directory."

# --- Summary ---
echo ""
log_info "=== Active Directory Unbind Complete ==="
echo ""
echo "============================================================"
echo "  Unbind complete!"
echo "============================================================"
echo ""
echo "  What was done:"
echo "  - Removed Active Directory binding"
echo "  - Cleaned search policy and directory service configuration"
echo "  - Flushed Kerberos tickets and cached credentials"
echo "  - Removed cached AD mobile account records"
echo "  - Cleaned up AD configuration files and caches"
echo "  - Restarted directory services and flushed DNS"
echo ""
echo "  Important notes:"
echo "  - AD network accounts can no longer log in to this Mac"
echo "  - Home folders for AD accounts were NOT deleted"
echo "  - If an AD binding profile exists in Jamf, remove this"
echo "    device from its scope to prevent re-binding"
echo "  - A reboot is recommended but not strictly required"
echo ""
echo "  Log file: ${LOG_FILE}"
echo ""

log_info "Done."
