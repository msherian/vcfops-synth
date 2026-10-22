function Import-SynthRvtools {
    <#
    .SYNOPSIS
        Turns an RVTools export into the inventory model every later stage works from.

    .DESCRIPTION
        Reads vInfo and vHost (required) and vCPU, vMemory, vDisk, vPartition,
        vNetwork, vSnapshot, vTools, vRP, vCluster, vHBA, vNIC, vSwitch, vPort,
        dvSwitch, dvPort, vSC_VMK, vDatastore and vMetaData (used when present),
        joins them by VM and host, and returns the whole estate: datacenters,
        clusters, hosts, datastores, switches, networks (port groups), resource
        pools, folders and VMs, with:

          - placement: VM to host, cluster, datacenter, datastores, folder,
            resource pool and networks; host to switches and networks;
          - sizing and configuration: vCPU, memory, virtual disks, network
            adapters, guest OS, hardware version, Tools status, snapshots; host
            NICs, HBAs and VMkernel adapters;
          - baselines from RVTools' single usage sample: VM CPU and memory use,
            guest disk use, host CPU and memory use, datastore use;
          - with -Performance, LiveOptics averages and peaks per VM and host;
          - a tier, application and workload profile from the tiering rules.

        Templates and SRM placeholders are skipped. IP addresses, DNS names, MAC
        addresses and WWNs are never read. With -Anonymise, names of VMs, hosts,
        clusters, datacenters, datastores, distributed switches, networks,
        resource pools and folders become stable pseudonyms (vm-3f9a2c1d0b), and
        annotations, snapshot names and partition paths are dropped. Tiering rules and the
        LiveOptics join still see the real values, because they run first.

        Rows that cannot be used are listed in report.skipped and other problems
        in report.warnings, by tab and spreadsheet row, so the import never fails
        on one bad row.

    .PARAMETER Path
        The RVTools xlsx, or a folder of RVTools CSV files.

    .PARAMETER Key
        Key for object IDs and pseudonyms; see Get-SynthAnonymisationKey.

    .PARAMETER TieringRules
        Rules from Get-SynthTieringRule. Defaults to every VM Bronze.

    .PARAMETER Anonymise
        Replace names with pseudonyms and drop free-text fields.

    .PARAMETER Performance
        LiveOptics rows from Read-SynthLiveOptics. VMs join on the vCenter
        managed object ID, then on name; hosts on name. A VM with LiveOptics data
        is profiled by its LiveOptics averages instead of the RVTools sample.

    .EXAMPLE
        $inventory = Import-SynthRvtools -Path ./data/rvtools.xlsx -Key $key -Anonymise

    .EXAMPLE
        $perf = Read-SynthLiveOptics -Path ./data/LiveOptics_VMWARE.xlsx
        $inventory = Import-SynthRvtools -Path ./data/rvtools.xlsx -Key $key -Performance $perf -Anonymise
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'RVTools is the product name, not a plural.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Key', Justification = 'Used inside the newId script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key,
        [hashtable]$TieringRules,
        [switch]$Anonymise,
        [hashtable]$Performance
    )

    if (-not $TieringRules) { $TieringRules = Get-SynthTieringRule }
    $source = Read-SynthRvtoolsSource -Path $Path
    $report = @{
        warnings = [System.Collections.Generic.List[string]]::new()
        skipped  = [System.Collections.Generic.List[hashtable]]::new()
    }

    # Resolve the columns of every tab present; a required tab or column missing stops the import.
    $tabs = @{}
    foreach ($name in $source.Tabs.Keys) {
        $columns = Resolve-SynthRvtoolsColumn -Tab $name -Header $source.Tabs[$name].Headers
        if ($columns.Missing.Count -gt 0) {
            if ($name -in 'vInfo', 'vHost') {
                throw "RVTools tab $name has no $($columns.Missing -join '; '). Is this an RVTools export?"
            }
            $report.warnings.Add("Tab $name was ignored: it has no $($columns.Missing -join '; ').")
            continue
        }
        $tabs[$name] = @{ Columns = $columns; Rows = $source.Tabs[$name].Rows }
    }
    foreach ($name in 'vInfo', 'vHost') {
        if (-not $tabs.ContainsKey($name)) {
            throw "The export has no $name tab, which the importer needs. Export all tabs from RVTools."
        }
    }
    foreach ($name in 'vCPU', 'vMemory', 'vCluster', 'vDatastore', 'vPartition', 'vSnapshot', 'vTools') {
        if (-not $tabs.ContainsKey($name)) { $report.warnings.Add("The export has no $name tab; the values it carries are left empty.") }
    }

    $ids = @{}
    $newId = {
        param($Kind, $Identity)
        $id = Get-SynthObjectId -Kind $Kind -Identity $Identity -Key $Key
        if ($ids.ContainsKey($id) -and $ids[$id] -ne $Identity) {
            throw "Two $Kind objects hash to the same ID $id. Delete anonymise.key and import again."
        }
        $ids[$id] = $Identity
        $id
    }
    $label = {
        param($Name, $Id)
        if ($Anonymise) { $Id } else { $Name }
    }

    # Hosts, clusters and datacenters, from vHost and vCluster.
    $datacenters = @{}
    $clusters = @{}
    $hosts = @{}
    $hostsByName = @{}
    $servers = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $clusterFlags = @{}
    if ($tabs.ContainsKey('vCluster')) {
        $t = $tabs.vCluster
        foreach ($row in $t.Rows) {
            $name = Get-SynthRvCell $row $t.Columns 'name'
            if (-not $name) { continue }
            $clusterFlags["$(Get-SynthRvCell $row $t.Columns 'server')|$name"] = @{
                haEnabled  = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'haEnabled')
                drsEnabled = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'drsEnabled')
                config     = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
            }
        }
    }

    $resolveCluster = {
        param($Server, $DatacenterName, $ClusterName)
        $dcId = $null
        if ($DatacenterName) {
            $dcKey = "$Server|$DatacenterName"
            if (-not $datacenters.ContainsKey($dcKey)) {
                $id = & $newId 'dc' $dcKey
                $datacenters[$dcKey] = [ordered]@{ id = $id; name = (& $label $DatacenterName $id) }
            }
            $dcId = $datacenters[$dcKey].id
        }
        if (-not $ClusterName) { return $null }
        $clusterKey = "$Server|$ClusterName"
        if (-not $clusters.ContainsKey($clusterKey)) {
            $id = & $newId 'cluster' $clusterKey
            $flags = if ($clusterFlags.ContainsKey($clusterKey)) { $clusterFlags[$clusterKey] } else { @{ haEnabled = $null; drsEnabled = $null; config = [ordered]@{} } }
            $clusters[$clusterKey] = [ordered]@{
                id         = $id
                name       = (& $label $ClusterName $id)
                datacenter = $dcId
                haEnabled  = $flags.haEnabled
                drsEnabled = $flags.drsEnabled
                config     = $flags.config
            }
        }
        elseif (-not $clusters[$clusterKey].datacenter) {
            $clusters[$clusterKey].datacenter = $dcId
        }
        $clusters[$clusterKey]
    }

    $perfHostsUsed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $t = $tabs.vHost
    $rowNumber = 1
    foreach ($row in $t.Rows) {
        $rowNumber++
        $name = Get-SynthRvCell $row $t.Columns 'host'
        if (-not $name) {
            $report.skipped.Add(@{ tab = 'vHost'; row = $rowNumber; reason = 'no host name' })
            continue
        }
        $server = [string](Get-SynthRvCell $row $t.Columns 'server')
        if ($server) { $null = $servers.Add($server) }
        $hostKey = "$server|$name"
        if ($hosts.ContainsKey($hostKey)) {
            $report.skipped.Add(@{ tab = 'vHost'; row = $rowNumber; reason = 'duplicate host' })
            continue
        }
        $dcName = Get-SynthRvCell $row $t.Columns 'datacenter'
        $cluster = & $resolveCluster $server $dcName (Get-SynthRvCell $row $t.Columns 'cluster')
        $dcId = if ($dcName) { $datacenters["$server|$dcName"].id } else { $null }
        $id = & $newId 'esx' $hostKey
        $hosts[$hostKey] = [ordered]@{
            id          = $id
            name        = (& $label $name $id)
            datacenter  = $dcId
            cluster     = if ($cluster) { $cluster.id } else { $null }
            cpuModel    = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'cpuModel')
            cpuMhz      = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'speedMhz')
            sockets     = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'sockets')
            cores       = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cores')
            memoryMiB   = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memoryMiB')
            esxVersion  = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'esxVersion')
            vendor      = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'vendor')
            model       = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'model')
            maintenance = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'maintenance')
            config      = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
            baseline    = [ordered]@{
                cpuUsagePct = ConvertTo-SynthPercent (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cpuUsagePct'))
                memUsagePct = ConvertTo-SynthPercent (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memUsagePct'))
                perf        = $null
            }
        }
        if ($Performance) {
            $lower = $name.ToLowerInvariant()
            $perfRow = if ($Performance.HostsByName.ContainsKey($lower)) { $Performance.HostsByName[$lower] }
            elseif ($Performance.HostsByName.ContainsKey($lower.Split('.')[0])) { $Performance.HostsByName[$lower.Split('.')[0]] }
            else { $null }
            if ($perfRow) {
                $hosts[$hostKey].baseline.perf = $perfRow.Values
                $null = $perfHostsUsed.Add($perfRow.Name)
            }
        }
        $hostsByName["$server|$($name.ToLowerInvariant())"] = $hosts[$hostKey]
        $short = $name.Split('.')[0].ToLowerInvariant()
        if (-not $hostsByName.ContainsKey("$server|$short")) { $hostsByName["$server|$short"] = $hosts[$hostKey] }
    }

    $findHost = {
        param($Server, $Name)
        if (-not $Name) { return $null }
        $lower = ([string]$Name).Trim().ToLowerInvariant()
        foreach ($candidate in "$Server|$lower", "$Server|$($lower.Split('.')[0])") {
            if ($hostsByName.ContainsKey($candidate)) { return $hostsByName[$candidate] }
        }
        $null
    }

    # Datastores, from vDatastore.
    $datastores = @{}
    if ($tabs.ContainsKey('vDatastore')) {
        $t = $tabs.vDatastore
        $rowNumber = 1
        foreach ($row in $t.Rows) {
            $rowNumber++
            $name = Get-SynthRvCell $row $t.Columns 'name'
            if (-not $name) {
                $report.skipped.Add(@{ tab = 'vDatastore'; row = $rowNumber; reason = 'no datastore name' })
                continue
            }
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $dsKey = "$server|$name"
            if ($datastores.ContainsKey($dsKey)) { continue }
            $capacity = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'capacityMiB')
            $free = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'freeMiB')
            $inUse = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'inUseMiB')
            if ($null -eq $inUse -and $null -ne $capacity -and $null -ne $free) { $inUse = $capacity - $free }
            $hostIds = @(([string](Get-SynthRvCell $row $t.Columns 'hosts')) -split '[,;]' |
                Where-Object { $_.Trim() } | ForEach-Object { & $findHost $server $_ } | Where-Object { $_ } |
                ForEach-Object { $_.id } | Sort-Object -Unique)
            $id = & $newId 'ds' $dsKey
            $datastores[$dsKey] = [ordered]@{
                id             = $id
                name           = (& $label $name $id)
                type           = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'type')
                capacityMiB    = $capacity
                provisionedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'provisionedMiB')
                inUseMiB       = $inUse
                hosts          = $hostIds
                config         = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
                baseline       = [ordered]@{
                    usedPct = if ($capacity -gt 0 -and $null -ne $inUse) { ConvertTo-SynthPercent ($inUse / $capacity * 100) } else { $null }
                }
            }
        }
    }

    $hostById = @{}
    foreach ($h in $hosts.Values) { $hostById[$h.id] = $h; $h.nics = @(); $h.hbas = @(); $h.vmkernels = @() }
    $dcIdFor = {
        param($Server, $Name)
        if ($Name -and $datacenters.ContainsKey("$Server|$Name")) { $datacenters["$Server|$Name"].id } else { $null }
    }
    $splitList = {
        param($Text)
        @(([string]$Text) -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    # Switches and port groups: standard ones per host from vSwitch and vPort, distributed ones from dvSwitch and dvPort.
    $switches = @{}
    $networks = @{}
    $networksByName = @{}
    $addNetwork = {
        param($NetKey, $Name, $Kind, $SwitchId, $DcId, $Vlan)
        if (-not $networks.ContainsKey($NetKey)) {
            $id = & $newId 'net' $NetKey
            $networks[$NetKey] = [ordered]@{
                id         = $id
                name       = (& $label $Name $id)
                kind       = $Kind
                switch     = $SwitchId
                datacenter = $DcId
                vlan       = $Vlan
                hosts      = [System.Collections.Generic.List[string]]::new()
            }
            $byName = "$($NetKey.Split('|')[0])|$Name"
            if (-not $networksByName.ContainsKey($byName)) { $networksByName[$byName] = [System.Collections.Generic.List[object]]::new() }
            $networksByName[$byName].Add($networks[$NetKey])
        }
        $networks[$NetKey]
    }
    $addHostTo = {
        param($Record, $HostId)
        if ($HostId -and -not $Record.hosts.Contains($HostId)) { $Record.hosts.Add($HostId) }
    }

    if ($tabs.ContainsKey('dvSwitch')) {
        $t = $tabs.dvSwitch
        foreach ($row in $t.Rows) {
            $name = Get-SynthRvCell $row $t.Columns 'name'
            if (-not $name) { continue }
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $swKey = "$server|dvs|$name"
            if ($switches.ContainsKey($swKey)) { continue }
            $id = & $newId 'dvs' $swKey
            $switches[$swKey] = [ordered]@{
                id         = $id
                name       = (& $label $name $id)
                kind       = 'distributed'
                datacenter = & $dcIdFor $server (Get-SynthRvCell $row $t.Columns 'datacenter')
                version    = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'version')
                mtu        = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'maxMtu')
                ports      = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'ports')
                hosts      = [System.Collections.Generic.List[string]]::new()
                config     = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
            }
            foreach ($member in & $splitList (Get-SynthRvCell $row $t.Columns 'hostMembers')) {
                $h = & $findHost $server $member
                if ($h) { & $addHostTo $switches[$swKey] $h.id }
            }
        }
    }
    if ($tabs.ContainsKey('dvPort')) {
        $t = $tabs.dvPort
        foreach ($row in $t.Rows) {
            $name = Get-SynthRvCell $row $t.Columns 'portGroup'
            if (-not $name) { continue }
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $switchName = Get-SynthRvCell $row $t.Columns 'switch'
            $sw = if ($switchName) { $switches["$server|dvs|$switchName"] } else { $null }
            $net = & $addNetwork "$server|dvpg|$switchName|$name" $name 'distributed' $(if ($sw) { $sw.id }) $(if ($sw) { $sw.datacenter }) (ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'vlan'))
            $net.ports = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'ports')
            $net.config = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
            if ($sw) { foreach ($h in $sw.hosts) { & $addHostTo $net $h } }
        }
    }
    if ($tabs.ContainsKey('vSwitch')) {
        $t = $tabs.vSwitch
        foreach ($row in $t.Rows) {
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $h = & $findHost $server (Get-SynthRvCell $row $t.Columns 'host')
            $name = Get-SynthRvCell $row $t.Columns 'switch'
            if (-not $h -or -not $name) { continue }
            $swKey = "$server|vss|$($h.id)|$name"
            if ($switches.ContainsKey($swKey)) { continue }
            $id = & $newId 'vss' $swKey
            $switches[$swKey] = [ordered]@{
                id         = $id
                # Standard switch names (vSwitch0) are the same on every host and identify nothing.
                name       = $name
                kind       = 'standard'
                datacenter = $h.datacenter
                mtu        = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'mtu')
                ports      = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'ports')
                hosts      = [System.Collections.Generic.List[string]]::new()
            }
            & $addHostTo $switches[$swKey] $h.id
        }
    }
    if ($tabs.ContainsKey('vPort')) {
        $t = $tabs.vPort
        foreach ($row in $t.Rows) {
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $h = & $findHost $server (Get-SynthRvCell $row $t.Columns 'host')
            $name = Get-SynthRvCell $row $t.Columns 'portGroup'
            if (-not $h -or -not $name) { continue }
            $switchName = Get-SynthRvCell $row $t.Columns 'switch'
            $sw = $switches["$server|vss|$($h.id)|$switchName"]
            # One network per standard port group name in a datacenter, as vCenter shows it.
            $net = & $addNetwork "$server|pg|$($h.datacenter)|$name" $name 'standard' $null $h.datacenter (ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'vlan'))
            & $addHostTo $net $h.id
            if ($sw) {
                if (-not $sw.Contains('portGroups')) { $sw.portGroups = [System.Collections.Generic.List[string]]::new() }
                if (-not $sw.portGroups.Contains($net.id)) { $sw.portGroups.Add($net.id) }
            }
        }
    }
    $findNetwork = {
        param($Server, $Name, $SwitchName, $DcId)
        if (-not $Name) { return $null }
        $candidates = $networksByName["$Server|$Name"]
        if ($candidates) {
            $dvs = if ($SwitchName) { $switches["$Server|dvs|$SwitchName"] } else { $null }
            $bySwitch = @(if ($dvs) { $candidates | Where-Object { $_.switch -eq $dvs.id } })
            if ($bySwitch.Count) { return $bySwitch[0] }
            $inDc = @($candidates | Where-Object { $_.datacenter -eq $DcId })
            if ($inDc.Count) { return $inDc[0] }
            return $candidates[0]
        }
        # A network seen only on a VM adapter, when the switch tabs are missing.
        $kind = if ($SwitchName -and $switches.ContainsKey("$Server|dvs|$SwitchName")) { 'distributed' } else { 'standard' }
        & $addNetwork "$Server|pg|$DcId|$Name" $Name $kind $null $DcId $null
    }

    # Host adapters: physical NICs, HBAs and VMkernel adapters. Addresses, MACs and WWNs are never read.
    foreach ($spec in @(
            @{ Tab = 'vNIC'; Into = 'nics' }
            @{ Tab = 'vHBA'; Into = 'hbas' }
            @{ Tab = 'vSC_VMK'; Into = 'vmkernels' }
        )) {
        if (-not $tabs.ContainsKey($spec.Tab)) { continue }
        $t = $tabs[$spec.Tab]
        $lists = @{}
        foreach ($row in $t.Rows) {
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $h = & $findHost $server (Get-SynthRvCell $row $t.Columns 'host')
            $device = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'device')
            if (-not $h -or -not $device) { continue }
            $item = switch ($spec.Tab) {
                'vNIC' {
                    [ordered]@{
                        device    = $device
                        driver    = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'driver')
                        speedMbps = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'speedMbps')
                        duplex    = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'duplex')
                        switch    = $(
                            $switchName = Get-SynthRvCell $row $t.Columns 'switch'
                            $sw = $switches["$server|vss|$($h.id)|$switchName"]
                            if (-not $sw) { $sw = $switches["$server|dvs|$switchName"] }
                            if ($sw) { $sw.id } else { $null }
                        )
                    }
                }
                'vHBA' {
                    [ordered]@{
                        device = $device
                        type   = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'type')
                        status = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'status')
                        model  = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'model')
                        driver = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'driver')
                    }
                }
                'vSC_VMK' {
                    $net = & $findNetwork $server (Get-SynthRvCell $row $t.Columns 'portGroup') $null $h.datacenter
                    if ($net) { & $addHostTo $net $h.id }
                    [ordered]@{
                        device  = $device
                        network = if ($net) { $net.id } else { $null }
                        mtu     = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'mtu')
                    }
                }
            }
            if (-not $lists.ContainsKey($h.id)) { $lists[$h.id] = [System.Collections.Generic.List[object]]::new() }
            $lists[$h.id].Add($item)
        }
        foreach ($hostId in $lists.Keys) { $hostById[$hostId][$spec.Into] = @($lists[$hostId] | Sort-Object { $_.device }) }
    }

    # Folders, built from each VM's folder path, one chain per datacenter.
    $folders = @{}
    $resolveFolder = {
        param($Server, $DcId, $Path)
        $segments = @(([string]$Path) -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $parent = $null
        $walked = ''
        foreach ($segment in $segments) {
            $walked = "$walked/$segment"
            $folderKey = "$Server|$DcId|$walked"
            if (-not $folders.ContainsKey($folderKey)) {
                $id = & $newId 'folder' $folderKey
                $folders[$folderKey] = [ordered]@{ id = $id; name = (& $label $segment $id); datacenter = $DcId; parent = $parent }
            }
            $parent = $folders[$folderKey].id
        }
        $parent
    }

    # Resource pools, from vRP and each VM's pool. Paths read /<datacenter>/<cluster>/Resources/<pool>/...
    # (older releases put /host/ before the cluster); a cluster's root pool is always called Resources.
    $pools = @{}
    $resolvePool = {
        param($Server, $ClusterId, $Path)
        $segments = @(([string]$Path) -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($segments.Count -eq 0) { return $null }
        $root = [array]::IndexOf(@($segments | ForEach-Object { $_.ToLowerInvariant() }), 'resources')
        if ($root -gt 0 -and $clusters.ContainsKey("$Server|$($segments[$root - 1])")) {
            $ClusterId = $clusters["$Server|$($segments[$root - 1])"].id
        }
        $chain = if ($root -ge 0) { @($segments[$root..($segments.Count - 1)]) } else { @('Resources') + $segments }
        $parent = $null
        $walked = ''
        $pool = $null
        foreach ($segment in $chain) {
            $walked = "$walked/$segment"
            $poolKey = "$Server|$ClusterId|$walked"
            if (-not $pools.ContainsKey($poolKey)) {
                $id = & $newId 'rp' $poolKey
                $pools[$poolKey] = [ordered]@{
                    id      = $id
                    name    = if ($null -eq $parent -and $segment -ieq 'Resources') { 'Resources' } else { & $label $segment $id }
                    cluster = $ClusterId
                    parent  = $parent
                    cpu     = [ordered]@{ reservationMhz = $null; limitMhz = $null; shares = $null; expandable = $null }
                    memory  = [ordered]@{ reservationMiB = $null; limitMiB = $null; shares = $null; expandable = $null }
                }
            }
            $pool = $pools[$poolKey]
            $parent = $pool.id
        }
        $pool
    }
    if ($tabs.ContainsKey('vRP')) {
        $t = $tabs.vRP
        foreach ($row in $t.Rows) {
            $server = [string](Get-SynthRvCell $row $t.Columns 'server')
            $path = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'path')
            if (-not $path) { $path = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'name') }
            $pool = & $resolvePool $server $null $path
            if (-not $pool) { continue }
            $pool.cpu.reservationMhz = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cpuReservationMhz')
            $pool.cpu.limitMhz = ConvertTo-SynthLimit (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cpuLimitMhz'))
            $pool.cpu.shares = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'cpuShares')
            $pool.cpu.expandable = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'cpuExpandable')
            $pool.memory.reservationMiB = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memReservationMiB')
            $pool.memory.limitMiB = ConvertTo-SynthLimit (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memLimitMiB'))
            $pool.memory.shares = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'memShares')
            $pool.memory.expandable = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'memExpandable')
        }
    }

    # Per-VM tabs, indexed by the same key as vInfo rows.
    $byVm = @{}
    foreach ($name in 'vCPU', 'vMemory', 'vTools', 'vPartition', 'vSnapshot', 'vDisk', 'vNetwork') {
        $byVm[$name] = @{}
        if (-not $tabs.ContainsKey($name)) { continue }
        $t = $tabs[$name]
        foreach ($row in $t.Rows) {
            if (-not (Get-SynthRvCell $row $t.Columns 'vm')) { continue }
            $vmKey = Get-SynthRvVmKey -Row $row -Columns $t.Columns
            if (-not $byVm[$name].ContainsKey($vmKey)) { $byVm[$name][$vmKey] = [System.Collections.Generic.List[hashtable]]::new() }
            $byVm[$name][$vmKey].Add(@{ Row = $row; Columns = $t.Columns })
        }
    }
    $first = {
        param($Tab, $VmKey)
        if ($byVm[$Tab].ContainsKey($VmKey)) { $byVm[$Tab][$VmKey][0] } else { $null }
    }

    # VMs, from vInfo joined to the per-VM tabs.
    $compiled = @(foreach ($rule in $TieringRules.rules) {
            @{
                Rule  = $rule
                Tests = @(foreach ($field in $rule.match.Keys) {
                        @{ Field = $field; Regex = [regex]::new([string]$rule.match[$field], 'IgnoreCase') }
                    })
            }
        })
    $vms = @{}
    $skippedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $perfVmsUsed = [System.Collections.Generic.HashSet[object]]::new()
    $t = $tabs.vInfo
    $singleServer = @($t.Rows | ForEach-Object { [string](Get-SynthRvCell $_ $t.Columns 'server') } | Sort-Object -Unique).Count -le 1
    $rowNumber = 1
    foreach ($row in $t.Rows) {
        $rowNumber++
        $name = Get-SynthRvCell $row $t.Columns 'vm'
        if (-not $name) {
            $report.skipped.Add(@{ tab = 'vInfo'; row = $rowNumber; reason = 'no VM name' })
            continue
        }
        $vmKey = Get-SynthRvVmKey -Row $row -Columns $t.Columns
        if (ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'template')) {
            $report.skipped.Add(@{ tab = 'vInfo'; row = $rowNumber; reason = 'template' })
            $null = $skippedKeys.Add($vmKey)
            continue
        }
        if (ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'srmPlaceholder')) {
            $report.skipped.Add(@{ tab = 'vInfo'; row = $rowNumber; reason = 'SRM placeholder' })
            $null = $skippedKeys.Add($vmKey)
            continue
        }
        if ($vms.ContainsKey($vmKey)) {
            $report.skipped.Add(@{ tab = 'vInfo'; row = $rowNumber; reason = 'duplicate VM' })
            continue
        }
        $id = & $newId 'vm' $vmKey
        $server = [string](Get-SynthRvCell $row $t.Columns 'server')
        $vmConfig = Get-SynthRvConfig $row $t.Columns -Anonymise:$Anonymise
        $where = if ($Anonymise) { "vInfo row $rowNumber ($id)" } else { "vInfo row $rowNumber ($name)" }

        # Placement.
        $hostName = Get-SynthRvCell $row $t.Columns 'host'
        $hostRecord = & $findHost $server $hostName
        if ($hostName -and -not $hostRecord) { $report.warnings.Add("$where runs on a host that is not in vHost; it has no host.") }
        $dcName = Get-SynthRvCell $row $t.Columns 'datacenter'
        $cluster = if ($hostRecord -and $hostRecord.cluster) {
            $clusters.Values | Where-Object { $_.id -eq $hostRecord.cluster } | Select-Object -First 1
        }
        else {
            & $resolveCluster $server $dcName (Get-SynthRvCell $row $t.Columns 'cluster')
        }
        $dcId = if ($hostRecord -and $hostRecord.datacenter) { $hostRecord.datacenter }
        elseif ($dcName -and $datacenters.ContainsKey("$server|$dcName")) { $datacenters["$server|$dcName"].id }
        else { $null }

        $datastoreIds = @()
        $vmPath = [string](Get-SynthRvCell $row $t.Columns 'path')
        if ($vmPath -match '^\[(?<ds>[^\]]+)\]') {
            $dsKey = "$server|$($Matches.ds)"
            if ($datastores.ContainsKey($dsKey)) { $datastoreIds = @($datastores[$dsKey].id) }
            elseif ($tabs.ContainsKey('vDatastore')) { $report.warnings.Add("$where is on a datastore that is not in vDatastore.") }
        }

        # Sizing and usage.
        $powerState = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'powerState')
        $cpus = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cpus')
        $cpu = & $first 'vCPU' $vmKey
        $usageMhz = $null; $maxMhz = $null; $sockets = $null; $coresPerSocket = $null; $reservationMhz = $null; $limitMhz = $null
        if ($cpu) {
            $usageMhz = ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'overallMhz')
            $maxMhz = ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'maxMhz')
            $sockets = ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'sockets')
            $coresPerSocket = ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'coresPerSocket')
            $reservationMhz = ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'reservationMhz')
            $limitMhz = ConvertTo-SynthLimit (ConvertTo-SynthNumber (Get-SynthRvCell $cpu.Row $cpu.Columns 'limitMhz'))
        }
        if (-not ($maxMhz -gt 0) -and $cpus -gt 0 -and $hostRecord -and $hostRecord.cpuMhz -gt 0) { $maxMhz = $cpus * $hostRecord.cpuMhz }

        $memory = & $first 'vMemory' $vmKey
        $sizeMiB = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memoryMiB')
        $activeMiB = $null; $consumedMiB = $null; $balloonedMiB = $null; $swappedMiB = $null; $memReservation = $null; $memLimit = $null
        if ($memory) {
            $fromTab = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'sizeMiB')
            if ($fromTab -gt 0) { $sizeMiB = $fromTab }
            $activeMiB = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'activeMiB')
            $consumedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'consumedMiB')
            $balloonedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'balloonedMiB')
            $swappedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'swappedMiB')
            $memReservation = ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'reservationMiB')
            $memLimit = ConvertTo-SynthLimit (ConvertTo-SynthNumber (Get-SynthRvCell $memory.Row $memory.Columns 'limitMiB'))
        }

        $partitions = [System.Collections.Generic.List[object]]::new()
        if ($byVm.vPartition.ContainsKey($vmKey)) {
            $n = 0
            foreach ($p in $byVm.vPartition[$vmKey]) {
                $n++
                $partitions.Add([ordered]@{
                        disk        = if ($Anonymise) { "disk$n" } else { ConvertTo-SynthText (Get-SynthRvCell $p.Row $p.Columns 'disk') }
                        capacityMiB = ConvertTo-SynthNumber (Get-SynthRvCell $p.Row $p.Columns 'capacityMiB')
                        consumedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $p.Row $p.Columns 'consumedMiB')
                    })
            }
        }
        $disks = [System.Collections.Generic.List[object]]::new()
        if ($byVm.vDisk.ContainsKey($vmKey)) {
            foreach ($d in $byVm.vDisk[$vmKey]) {
                $diskStore = $null
                $diskFile = [string](Get-SynthRvCell $d.Row $d.Columns 'diskPath')
                if (-not $diskFile) { $diskFile = [string](Get-SynthRvCell $d.Row $d.Columns 'filePath') }
                if ($diskFile -match '^\[(?<ds>[^\]]+)\]') {
                    $dsKey = "$server|$($Matches.ds)"
                    if ($datastores.ContainsKey($dsKey)) { $diskStore = $datastores[$dsKey].id }
                }
                $disks.Add([ordered]@{
                        label       = ConvertTo-SynthText (Get-SynthRvCell $d.Row $d.Columns 'label')
                        capacityMiB = ConvertTo-SynthNumber (Get-SynthRvCell $d.Row $d.Columns 'capacityMiB')
                        thin        = ConvertTo-SynthBoolean (Get-SynthRvCell $d.Row $d.Columns 'thin')
                        mode        = ConvertTo-SynthText (Get-SynthRvCell $d.Row $d.Columns 'diskMode')
                        controller  = ConvertTo-SynthText (Get-SynthRvCell $d.Row $d.Columns 'controller')
                        unit        = ConvertTo-SynthNumber (Get-SynthRvCell $d.Row $d.Columns 'unit')
                        datastore   = $diskStore
                    })
                if ($diskStore -and $diskStore -notin $datastoreIds) { $datastoreIds += $diskStore }
            }
        }

        $nics = [System.Collections.Generic.List[object]]::new()
        if ($byVm.vNetwork.ContainsKey($vmKey)) {
            foreach ($n in $byVm.vNetwork[$vmKey]) {
                $net = & $findNetwork $server (Get-SynthRvCell $n.Row $n.Columns 'network') (Get-SynthRvCell $n.Row $n.Columns 'switch') $dcId
                if ($net -and $hostRecord) { & $addHostTo $net $hostRecord.id }
                $nics.Add([ordered]@{
                        label     = ConvertTo-SynthText (Get-SynthRvCell $n.Row $n.Columns 'label')
                        adapter   = ConvertTo-SynthText (Get-SynthRvCell $n.Row $n.Columns 'adapter')
                        network   = if ($net) { $net.id } else { $null }
                        connected = ConvertTo-SynthBoolean (Get-SynthRvCell $n.Row $n.Columns 'connected')
                    })
            }
        }

        # Some exports leave Folder empty and give only the folder's object ID, which still groups VMs.
        $folderPath = Get-SynthRvCell $row $t.Columns 'folder'
        if (-not $folderPath) { $folderPath = Get-SynthRvCell $row $t.Columns 'folderRef' }
        $folderId = & $resolveFolder $server $dcId $folderPath
        $pool = & $resolvePool $server $(if ($cluster) { $cluster.id }) (Get-SynthRvCell $row $t.Columns 'resourcePool')

        $diskCapacity = ($partitions | ForEach-Object { $_.capacityMiB } | Measure-Object -Sum).Sum
        $diskConsumed = ($partitions | ForEach-Object { $_.consumedMiB } | Measure-Object -Sum).Sum

        $snapshots = [System.Collections.Generic.List[object]]::new()
        if ($byVm.vSnapshot.ContainsKey($vmKey)) {
            foreach ($s in $byVm.vSnapshot[$vmKey]) {
                $snapshot = [ordered]@{
                    created = ConvertTo-SynthDateText (Get-SynthRvCell $s.Row $s.Columns 'created')
                    sizeMiB = ConvertTo-SynthNumber (Get-SynthRvCell $s.Row $s.Columns 'sizeMiB')
                }
                if (-not $Anonymise) { $snapshot.name = ConvertTo-SynthText (Get-SynthRvCell $s.Row $s.Columns 'name') }
                $snapshots.Add($snapshot)
            }
        }

        $tools = & $first 'vTools' $vmKey
        $guestOs = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'osTools')
        if (-not $guestOs) { $guestOs = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'osConfig') }
        $hwVersion = if ($tools) { ConvertTo-SynthText (Get-SynthRvCell $tools.Row $tools.Columns 'vmVersion') } else { $null }
        if (-not $hwVersion) { $hwVersion = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'hwVersion') }

        # LiveOptics: the managed object ID is unique per vCenter, so it is trusted when the name agrees
        # or the export covers one vCenter; otherwise the name must match exactly one row.
        $perf = $null
        if ($Performance) {
            $vmIdValue = [string](Get-SynthRvCell $row $t.Columns 'vmId')
            $byId = @(if ($vmIdValue -and $Performance.VmsById.ContainsKey($vmIdValue)) { $Performance.VmsById[$vmIdValue] })
            $perfRow = $byId | Where-Object { $_.Name -ieq [string]$name } | Select-Object -First 1
            if (-not $perfRow -and $byId.Count -eq 1 -and $singleServer) { $perfRow = $byId[0] }
            if (-not $perfRow) {
                $byName = @(if ($Performance.VmsByName.ContainsKey(([string]$name).ToLowerInvariant())) { $Performance.VmsByName[([string]$name).ToLowerInvariant()] })
                if ($byName.Count -eq 1) { $perfRow = $byName[0] }
            }
            if ($perfRow) {
                $perf = [ordered]@{ ioClass = $perfRow.IoClass }
                foreach ($field in $perfRow.Values.Keys) { $perf[$field] = $perfRow.Values[$field] }
                $null = $perfVmsUsed.Add($perfRow)
            }
        }

        $poweredOn = $powerState -eq 'poweredOn'
        $baseline = [ordered]@{
            cpuUsagePct    = if ($poweredOn -and $maxMhz -gt 0 -and $null -ne $usageMhz) { ConvertTo-SynthPercent ($usageMhz / $maxMhz * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            memActivePct   = if ($poweredOn -and $sizeMiB -gt 0 -and $null -ne $activeMiB) { ConvertTo-SynthPercent ($activeMiB / $sizeMiB * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            memConsumedPct = if ($poweredOn -and $sizeMiB -gt 0 -and $null -ne $consumedMiB) { ConvertTo-SynthPercent ($consumedMiB / $sizeMiB * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            diskUsedPct    = if ($diskCapacity -gt 0) { ConvertTo-SynthPercent ($diskConsumed / $diskCapacity * 100) } else { $null }
            perf           = $perf
        }
        # LiveOptics averages over days describe a VM better than RVTools' single sample.
        $classBaseline = if ($perf) { @{ cpuUsagePct = $perf.cpuAvgPct; memActivePct = $perf.memAvgPct } } else { $baseline }

        # Tier, application and profile, from the real values.
        $facts = @{}
        foreach ($header in $row.Keys) { $facts["attribute:$header"] = $row[$header] }
        $facts.name = $name
        $facts.cluster = Get-SynthRvCell $row $t.Columns 'cluster'
        $facts.host = $hostName
        $facts.datacenter = $dcName
        $facts.folder = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'folder')
        $facts.resourcePool = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'resourcePool')
        $facts.annotation = ConvertTo-SynthText (Get-SynthRvCell $row $t.Columns 'annotation')
        $facts.guestOs = $guestOs
        $facts.powerState = $powerState
        $assigned = Resolve-SynthVmClass -Fact $facts -Rule $compiled -TieringRules $TieringRules -Baseline $classBaseline -PoweredOn $poweredOn

        $vm = [ordered]@{
            id              = $id
            name            = (& $label $name $id)
            powerState      = $powerState
            datacenter      = $dcId
            cluster         = if ($cluster) { $cluster.id } else { $null }
            host            = if ($hostRecord) { $hostRecord.id } else { $null }
            datastores      = $datastoreIds
            folderId        = $folderId
            resourcePoolId  = if ($pool) { $pool.id } else { $null }
            config          = $vmConfig
            cpuReadyPct     = if ($vmConfig.Contains('cpuReadiness')) { ConvertTo-SynthNumber $vmConfig.cpuReadiness } else { $null }
            tier            = $assigned.tier
            application     = $assigned.application
            profile         = $assigned.profile
            guestOs         = $guestOs
            hardwareVersion = $hwVersion
            toolsStatus     = if ($tools) { ConvertTo-SynthText (Get-SynthRvCell $tools.Row $tools.Columns 'toolsStatus') } else { $null }
            toolsVersion    = if ($tools) { ConvertTo-SynthText (Get-SynthRvCell $tools.Row $tools.Columns 'toolsVersion') } else { $null }
            cpu             = [ordered]@{
                vcpus          = $cpus
                sockets        = $sockets
                coresPerSocket = $coresPerSocket
                capacityMhz    = $maxMhz
                usageMhz       = $usageMhz
                reservationMhz = $reservationMhz
                limitMhz       = $limitMhz
            }
            memory          = [ordered]@{
                sizeMiB        = $sizeMiB
                activeMiB      = $activeMiB
                consumedMiB    = $consumedMiB
                balloonedMiB   = $balloonedMiB
                swappedMiB     = $swappedMiB
                reservationMiB = $memReservation
                limitMiB       = $memLimit
            }
            storage         = [ordered]@{
                provisionedMiB = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'provisionedMiB')
                inUseMiB       = ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'inUseMiB')
                partitions     = @($partitions)
                disks          = @($disks)
            }
            nics            = @($nics)
            snapshots       = @($snapshots | Sort-Object { $_.created })
            baseline        = $baseline
        }
        if (-not $Anonymise) {
            $vm.folder = $facts.folder
            $vm.resourcePool = $facts.resourcePool
            $vm.annotation = $facts.annotation
        }
        $vms[$vmKey] = $vm
    }

    # Per-VM rows that match no VM usually mean a tab from a different export.
    foreach ($name in $byVm.Keys) {
        $orphans = @($byVm[$name].Keys | Where-Object { -not $vms.ContainsKey($_) -and -not $skippedKeys.Contains($_) }).Count
        if ($orphans -gt 0) {
            $report.warnings.Add("$name has rows for $orphans VM(s) that are not in vInfo; they were ignored.")
        }
    }

    $perfReport = $null
    if ($Performance) {
        $vmsWithPerf = @($vms.Values | Where-Object { $_.baseline.perf }).Count
        $perfReport = [ordered]@{
            vmsMatched     = $vmsWithPerf
            vmsWithout     = $vms.Count - $vmsWithPerf
            vmRowsUnused   = $Performance.Vms.Count - $perfVmsUsed.Count
            hostsMatched   = @($hosts.Values | Where-Object { $_.baseline.perf }).Count
            hostsWithout   = @($hosts.Values | Where-Object { -not $_.baseline.perf }).Count
            hostRowsUnused = $Performance.Hosts.Count - $perfHostsUsed.Count
            latencyDropped = [int]$Performance.LatencyDropped
        }
        if ($perfReport.latencyDropped -gt 0) {
            $report.warnings.Add("LiveOptics has $($perfReport.latencyDropped) latency figure(s) over 10,000 ms; they were read as missing.")
        }
        if ($perfReport.vmRowsUnused -gt 0) {
            $report.warnings.Add("LiveOptics has $($perfReport.vmRowsUnused) VM row(s) that match no VM in the RVTools export; they were ignored.")
        }
        if ($perfReport.hostRowsUnused -gt 0) {
            $report.warnings.Add("LiveOptics has $($perfReport.hostRowsUnused) host row(s) that match no host in the RVTools export; they were ignored.")
        }
    }

    $metadata = @{ rvtoolsVersion = $null; created = $null }
    if ($tabs.ContainsKey('vMetaData') -and $tabs.vMetaData.Rows.Count -gt 0) {
        $m = $tabs.vMetaData
        $metadata.rvtoolsVersion = ConvertTo-SynthText (Get-SynthRvCell $m.Rows[0] $m.Columns 'rvtoolsVersion')
        $metadata.created = ConvertTo-SynthDateText (Get-SynthRvCell $m.Rows[0] $m.Columns 'created')
    }

    $sorted = { param($Table) @($Table.Values | Sort-Object { $_.id }) }
    foreach ($record in @($switches.Values) + @($networks.Values)) { $record.hosts = @($record.hosts | Sort-Object) }
    foreach ($record in $switches.Values) { if ($record.Contains('portGroups')) { $record.portGroups = @($record.portGroups | Sort-Object) } }
    [ordered]@{
        schemaVersion = 3
        importedAt    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        source        = [ordered]@{
            format         = $source.Format
            file           = if ($Anonymise) { $null } else { Split-Path -Leaf $source.Source }
            rvtoolsVersion = $metadata.rvtoolsVersion
            exportedAt     = $metadata.created
            anonymised     = [bool]$Anonymise
            # The customer's vCenter (VI SDK Server) and the project folder the export sits in; both are real names.
            vcenter        = if ($Anonymise) { $null } else { ($servers -join ', ') }
            project        = if ($Anonymise) { $null } else { Get-SynthProjectName -Path $source.Source }
            tiering        = if ($TieringRules.sourcePath) { Split-Path -Leaf $TieringRules.sourcePath } else { $null }
            performance    = if ($Performance) { [ordered]@{ format = 'LiveOptics'; collectedOn = $Performance.CollectedOn } } else { $null }
        }
        datacenters   = @(& $sorted $datacenters)
        clusters      = @(& $sorted $clusters)
        hosts         = @(& $sorted $hosts)
        datastores    = @(& $sorted $datastores)
        switches      = @(& $sorted $switches)
        networks      = @(& $sorted $networks)
        resourcePools = @(& $sorted $pools)
        folders       = @(& $sorted $folders)
        vms           = @(& $sorted $vms)
        report        = [ordered]@{
            warnings    = @($report.warnings)
            skipped     = @($report.skipped | ForEach-Object { [ordered]@{ tab = $_.tab; row = $_.row; reason = $_.reason } })
            performance = $perfReport
        }
    }
}

