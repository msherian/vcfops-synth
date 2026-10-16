# The generator and pusher are C#: 30 days at 5 minutes for every numeric key is billions of samples.
if (-not ('VcfOpsSynth.Backfill' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'BackfillEngine.cs') -ReferencedAssemblies 'System.Net.Http', 'System.Net.Primitives', 'System.Net.Security', 'System.Security.Cryptography', 'System.Collections', 'System.Linq', 'System.Threading', 'System.Console', 'System.Runtime', 'System.Text.Encoding.Extensions', 'System.Text.RegularExpressions', 'System.Threading.Tasks.Parallel'
}

function Get-SynthCalibration {
    <#
    .SYNOPSIS
        The LiveOptics average and peak behind each calibrated stat key of a VM or host.

    .DESCRIPTION
        Returns key = @(average, peak, cap). Percentages are capped at 100;
        MHz and KB figures are the percentages over the object's own capacity.
        Powered-off VMs and objects without LiveOptics data get nothing here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Item
    )

    $out = @{}
    $perf = if ($Item.Contains('baseline') -and $Item.baseline -is [System.Collections.IDictionary] -and $Item.baseline.Contains('perf')) { $Item.baseline.perf } else { $null }
    if ($perf -isnot [System.Collections.IDictionary]) { return $out }
    $get = { param($k) if ($perf.Contains($k) -and $null -ne $perf[$k]) { [double]$perf[$k] } else { $null } }
    $pair = {
        param([string[]]$Keys, $avg, $peak, $scale, $cap)
        if ($null -eq $avg -or $null -eq $peak) { return }
        foreach ($k in $Keys) { $out[$k] = @(($avg * $scale), ([math]::Max($avg, $peak) * $scale), $cap) }
    }
    $nan = [double]::NaN
    switch ($Kind) {
        'VirtualMachine' {
            if ($Item.powerState -ne 'poweredOn') { return $out }
            $capMhz = if ($Item.cpu -and $Item.cpu.Contains('capacityMhz') -and $Item.cpu.capacityMhz) { [double]$Item.cpu.capacityMhz } else { 0 }
            $memKb = if ($Item.memory -and $Item.memory.Contains('sizeMiB') -and $Item.memory.sizeMiB) { [double]$Item.memory.sizeMiB * 1024 } else { 0 }
            & $pair @('cpu|usage_average', 'cpu|demandPct') (& $get 'cpuAvgPct') (& $get 'cpuPeakPct') 1 100
            if ($capMhz) { & $pair @('cpu|usagemhz_average', 'cpu|demandmhz') (& $get 'cpuAvgPct') (& $get 'cpuPeakPct') ($capMhz / 100) $nan }
            & $pair @('mem|usage_average') (& $get 'memAvgPct') (& $get 'memPeakPct') 1 100
            if ($memKb) { & $pair @('mem|active_average', 'mem|host_demand', 'mem|guest_demand', 'mem|vmMemoryDemand') (& $get 'memAvgPct') (& $get 'memPeakPct') ($memKb / 100) $nan }
            & $pair @('virtualDisk|numberReadAveraged_average') (& $get 'readIopsAvg') (& $get 'readIopsPeak') 1 $nan
            & $pair @('virtualDisk|numberWriteAveraged_average') (& $get 'writeIopsAvg') (& $get 'writeIopsPeak') 1 $nan
            & $pair @('virtualDisk|read_average') (& $get 'readMBpsAvg') (& $get 'readMBpsPeak') 1024 $nan
            & $pair @('virtualDisk|write_average') (& $get 'writeMBpsAvg') (& $get 'writeMBpsPeak') 1024 $nan
            & $pair @('virtualDisk|totalReadLatency_average', 'storage|totalReadLatency_average') (& $get 'readLatencyAvgMs') (& $get 'readLatencyPeakMs') 1 $nan
            & $pair @('virtualDisk|totalWriteLatency_average', 'storage|totalWriteLatency_average') (& $get 'writeLatencyAvgMs') (& $get 'writeLatencyPeakMs') 1 $nan
        }
        'HostSystem' {
            $capMhz = [double]$(if ($Item.cores) { $Item.cores } else { 0 }) * [double]$(if ($Item.cpuMhz) { $Item.cpuMhz } else { 0 })
            $memKb = [double]$(if ($Item.memoryMiB) { $Item.memoryMiB } else { 0 }) * 1024
            & $pair @('cpu|usage_average', 'cpu|demandPct', 'cpu|capacity_usagepct_average') (& $get 'cpuAvgPct') (& $get 'cpuPeakPct') 1 100
            if ($capMhz) { & $pair @('cpu|usagemhz_average', 'cpu|demandmhz', 'cpu|demand_without_overhead') (& $get 'cpuAvgPct') (& $get 'cpuPeakPct') ($capMhz / 100) $nan }
            & $pair @('mem|usage_average', 'mem|host_usagePct') (& $get 'memAvgPct') (& $get 'memPeakPct') 1 100
            if ($memKb) { & $pair @('mem|consumed_average', 'mem|host_usage', 'mem|host_demand') (& $get 'memAvgPct') (& $get 'memPeakPct') ($memKb / 100) $nan }
            & $pair @('storage|commandsAveraged_average') (& $get 'iopsAvg') (& $get 'iopsPeak') 1 $nan
            & $pair @('storage|usage_average') (& $get 'throughputAvgMBps') (& $get 'throughputPeakMBps') 1024 $nan
            & $pair @('storage|totalReadLatency_average') (& $get 'readLatencyAvgMs') (& $get 'readLatencyPeakMs') 1 $nan
            & $pair @('storage|totalWriteLatency_average') (& $get 'writeLatencyAvgMs') (& $get 'writeLatencyPeakMs') 1 $nan
        }
    }
    $out
}

