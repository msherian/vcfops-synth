function Get-SynthAlertContent {
    <#
    .SYNOPSIS
        The symptoms, recommendations, alerts and super metrics the toolset publishes, so the scenarios raise alerts.

    .DESCRIPTION
        Thresholds follow the plan's tiers: CPU contention (ready time) warns at
        3 % and is critical at 5 % on Gold VMs, 5 % and 10 % on Silver, and is off
        on Bronze; disk latency warns at 10 ms and is critical at 20 ms on Gold,
        20 ms and 40 ms on Silver, and is critical at 50 ms on Bronze. A VM's tier
        comes from the vcfops-synth|tier property seed writes, through a property
        symptom, so one set of alerts covers every tier without policy overrides.

        Each scenario has an alert: S1 Gold and Silver CPU contention, S2 memory
        pressure on the host and its VMs, S3 disk latency by tier and on the
        datastore, S4 guest file system space, S8 host not responding.

        Names carry the content prefix so reset can find them. Alert type and
        subtype follow the Suite API's numbering (15 Virtualization/Hypervisor;
        18 Availability, 19 Performance, 20 Capacity).

    .PARAMETER Prefix
        The content prefix (lab.json prefix).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Prefix = 'Synth-')

    $vm = @{ AdapterKind = 'VMWARE'; ResourceKind = 'VirtualMachine' }
    $esx = @{ AdapterKind = 'VMWARE'; ResourceKind = 'HostSystem' }
    $ds = @{ AdapterKind = 'VMWARE'; ResourceKind = 'Datastore' }
    $metric = { param($on, $name, $key, $op, $value, $severity) $on + @{ Name = "$Prefix$name"; Type = 'metric'; Key = $key; Operator = $op; Value = $value; Severity = $severity } }
    $property = { param($on, $name, $key, $value, $severity) $on + @{ Name = "$Prefix$name"; Type = 'property'; Key = $key; Operator = 'EQ'; Value = $value; Severity = $severity } }

    $symptoms = @(
        foreach ($tier in 'Gold', 'Silver', 'Bronze') { & $property $vm "VM tier is $tier" 'vcfops-synth|tier' $tier 'INFORMATION' }
        & $metric $vm 'VM CPU ready above 3 %' 'cpu|readyPct' 'GT' 3 'WARNING'
        & $metric $vm 'VM CPU ready above 5 %' 'cpu|readyPct' 'GT' 5 'CRITICAL'
        & $metric $vm 'VM CPU ready above 10 %' 'cpu|readyPct' 'GT' 10 'CRITICAL'
        foreach ($ms in 10, 20, 40, 50) {
            & $metric $vm "VM disk read latency above $ms ms" 'virtualDisk|totalReadLatency_average' 'GT' $ms $(if ($ms -eq 10) { 'WARNING' } else { 'CRITICAL' })
            & $metric $vm "VM disk write latency above $ms ms" 'virtualDisk|totalWriteLatency_average' 'GT' $ms $(if ($ms -eq 10) { 'WARNING' } else { 'CRITICAL' })
        }
        & $metric $vm 'VM memory ballooning above 10 %' 'mem|balloonPct' 'GT' 10 'WARNING'
        & $metric $vm 'VM swapping in' 'mem|swapinRate_average' 'GT' 1024 'CRITICAL'
        & $metric $vm 'VM guest file system above 90 %' 'guestfilesystem|percentage_total' 'GT' 90 'WARNING'
        & $metric $vm 'VM guest file system above 95 %' 'guestfilesystem|percentage_total' 'GT' 95 'CRITICAL'
        & $metric $esx 'Host memory usage above 95 %' 'mem|usage_average' 'GT' 95 'CRITICAL'
        & $metric $esx 'Host memory ballooning above 5 %' 'mem|balloonPct' 'GT' 5 'WARNING'
        & $metric $esx 'Host CPU demand above 100 %' 'cpu|demandPct' 'GT' 100 'CRITICAL'
        & $property $esx 'Host not responding' 'runtime|connectionState' 'notResponding' 'CRITICAL'
        & $metric $ds 'Datastore read latency above 30 ms' 'datastore|totalReadLatency_average' 'GT' 30 'CRITICAL'
        & $metric $ds 'Datastore write latency above 30 ms' 'datastore|totalWriteLatency_average' 'GT' 30 'CRITICAL'
    )

    $recommendations = @(
        @{ Key = 'cpu'; Text = "${Prefix}Move the busy Bronze VMs off this host, or limit their CPU shares, so the Gold and Silver VMs get their CPU time." }
        @{ Key = 'memory'; Text = "${Prefix}Move VMs off this host or add memory: ballooning and swapping mean the host is overcommitted." }
        @{ Key = 'latency'; Text = "${Prefix}Move the busiest VMs to a faster datastore, or find what is saturating this one." }
        @{ Key = 'disk'; Text = "${Prefix}Extend the guest disk or clear space inside the guest before it fills." }
        @{ Key = 'host'; Text = "${Prefix}Check the host's connection to vCenter and its hardware; HA restarts its VMs on the other hosts." }
    )

    # A state: severity, the symptoms that must all hold (each item a name, or an array of names any of which holds).
    $state = { param($severity, [object[]]$all, $rec) @{ Severity = $severity; All = $all; Recommendation = $rec } }
    $latency = { param($ms) , @("${Prefix}VM disk read latency above $ms ms", "${Prefix}VM disk write latency above $ms ms") }
    $alerts = @(
        $vm + @{ Name = "${Prefix}Gold VM CPU contention"; Type = 15; SubType = 19; Description = 'A Gold VM waits for CPU (ready time above its tier threshold), usually because neighbours on its host are busy.'
            States = @((& $state 'CRITICAL' @("${Prefix}VM tier is Gold", "${Prefix}VM CPU ready above 5 %") 'cpu'), (& $state 'WARNING' @("${Prefix}VM tier is Gold", "${Prefix}VM CPU ready above 3 %") 'cpu')) }
        $vm + @{ Name = "${Prefix}Silver VM CPU contention"; Type = 15; SubType = 19; Description = 'A Silver VM waits for CPU (ready time above its tier threshold).'
            States = @((& $state 'CRITICAL' @("${Prefix}VM tier is Silver", "${Prefix}VM CPU ready above 10 %") 'cpu'), (& $state 'WARNING' @("${Prefix}VM tier is Silver", "${Prefix}VM CPU ready above 5 %") 'cpu')) }
        $vm + @{ Name = "${Prefix}Gold VM disk latency"; Type = 15; SubType = 19; Description = "A Gold VM's disk latency is above its tier threshold."
            States = @((& $state 'CRITICAL' @("${Prefix}VM tier is Gold", (& $latency 20)) 'latency'), (& $state 'WARNING' @("${Prefix}VM tier is Gold", (& $latency 10)) 'latency')) }
        $vm + @{ Name = "${Prefix}Silver VM disk latency"; Type = 15; SubType = 19; Description = "A Silver VM's disk latency is above its tier threshold."
            States = @((& $state 'CRITICAL' @("${Prefix}VM tier is Silver", (& $latency 40)) 'latency'), (& $state 'WARNING' @("${Prefix}VM tier is Silver", (& $latency 20)) 'latency')) }
        $vm + @{ Name = "${Prefix}Bronze VM disk latency"; Type = 15; SubType = 19; Description = "A Bronze VM's disk latency is above 50 ms."
            States = @((& $state 'CRITICAL' @("${Prefix}VM tier is Bronze", (& $latency 50)) 'latency')) }
        $vm + @{ Name = "${Prefix}VM memory pressure"; Type = 15; SubType = 19; Description = 'A VM is ballooning or swapping because its host is short of memory.'
            States = @((& $state 'CRITICAL' @(, @("${Prefix}VM swapping in")) 'memory'), (& $state 'WARNING' @(, @("${Prefix}VM memory ballooning above 10 %")) 'memory')) }
        $vm + @{ Name = "${Prefix}VM guest file system nearly full"; Type = 15; SubType = 20; Description = "A VM's guest file systems are nearly full."
            States = @((& $state 'CRITICAL' @(, @("${Prefix}VM guest file system above 95 %")) 'disk'), (& $state 'WARNING' @(, @("${Prefix}VM guest file system above 90 %")) 'disk')) }
        $esx + @{ Name = "${Prefix}Host memory pressure"; Type = 15; SubType = 19; Description = 'A host is out of memory: usage above 95 % with ballooning.'
            States = @((& $state 'CRITICAL' @("${Prefix}Host memory usage above 95 %", "${Prefix}Host memory ballooning above 5 %") 'memory')) }
        $esx + @{ Name = "${Prefix}Host CPU overcommitted"; Type = 15; SubType = 19; Description = 'A host is asked for more CPU than it has.'
            States = @((& $state 'CRITICAL' @(, @("${Prefix}Host CPU demand above 100 %")) 'cpu')) }
        $esx + @{ Name = "${Prefix}Host not responding"; Type = 15; SubType = 18; Description = 'A host has stopped responding to vCenter.'
            States = @((& $state 'CRITICAL' @(, @("${Prefix}Host not responding")) 'host')) }
        $ds + @{ Name = "${Prefix}Datastore latency"; Type = 17; SubType = 19; Description = 'A datastore is slow to read or write.'
            States = @((& $state 'CRITICAL' @(, @("${Prefix}Datastore read latency above 30 ms", "${Prefix}Datastore write latency above 30 ms")) 'latency')) }
    )

    # Super metrics the dashboards use, assigned to these kinds; Operations computes them once a policy enables them.
    $superMetrics = @(
        @{ Name = "${Prefix}VM CPU demand over allocation"; ResourceKinds = @(@{ AdapterKind = 'VMWARE'; ResourceKind = 'VirtualMachine' }); UnitId = 'percent'; Description = 'CPU demand as a share of the VM''s allocation: low means oversized, high means undersized.'
            Formula = '${this, metric=cpu|demandmhz} / ${this, metric=cpu|vm_capacity_provisioned} * 100' }
        @{ Name = "${Prefix}Cluster worst VM CPU ready"; ResourceKinds = @(@{ AdapterKind = 'VMWARE'; ResourceKind = 'ClusterComputeResource' }); UnitId = 'percent'; Description = 'The highest CPU ready time of any VM in the cluster.'
            Formula = 'max(${adaptertype=VMWARE, objecttype=VirtualMachine, metric=cpu|readyPct, depth=2})' }
        @{ Name = "${Prefix}Cluster worst VM disk latency"; ResourceKinds = @(@{ AdapterKind = 'VMWARE'; ResourceKind = 'ClusterComputeResource' }); UnitId = 'ms'; Description = 'The highest disk read latency of any VM in the cluster.'
            Formula = 'max(${adaptertype=VMWARE, objecttype=VirtualMachine, metric=virtualDisk|totalReadLatency_average, depth=2})' }
        @{ Name = "${Prefix}Tier VM health"; ResourceKinds = @(@{ AdapterKind = 'Container'; ResourceKind = 'Service Level Objective' }); UnitId = ''; Description = 'The average health of the VMs in a tier group.'
            Formula = 'avg(${adaptertype=VMWARE, objecttype=VirtualMachine, metric=badge|health, depth=1})' }
    )

    @{ Symptoms = $symptoms; Recommendations = $recommendations; Alerts = $alerts; SuperMetrics = $superMetrics }
}