function Save-SynthInventory {
    <#
    .SYNOPSIS
        Writes an inventory model to JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][string]$Path
    )

    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $Inventory | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-SynthInventory {
    <#
    .SYNOPSIS
        Reads an inventory model written by Save-SynthInventory.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No inventory at '$Path'. Run 'import' first."
    }
    $inventory = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($inventory.schemaVersion -ne 3) {
        throw "Inventory '$Path' has schema version $($inventory.schemaVersion); this build reads version 3. Run 'import' again."
    }
    $inventory
}

function Get-SynthInventorySummary {
    <#
    .SYNOPSIS
        Describes an inventory model in a few lines for a person.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Inventory)

    $count = {
        param($Items, $Noun, $Plural = "$($Noun)s")
        $n = @($Items).Count
        "$n $(if ($n -eq 1) { $Noun } else { $Plural })"
    }
    $vms = @($Inventory.vms)
    $on = @($vms | Where-Object { $_.powerState -eq 'poweredOn' }).Count
    "$(& $count $vms 'VM') ($on powered on) on $(& $count $Inventory.hosts 'host') in $(& $count $Inventory.clusters 'cluster'), $(& $count $Inventory.datastores 'datastore'), $(& $count $Inventory.datacenters 'datacenter')"

    if (@($Inventory.networks).Count -or @($Inventory.resourcePools).Count) {
        "$(& $count $Inventory.networks 'network') on $(& $count $Inventory.switches 'switch' 'switches'), $(& $count $Inventory.resourcePools 'resource pool'), $(& $count $Inventory.folders 'folder')"
    }
    if ($Inventory.report.performance) {
        $p = $Inventory.report.performance
        "Performance: LiveOptics for $($p.vmsMatched) of $($p.vmsMatched + $p.vmsWithout) VMs and $($p.hostsMatched) of $($p.hostsMatched + $p.hostsWithout) hosts"
    }

    $tiers = foreach ($tier in Get-SynthTierName) {
        $count = @($vms | Where-Object { $_.tier -eq $tier }).Count
        if ($count) { "$tier $count" }
    }
    "Tiers: $($tiers -join ', ')"

    $profiles = $vms | Group-Object { $_.profile } | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }
    "Profiles: $($profiles -join ', ')"

    $apps = @($vms | Where-Object { $_.application } | Group-Object { $_.application } | ForEach-Object { "$($_.Name) $($_.Count)" })
    if ($apps.Count) { "Applications: $($apps -join ', ')" }

    $names = if ($Inventory.source.anonymised) { 'anonymised' } else { 'real names kept' }
    "Source: $($Inventory.source.format)$(if ($Inventory.source.rvtoolsVersion) { ", RVTools $($Inventory.source.rvtoolsVersion)" }), $names"
}
