function Get-SynthRubric {
    <#
    .SYNOPSIS
        Loads the per-kind rubrics captured from real objects in the lab.

    .DESCRIPTION
        Each file in the folder is VMWARE-<ResourceKind>.json, holding the stat
        keys, the latest value of each (numbers, or text for text metrics) and the
        properties of one real object of that kind. A synthetic object gets every
        key in its kind's rubric. The files hold real lab names and values, so
        they stay in the gitignored data folder; see docs/runbook.md, spike 0.5.

    .PARAMETER Path
        The rubrics folder.

    .EXAMPLE
        $rubrics = Get-SynthRubric -Path ./data/rubrics
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No rubrics folder at '$Path'. Capture rubrics from the lab first (runbook, spike 0.5)." }
    $rubrics = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter 'VMWARE-*.json') {
        $rubric = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $kind = if ($rubric.resourceKind) { $rubric.resourceKind } else { $file.BaseName -replace '^VMWARE-', '' }
        $rubrics[$kind] = $rubric
    }
    $missing = @(Get-SynthSeedKind -WithRubric | Where-Object { -not $rubrics.ContainsKey($_) })
    if ($missing.Count) { throw "Rubrics folder '$Path' has no rubric for $($missing -join ', ')." }
    $rubrics
}

function New-SynthSeedPlan {
    <#
    .SYNOPSIS
        Works out every object, metric, property and link the seed creates, without calling Operations.

    .DESCRIPTION
        Turns the inventory model into objects under a vCenter adapter instance,
        foundations first: an optional Physical Data Center, then datacenters,
        clusters, datastores, hosts, distributed and standard switches, their port
        groups, VM folders and VMs. Each keeps its inventory name (with the
        optional prefix) and carries the synthetic tag. VMWARE kinds get every
        stat key and property of their kind's rubric. Per-instance keys are
        expanded from the object's own devices: virtual disks, guest file systems
        and network adapters for a VM; physical NICs, VMkernel adapters and HBAs
        for a host; member hosts for a switch. Identity, parent and sizing
        properties come from the inventory, and IP and MAC addresses from the
        reference object are never copied. Standard switches and port groups have
        no VMWARE kind, so they go under the toolset's own adapter kind with the
        inventory's properties only.

        Every relationship is worked out here, before anything is created. Links
        join each object to its parents in the plan, and the datacenters to the
        vCenter adapter instance ('@vcenter') and the Physical Data Center.
        Operations does not show the root Resources pool of a cluster or
        standalone host, so these are counted in skipped. User-created resource
        pools are a VMWARE kind but are not seeded yet; skipped.userResourcePools
        counts them.

    .PARAMETER Inventory
        The model from Import-SynthRvtools or Get-SynthInventory.

    .PARAMETER Rubric
        Rubrics from Get-SynthRubric.

    .PARAMETER VcId
        The vCenter instance UUID (VMEntityVCID) of the adapter instance the objects go under.

    .PARAMETER Prefix
        Optional name prefix. Empty by default, so objects keep their inventory
        names; the tag is what marks them as synthetic.

    .PARAMETER Tag
        The vSphere tags every object carries, each as Category and Name, for
        example the synthetic marker and the project. They are written to
        summary|tag and summary|tagJson.

    .PARAMETER CustomAdapterKind
        The toolset's own adapter kind, for standard switches and port groups,
        which have no VMWARE kind.

    .PARAMETER PhysicalDatacenter
        Name of a Physical Data Center to put above the datacenters. Empty means none.

    .EXAMPLE
        $plan = New-SynthSeedPlan -Inventory $inventory -Rubric $rubrics -VcId $vcId
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan in memory; Invoke-SynthSeed makes the changes.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CustomAdapterKind', Justification = 'Used inside the add script block, which the rule does not follow.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][hashtable]$Rubric,
        [Parameter(Mandatory)][string]$VcId,
        [AllowEmptyString()][string]$Prefix = '',
        [System.Collections.IDictionary[]]$Tag = @(@{ Category = 'vcfops-synth'; Name = 'synthetic' }),
        [string]$CustomAdapterKind = 'VcfOpsSynth',
        [AllowEmptyString()][string]$PhysicalDatacenter = ''
    )

    $objects = [System.Collections.Generic.List[object]]::new()
    $byId = @{}
    $children = [ordered]@{}
    $link = {
        param($ParentId, $ChildId)
        # '@vcenter' is the adapter instance itself, which Invoke-SynthSeed resolves.
        if (-not $ParentId -or -not $ChildId -or -not $byId.ContainsKey($ChildId)) { return }
        if ($ParentId -ne '@vcenter' -and -not $byId.ContainsKey($ParentId)) { return }
        if (-not $children.Contains($ParentId)) { $children[$ParentId] = [System.Collections.Generic.List[string]]::new() }
        if (-not $children[$ParentId].Contains($ChildId)) { $children[$ParentId].Add($ChildId) }
    }
    # Every inventory name, prefixed, so a VM adapter on a standard port group still names it.
    $names = @{}
    foreach ($collection in 'datacenters', 'clusters', 'hosts', 'datastores', 'switches', 'networks', 'folders', 'resourcePools', 'vms') {
        foreach ($entry in @($Inventory[$collection])) { if ($entry -and $entry.id) { $names[$entry.id] = "$Prefix$($entry.name)" } }
    }
    $nameOf = { param($Id) if ($Id -and $names.ContainsKey($Id)) { $names[$Id] } else { '' } }
    $moidOf = { param($Id) if ($Id -and $byId.ContainsKey($Id)) { $byId[$Id].moid } else { & $nameOf $Id } }
    # The customer vCenter the export came from (RVTools VI SDK Server), when the inventory records it.
    $vcenterName = if ($Inventory.Contains('source') -and $Inventory.source -is [System.Collections.IDictionary] -and $Inventory.source.Contains('vcenter')) { [string]$Inventory.source.vcenter } else { '' }
    $prepared = @{}
    $tags = @($Tag | Where-Object { $_ -and $_.Category -and $_.Name })
    $tagSet = [ordered]@{
        # Operations strips anything in angle brackets from pushed values, so the vCenter adapter's <Category-Tag> form cannot be used.
        'summary|tag'     = "[$(($tags | ForEach-Object { "$($_.Category)-$($_.Name)" }) -join ', ')]"
        'summary|tagJson' = ConvertTo-Json -Compress -InputObject @($tags | ForEach-Object { [ordered]@{ category = [string]$_.Category; name = [string]$_.Name } })
    }
    $context = Get-SynthDerivationContext -Inventory $Inventory
    $customKinds = Get-SynthSeedKind -Custom

    # Objects first, parents before children, so links and parent names can look each other up.
    $add = {
        param($Kind, $Item)
        $adapterKind = if ($Kind -in $customKinds) { $CustomAdapterKind } else { 'VMWARE' }
        $record = [ordered]@{
            key         = $Item.id
            kind        = $Kind
            adapterKind = $adapterKind
            name        = "$Prefix$($Item.name)"
            moid        = if ($adapterKind -eq 'VMWARE' -and $Kind -ne 'PhysicalDatacenter') { "$(Get-SynthMoidPrefix -Kind $Kind)-synth-$(($Item.id -split '-')[-1])" } else { $null }
            item        = $Item
            identifiers = $null
            stats       = $null
            properties  = $null
        }
        $objects.Add($record)
        $byId[$Item.id] = $record
    }
    if ($PhysicalDatacenter) { & $add 'PhysicalDatacenter' @{ id = 'pdc-synth'; name = $PhysicalDatacenter } }
    foreach ($dc in @($Inventory.datacenters)) { & $add 'Datacenter' $dc }
    foreach ($cluster in @($Inventory.clusters)) { & $add 'ClusterComputeResource' $cluster }
    foreach ($ds in @($Inventory.datastores)) { & $add 'Datastore' $ds }
    foreach ($h in @($Inventory.hosts)) { & $add 'HostSystem' $h }
    foreach ($sw in @($Inventory.switches | Where-Object { $_.kind -eq 'distributed' })) { & $add 'VmwareDistributedVirtualSwitch' $sw }
    foreach ($sw in @($Inventory.switches | Where-Object { $_.kind -ne 'distributed' })) { & $add 'StandardSwitch' $sw }
    foreach ($net in @($Inventory.networks | Where-Object { $_.kind -eq 'distributed' })) { & $add 'DistributedVirtualPortgroup' $net }
    foreach ($net in @($Inventory.networks | Where-Object { $_.kind -ne 'distributed' })) { & $add 'StandardPortgroup' $net }
    foreach ($folder in @($Inventory.folders)) { & $add 'VMFolder' $folder }
    foreach ($vm in @($Inventory.vms)) { & $add 'VirtualMachine' $vm }

    foreach ($record in $objects) {
        $item = $record.item
        $kind = $record.kind
        $families = @()
        $set = [ordered]@{ 'config|name' = $record.name }
        switch ($kind) {
            'PhysicalDatacenter' { }
            'Datacenter' { }
            'StandardSwitch' {
                $set['summary|parentDatacenter'] = & $nameOf $item.datacenter
                $set['summary|parentHost'] = (@($item.hosts | ForEach-Object { & $nameOf $_ }) -join ', ')
                if ($item.mtu) { $set['config|mtu'] = $item.mtu }
                if ($item.ports) { $set['config|numPorts'] = $item.ports }
            }
            'StandardPortgroup' {
                $set['summary|parentDatacenter'] = & $nameOf $item.datacenter
                $set['summary|parentHost'] = (@($item.hosts | ForEach-Object { & $nameOf $_ }) -join ', ')
                if ($item.switch) { $set['summary|parentSwitch'] = & $nameOf $item.switch }
                $set['config|policies|security|vlan_id'] = if ($item.vlan) { [string]$item.vlan } else { 'none' }
            }
            'ClusterComputeResource' {
                $set['summary|parentDatacenter'] = & $nameOf $item.datacenter
                if ($null -ne $item.haEnabled) { $set['configuration|dasConfig|enabled'] = if ($item.haEnabled) { 'Enabled' } else { 'Disabled' } }
                if ($null -ne $item.drsEnabled) { $set['configuration|drsConfig|enabled'] = [string]([bool]$item.drsEnabled).ToString().ToLowerInvariant() }
            }
            'HostSystem' {
                $set['summary|parentDatacenter'] = & $nameOf $item.datacenter
                $set['summary|parentCluster'] = & $nameOf $item.cluster
                if ($item.cpuModel) { $set['cpu|cpuModel'] = $item.cpuModel }
                if ($item.sockets) { $set['cpu|numCpuSockets'] = $item.sockets; $set['hardware|cpuInfo|numCpuPackages'] = $item.sockets }
                if ($item.cores) { $set['hardware|cpuInfo|numCpuCores'] = $item.cores }
                if ($item.cpuMhz) {
                    $set['hardware|cpuInfo|hz'] = $item.cpuMhz * 1e6
                    if ($item.cores) { $set['cpu|speed'] = $item.cpuMhz * $item.cores }
                }
                if ($item.memoryMiB) { $set['hardware|memorySize'] = $item.memoryMiB * 1024 }
                if ($item.vendor) { $set['hardware|vendor'] = $item.vendor }
                if ($item.vendor -or $item.model) { $set['hardware|vendorModel'] = "$($item.vendor) $($item.model)".Trim() }
                if ($item.esxVersion -match '(?<ver>\d+\.\d+\.\d+)\D+(?<build>\d+)') {
                    # Every version key the reference host carries; the host summary card reads summary|version_4d.
                    $set['summary|version'] = "$($Matches.ver)-$($Matches.build)"
                    $set['summary|version_4d'] = "$($Matches.ver).0.$($Matches.build)"
                    $set['config|product|apiVersion'] = "$($Matches.ver).0"
                    $set['sys|build'] = $Matches.build
                }
                $set['runtime|maintenanceState'] = if ($item.maintenance) { 'inMaintenance' } else { 'notInMaintenance' }
                $set['config|network|nnic'] = @($item.nics).Count
                $families = @(
                    @{ Prefix = 'net'; Match = '^vmnic\d+$'; Instances = @(foreach ($nic in @($item.nics)) {
                                @{ Name = $nic.device; Set = @{ speed = $nic.speedMbps; nicDriver = $nic.driver } }
                            })
                    }
                    @{ Prefix = 'net'; Match = '^vmk\d+$'; Instances = @(foreach ($vmk in @($item.vmkernels)) {
                                @{ Name = $vmk.device; Set = @{ port_group_key = (& $moidOf $vmk.network) } }
                            })
                    }
                    @{ Prefix = 'storageAdapter'; Match = '^vmhba\d+$'; Instances = @(foreach ($hba in @($item.hbas)) {
                                @{ Name = $hba.device; Set = @{ hbaDriver = $hba.driver } }
                            })
                    }
                )
            }
            'Datastore' {
                $set['summary|parentDatacenter'] = (& $nameOf (Get-SynthDatastoreDatacenter -Datastore $item -Hosts $byId))
                if ($item.type) { $set['summary|type'] = ([string]$item.type).ToLowerInvariant() }
                if ($item.capacityMiB) { $set['summary|diskCapacity'] = [math]::Round($item.capacityMiB / 1024, 3) }
                $set['summary|path'] = "ds:///vmfs/volumes/$($record.moid)/"
                $set['datastore|hostcount'] = @($item.hosts).Count
                $set['summary|isLocal'] = if (@($item.hosts).Count -le 1) { 'true' } else { 'false' }
            }
            'VmwareDistributedVirtualSwitch' {
                if ($item.version) { $set['summary|version'] = $item.version }
                $set['summary|dvs_uuid'] = (ConvertTo-SynthGuid -Text $record.moid)
                $families = @(@{ Prefix = 'host'; Match = '.'; Instances = @(foreach ($hostId in @($item.hosts)) {
                                if ($byId.ContainsKey($hostId)) { @{ Name = $byId[$hostId].name; Set = @{} } }
                            })
                    })
            }
            'DistributedVirtualPortgroup' {
                $set['config|policies|security|vlan_id'] = if ($item.vlan) { [string]$item.vlan } else { 'none' }
            }
            'VMFolder' {
                $set['summary|parentDatacenter'] = & $nameOf $item.datacenter
            }
            'VirtualMachine' {
                $vmSet = Get-SynthVmProperty -Vm $item -Record $record -NameOf $nameOf
                foreach ($key in $vmSet.Keys) { $set[$key] = $vmSet[$key] }
                if ($item.host -and $byId.ContainsKey($item.host) -and $byId[$item.host].item.esxVersion -match '\d+\.\d+\.\d+') {
                    $set['summary|parentHostVersion'] = $Matches[0]
                    $set['summary|parentHostVersion4d'] = "$($Matches[0]).0"
                }
                $families = Get-SynthVmFamily -Vm $item -Record $record -NameOf $nameOf
            }
        }
        # Kinds with no rubric (a Physical Data Center, standard switches and port groups) carry only what the inventory says.
        # A rubric only says which keys a kind has: every value comes from the inventory, is derived from it, or is a neutral placeholder.
        $hasRubric = $Rubric.ContainsKey($kind)
        $kindRubric = if ($hasRubric) { $Rubric[$kind] } else { @{ latest = @(); properties = @() } }
        # RVTools configuration the inventory kept for this object (HA/DRS, port group policies, host hardware, ...).
        $fromConfig = Get-SynthConfigProperty -Kind $kind -Item $item
        foreach ($key in $fromConfig.Keys) { if (-not $set.Contains($key)) { $set[$key] = $fromConfig[$key] } }
        foreach ($key in $tagSet.Keys) { $set[$key] = $tagSet[$key] }
        if ($vcenterName -and @($kindRubric.properties | Where-Object { $_.name -eq 'summary|parentVcenter' }).Count) { $set['summary|parentVcenter'] = $vcenterName }
        if (-not $prepared.ContainsKey($kind)) {
            # Worked out once per kind: the key list, each key's placeholder, and the per-instance templates.
            # Operations computes its own analytics (capacity, badges, alert counts, ...); pushing them would mask its results.
            $statEntries = @($kindRubric.latest | Where-Object { -not (Test-SynthComputedStatKey -Key $_.key) } | ForEach-Object { @{ key = $_.key; value = (Get-SynthPlaceholder -Value $_.value -Metric) } })
            # Operations sets System Properties itself, so they are not pushed.
            $propEntries = @($kindRubric.properties | Where-Object { $_.name -notlike 'System Properties|*' } | ForEach-Object { @{ key = $_.name; value = (Get-SynthPlaceholder -Value $_.value) } })
            $prepared[$kind] = @{
                Stats      = Split-SynthRubricEntry -Entry $statEntries -Family $families
                Properties = Split-SynthRubricEntry -Entry $propEntries -Family $families
            }
        }
        $prep = $prepared[$kind]

        $record.identifiers = @(Get-SynthSeedIdentifier -Kind $kind -Record $record -VcId $VcId)
        $derived = Get-SynthDerivedStat -Kind $kind -Item $item -Context $context
        $record.stats = @(foreach ($s in (Join-SynthRubricEntry -Split $prep.Stats -Family $families)) {
                if ($derived.Contains($s.key)) { @{ key = $s.key; value = $derived[$s.key] } } else { $s }
            })
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $record.properties = @(foreach ($p in (Join-SynthRubricEntry -Split $prep.Properties -Family $families)) {
                $null = $seen.Add($p.key)
                if ($set.Contains($p.key)) { @{ key = $p.key; value = $set[$p.key] } } else { $p }
            }
            # A kind with a rubric keeps exactly the rubric's keys, plus the tag; one without gets everything the inventory gave.
            foreach ($key in $set.Keys) {
                if (-not $seen.Contains($key) -and (-not $hasRubric -or $tagSet.Contains($key))) { @{ key = $key; value = $set[$key] } }
            })
    }

    # Links, parent to children, between objects in this plan; datacenters also go under the vCenter adapter instance.
    foreach ($record in $objects) {
        $item = $record.item
        switch ($record.kind) {
            'Datacenter' {
                & $link '@vcenter' $item.id
                if ($PhysicalDatacenter) { & $link 'pdc-synth' $item.id }
            }
            'StandardSwitch' { foreach ($hostId in @($item.hosts)) { & $link $hostId $item.id } }
            'StandardPortgroup' {
                if ($item.switch -and $byId.ContainsKey($item.switch)) { & $link $item.switch $item.id }
                else { foreach ($hostId in @($item.hosts)) { & $link $hostId $item.id } }
            }
            'ClusterComputeResource' { & $link $item.datacenter $item.id }
            'HostSystem' { if ($item.cluster -and $byId.ContainsKey($item.cluster)) { & $link $item.cluster $item.id } else { & $link $item.datacenter $item.id } }
            'Datastore' {
                & $link (Get-SynthDatastoreDatacenter -Datastore $item -Hosts $byId) $item.id
                foreach ($hostId in @($item.hosts)) { & $link $hostId $item.id }
            }
            'VmwareDistributedVirtualSwitch' { & $link $item.datacenter $item.id }
            'DistributedVirtualPortgroup' { & $link $item.switch $item.id }
            'VMFolder' { if ($item.parent) { & $link $item.parent $item.id } else { & $link $item.datacenter $item.id } }
            'VirtualMachine' {
                & $link $item.host $item.id
                & $link $item.folderId $item.id
                foreach ($dsId in @($item.datastores)) { & $link $dsId $item.id }
                foreach ($nic in @($item.nics)) { & $link $nic.network $item.id }
            }
        }
    }

    [ordered]@{
        vcId    = $VcId
        prefix  = $Prefix
        objects = @($objects | ForEach-Object {
                [ordered]@{ key = $_.key; kind = $_.kind; adapterKind = $_.adapterKind; name = $_.name; moid = $_.moid; identifiers = $_.identifiers; stats = $_.stats; properties = $_.properties }
            })
        links   = @(foreach ($parentId in $children.Keys) { [ordered]@{ parent = $parentId; children = @($children[$parentId]) } })
        skipped = [ordered]@{
            rootResourcePools = @($Inventory.resourcePools | Where-Object { -not $_.parent -and $_.name -eq 'Resources' }).Count
            userResourcePools = @($Inventory.resourcePools | Where-Object { $_.parent -or $_.name -ne 'Resources' }).Count
        }
    }
}

