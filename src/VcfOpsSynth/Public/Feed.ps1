function New-SynthFeedObject {
    <#
    .SYNOPSIS
        Prepares the live feed for each seeded object: its series, scaled to carry on from the backfill.

    .DESCRIPTION
        Builds the same per-object spec as the backfill (New-SynthBackfillSpec), then
        works out each series' scale over the reference window, which should be the
        backfill's range, so live points sit at the levels the history set. Text
        stats in the plan are pushed unchanged with every live point, so Operations
        keeps them current.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER Inventory
        The inventory the plan was built from.

    .PARAMETER Ids
        Plan key to resource ID in Operations.

    .PARAMETER Range
        The reference window: the backfill's range (Read-SynthBackfillState), or Get-SynthBackfillRange.

    .PARAMETER TimeZone
        Time zone the workload profiles' hours are in.

    .PARAMETER Concurrency
        Objects prepared in parallel.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds feed objects in memory; Invoke-SynthFeed pushes them.')]
    [CmdletBinding()]
    [OutputType([VcfOpsSynth.FeedObject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][hashtable]$Ids,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Range,
        [string]$TimeZone = 'Europe/Dublin',
        [ValidateRange(1, 64)][int]$Concurrency = 4
    )

    $spec = [VcfOpsSynth.ObjectSpec[]]@(New-SynthBackfillSpec -Plan $Plan -Inventory $Inventory -Ids $Ids)
    if (-not $spec.Count) { return }
    $feed = [VcfOpsSynth.Feed]::PrepareAll($spec, [long]$Range.StartMs, [int]$Range.StepMs, [int]$Range.Points, $TimeZone, $Concurrency)
    $byKey = @{}
    foreach ($object in @($Plan.objects)) { $byKey[$object.key] = $object }
    foreach ($f in $feed) {
        $object = $byKey[$f.Spec.Key]
        $text = @($object.stats | Where-Object { $_.value -is [string] -and -not (Test-SynthNumericText -Text $_.value) })
        $f.TextKeys = [string[]]@($text | ForEach-Object { $_.key })
        $f.TextValues = [string[]]@($text | ForEach-Object { [string]$_.value })
        $f
    }
}

function Test-SynthNumericText {
    <# True when a text stat value reads as a number, which Operations stores as data rather than text. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $number = 0.0
    [double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number)
}

function Get-SynthFeedTime {
    <#
    .SYNOPSIS
        The timestamps one feed cycle pushes: catch-up points since the last push (or the backfill's end), and the live point.

    .DESCRIPTION
        The live point is the last whole interval at or before Now. Catch-up points
        fill the gap after LastMs, at most MaxCatchUpHours of them, so a feed that
        was stopped for a while leaves no hole in the charts.

    .PARAMETER LastMs
        The last timestamp already in Operations; 0 for none.

    .PARAMETER StepMs
        Milliseconds between points.

    .PARAMETER Now
        The current time; defaults to now.

    .PARAMETER MaxCatchUpHours
        Longest gap filled; older points are left for a backfill.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [long]$LastMs = 0,
        [Parameter(Mandatory)][int]$StepMs,
        [Nullable[DateTimeOffset]]$Now,
        [ValidateRange(0, 168)][int]$MaxCatchUpHours = 24
    )

    $nowMs = if ($Now) { ([DateTimeOffset]$Now).ToUnixTimeMilliseconds() } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $live = [long]([math]::Floor($nowMs / $StepMs) * $StepMs)
    $earliest = $live - [long]$MaxCatchUpHours * 3600000
    $first = if ($LastMs -gt 0) { [math]::Max($LastMs + $StepMs, $earliest) } else { $live }
    # A first point not on the step grid (a range from another interval) is moved onto it.
    $first = [long]([math]::Ceiling($first / $StepMs) * $StepMs)
    $catchUp = [System.Collections.Generic.List[long]]::new()
    for ($t = $first; $t -lt $live; $t += $StepMs) { $catchUp.Add($t) }
    @{ CatchUp = [long[]]$catchUp.ToArray(); Live = $live }
}

function Get-SynthScenarioCatalogue {
    <#
    .SYNOPSIS
        The scenarios the feed can overlay (plan section 7), with the kind of object each one targets.

    .DESCRIPTION
        S5 (datastore runway), S6 (sizing) and S7 (configuration hygiene) come
        from the backfill and the seed, so they are not overlays and are not
        listed here.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    [ordered]@{
        S1 = [ordered]@{ Name = 'noisy-neighbour'; Target = 'HostSystem'; Description = 'Bronze VMs on one host take its CPU; the Gold VMs there see ready time and contention' }
        S2 = [ordered]@{ Name = 'memory-pressure'; Target = 'HostSystem'; Description = 'Ballooning, swapping and memory contention on one host and its VMs' }
        S3 = [ordered]@{ Name = 'storage-latency'; Target = 'Datastore'; Description = 'Read and write latency step on one datastore and the VMs on it' }
        S4 = [ordered]@{ Name = 'guest-disk-filling'; Target = 'VirtualMachine'; Description = "One VM's guest file systems fill to 95 %" }
        S8 = [ordered]@{ Name = 'host-failure'; Target = 'HostSystem'; Description = 'One host stops reporting and shows as not responding; its cluster loses that capacity and the other hosts take its load' }
    }
}

function Resolve-SynthScenarioTarget {
    <#
    .SYNOPSIS
        The inventory object a scenario runs on: the one named (by ID or name), or a sensible default.

    .DESCRIPTION
        Defaults: S1 the host with the most powered-on VMs among those holding both
        Gold and Bronze VMs (any busy host when none does); S2 the busiest host other
        than S1's; S3 the datastore with the most powered-on VMs; S4 the first
        powered-on Gold VM with guest file systems (any tier when none); S8 the
        busiest host in a cluster of two or more hosts.

    .PARAMETER Id
        The scenario ID (S1, S2, S3, S4 or S8).

    .PARAMETER Inventory
        The inventory model.

    .PARAMETER Target
        An inventory ID or object name; empty for the default.

    .PARAMETER Avoid
        Inventory IDs other running scenarios already use, skipped by the defaults.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Avoid', Justification = 'Used inside the free script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [string]$Target,
        [string[]]$Avoid = @()
    )

    $catalogue = Get-SynthScenarioCatalogue
    $entry = $catalogue[$Id.ToUpperInvariant()]
    if (-not $entry) { throw "Unknown scenario '$Id'. Scenarios: $($catalogue.Keys -join ', ')." }
    $collection = @{ HostSystem = 'hosts'; Datastore = 'datastores'; VirtualMachine = 'vms' }[$entry.Target]
    $pool = @($Inventory[$collection])
    if ($Target) {
        $found = @($pool | Where-Object { $_.id -eq $Target })
        if (-not $found.Count) { $found = @($pool | Where-Object { $_.name -ieq $Target }) }
        if ($found.Count -gt 1) { throw "'$Target' names $($found.Count) $collection; use the inventory ID instead." }
        if (-not $found.Count) { throw "No $($entry.Target) '$Target' in the inventory." }
        return $found[0]
    }

    $on = @($Inventory.vms | Where-Object { $_.powerState -eq 'poweredOn' })
    $byHost = @{}
    foreach ($vm in $on) { if ($vm.host) { if (-not $byHost.ContainsKey($vm.host)) { $byHost[$vm.host] = [System.Collections.Generic.List[object]]::new() }; $byHost[$vm.host].Add($vm) } }
    $free = { param($o) $o.id -notin $Avoid }
    $busiest = { param($candidates) @($candidates | Where-Object { & $free $_ } | Sort-Object @{ Expression = { if ($byHost.ContainsKey($_.id)) { $byHost[$_.id].Count } else { 0 } }; Descending = $true }, @{ Expression = { $_.id } })[0] }
    $pick = switch ($Id.ToUpperInvariant()) {
        'S1' {
            $mixed = @($Inventory.hosts | Where-Object { $byHost.ContainsKey($_.id) -and @($byHost[$_.id] | Where-Object { $_.tier -eq 'Gold' }).Count -and @($byHost[$_.id] | Where-Object { $_.tier -eq 'Bronze' }).Count })
            if ($mixed.Count) { & $busiest $mixed } else { & $busiest @($Inventory.hosts) }
        }
        'S2' { & $busiest @($Inventory.hosts) }
        'S3' {
            $count = @{}
            foreach ($vm in $on) { foreach ($ds in @($vm.datastores)) { if ($ds) { $count[$ds] = 1 + $(if ($count.ContainsKey($ds)) { $count[$ds] } else { 0 }) } } }
            @($Inventory.datastores | Where-Object { & $free $_ } | Sort-Object @{ Expression = { if ($count.ContainsKey($_.id)) { $count[$_.id] } else { 0 } }; Descending = $true }, @{ Expression = { $_.id } })[0]
        }
        'S4' {
            $withFs = @($on | Where-Object { (& $free $_) -and $_.storage -and @($_.storage.partitions).Count } | Sort-Object { $_.id })
            $gold = @($withFs | Where-Object { $_.tier -eq 'Gold' })
            if ($gold.Count) { $gold[0] } elseif ($withFs.Count) { $withFs[0] } else { $null }
        }
        'S8' {
            $hostsPerCluster = @{}
            foreach ($h in @($Inventory.hosts)) { if ($h.cluster) { $hostsPerCluster[$h.cluster] = 1 + $(if ($hostsPerCluster.ContainsKey($h.cluster)) { $hostsPerCluster[$h.cluster] } else { 0 }) } }
            & $busiest @($Inventory.hosts | Where-Object { $_.cluster -and $hostsPerCluster[$_.cluster] -ge 2 })
        }
    }
    if (-not $pick) { throw "No suitable $($entry.Target) for $Id in the inventory; name one with -Target." }
    $pick
}