function Get-SynthSeriesMode {
    <#
    .SYNOPSIS
        How a stat key without LiveOptics data gets its history, from the last part of its name.

    .DESCRIPTION
        Capacity, configuration and count keys stay flat; space in use grows to
        its current value; everything else is activity, following the object's
        shape around its current value. Percentages are capped at 100.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Key)

    $leaf = ($Key -split '\|')[-1]
    $percent = $leaf -match '(?i)pct|percent' -or $Key -match '^(cpu|mem)\|usage_average$'
    $cap = if ($percent) { 100 } else { [double]::NaN }
    # Capacity stays put: totalCapacity_average is a size, though its name ends in _average.
    if ($leaf -match '(?i)capacity|provisioned|usable' -and $leaf -notmatch '(?i)pct|percent|usage|used|contention|demand|consumer') { return @{ Mode = [VcfOpsSynth.SeriesMode]::Constant; Cap = $cap } }
    # Space in use first: total_usage and a guest file system's usage are space, not activity.
    if ($leaf -match '(?i)^(used|usage|diskused|used_space|usage_total|total_usage|percentage|percentage_total|usedSpacePct|snapshot.*|otherused|consumer_provisioned)$') { return @{ Mode = [VcfOpsSynth.SeriesMode]::Ramp; Cap = $cap } }
    if ($leaf -match '(?i)usage|demand|contention|ready|latency|average|rate|_ratio|workload|load|active|swap|balloon') { return @{ Mode = [VcfOpsSynth.SeriesMode]::Activity; Cap = $cap } }
    if ($leaf -match '(?i)capacity|provisioned|corecount|^num|number|count|configured|limit|reservation|size|total|max|min|speed|vcpus|shares|version|days|timestamp|age') { return @{ Mode = [VcfOpsSynth.SeriesMode]::Constant; Cap = $cap } }
    @{ Mode = [VcfOpsSynth.SeriesMode]::Activity; Cap = $cap }
}