function ConvertTo-SynthSymptomBody {
    <# The Suite API body for one symptom definition. #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [string]$Id
    )
    $condition = if ($Definition.Type -eq 'property') {
        [ordered]@{ type = 'CONDITION_PROPERTY_STRING'; key = $Definition.Key; operator = $Definition.Operator; stringValue = [string]$Definition.Value; thresholdType = 'STATIC' }
    }
    else {
        [ordered]@{ type = 'CONDITION_HT'; key = $Definition.Key; operator = $Definition.Operator; value = [string]$Definition.Value; valueType = 'NUMERIC'; instanced = $false; thresholdType = 'STATIC' }
    }
    $body = [ordered]@{
        name            = $Definition.Name
        adapterKindKey  = $Definition.AdapterKind
        resourceKindKey = $Definition.ResourceKind
        waitCycles      = 1
        cancelCycles    = 1
        state           = [ordered]@{ severity = $Definition.Severity; condition = $condition }
    }
    if ($Id) { $body = [ordered]@{ id = $Id } + $body }
    $body
}

function ConvertTo-SynthAlertBody {
    <#
    .SYNOPSIS
        The Suite API body for one alert definition, with symptom and recommendation names turned into IDs.

    .DESCRIPTION
        Each state needs all of its items to hold; an item that is a list of
        names holds when any of them does. A state of one plain set becomes a
        SYMPTOM_SET; anything else a SYMPTOM_SET_COMPOSITE of sets joined by AND.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [Parameter(Mandatory)][hashtable]$SymptomId,
        [hashtable]$RecommendationId = @{},
        [string]$Id
    )
    $ids = $SymptomId
    $idOf = { param($name) if (-not $ids.ContainsKey($name)) { throw "Alert '$($Definition.Name)' needs symptom '$name', which was not published." }; $ids[$name] }
    $set = { param([string[]]$names, [string]$operator) [ordered]@{ type = 'SYMPTOM_SET'; relation = 'SELF'; aggregation = 'ALL'; symptomSetOperator = $operator; symptomDefinitionIds = @($names | ForEach-Object { & $idOf $_ }) } }
    $states = foreach ($s in $Definition.States) {
        $singles = @($s.All | Where-Object { $_ -is [string] })
        $anyOf = @($s.All | Where-Object { $_ -isnot [string] })
        $sets = @()
        if ($singles.Count) { $sets += , (& $set $singles 'AND') }
        foreach ($group in $anyOf) { $sets += , (& $set @($group) 'OR') }
        $base = if ($sets.Count -eq 1) { $sets[0] } else { [ordered]@{ type = 'SYMPTOM_SET_COMPOSITE'; operator = 'AND'; 'symptom-sets' = $sets } }
        $entry = [ordered]@{ severity = $s.Severity; 'base-symptom-set' = $base; impact = [ordered]@{ impactType = 'BADGE'; detail = 'HEALTH' } }
        if ($s.Recommendation -and $RecommendationId.ContainsKey($s.Recommendation)) { $entry.recommendationPriorityMap = @{ $RecommendationId[$s.Recommendation] = 1 } }
        $entry
    }
    $body = [ordered]@{
        name            = $Definition.Name
        description     = $Definition.Description
        adapterKindKey  = $Definition.AdapterKind
        resourceKindKey = $Definition.ResourceKind
        waitCycles      = 1
        cancelCycles    = 1
        type            = $Definition.Type
        subType         = $Definition.SubType
        states          = @($states)
    }
    if ($Id) { $body = [ordered]@{ id = $Id } + $body }
    $body
}