function Get-SynthScenarioEffect {
    <#
    .SYNOPSIS
        What a running scenario changes: metric overlays per plan key, and properties to push when it starts and stops.

    .DESCRIPTION
        Returns @{ Overlays = @{ key = Overlay[] }; Start = @{ key = @{ property = value } }; Stop = @{ ... } }.
        Overlays are applied by the feed from the scenario's start time, ramping
        in over RampMinutes; properties are pushed by Start-SynthScenario and
        Stop-SynthScenario. Values that depend on an object's size (MHz, KB) are
        worked out here from the inventory and the plan's current values.

    .PARAMETER Scenario
        A running scenario from the state file: id, target, startedMs, rampMinutes.

    .PARAMETER Inventory
        The inventory model.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan, for the current values of size keys.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Scenario,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $id = ([string]$Scenario.id).ToUpperInvariant()
    $name = (Get-SynthScenarioCatalogue)[$id].Name
    $startMs = [long]$Scenario.startedMs
    $rampMs = [long]([double]$(if ($Scenario.Contains('rampMinutes')) { $Scenario.rampMinutes } else { 10 }) * 60000)
    $effect = @{ Overlays = @{}; Start = @{}; Stop = @{} }
    $add = {
        param([string]$Key, [string]$Pattern, [VcfOpsSynth.OverlayOp]$Op, [double]$Value)
        $ov = [VcfOpsSynth.Overlay]::new()
        $ov.Scenario = $id; $ov.Pattern = $Pattern; $ov.Op = $Op; $ov.Value = $Value; $ov.StartMs = $startMs; $ov.RampMs = $rampMs
        if (-not $effect.Overlays.ContainsKey($Key)) { $effect.Overlays[$Key] = [System.Collections.Generic.List[VcfOpsSynth.Overlay]]::new() }
        $effect.Overlays[$Key].Add($ov)
    }
    $mark = { param([string]$Key, [hashtable]$On, [hashtable]$Off) $effect.Start[$Key] = $On; $effect.Stop[$Key] = $Off }
    $planStats = @{}
    foreach ($o in @($Plan.objects)) { $planStats[$o.key] = $o }
    $statValue = { param([string]$Key, [string]$Stat) $o = $planStats[$Key]; if (-not $o) { return $null }; $s = @($o.stats | Where-Object { $_.key -eq $Stat })[0]; if ($s -and $s.value -isnot [string]) { [double]$s.value } }
    $num = { param($v) if ($null -eq $v) { 0.0 } else { [double]$v } }
    $target = [string]$Scenario.target
    $vmsOn = { param([scriptblock]$Where) @($Inventory.vms | Where-Object { $_.powerState -eq 'poweredOn' } | Where-Object $Where) }
    $hostOf = @{}
    foreach ($h in @($Inventory.hosts)) { $hostOf[$h.id] = $h }

    switch ($id) {
        'S1' {
            $vms = & $vmsOn { $_.host -eq $target }
            foreach ($vm in @($vms | Where-Object { $_.tier -eq 'Bronze' })) {
                $mhz = & $num $vm.cpu.capacityMhz
                & $add $vm.id '^cpu\|(usage_average|demandPct)$' Set 95
                if ($mhz) { & $add $vm.id '^cpu\|(usagemhz_average|demandmhz)$' Set (0.95 * $mhz) }
                & $mark $vm.id @{ 'vcfops-synth|scenario' = $name } @{ 'vcfops-synth|scenario' = 'none' }
            }
            foreach ($vm in @($vms | Where-Object { $_.tier -in 'Gold', 'Silver' })) {
                & $add $vm.id '^cpu\|readyPct$' Set 12
                & $add $vm.id '^cpu\|(capacity_)?contentionPct$' Set 15
                & $add $vm.id '^cpu\|costopPct$' Set 4
            }
            $h = $hostOf[$target]
            $capMhz = (& $num $h.cores) * (& $num $h.cpuMhz)
            & $add $target '^cpu\|(usage_average|capacity_usagepct_average)$' Set 97
            & $add $target '^cpu\|demandPct$' Set 115
            if ($capMhz) { & $add $target '^cpu\|(usagemhz_average)$' Set (0.97 * $capMhz); & $add $target '^cpu\|(demandmhz|demand_without_overhead)$' Set (1.15 * $capMhz) }
            & $add $target '^cpu\|(readyPct|capacity_contentionPct)$' Set 12
        }
        'S2' {
            $vms = & $vmsOn { $_.host -eq $target }
            foreach ($vm in $vms) {
                $kb = (& $num $vm.memory.sizeMiB) * 1024
                & $add $vm.id '^mem\|balloonPct$' Set 25
                if ($kb) { & $add $vm.id '^mem\|vmmemctl_average$' Set (0.25 * $kb); & $add $vm.id '^mem\|swapped_average$' Set (0.08 * $kb) }
                & $add $vm.id '^mem\|swapinRate_average$' Set 4096
                & $add $vm.id '^mem\|swapoutRate_average$' Set 2048
                & $add $vm.id '^mem\|(host_)?contentionPct$' Set 12
            }
            $h = $hostOf[$target]
            $kb = (& $num $h.memoryMiB) * 1024
            & $add $target '^mem\|(usage_average|host_usagePct)$' Set 98
            if ($kb) { & $add $target '^mem\|(consumed_average|host_usage)$' Set (0.98 * $kb); & $add $target '^mem\|host_demand$' Set (1.1 * $kb); & $add $target '^mem\|vmmemctl_average$' Set (0.12 * $kb) }
            & $add $target '^mem\|(balloonPct)$' Set 12
            & $add $target '^mem\|swapinRate_average$' Set 16384
            & $add $target '^mem\|(host_)?contentionPct$' Set 10
        }
        'S3' {
            $latency = '^(datastore|storage|virtualDisk(:[^|]+)?)\|total(Read|Write)Latency_average$'
            & $add $target $latency Set 45
            & $add $target '^datastore\|(totalLatency_max|maxTotalLatency_latest)$' Set 60
            foreach ($vm in (& $vmsOn { $target -in @($_.datastores) })) { & $add $vm.id $latency Set 45 }
        }
        'S4' {
            $o = $planStats[$target]
            foreach ($s in @($o.stats | Where-Object { $_.key -match '^guestfilesystem:([^|]+)\|capacity$' })) {
                $path = [regex]::Escape(($s.key -split '\|')[0])
                if ($s.value -isnot [string] -and [double]$s.value -gt 0) { & $add $target "^$path\|usage$" Set (0.95 * [double]$s.value) }
                & $add $target "^$path\|percentage$" Set 95
            }
            & $add $target '^guestfilesystem\|percentage_total$' Set 95
            $cap = & $statValue $target 'guestfilesystem|capacity_total'
            if ($cap) { & $add $target '^guestfilesystem\|usage_total$' Set (0.95 * $cap) }
        }
        'S8' {
            $h = $hostOf[$target]
            # The host goes quiet apart from its power state, and shows as not responding.
            & $add $target '^(?!sys\|poweredOn$).*' Drop 0
            & $add $target '^sys\|poweredOn$' Set 0
            & $mark $target @{ 'runtime|connectionState' = 'notResponding'; 'runtime|powerState' = 'unknown' } @{ 'runtime|connectionState' = 'connected'; 'runtime|powerState' = 'poweredOn' }
            $peers = @($Inventory.hosts | Where-Object { $_.cluster -and $_.cluster -eq $h.cluster -and $_.id -ne $target })
            if ($peers.Count) {
                # The rest of the cluster takes the failed host's share of the load...
                $factor = ($peers.Count + 1) / $peers.Count
                foreach ($p in $peers) { & $add $p.id '^(cpu|mem)\|(usage_average|usagemhz_average|demandPct|demandmhz|consumed_average|host_usage|host_usagePct|host_demand|capacity_usagepct_average)$' Multiply $factor }
                # ...and loses its capacity, so headroom drops.
                $share = $peers.Count / ($peers.Count + 1)
                & $add $h.cluster '^(cpu|mem)\|(totalCapacity_average|haTotalCapacity_average)$' Multiply $share
                & $add $h.cluster '^summary\|number_running_hosts$' Add -1
            }
        }
    }
    $effect
}