function New-SynthBackfillSpec {
    <#
    .SYNOPSIS
        The engine's spec for each planned object that has numeric stat keys.

    .DESCRIPTION
        Every numeric key of the seed plan becomes a series: calibrated to the
        LiveOptics average and peak where there are figures, otherwise an
        activity curve, a flat value or a growth ramp around the derived
        current value; keys with no value stay at zero. Text metrics have no
        history and are skipped. Each object's shape is the sum of its own VMs'
        curves (the VM itself, a host's VMs, a datastore's, a port group's and so
        on), so a peak on a VM is a peak on its host, cluster and datastore.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER Inventory
        The inventory the plan was built from.

    .PARAMETER Ids
        Plan key to resource ID in Operations, for the objects to backfill.

    .PARAMETER GrowthPerWeek
        Weekly growth of space in use, as a fraction (0.01 = 1% a week).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds specs in memory; Invoke-SynthBackfill pushes them.')]
    [CmdletBinding()]
    [OutputType([VcfOpsSynth.ObjectSpec])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][hashtable]$Ids,
        [double]$GrowthPerWeek = 0.01
    )

    $items = @{}
    foreach ($collection in 'datacenters', 'clusters', 'hosts', 'datastores', 'switches', 'networks', 'folders', 'vms') {
        foreach ($entry in @($Inventory[$collection])) { if ($entry -and $entry.id) { $items[$entry.id] = $entry } }
    }
    # Each VM's curve, and which objects it feeds.
    $members = @{}
    $addTo = { param($key, $c) if ($key) { if (-not $members.ContainsKey($key)) { $members[$key] = [System.Collections.Generic.List[object]]::new() }; $members[$key].Add($c) } }
    $networkSwitch = @{}
    foreach ($net in @($Inventory.networks)) { if ($net.switch) { $networkSwitch[$net.id] = $net.switch } }
    foreach ($vm in @($Inventory.vms)) {
        $c = [VcfOpsSynth.ShapeComponent]::new()
        $c.Profile = if ($vm.powerState -ne 'poweredOn') { 'off' } elseif ($vm.Contains('profile') -and $vm.profile) { [string]$vm.profile } else { 'steady' }
        $c.Seed = [string]$vm.id
        $mhz = if ($vm.cpu -and $vm.cpu.Contains('usageMhz') -and $vm.cpu.usageMhz) { [double]$vm.cpu.usageMhz } else { 0 }
        $c.Weight = [math]::Max(1, $mhz)
        foreach ($target in @($vm.id, $vm.host, $vm.cluster, $vm.datacenter, $vm.folderId)) { & $addTo $target $c }
        foreach ($ds in @($vm.datastores)) { & $addTo $ds $c }
        $switchesSeen = @{}
        foreach ($nic in @($vm.nics)) {
            if (-not $nic -or -not $nic.network) { continue }
            & $addTo $nic.network $c
            $sw = $networkSwitch[$nic.network]
            if ($sw -and -not $switchesSeen.ContainsKey($sw)) { $switchesSeen[$sw] = $true; & $addTo $sw $c }
        }
    }

    foreach ($object in @($Plan.objects)) {
        if (-not $Ids.ContainsKey($object.key)) { continue }
        $numeric = @($object.stats | Where-Object { $_.value -is [ValueType] -and $_.value -isnot [bool] })
        if (-not $numeric.Count) { continue }
        $item = $items[$object.key]
        $calibration = if ($item) { Get-SynthCalibration -Kind $object.kind -Item $item } else { @{} }
        # Ops sums a VM's per-disk write throughput into the total, overwriting a pushed total, so the
        # first disk carries the LiveOptics figure (read too, so the per-disk view agrees); other disks stay 0.
        foreach ($total in 'virtualDisk|read_average', 'virtualDisk|write_average') {
            if (-not $calibration.ContainsKey($total)) { continue }
            $leaf = ($total -split '\|')[1]
            $first = @($numeric | Where-Object { $_.key -match "^virtualDisk:[^|]+\|$([regex]::Escape($leaf))$" } | ForEach-Object key | Sort-Object)[0]
            if ($first) { $calibration[$first] = $calibration[$total] }
        }
        $spec = [VcfOpsSynth.ObjectSpec]::new()
        $spec.Key = $object.key
        $spec.ResourceId = $Ids[$object.key]
        $spec.Seed = $object.key
        # A VM's own curve, at weight 1, is exactly the curve its host and cluster include.
        $spec.Components = if ($members.ContainsKey($object.key)) {
            [VcfOpsSynth.ShapeComponent[]]@($members[$object.key] | ForEach-Object { if ($object.kind -eq 'VirtualMachine') { $one = [VcfOpsSynth.ShapeComponent]::new(); $one.Profile = $_.Profile; $one.Seed = $_.Seed; $one.Weight = 1; $one } else { $_ } })
        }
        else { [VcfOpsSynth.ShapeComponent[]]@() }
        $spec.Series = [VcfOpsSynth.SeriesSpec[]]@(foreach ($stat in $numeric) {
                $s = [VcfOpsSynth.SeriesSpec]::new()
                $s.Key = $stat.key
                $value = [double]$stat.value
                if ($calibration.ContainsKey($stat.key)) {
                    $s.Mode = [VcfOpsSynth.SeriesMode]::Calibrated
                    $s.A = $calibration[$stat.key][0]; $s.B = $calibration[$stat.key][1]; $s.Cap = $calibration[$stat.key][2]
                }
                elseif ($value -eq 0) { $s.Mode = [VcfOpsSynth.SeriesMode]::Constant; $s.A = 0 }
                else {
                    $mode = Get-SynthSeriesMode -Key $stat.key
                    $s.Mode = $mode.Mode; $s.A = $value; $s.Cap = $mode.Cap
                    if ($s.Mode -eq [VcfOpsSynth.SeriesMode]::Ramp) { $s.B = $GrowthPerWeek }
                }
                $s
            })
        $spec
    }
}
