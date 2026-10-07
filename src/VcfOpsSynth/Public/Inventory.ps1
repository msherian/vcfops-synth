function Import-SynthRvtools {
    <#
    .SYNOPSIS
        Turns an RVTools export into the inventory model every later stage works from.

    .DESCRIPTION
        Reads vInfo and vHost (required) and vCPU, vMemory, vCluster, vDatastore,
        vPartition, vSnapshot, vTools and vMetaData (used when present), joins them
        by VM, and returns datacenters, clusters, hosts, datastores and VMs with:

          - placement: VM to host, cluster, datacenter and datastores;
          - sizing and configuration: vCPU, memory, disks, guest OS, hardware
            version, Tools status, snapshots;
          - baselines from RVTools' single usage sample: VM CPU and memory use,
            guest disk use, host CPU and memory use, datastore use;
          - a tier, application and workload profile from the tiering rules.

        Templates and SRM placeholders are skipped. IP addresses, DNS names and
        MAC addresses are never read. With -Anonymise, names become stable
        pseudonyms (vm-3f9a2c1d0b), and folders, resource pools, annotations,
        snapshot names and partition paths are dropped. Tiering rules still see
        the real values, because they run first.

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

    .EXAMPLE
        $inventory = Import-SynthRvtools -Path ./data/rvtools.xlsx -Key $key -Anonymise
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'RVTools is the product name, not a plural.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Key', Justification = 'Used inside the newId script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key,
        [hashtable]$TieringRules,
        [switch]$Anonymise
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
    $clusterFlags = @{}
    if ($tabs.ContainsKey('vCluster')) {
        $t = $tabs.vCluster
        foreach ($row in $t.Rows) {
            $name = Get-SynthRvCell $row $t.Columns 'name'
            if (-not $name) { continue }
            $clusterFlags["$(Get-SynthRvCell $row $t.Columns 'server')|$name"] = @{
                haEnabled  = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'haEnabled')
                drsEnabled = ConvertTo-SynthBoolean (Get-SynthRvCell $row $t.Columns 'drsEnabled')
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
            $flags = if ($clusterFlags.ContainsKey($clusterKey)) { $clusterFlags[$clusterKey] } else { @{ haEnabled = $null; drsEnabled = $null } }
            $clusters[$clusterKey] = [ordered]@{
                id         = $id
                name       = (& $label $ClusterName $id)
                datacenter = $dcId
                haEnabled  = $flags.haEnabled
                drsEnabled = $flags.drsEnabled
            }
        }
        elseif (-not $clusters[$clusterKey].datacenter) {
            $clusters[$clusterKey].datacenter = $dcId
        }
        $clusters[$clusterKey]
    }

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
            baseline    = [ordered]@{
                cpuUsagePct = ConvertTo-SynthPercent (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'cpuUsagePct'))
                memUsagePct = ConvertTo-SynthPercent (ConvertTo-SynthNumber (Get-SynthRvCell $row $t.Columns 'memUsagePct'))
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
                baseline       = [ordered]@{
                    usedPct = if ($capacity -gt 0 -and $null -ne $inUse) { ConvertTo-SynthPercent ($inUse / $capacity * 100) } else { $null }
                }
            }
        }
    }

    # Per-VM tabs, indexed by the same key as vInfo rows.
    $byVm = @{}
    foreach ($name in 'vCPU', 'vMemory', 'vTools', 'vPartition', 'vSnapshot') {
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
    $t = $tabs.vInfo
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

        $poweredOn = $powerState -eq 'poweredOn'
        $baseline = [ordered]@{
            cpuUsagePct    = if ($poweredOn -and $maxMhz -gt 0 -and $null -ne $usageMhz) { ConvertTo-SynthPercent ($usageMhz / $maxMhz * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            memActivePct   = if ($poweredOn -and $sizeMiB -gt 0 -and $null -ne $activeMiB) { ConvertTo-SynthPercent ($activeMiB / $sizeMiB * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            memConsumedPct = if ($poweredOn -and $sizeMiB -gt 0 -and $null -ne $consumedMiB) { ConvertTo-SynthPercent ($consumedMiB / $sizeMiB * 100) } elseif (-not $poweredOn) { 0 } else { $null }
            diskUsedPct    = if ($diskCapacity -gt 0) { ConvertTo-SynthPercent ($diskConsumed / $diskCapacity * 100) } else { $null }
        }

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
        $assigned = Resolve-SynthVmClass -Fact $facts -Rule $compiled -TieringRules $TieringRules -Baseline $baseline -PoweredOn $poweredOn

        $vm = [ordered]@{
            id              = $id
            name            = (& $label $name $id)
            powerState      = $powerState
            datacenter      = $dcId
            cluster         = if ($cluster) { $cluster.id } else { $null }
            host            = if ($hostRecord) { $hostRecord.id } else { $null }
            datastores      = $datastoreIds
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
            }
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

    $metadata = @{ rvtoolsVersion = $null; created = $null }
    if ($tabs.ContainsKey('vMetaData') -and $tabs.vMetaData.Rows.Count -gt 0) {
        $m = $tabs.vMetaData
        $metadata.rvtoolsVersion = ConvertTo-SynthText (Get-SynthRvCell $m.Rows[0] $m.Columns 'rvtoolsVersion')
        $metadata.created = ConvertTo-SynthDateText (Get-SynthRvCell $m.Rows[0] $m.Columns 'created')
    }

    $sorted = { param($Table) @($Table.Values | Sort-Object { $_.id }) }
    [ordered]@{
        schemaVersion = 1
        importedAt    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        source        = [ordered]@{
            format         = $source.Format
            file           = if ($Anonymise) { $null } else { Split-Path -Leaf $source.Source }
            rvtoolsVersion = $metadata.rvtoolsVersion
            exportedAt     = $metadata.created
            anonymised     = [bool]$Anonymise
            tiering        = if ($TieringRules.sourcePath) { Split-Path -Leaf $TieringRules.sourcePath } else { $null }
        }
        datacenters   = @(& $sorted $datacenters)
        clusters      = @(& $sorted $clusters)
        hosts         = @(& $sorted $hosts)
        datastores    = @(& $sorted $datastores)
        vms           = @(& $sorted $vms)
        report        = [ordered]@{
            warnings = @($report.warnings)
            skipped  = @($report.skipped | ForEach-Object { [ordered]@{ tab = $_.tab; row = $_.row; reason = $_.reason } })
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
    if ($inventory.schemaVersion -ne 1) {
        throw "Inventory '$Path' has schema version $($inventory.schemaVersion); this build reads version 1. Run 'import' again."
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
        param($Items, $Noun)
        $n = @($Items).Count
        "$n $Noun$(if ($n -ne 1) { 's' })"
    }
    $vms = @($Inventory.vms)
    $on = @($vms | Where-Object { $_.powerState -eq 'poweredOn' }).Count
    "$(& $count $vms 'VM') ($on powered on) on $(& $count $Inventory.hosts 'host') in $(& $count $Inventory.clusters 'cluster'), $(& $count $Inventory.datastores 'datastore'), $(& $count $Inventory.datacenters 'datacenter')"

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