function Read-SynthScenarioState {
    <# The running scenarios in the state file, oldest first; wrap the call in @() for a list. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $all = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $all -or -not $all.ContainsKey('scenarios')) { return }
    foreach ($s in @($all.scenarios)) { if ($s) { $s } }
}

function Save-SynthStateSection {
    <# Writes one section of the state file, keeping the rest, through a temporary file. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [AllowNull()][AllowEmptyCollection()]$Value
    )
    $all = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if (-not $all) { $all = @{} }
    $all[$Section] = $Value
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder }
    if ($PSCmdlet.ShouldProcess($Path, "Save $Section state")) {
        $temp = "$Path.tmp"
        $all | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}

function Push-SynthScenarioProperty {
    <# Pushes a scenario's start or stop properties to the objects it marks. #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Change,
        [Parameter(Mandatory)][hashtable]$Ids
    )
    $count = 0
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach ($key in $Change.Keys) {
        if (-not $Ids.ContainsKey($key)) { continue }
        $entries = @(foreach ($p in $Change[$key].Keys) { @{ key = $p; value = [string]$Change[$key][$p] } })
        if (-not $PSCmdlet.ShouldProcess($key, 'Push scenario properties')) { continue }
        $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$($Ids[$key])/properties" -Body @{ 'property-content' = @(ConvertTo-SynthSampleList -Entry $entries -Timestamp $now) }
        $count++
    }
    $count
}

