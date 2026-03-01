# Modern Device Management

A collection of scripts for modern device management tasks across macOS and Windows platforms.

## Repository Structure

```
modern-device-management/
├── macOS/              # Scripts for macOS device management
├── Windows/            # Scripts for Windows device management (PowerShell Core)
└── README.md
```

## Scripts

### Windows

| Script | Description |
|--------|-------------|
| [Convert-HybridToEntraManaged.ps1](Windows/Convert-HybridToEntraManaged.ps1) | Converts a Hybrid Azure AD Joined, co-managed device to Entra ID Joined only with Intune management. Removes SCCM, Group Policy artifacts, and the on-premises domain join. |

### macOS

*No scripts yet.*

## Requirements

- **Windows scripts**: PowerShell 7+ (PowerShell Core)
- **macOS scripts**: Bash or Zsh (as noted per script)

## Getting Started

Clone the repository and navigate to the platform-specific folder for the script you need. Each folder contains its own README with detailed usage instructions for the scripts within.

```bash
git clone <repository-url>
cd modern-device-management
```
