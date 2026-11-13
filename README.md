# VCF 9.x Adoption Pre-check

A read-only PowerCLI script that looks over an existing vSphere environment before you bring it into VMware Cloud Foundation 9.x, either by converging it into a new VCF instance or importing it as a VI workload domain.

The VCF Installer has its own prerequisite validation, and that stays the final gate. This script is for the weeks before that run, when you want a list of blockers you can hand to the platform team and work through, rather than finding them one at a time in the installer wizard.

Nothing in the environment is changed.

## What it looks at

| Area | Checks |
|---|---|
| vCenter | Version against the mode's minimum, Enhanced Linked Mode, vCenter HA, DNS forward and reverse, Machine SSL certificate expiry, which cluster the appliance runs in |
| Clusters | Host count, HA, DRS (fully automated), vLCM image vs baselines, ESX minimum version and build consistency, standalone hosts |
| vSAN | Enabled, ESA, stretched cluster, Skyline health |
| Storage | Type of each shared datastore; VMFS transport (FC, iSCSI and so on) read through esxcli |
| Networking | VMkernel adapters left on standard switches, standard switch uplinks, vMotion and vSAN VMkernels, LACP/LAG on vDS, vDS MTU |
| Hosts | Connection state, lockdown mode, DNS, NTP configured, running and consistent |
| NSX (optional) | Version, 1:1 compute manager registration, manager cluster status |
| Capacity | Free CPU, memory and shared storage per cluster against the headroom you expect the new management appliances to need |

Each finding is marked:

- **FAIL**: a known blocker, fix it first
- **WARN**: might block, or is a design decision to confirm against your target 9.x build
- **PASS** / **INFO**

## Requirements

- PowerShell 7.x (Windows PowerShell 5.1 mostly works, but the NSX calls are written for 7)
- `VCF.PowerCLI` 9.x or `VMware.PowerCLI` 13.x
- A vCenter account with at least read-only rights. The esxcli storage path lookup needs host storage visibility.
- Network access to vCenter, the ESX hosts' DNS names, and NSX Manager if you're checking it

```powershell
Install-Module VCF.PowerCLI -Scope CurrentUser
```

## Usage

```powershell
$cred = Get-Credential administrator@vsphere.local

# Import into an existing VCF 9.x instance as a workload domain
.\Invoke-VcfAdoptionPrecheck.ps1 -VCenter vc01.corp.local -Credential $cred -Mode Import

# Same, with NSX already attached to this vCenter
.\Invoke-VcfAdoptionPrecheck.ps1 -VCenter vc01.corp.local -Credential $cred -Mode Import `
    -NsxManager nsx01.corp.local -NsxCredential (Get-Credential admin)

# Converge into a new VCF instance, with your own capacity targets
.\Invoke-VcfAdoptionPrecheck.ps1 -VCenter vc01.corp.local -Credential $cred -Mode Converge `
    -RequiredFreeCpuGHz 80 -RequiredFreeMemoryGB 256 -RequiredFreeStorageGB 3000 `
    -OutputPath C:\Reports\vc01
```

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Mode` | `Import` | `Converge` or `Import` |
| `-MinVCenterVersion` | 9.0.0 (Converge), 8.0.1 (Import) | |
| `-MinEsxVersion` | 8.0.1 | |
| `-MinNsxVersion` | 4.1.0.2 | |
| `-NsxManager`, `-NsxCredential` | none | NSX checks are skipped without these |
| `-RequiredFreeCpuGHz` / `MemoryGB` / `StorageGB` | 60 / 192 / 2000 | Placeholders. Size from the VCF 9 planning guide |
| `-MinHostsPerCluster` | 3 | |
| `-CertWarnDays` | 60 | |
| `-OutputPath` | `./vcf-precheck-<timestamp>` | |

The version defaults follow the published VCF 9.0 guidance. Support has been widening with each 9.x release, so check the release notes for the build you're actually targeting and override as needed.

## Output

- Colour-coded console output as it runs
- `vcf-precheck.csv` for filtering or importing elsewhere
- `vcf-precheck.html`, sorted FAIL first, with a remediation note on each row

Exit codes: `0` everything passed, `1` warnings, `2` at least one failure. Handy if you schedule it or run it from a pipeline.

## Known gaps

- Hardware compatibility (BCG/HCL) isn't checked. Use vLCM's hardware compatibility view.
- Capacity is raw free resource and doesn't model HA admission control.
- Storage and stretched-cluster support differs between converge and import and between 9.x builds, so those come back as WARN rather than FAIL.

## Licence

MIT. Use at your own risk, and test against a lab vCenter before pointing it at production.