function Start-SynthScenario {
    <#
    .SYNOPSIS
        Starts a scenario on a target: records it in the state file and pushes its marker properties.

    .DESCRIPTION
        The feed applies a running scenario's overlays from its start, ramping in
        over RampMinutes, so symptoms and alerts raise within a few feed cycles.
        Starting a scenario that is already running restarts it on the new target.
        Without a session (Connect-SynthOps) only the state file changes.

    .PARAMETER Id
        S1, S2, S3, S4 or S8.

    .PARAMETER Inventory
        The inventory model.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER StatePath
        The state file (paths.state).

    .PARAMETER Target
        Inventory ID or name; empty for the scenario's default target.

    .PARAMETER RampMinutes
        Minutes over which the overlay reaches full effect.

    .PARAMETER Ids
        Plan key to resource ID, for pushing marker properties.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$StatePath,
        [string]$Target,
        [ValidateRange(0, 1440)][int]$RampMinutes = 10,
        [hashtable]$Ids = @{}
    )

    $id = $Id.ToUpperInvariant()
    $running = @(Read-SynthScenarioState -Path $StatePath | Where-Object { $_.id -ne $id })
    $object = Resolve-SynthScenarioTarget -Id $id -Inventory $Inventory -Target $Target -Avoid @($running | ForEach-Object { $_.target })
    $entry = [ordered]@{ id = $id; name = (Get-SynthScenarioCatalogue)[$id].Name; target = $object.id; targetName = $object.name; startedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); rampMinutes = $RampMinutes }
    if (-not $PSCmdlet.ShouldProcess("$id on $($object.name)", 'Start scenario')) { return $entry }
    $previous = @(Read-SynthScenarioState -Path $StatePath | Where-Object { $_.id -eq $id })
    foreach ($old in $previous) { if ($script:OpsSession -and $Ids.Count) { $null = Push-SynthScenarioProperty -Change (Get-SynthScenarioEffect -Scenario $old -Inventory $Inventory -Plan $Plan).Stop -Ids $Ids } }
    Save-SynthStateSection -Path $StatePath -Section 'scenarios' -Value @(@($running) + @(, $entry))
    if ($script:OpsSession -and $Ids.Count) { $null = Push-SynthScenarioProperty -Change (Get-SynthScenarioEffect -Scenario $entry -Inventory $Inventory -Plan $Plan).Start -Ids $Ids }
    $entry
}