function Invoke-SynthSeed {
    <#
    .SYNOPSIS
        Creates the objects of a seed plan in VCF Operations and links them.

    .DESCRIPTION
        For each object in the plan, foundations first: if an object of that
        kind with the same unique identifier already exists, it is skipped and
        only used for links (and listed in renamed when its name differs);
        otherwise it is created, VMWARE kinds under the adapter instance and the
        toolset's own kinds under their adapter kind, then its stats and
        properties are pushed. Numbers go as data and text as values. Last, each
        parent is linked to its children: objects from the plan, plus the
        adapter instance itself above the datacenters.

        Run Connect-SynthOps first.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER AdapterInstanceId
        The vCenter adapter instance to create the objects under.

    .PARAMETER Refresh
        Also pushes the planned properties and current stats to objects that
        already exist, so a fix to the plan reaches them without recreating them.

    .EXAMPLE
        Invoke-SynthSeed -Plan $plan -AdapterInstanceId $adapterId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$AdapterInstanceId,
        [switch]$Refresh
    )

    $result = [ordered]@{
        created = [ordered]@{}; existing = [ordered]@{}; refreshed = 0; renamed = [System.Collections.Generic.List[string]]::new()
        failed = [System.Collections.Generic.List[string]]::new(); links = 0
    }
    # '@vcenter' in the plan's links is the adapter instance's own resource, the vCenter the datacenters sit under.
    $ids = @{ '@vcenter' = $AdapterInstanceId }
    $objects = @($Plan.objects)
    $total = $objects.Count
    $done = 0

    foreach ($kind in Get-SynthSeedKind) {
        $ofKind = @($objects | Where-Object { $_.kind -eq $kind })
        $result.created[$kind] = 0
        $result.existing[$kind] = 0
        if (-not $ofKind.Count) { continue }
        $adapterKind = if ($ofKind[0].Contains('adapterKind') -and $ofKind[0].adapterKind) { $ofKind[0].adapterKind } else { 'VMWARE' }
        $native = $adapterKind -eq 'VMWARE'
        $unique = @($ofKind[0].identifiers | Where-Object { $_.unique })
        $lookup = @{ Kind = $kind; AdapterKind = $adapterKind }
        if ($native) { $lookup.AdapterInstanceId = $AdapterInstanceId }
        if ($unique.Count) { $lookup.IdentifierName = $unique[0].name }
        $existing = Get-SynthExistingResource @lookup
        foreach ($object in $ofKind) {
            $done++
            if ($done % 50 -eq 0) { Write-Progress -Activity 'Seeding VCF Operations' -Status "$done of $total" -PercentComplete ($done / $total * 100) }
            $match = $existing[(Get-SynthSeedUniqueKey -Object $object)]
            if ($match) {
                $ids[$object.key] = $match.id
                $result.existing[$kind]++
                # Operations collapses runs of spaces in names, so only a difference beyond that counts.
                if (($match.name -replace '\s+', ' ').Trim() -ne ($object.name -replace '\s+', ' ').Trim()) { $result.renamed.Add("$kind '$($match.name)' is planned as '$($object.name)'; delete it to reseed under the new name") }
                if ($Refresh -and $PSCmdlet.ShouldProcess("$kind $($object.name)", 'Refresh properties and stats')) {
                    try {
                        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        if (@($object.properties).Count) { $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$($match.id)/properties" -Body @{ 'property-content' = @(ConvertTo-SynthSampleList -Entry $object.properties -Timestamp $now) } }
                        if (@($object.stats).Count) { $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$($match.id)/stats" -Body @{ 'stat-content' = @(ConvertTo-SynthSampleList -Entry $object.stats -Timestamp $now) } }
                        $result.refreshed++
                    }
                    catch { $result.failed.Add("refresh $kind $($object.name): $($_.Exception.Message)") }
                }
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("$kind $($object.name)", 'Create')) { continue }
            try {
                $path = if ($native) { "resources/adapters/$AdapterInstanceId" } else { "resources/adapterkinds/$adapterKind" }
                $created = Invoke-SynthOpsRequest -Method Post -Path $path -Body (ConvertTo-SynthResourceBody -Object $object)
                $id = $created.identifier
                $ids[$object.key] = $id
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if (@($object.stats).Count) {
                    $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$id/stats" -Body @{ 'stat-content' = @(ConvertTo-SynthSampleList -Entry $object.stats -Timestamp $now) }
                }
                $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$id/properties" -Body @{ 'property-content' = @(ConvertTo-SynthSampleList -Entry $object.properties -Timestamp $now) }
                $result.created[$kind]++
            }
            catch {
                $result.failed.Add("$kind $($object.name): $($_.Exception.Message)")
            }
        }
    }
    Write-Progress -Activity 'Seeding VCF Operations' -Completed

    foreach ($entry in @($Plan.links)) {
        if (-not $ids.ContainsKey($entry.parent)) { continue }
        $childIds = @($entry.children | Where-Object { $ids.ContainsKey($_) } | ForEach-Object { $ids[$_] })
        if (-not $childIds.Count) { continue }
        if (-not $PSCmdlet.ShouldProcess($ids[$entry.parent], "Link $($childIds.Count) children")) { continue }
        try {
            $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$($ids[$entry.parent])/relationships/children" -Body @{ uuids = $childIds }
            $result.links += $childIds.Count
        }
        catch {
            $result.failed.Add("links of $($entry.parent): $($_.Exception.Message)")
        }
    }
    $result.ids = $ids
    $result
}

function Resolve-SynthSeedTarget {
    <#
    .SYNOPSIS
        Finds the vCenter adapter instance by name and the VMEntityVCID its objects carry.

    .PARAMETER Name
        The adapter instance name, for example vc-mgmt-a.

    .EXAMPLE
        $target = Resolve-SynthSeedTarget -Name 'vc-mgmt-a'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)

    $instances = @((Invoke-SynthOpsRequest -Method Get -Path 'adapters' -Query @{ adapterKindKey = 'VMWARE' }).adapterInstancesInfoDto)
    $instance = @($instances | Where-Object { $_.resourceKey.name -eq $Name -or $_.resourceKey.name -like "$Name.*" })
    if ($instance.Count -ne 1) {
        throw "Found $($instance.Count) VMWARE adapter instances named '$Name'; there are: $(($instances | ForEach-Object { $_.resourceKey.name }) -join ', ')."
    }
    $adapterId = $instance[0].id
    # Read the vCenter UUID from a real datacenter under the instance, as the vCenter adapter writes it.
    $datacenters = @((Invoke-SynthOpsRequest -Method Get -Path 'resources' -Query @{ adapterKind = 'VMWARE'; resourceKind = 'Datacenter'; adapterInstanceId = $adapterId; pageSize = 50 }).resourceList)
    $vcId = $null
    foreach ($dc in $datacenters) {
        $id = @($dc.resourceKey.resourceIdentifiers | Where-Object { $_.identifierType.name -eq 'VMEntityVCID' })
        if ($id.Count -and $id[0].value) { $vcId = $id[0].value; break }
    }
    if (-not $vcId) { throw "Adapter instance '$Name' has no datacenter to read its vCenter UUID from." }
    @{ AdapterInstanceId = $adapterId; VcId = $vcId }
}

function Get-SynthSeedKind {
    <#
    .SYNOPSIS
        The resource kinds the seed creates, foundations first.

    .DESCRIPTION
        With -WithRubric, only the VMWARE kinds filled from a rubric. With
        -Custom, only the kinds that go under the toolset's own adapter kind
        (standard switches and port groups, which VMWARE does not model).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$WithRubric, [switch]$Custom)
    $customKinds = 'StandardSwitch', 'StandardPortgroup'
    if ($Custom) { return $customKinds }
    $all = 'PhysicalDatacenter', 'Datacenter', 'ClusterComputeResource', 'Datastore', 'HostSystem', 'VmwareDistributedVirtualSwitch', 'StandardSwitch', 'DistributedVirtualPortgroup', 'StandardPortgroup', 'VMFolder', 'VirtualMachine'
    if ($WithRubric) { return @($all | Where-Object { $_ -notin $customKinds -and $_ -ne 'PhysicalDatacenter' }) }
    $all
}
