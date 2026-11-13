<#
.SYNOPSIS
    Read-only pre-check of an existing vSphere platform before adopting it into VCF 9.x
    (Converge to a new VCF instance / management domain, or Import as a VI workload domain).

.DESCRIPTION
    Connects to a vCenter with PowerCLI and evaluates the environment against the common
    blockers seen when running the VCF Installer converge or import workflows. Nothing is
    changed in the environment. Results are written to the console, a CSV and an HTML report.

    This script complements, and does not replace, the built-in validation in the VCF Installer
    or SDDC Manager. Version thresholds are parameters: confirm them against the Broadcom
    release notes and the "Supported scenarios to converge to VCF" documentation for the exact
    9.x build you are targeting, then override as needed.

    Status meanings:
      FAIL  Known blocker, remediate before running the VCF workflow
      WARN  Possible blocker or design decision, review against the target 9.x release
      PASS  Check met
      INFO  Context only

.PARAMETER Mode
    Converge : existing vCenter becomes the management domain of a new VCF instance (all clusters
               in that vCenter are adopted into the management domain).
    Import   : existing vCenter is imported into an existing VCF 9.x instance as a VI workload domain.

.EXAMPLE
    $cred = Get-Credential administrator@vsphere.local
    .\Invoke-VcfAdoptionPrecheck.ps1 -VCenter vc01.corp.local -Credential $cred -Mode Import `
        -NsxManager nsx01.corp.local -NsxCredential (Get-Credential admin)

.EXAMPLE
    .\Invoke-VcfAdoptionPrecheck.ps1 -VCenter vc01.corp.local -Credential $cred -Mode Converge `
        -MinVCenterVersion 9.0.0 -RequiredFreeMemoryGB 256 -OutputPath C:\Reports

.NOTES
    Requires: PowerShell 7.x recommended, VMware.PowerCLI 13.x or later (VCF.PowerCLI 9.x also works).
    Account: read-only vCenter role is sufficient for everything except esxcli path listing,
             which needs Host.Config.Storage visibility (any admin-class read role works).
    Exit code: 0 = all PASS/INFO, 1 = WARN present, 2 = FAIL present.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VCenter,
    [Parameter(Mandatory)] [pscredential] $Credential,
    [ValidateSet('Converge', 'Import')] [string] $Mode = 'Import',

    # Version gates (defaults reflect published VCF 9.0 guidance; override for your target build)
    [version] $MinVCenterVersion,
    [version] $MinEsxVersion = '8.0.1',
    [version] $MinNsxVersion = '4.1.0.2',

    # Optional NSX Manager to validate (VIP or node FQDN)
    [string] $NsxManager,
    [pscredential] $NsxCredential,

    # Capacity headroom you expect to need for new VCF management appliances
    # (SDDC Manager, NSX Managers, VCF Operations, fleet components). Size from the VCF planning guide.
    [int] $RequiredFreeCpuGHz = 60,
    [int] $RequiredFreeMemoryGB = 192,
    [int] $RequiredFreeStorageGB = 2000,

    [int] $MinHostsPerCluster = 3,
    [int] $CertWarnDays = 60,
    [string] $OutputPath = (Join-Path $PWD "vcf-precheck-$(Get-Date -Format yyyyMMdd-HHmm)")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('MinVCenterVersion')) {
    # Converge to VCF 9.0.0/9.0.1 (no attached NSX) requires vCenter 9.0+; Import accepts 8.0 U1+.
    $MinVCenterVersion = if ($Mode -eq 'Converge') { [version]'9.0.0' } else { [version]'8.0.1' }
}

#region Helpers ---------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string] $Category, [string] $Scope, [string] $Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status,
        [string] $Detail, [string] $Remediation = ''
    )
    $script:Results.Add([pscustomobject]@{
            Category = $Category; Scope = $Scope; Check = $Check
            Status = $Status; Detail = $Detail; Remediation = $Remediation
        })
    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host ("[{0}] {1,-12} {2,-28} {3}: {4}" -f $Status, $Category, $Scope, $Check, $Detail) -ForegroundColor $colour
}