function Stop-SynthScenario {
    <#
    .SYNOPSIS
        Stops one running scenario, or all of them, and pushes back the properties they changed.

    .DESCRIPTION
        The feed's next cycle goes back to the normal curve, so the alerts the
        scenario raised clear after their cancel cycles.

    .PARAMETER Id
        The scenario ID, or 'all'.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$StatePath,
        [hashtable]$Ids = @{}
    )

    $running = @(Read-SynthScenarioState -Path $StatePath)
    $stop = @($running | Where-Object { $Id -ieq 'all' -or $_.id -ieq $Id })
    foreach ($s in $stop) {
        if (-not $PSCmdlet.ShouldProcess("$($s.id) on $($s.targetName)", 'Stop scenario')) { continue }
        if ($script:OpsSession -and $Ids.Count) { $null = Push-SynthScenarioProperty -Change (Get-SynthScenarioEffect -Scenario $s -Inventory $Inventory -Plan $Plan).Stop -Ids $Ids }
        $running = @($running | Where-Object { $_.id -ne $s.id })
        Save-SynthStateSection -Path $StatePath -Section 'scenarios' -Value $running
        $s
    }
}

function Set-SynthFeedOverlay {
    <#
    .SYNOPSIS
        Puts the running scenarios' overlays on the feed objects, replacing any from before.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][VcfOpsSynth.FeedObject[]]$Feed,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Scenario,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )
    $all = @{}
    foreach ($s in $Scenario) {
        $effect = Get-SynthScenarioEffect -Scenario $s -Inventory $Inventory -Plan $Plan
        foreach ($key in $effect.Overlays.Keys) {
            if (-not $all.ContainsKey($key)) { $all[$key] = [System.Collections.Generic.List[VcfOpsSynth.Overlay]]::new() }
            $all[$key].AddRange($effect.Overlays[$key])
        }
    }
    if (-not $PSCmdlet.ShouldProcess("$($Feed.Count) feed objects", 'Set scenario overlays')) { return }
    foreach ($f in $Feed) {
        # Built inside @() so an object with no overlays gets an empty array, not $null (an empty array returned from if is unrolled).
        $f.Overlays = [VcfOpsSynth.Overlay[]]@(if ($all.ContainsKey($f.Spec.Key)) { $all[$f.Spec.Key] })
    }
}