function Get-SynthResponseField {
    <# One field of a Suite API response, or $null when it is missing; works on parsed JSON and on hashtables. #>
    [CmdletBinding()]
    param($Response, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Response) { return $null }
    if ($Response -is [System.Collections.IDictionary]) { return $(if ($Response.Contains($Name)) { $Response[$Name] }) }
    $p = $Response.PSObject.Properties[$Name]
    if ($p) { $p.Value }
}

function Get-SynthPagedList {
    <# Every item of a paged Suite API list, following pageInfo. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Property,
        [hashtable]$Query = @{}
    )
    $page = 0
    do {
        $q = $Query.Clone(); $q.page = $page; $q.pageSize = 1000
        $r = Invoke-SynthOpsRequest -Method Get -Path $Path -Query $q
        $items = @(Get-SynthResponseField $r $Property | Where-Object { $null -ne $_ })
        foreach ($i in $items) { $i }
        $page++
        $total = [int](Get-SynthResponseField (Get-SynthResponseField $r 'pageInfo') 'totalCount')
    } while ($items.Count -and $page * 1000 -lt $total)
}

function Publish-SynthAlertContent {
    <#
    .SYNOPSIS
        Creates or updates the toolset's symptoms, recommendations, alerts and super metrics, by name within the prefix.

    .DESCRIPTION
        Symptoms first, since alerts refer to them by ID; then recommendations
        (matched by their text, which starts with the prefix); then alerts and
        super metrics. Content outside the prefix is never touched, and an
        existing item keeps its ID. One failure is reported and the rest carry
        on, so a single rejected definition does not hold up the others.

    .PARAMETER Content
        From Get-SynthAlertContent.

    .PARAMETER Prefix
        The content prefix; only items whose names start with it are matched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Content,
        [string]$Prefix = 'Synth-'
    )

    $report = { param($kind, $name, $action, $id, $err) [pscustomobject]@{ Kind = $kind; Name = $name; Action = $action; Id = $id; Error = $err } }
    $upsert = {
        param($kind, $name, $found, [string]$path, [scriptblock]$makeBody)
        $action = if ($found) { 'Update' } else { 'Create' }
        if (-not $PSCmdlet.ShouldProcess($name, "$action $kind")) { return & $report $kind $name "would $($action.ToLowerInvariant())" $(if ($found) { $found.id }) $null }
        try {
            $body = & $makeBody $(if ($found) { [string]$found.id })
            $r = if ($found) { Invoke-SynthOpsRequest -Method Put -Path $path -Body $body } else { Invoke-SynthOpsRequest -Method Post -Path $path -Body $body }
            $newId = [string](Get-SynthResponseField $r 'id')
            if (-not $newId -and $found) { $newId = [string]$found.id }
            & $report $kind $name ($action.ToLowerInvariant() + 'd') $newId $null
        }
        catch { & $report $kind $name 'failed' $(if ($found) { $found.id }) $_.Exception.Message }
    }

    $symptomId = @{}
    $existing = @{}
    foreach ($s in @(Get-SynthPagedList -Path 'symptomdefinitions' -Property 'symptomDefinitions')) { if ($s.name -like "$Prefix*") { $existing[$s.name] = $s } }
    foreach ($d in $Content.Symptoms) {
        $r = & $upsert 'symptom' $d.Name $existing[$d.Name] 'symptomdefinitions' { param($id) ConvertTo-SynthSymptomBody -Definition $d -Id $id }
        if ($r.Id) { $symptomId[$d.Name] = $r.Id }
        $r
    }

    $recommendationId = @{}
    $existing = @{}
    foreach ($r in @(Get-SynthPagedList -Path 'recommendations' -Property 'recommendations')) { if ($r.description -like "$Prefix*") { $existing[$r.description] = $r } }
    foreach ($d in $Content.Recommendations) {
        $r = & $upsert 'recommendation' $d.Text $existing[$d.Text] 'recommendations' { param($id) $b = [ordered]@{ description = $d.Text }; if ($id) { $b = [ordered]@{ id = $id } + $b }; $b }
        if ($r.Id) { $recommendationId[$d.Key] = $r.Id }
        $r
    }

    $existing = @{}
    foreach ($a in @(Get-SynthPagedList -Path 'alertdefinitions' -Property 'alertDefinitions')) { if ($a.name -like "$Prefix*") { $existing[$a.name] = $a } }
    foreach ($d in $Content.Alerts) {
        & $upsert 'alert' $d.Name $existing[$d.Name] 'alertdefinitions' { param($id) ConvertTo-SynthAlertBody -Definition $d -SymptomId $symptomId -RecommendationId $recommendationId -Id $id }
    }

    $existing = @{}
    foreach ($m in @(Get-SynthPagedList -Path 'supermetrics' -Property 'superMetrics')) { if ($m.name -like "$Prefix*") { $existing[$m.name] = $m } }
    foreach ($d in $Content.SuperMetrics) {
        & $upsert 'super metric' $d.Name $existing[$d.Name] 'supermetrics' {
            param($id)
            $b = [ordered]@{ name = $d.Name; formula = $d.Formula; description = $d.Description }
            if ($d.UnitId) { $b.unitId = $d.UnitId }
            $b.resourceKinds = @($d.ResourceKinds | ForEach-Object { [ordered]@{ adapterKindKey = $_.AdapterKind; resourceKindKey = $_.ResourceKind } })
            if ($id) { $b = [ordered]@{ id = $id } + $b }
            $b
        }
    }
}