function ConvertTo-Version([string] $v) {
    # Normalise strings such as "8.0.3" or "4.2.1.0.0.24304122" to a comparable [version]
    $parts = ($v -split '[^\d]+' | Where-Object { $_ -ne '' } | Select-Object -First 4)
    while ($parts.Count -lt 2) { $parts += '0' }
    [version]($parts -join '.')
}

function Test-DnsRoundTrip([string] $Name) {
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($Name) | Where-Object AddressFamily -eq 'InterNetwork'
        if (-not $ips) { return @{ Ok = $false; Detail = "No A record for $Name" } }
        $ip = $ips[0].IPAddressToString
        try {
            $rev = [System.Net.Dns]::GetHostEntry($ip).HostName
        } catch { return @{ Ok = $false; Detail = "$Name -> $ip, no PTR record" } }
        if ($rev -ieq $Name -or $rev -ilike "$Name.*" -or $Name -ilike "$rev.*") {
            return @{ Ok = $true; Detail = "$Name <-> $ip" }
        }
        return @{ Ok = $false; Detail = "$Name -> $ip but PTR returns $rev" }
    } catch { return @{ Ok = $false; Detail = "Lookup failed for ${Name}: $($_.Exception.Message)" } }
}

function Get-RemoteCertificate([string] $HostName, [int] $Port = 443) {
    $tcp = [System.Net.Sockets.TcpClient]::new($HostName, $Port)
    try {
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($HostName)
        [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
    } finally { $tcp.Dispose() }
}
#endregion

#region Connect ---------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core, VCF.PowerCLI)) {
    throw 'PowerCLI not found. Install-Module VCF.PowerCLI (or VMware.PowerCLI) -Scope CurrentUser'
}
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

Write-Host "`nVCF 9.x adoption pre-check | Mode: $Mode | Target: $VCenter`n" -ForegroundColor Cyan
$vc = Connect-VIServer -Server $VCenter -Credential $Credential
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
#endregion

#region vCenter ----------------------------------------------------------------
$cat = 'vCenter'
$vcVer = ConvertTo-Version $vc.Version
Add-Result $cat $VCenter 'Version' ($(if ($vcVer -ge $MinVCenterVersion) { 'PASS' } else { 'FAIL' })) `
    "vCenter $($vc.Version) build $($vc.Build) (minimum $MinVCenterVersion for $Mode)" `
    'Upgrade vCenter using the standard vSphere upgrade process before adoption.'

# Enhanced Linked Mode
try {
    $linked = Connect-VIServer -Server $VCenter -Credential $Credential -AllLinked -NotDefault -ErrorAction Stop
    $others = @($linked | Where-Object { $_.Name -ne $vc.Name })
    if ($others.Count -gt 0) {
        Add-Result $cat $VCenter 'Enhanced Linked Mode' 'FAIL' "Linked with: $($others.Name -join ', ')" `
            'Each adopted vCenter needs its own SSO domain. Plan ELM decommission/repointing per Broadcom guidance.'
    } else {
        Add-Result $cat $VCenter 'Enhanced Linked Mode' 'PASS' 'Standalone SSO domain'
    }
    $others | ForEach-Object { Disconnect-VIServer -Server $_ -Confirm:$false -ErrorAction SilentlyContinue }
} catch {
    Add-Result $cat $VCenter 'Enhanced Linked Mode' 'WARN' "Could not evaluate: $($_.Exception.Message)"
}

# vCenter HA
try {
    $si = Get-View ServiceInstance -Server $vc
    $fcm = Get-View $si.Content.FailoverClusterManager -Server $vc
    $vchaMode = $fcm.GetClusterMode()
    Add-Result $cat $VCenter 'vCenter HA' ($(if ($vchaMode -eq 'disabled') { 'PASS' } else { 'FAIL' })) `
        "VCHA mode: $vchaMode" 'Remove vCenter HA before adoption.'
} catch {
    Add-Result $cat $VCenter 'vCenter HA' 'INFO' 'VCHA not configured or not queryable'
}

# DNS and certificate
$dns = Test-DnsRoundTrip $VCenter
Add-Result $cat $VCenter 'DNS forward/reverse' ($(if ($dns.Ok) { 'PASS' } else { 'FAIL' })) $dns.Detail `
    'Create matching A and PTR records using the FQDN (not short name or IP).'

try {
    $cert = Get-RemoteCertificate $VCenter
    $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
    $st = if ($days -lt 0) { 'FAIL' } elseif ($days -lt $CertWarnDays) { 'WARN' } else { 'PASS' }
    Add-Result $cat $VCenter 'Machine SSL certificate' $st "Expires $($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days), issuer: $($cert.Issuer)" `
        'Renew the vCenter Machine SSL certificate before adoption.'
} catch {
    Add-Result $cat $VCenter 'Machine SSL certificate' 'WARN' "Could not read certificate: $($_.Exception.Message)"
}