function Invoke-SynthFeed {
    <#
    .SYNOPSIS
        Pushes live points every interval with analytics on, filling any gap since the last push first.

    .DESCRIPTION
        Each cycle reads the running scenarios from the state file (so scenario
        start and stop take effect without restarting the feed), pushes catch-up
        points with analytics off and the current point with analytics on, saves
        the last timestamp pushed, then waits for the next interval. Stops after
        Cycles cycles, or never when Cycles is 0.

        Run Connect-SynthOps first.

    .PARAMETER Feed
        Feed objects from New-SynthFeedObject.

    .PARAMETER Inventory
        The inventory model, for scenario effects.

    .PARAMETER Plan
        The seed plan, for scenario effects.

    .PARAMETER StatePath
        The state file: feed progress and running scenarios.

    .PARAMETER StepMs
        Milliseconds between points.

    .PARAMETER TimeZone
        Time zone the workload profiles' hours are in.

    .PARAMETER Cycles
        Cycles to run; 0 runs until stopped.

    .PARAMETER Concurrency
        Objects posted at once.

    .PARAMETER MaxCatchUpHours
        Longest gap filled when the feed starts.

    .PARAMETER DelaySeconds
        Seconds after each interval boundary before pushing, so the point is complete.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][VcfOpsSynth.FeedObject[]]$Feed,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$StepMs,
        [string]$TimeZone = 'Europe/Dublin',
        [ValidateRange(0, 1000000)][int]$Cycles = 0,
        [ValidateRange(1, 64)][int]$Concurrency = 8,
        [ValidateRange(0, 168)][int]$MaxCatchUpHours = 24,
        [ValidateRange(0, 240)][int]$DelaySeconds = 20
    )

    if (-not $script:OpsSession) { throw 'Not signed in to VCF Operations; run Connect-SynthOps first.' }
    $summary = @{ cycles = 0; samples = 0L; failed = 0 }
    if (-not $PSCmdlet.ShouldProcess("$($Feed.Count) objects every $($StepMs / 60000) minutes", 'Feed live metrics')) { return $summary }
    while ($true) {
        $state = if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
        if (-not $state) { $state = @{} }
        $last = if ($state.ContainsKey('feed') -and $state.feed.lastMs) { [long]$state.feed.lastMs }
        elseif ($state.ContainsKey('backfill') -and $state.backfill.range) { [long]$state.backfill.range.EndMs }
        else { 0 }
        $times = Get-SynthFeedTime -LastMs $last -StepMs $StepMs -MaxCatchUpHours $MaxCatchUpHours
        $scenarios = @(if ($state.ContainsKey('scenarios')) { $state.scenarios })
        Set-SynthFeedOverlay -Feed $Feed -Scenario $scenarios -Inventory $Inventory -Plan $Plan
        # A cheap call first, so an expired token is renewed before the engine uses it.
        $null = Invoke-SynthOpsRequest -Method Get -Path 'versions/current'
        $failed = 0
        if ($times.CatchUp.Count -and $times.Live -gt $last) {
            $r = @(Invoke-SynthFeedEngine -Feed $Feed -Time $times.CatchUp -StepMs $StepMs -TimeZone $TimeZone -Analytics $false -Concurrency $Concurrency)
            $summary.samples += ($r | Measure-Object -Property Samples -Sum).Sum
            $failed += @($r | Where-Object Status -NE 0).Count
            Write-Verbose ('{0:HH:mm:ss}Z caught up {1} points' -f [DateTime]::UtcNow, $times.CatchUp.Count)
        }
        if ($times.Live -gt $last) {
            $r = @(Invoke-SynthFeedEngine -Feed $Feed -Time ([long[]]@($times.Live)) -StepMs $StepMs -TimeZone $TimeZone -Analytics $true -Concurrency $Concurrency)
            $summary.samples += ($r | Measure-Object -Property Samples -Sum).Sum
            $bad = @($r | Where-Object Status -NE 0)
            $failed += $bad.Count
            foreach ($b in @($bad | Select-Object -First 3)) { Write-Warning "$($b.Key): $($b.Error)" }
            Save-SynthStateSection -Path $StatePath -Section 'feed' -Value ([ordered]@{ lastMs = $times.Live; updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) })
            $active = if ($scenarios.Count) { '; scenarios ' + (($scenarios | ForEach-Object { $_.id }) -join ', ') } else { '' }
            Write-Verbose ('{0:HH:mm:ss}Z pushed {1:u} for {2} objects, {3} failed{4}' -f [DateTime]::UtcNow, [DateTimeOffset]::FromUnixTimeMilliseconds($times.Live), $Feed.Count, $failed, $active)
        }
        $summary.cycles++
        $summary.failed += $failed
        if ($Cycles -and $summary.cycles -ge $Cycles) { break }
        $next = [DateTimeOffset]::FromUnixTimeMilliseconds($times.Live + $StepMs).AddSeconds($DelaySeconds)
        $wait = $next - [DateTimeOffset]::UtcNow
        if ($wait.TotalMilliseconds -gt 0) { Start-Sleep -Milliseconds ([int]$wait.TotalMilliseconds) }
    }
    $summary
}

function Invoke-SynthFeedEngine {
    <# One engine call: the given timestamps for every feed object, with the session's address, token and certificate setting. #>
    [CmdletBinding()]
    [OutputType([VcfOpsSynth.PushResult])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][VcfOpsSynth.FeedObject[]]$Feed,
        [Parameter(Mandatory)][long[]]$Time,
        [Parameter(Mandatory)][int]$StepMs,
        [Parameter(Mandatory)][string]$TimeZone,
        [Parameter(Mandatory)][bool]$Analytics,
        [Parameter(Mandatory)][int]$Concurrency
    )
    $session = $script:OpsSession
    [VcfOpsSynth.Feed]::Run($session.BaseUri, $session.Token, [bool]$session.SkipCertificateCheck, $Feed, $Time, $StepMs, $TimeZone, $Analytics, $Concurrency, [int][math]::Max(120, $session.TimeoutSec))
}