# Where does the vCenter appliance itself run?
$vcIps = @([System.Net.Dns]::GetHostAddresses($VCenter) | ForEach-Object IPAddressToString)
$vcCluster = $null
$vcVm = Get-VM -Server $vc | Where-Object {
    $_.Guest.HostName -ieq $VCenter -or ($_.Guest.IPAddress | Where-Object { $_ -in $vcIps })
} | Select-Object -First 1
if ($vcVm) {
    $vcCluster = (Get-Cluster -VM $vcVm -Server $vc -ErrorAction SilentlyContinue).Name
    Add-Result $cat $VCenter 'Appliance placement' 'INFO' "vCenter VM '$($vcVm.Name)' runs in cluster '$vcCluster'"
} else {
    $st = if ($Mode -eq 'Converge') { 'WARN' } else { 'INFO' }
    Add-Result $cat $VCenter 'Appliance placement' $st 'vCenter VM not found in its own inventory (externally hosted?)' `
        'Converge expects the vCenter appliance to run in a cluster it manages. Confirm the supported topology.'
}
#endregion

#region Inventory shape -------------------------------------------------------
$cat = 'Inventory'
$clusters = @(Get-Cluster -Server $vc)
$allHosts = @(Get-VMHost -Server $vc)
Add-Result $cat $VCenter 'Clusters / hosts' 'INFO' "$($clusters.Count) clusters, $($allHosts.Count) hosts, $(@(Get-Datacenter -Server $vc).Count) datacenter(s)"
if ($Mode -eq 'Converge') {
    Add-Result $cat $VCenter 'Converge scope' 'INFO' 'All clusters in this vCenter will be adopted into the management domain.'
}

$standalone = @($allHosts | Where-Object { $_.ExtensionData.Parent.Type -ne 'ClusterComputeResource' })
Add-Result $cat $VCenter 'Standalone hosts' ($(if ($standalone.Count) { 'FAIL' } else { 'PASS' })) `
    ($(if ($standalone.Count) { "Not in a cluster: $($standalone.Name -join ', ')" } else { 'All hosts are in clusters' })) `
    'Move standalone hosts into a cluster or remove them from vCenter.'
#endregion

#region Per cluster -----------------------------------------------------------
$transportCache = @{}

foreach ($cl in $clusters) {
    $cat = 'Cluster'
    $hosts = @(Get-VMHost -Location $cl -Server $vc)
    $scope = $cl.Name
    $vsan = $null

    Add-Result $cat $scope 'Host count' ($(if ($hosts.Count -ge $MinHostsPerCluster) { 'PASS' } else { 'WARN' })) `
        "$($hosts.Count) hosts (expected >= $MinHostsPerCluster)" 'Confirm the minimum host count for this storage type and domain role.'

    Add-Result $cat $scope 'vSphere HA' ($(if ($cl.HAEnabled) { 'PASS' } else { 'WARN' })) "HA enabled: $($cl.HAEnabled)" 'Enable vSphere HA.'

    $drsOk = $cl.DrsEnabled -and $cl.DrsAutomationLevel -eq 'FullyAutomated'
    Add-Result $cat $scope 'vSphere DRS' ($(if ($drsOk) { 'PASS' } else { 'WARN' })) `
        "DRS enabled: $($cl.DrsEnabled), level: $($cl.DrsAutomationLevel)" 'Enable DRS in Fully Automated mode.'

    $lcm = $cl.ExtensionData.LifecycleManaged
    Add-Result $cat $scope 'vLCM image-managed' ($(if ($lcm) { 'PASS' } else { 'WARN' })) `
        ($(if ($lcm) { 'Cluster is managed by a single image' } else { 'Cluster uses baselines (VUM)' })) `
        'Transition the cluster to vLCM images. Baseline clusters have reduced lifecycle options after adoption in VCF 9.x.'

    # ESX version gate and consistency
    $versions = $hosts | Group-Object { "$($_.Version) build $($_.Build)" }
    $low = @($hosts | Where-Object { (ConvertTo-Version $_.Version) -lt $MinEsxVersion })
    Add-Result $cat $scope 'ESX minimum version' ($(if ($low.Count) { 'FAIL' } else { 'PASS' })) `
        ($(if ($low.Count) { "Below $($MinEsxVersion): $($low.Name -join ', ')" } else { "All hosts >= $MinEsxVersion" })) `
        'Upgrade ESX hosts with vLCM before adoption.'
    Add-Result $cat $scope 'ESX build consistency' ($(if ($versions.Count -eq 1) { 'PASS' } else { 'WARN' })) `
        (($versions | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join '; ') `
        'Remediate hosts to a single image/build.'

    # vSAN
    try {
        $vsan = Get-VsanClusterConfiguration -Cluster $cl -Server $vc
        if ($vsan.VsanEnabled) {
            $esa = if ($vsan.PSObject.Properties['VsanEsaEnabled']) { $vsan.VsanEsaEnabled } else { 'unknown' }
            Add-Result 'vSAN' $scope 'vSAN' 'INFO' "vSAN enabled, ESA: $esa"
            Add-Result 'vSAN' $scope 'Stretched cluster' ($(if ($vsan.StretchedClusterEnabled) { 'WARN' } else { 'PASS' })) `
                "Stretched: $($vsan.StretchedClusterEnabled)" 'Confirm stretched-cluster support for this adoption path and 9.x build.'
            try {
                $health = Test-VsanClusterHealth -Cluster $cl -Server $vc -ErrorAction Stop
                $st = switch ($health.OverallHealthStatus) { 'green' { 'PASS' } 'yellow' { 'WARN' } default { 'FAIL' } }
                Add-Result 'vSAN' $scope 'vSAN health' $st "Overall: $($health.OverallHealthStatus)" 'Resolve vSAN Skyline Health findings.'
            } catch { Add-Result 'vSAN' $scope 'vSAN health' 'WARN' 'Health test not available with this account/PowerCLI' }
        }
    } catch { Add-Result 'vSAN' $scope 'vSAN' 'WARN' "Could not read vSAN config: $($_.Exception.Message)" }

    # Storage types
    $dsList = @(Get-Datastore -RelatedObject $cl -Server $vc | Where-Object { $_.ExtensionData.Summary.MultipleHostAccess })
    foreach ($ds in $dsList) {
        $type = $ds.Type
        $status = 'PASS'; $detail = "$type, $([math]::Round($ds.FreeSpaceGB)) GB free of $([math]::Round($ds.CapacityGB)) GB"
        switch ($type) {
            'NFS41' { $status = 'WARN'; $detail += ' (NFS 4.1: confirm support as principal storage)' }
            'VVOL'  { $status = 'WARN'; $detail += ' (vVols: confirm support for this path)' }
            'VMFS' {
                $h0 = $hosts | Where-Object ConnectionState -eq 'Connected' | Select-Object -First 1
                if ($h0) {
                    if (-not $transportCache.ContainsKey($h0.Name)) {
                        try {
                            $esx = Get-EsxCli -VMHost $h0 -V2 -Server $vc
                            $map = @{}
                            $esx.storage.core.path.list.Invoke() | ForEach-Object { $map[$_.Device] = $_.Transport }
                            $transportCache[$h0.Name] = $map
                        } catch { $transportCache[$h0.Name] = @{} }
                    }
                    $tx = @($ds.ExtensionData.Info.Vmfs.Extent | ForEach-Object { $transportCache[$h0.Name][$_.DiskName] } |
                            Where-Object { $_ } | Select-Object -Unique)
                    $detail += " transport: $(if ($tx) { $tx -join ',' } else { 'unknown' })"
                    if ($tx -and ($tx | Where-Object { $_ -notin 'fc', 'fcoe' })) {
                        $status = 'WARN'; $detail += ' (non-FC VMFS: confirm support as principal storage)'
                    }
                }
            }
        }
        Add-Result 'Storage' "$scope/$($ds.Name)" 'Shared datastore' $status $detail
    }

    # Capacity headroom (raw, before HA admission control)
    $freeCpu = 0; $freeMem = 0; $freeDs = 0
    foreach ($h in $hosts) { $freeCpu += ($h.CpuTotalMhz - $h.CpuUsageMhz) / 1000; $freeMem += $h.MemoryTotalGB - $h.MemoryUsageGB }
    foreach ($ds in $dsList) { $freeDs += $ds.FreeSpaceGB }
    $capOk = $freeCpu -ge $RequiredFreeCpuGHz -and $freeMem -ge $RequiredFreeMemoryGB -and $freeDs -ge $RequiredFreeStorageGB
    $capStatus = if ($capOk) { 'PASS' } elseif ($Mode -eq 'Converge' -or $cl.Name -eq $vcCluster) { 'WARN' } else { 'INFO' }
    Add-Result 'Capacity' $scope 'Headroom for VCF appliances' $capStatus `
        ("Free: {0:N0} GHz CPU, {1:N0} GB RAM, {2:N0} GB shared storage (target {3}/{4}/{5})" -f $freeCpu, $freeMem, $freeDs, $RequiredFreeCpuGHz, $RequiredFreeMemoryGB, $RequiredFreeStorageGB) `
        'Size against the VCF 9.x planning guide including HA failover capacity.'

    #region Per host
    $ntpSets = @{}
    foreach ($h in $hosts) {
        $hs = "$scope/$($h.Name)"

        $connOk = $h.ConnectionState -eq 'Connected'
        Add-Result 'Host' $hs 'State' ($(if ($connOk) { 'PASS' } else { 'FAIL' })) "ConnectionState: $($h.ConnectionState)" `
            'Exit maintenance mode and reconnect all hosts.'
        if ($h.ConnectionState -ne 'Connected' -and $h.ConnectionState -ne 'Maintenance') { continue }

        $lock = $h.ExtensionData.Config.LockdownMode
        Add-Result 'Host' $hs 'Lockdown mode' ($(if ($lock -eq 'lockdownDisabled') { 'PASS' } else { 'WARN' })) "$lock" 'Disable lockdown mode for the adoption window.'

        $d = Test-DnsRoundTrip $h.Name
        Add-Result 'Host' $hs 'DNS forward/reverse' ($(if ($d.Ok) { 'PASS' } else { 'FAIL' })) $d.Detail `
            'Hosts must be added to vCenter by FQDN with matching A and PTR records.'

        # NTP
        $ntp = @(Get-VMHostNtpServer -VMHost $h -Server $vc)
        $ntpd = Get-VMHostService -VMHost $h -Server $vc | Where-Object Key -eq 'ntpd'
        $ntpOk = $ntp.Count -gt 0 -and $ntpd.Running
        $ntpSets[$h.Name] = ($ntp | Sort-Object) -join ','
        Add-Result 'Host' $hs 'NTP' ($(if ($ntpOk) { 'PASS' } else { 'FAIL' })) "Servers: $($ntpSets[$h.Name]); ntpd running: $($ntpd.Running)" `
            'Configure NTP and start ntpd (policy On).'

        # Networking: VMkernel adapters must sit on a vDS
        $vmks = @(Get-VMHostNetworkAdapter -VMHost $h -VMKernel -Server $vc)
        $onVss = @($vmks | Where-Object { -not $_.ExtensionData.Spec.DistributedVirtualPort })
        Add-Result 'Network' $hs 'VMkernel on vDS' ($(if ($onVss.Count) { 'FAIL' } else { 'PASS' })) `
            ($(if ($onVss.Count) { "On standard switch: $(($onVss | ForEach-Object { "$($_.Name)/$($_.PortGroupName)" }) -join ', ')" } else { 'All VMkernel adapters on vDS' })) `
            'Migrate VMkernel adapters (management, vMotion, vSAN, storage) to a vDS.'

        $vssWithUplinks = @(Get-VirtualSwitch -VMHost $h -Standard -Server $vc | Where-Object { $_.Nic })
        if ($vssWithUplinks) {
            Add-Result 'Network' $hs 'Standard switch uplinks' 'WARN' "vSS with physical NICs: $($vssWithUplinks.Name -join ', ')" `
                'Move remaining uplinks and port groups to vDS.'
        }

        $vmo = @($vmks | Where-Object VMotionEnabled)
        Add-Result 'Network' $hs 'vMotion VMkernel' ($(if ($vmo.Count) { 'PASS' } else { 'FAIL' })) `
            ($(if ($vmo.Count) { "$($vmo.Name -join ',')" } else { 'No vMotion-enabled VMkernel' })) 'Create a dedicated vMotion VMkernel on the vDS.'

        if ($vsan -and $vsan.VsanEnabled) {
            $vsk = @($vmks | Where-Object VsanTrafficEnabled)
            Add-Result 'Network' $hs 'vSAN VMkernel' ($(if ($vsk.Count) { 'PASS' } else { 'FAIL' })) `
                ($(if ($vsk.Count) { "$($vsk.Name -join ',')" } else { 'No vSAN-enabled VMkernel' })) 'Tag a vDS VMkernel for vSAN traffic.'
        }
    }
    $distinctNtp = @($ntpSets.Values | Select-Object -Unique)
    Add-Result 'Host' $scope 'NTP consistency' ($(if ($distinctNtp.Count -le 1) { 'PASS' } else { 'WARN' })) `
        "$($distinctNtp.Count) distinct NTP configuration(s)" 'Use the same NTP sources on every host and vCenter.'
    #endregion
}
#endregion

#region Distributed switches -------------------------------------------------
foreach ($vds in @(Get-VDSwitch -Server $vc)) {
    $lag = @($vds.ExtensionData.Config.LacpGroupConfig)
    Add-Result 'Network' "vDS/$($vds.Name)" 'LACP / LAG' ($(if ($lag.Count) { 'WARN' } else { 'PASS' })) `
        ($(if ($lag.Count) { "LAGs: $($lag.Name -join ', ')" } else { 'No LAGs configured' })) `
        'LACP on vDS can block NSX deployment during adoption. Confirm support or move to active/active teaming.'
    Add-Result 'Network' "vDS/$($vds.Name)" 'Version / MTU' 'INFO' "vDS $($vds.Version), MTU $($vds.Mtu), hosts $(@($vds | Get-VMHost).Count)"
    if ($vds.Mtu -lt 1600) {
        Add-Result 'Network' "vDS/$($vds.Name)" 'MTU for overlay' 'WARN' "MTU $($vds.Mtu)" 'NSX overlay needs MTU >= 1600 (9000 recommended) end to end.'
    }
}
#endregion

#region NSX (optional) -------------------------------------------------------
if ($NsxManager) {
    if (-not $NsxCredential) { $NsxCredential = Get-Credential -Message "NSX Manager credentials for $NsxManager" }
    try {
        $irm = @{ Uri = "https://$NsxManager/api/v1/node/version"; Credential = $NsxCredential; Authentication = 'Basic' }
        if ($PSVersionTable.PSVersion.Major -ge 7) { $irm.SkipCertificateCheck = $true }
        $nv = Invoke-RestMethod @irm
        $nsxVer = ConvertTo-Version $nv.product_version
        Add-Result 'NSX' $NsxManager 'Version' ($(if ($nsxVer -ge $MinNsxVersion) { 'PASS' } else { 'FAIL' })) `
            "NSX $($nv.product_version) (minimum $MinNsxVersion)" 'Upgrade NSX before adoption.'

        $irm.Uri = "https://$NsxManager/api/v1/fabric/compute-managers"
        $cms = (Invoke-RestMethod @irm).results
        $st = if (@($cms).Count -eq 1) { 'PASS' } else { 'FAIL' }
        Add-Result 'NSX' $NsxManager 'Compute managers' $st "Registered: $((@($cms) | ForEach-Object server) -join ', ')" `
            'NSX Manager must be registered to exactly one vCenter (1:1) for adoption.'

        $irm.Uri = "https://$NsxManager/api/v1/cluster/status"
        $cs = Invoke-RestMethod @irm
        $st = if ($cs.mgmt_cluster_status.status -eq 'STABLE') { 'PASS' } else { 'FAIL' }
        Add-Result 'NSX' $NsxManager 'Manager cluster' $st "Mgmt cluster: $($cs.mgmt_cluster_status.status); control: $($cs.control_cluster_status.status)"
    } catch {
        Add-Result 'NSX' $NsxManager 'API' 'FAIL' "NSX API call failed: $($_.Exception.Message)"
    }
} else {
    Add-Result 'NSX' $VCenter 'NSX' 'INFO' 'No NSX Manager supplied. If NSX is attached to this vCenter, re-run with -NsxManager.'
}
#endregion

#region Report ---------------------------------------------------------------
$csv  = Join-Path $OutputPath 'vcf-precheck.csv'
$html = Join-Path $OutputPath 'vcf-precheck.html'
$script:Results | Export-Csv -Path $csv -NoTypeInformation

$summary = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
$style = @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#222;margin:24px}
h1{font-size:20px} table{border-collapse:collapse;width:100%} th,td{border:1px solid #ddd;padding:6px;text-align:left;vertical-align:top}
th{background:#f3f4f6} tr.FAIL td{background:#fde8e8} tr.WARN td{background:#fff7e0} tr.PASS td{background:#eef9f0}
</style>
'@
$rows = ($script:Results | Sort-Object @{ e = { @{ FAIL = 0; WARN = 1; PASS = 2; INFO = 3 }[$_.Status] } }, Category, Scope | ForEach-Object {
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        "<tr class='$($_.Status)'><td>$($_.Status)</td><td>$(& $enc $_.Category)</td><td>$(& $enc $_.Scope)</td><td>$(& $enc $_.Check)</td><td>$(& $enc $_.Detail)</td><td>$(& $enc $_.Remediation)</td></tr>"
    }) -join "`n"
@"
<html><head><meta charset='utf-8'><title>VCF 9.x adoption pre-check: $VCenter</title>$style</head><body>
<h1>VCF 9.x adoption pre-check: $VCenter</h1>
<p>Mode: <b>$Mode</b> | vCenter $($vc.Version) build $($vc.Build) | Run: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $($summary -join ' | ')</p>
<p>Thresholds: vCenter &gt;= $MinVCenterVersion, ESX &gt;= $MinEsxVersion, NSX &gt;= $MinNsxVersion. Validate against Broadcom documentation for the target 9.x build. Run the VCF Installer prerequisite check as the final gate.</p>
<table><tr><th>Status</th><th>Category</th><th>Scope</th><th>Check</th><th>Detail</th><th>Remediation</th></tr>
$rows
</table></body></html>
"@ | Set-Content -Path $html -Encoding UTF8

Disconnect-VIServer -Server $vc -Confirm:$false
Write-Host "`nSummary: $($summary -join ' | ')" -ForegroundColor Cyan
Write-Host "Reports: $csv`n         $html`n" -ForegroundColor Cyan

if ($script:Results.Status -contains 'FAIL') { exit 2 }
elseif ($script:Results.Status -contains 'WARN') { exit 1 }
else { exit 0 }
#endregion
