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
    $missing = @(Get-SynthSeedKind | Where-Object { -not $rubrics.ContainsKey($_) })
    if ($missing.Count) { throw "Rubrics folder '$Path' has no rubric for $($missing -join ', ')." }
    $rubrics
}

function New-SynthSeedPlan {
    <#
    .SYNOPSIS
        Works out every object, metric, property and link the seed creates, without calling Operations.

    .DESCRIPTION
        Turns the inventory model into VMWARE objects under a vCenter adapter
        instance: datacenters, clusters, hosts, datastores, distributed switches
        and port groups, VM folders and VMs. Each is named with the prefix and its
        inventory name, and gets every stat key and property of its kind's
        rubric. Per-instance keys are expanded from the object's own devices:
        virtual disks, guest file systems and network adapters for a VM; physical
        NICs, VMkernel adapters and HBAs for a host; member hosts for a switch.
        Identity, parent and sizing properties come from the inventory, and IP
        and MAC addresses from the reference object are never copied.

        Links join each object to its synthetic parents only. Standard port groups
        and resource pools have no VMWARE kind with a rubric, so they are counted
        in skipped instead.

    .PARAMETER Inventory
        The model from Import-SynthRvtools or Get-SynthInventory.

    .PARAMETER Rubric
        Rubrics from Get-SynthRubric.

    .PARAMETER VcId
        The vCenter instance UUID (VMEntityVCID) of the adapter instance the objects go under.

    .PARAMETER Prefix
        Name prefix that marks synthetic objects. Defaults to Synth-.

    .EXAMPLE
        $plan = New-SynthSeedPlan -Inventory $inventory -Rubric $rubrics -VcId $vcId
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan in memory; Invoke-SynthSeed makes the changes.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [Parameter(Mandatory)][hashtable]$Rubric,
        [Parameter(Mandatory)][string]$VcId,
        [string]$Prefix = 'Synth-'
    )

    $objects = [System.Collections.Generic.List[object]]::new()
    $byId = @{}
    $children = [ordered]@{}
    $link = {
        param($ParentId, $ChildId)
        if (-not $ParentId -or -not $ChildId -or -not $byId.ContainsKey($ParentId) -or -not $byId.ContainsKey($ChildId)) { return }
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
    $vcenter = Get-SynthRubricValue -Rubric $Rubric.Datacenter -Name 'summary|parentVcenter'
    $prepared = @{}
    $renameKeys = 'config|name', 'summary|parentDatacenter', 'summary|parentCluster', 'summary|parentHost', 'summary|parentFolder', 'summary|folder', 'summary|datastore'

    # Objects first, so links and parent names can look each other up.
    $add = {
        param($Kind, $Item)
        $record = [ordered]@{
            key        = $Item.id
            kind       = $Kind
            name       = "$Prefix$($Item.name)"
            moid       = "$(Get-SynthMoidPrefix -Kind $Kind)-synth-$(($Item.id -split '-')[-1])"
            item       = $Item
            identifiers = $null
            stats      = $null
            properties = $null
        }
        $objects.Add($record)
        $byId[$Item.id] = $record
    }
    foreach ($dc in @($Inventory.datacenters)) { & $add 'Datacenter' $dc }
    foreach ($cluster in @($Inventory.clusters)) { & $add 'ClusterComputeResource' $cluster }
    foreach ($h in @($Inventory.hosts)) { & $add 'HostSystem' $h }
    foreach ($ds in @($Inventory.datastores)) { & $add 'Datastore' $ds }
    foreach ($sw in @($Inventory.switches | Where-Object { $_.kind -eq 'distributed' })) { & $add 'VmwareDistributedVirtualSwitch' $sw }
    foreach ($net in @($Inventory.networks | Where-Object { $_.kind -eq 'distributed' })) { & $add 'DistributedVirtualPortgroup' $net }
    foreach ($folder in @($Inventory.folders)) { & $add 'VMFolder' $folder }
    foreach ($vm in @($Inventory.vms)) { & $add 'VirtualMachine' $vm }

    foreach ($record in $objects) {
        $item = $record.item
        $kind = $record.kind
        $families = @()
        $set = [ordered]@{ 'config|name' = $record.name }
        switch ($kind) {
            'Datacenter' { }
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
                    $set['summary|version'] = "$($Matches.ver)-$($Matches.build)"
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
                if ($item.host -and $byId.ContainsKey($item.host) -and $byId[$item.host].item.esxVersion -match '\d+\.\d+\.\d+') { $set['summary|parentHostVersion'] = $Matches[0] }
                $families = Get-SynthVmFamily -Vm $item -Record $record -NameOf $nameOf
            }
        }
        $kindRubric = $Rubric[$kind]
        if (-not $prepared.ContainsKey($kind)) {
            # Everything that depends only on the kind's rubric, worked out once instead of once per object.
            $real = @{}
            if ($kindRubric.Contains('sourceName') -and $kindRubric.sourceName) { $real['@self'] = [string]$kindRubric.sourceName }
            foreach ($key in $renameKeys) {
                $value = [string](Get-SynthRubricValue -Rubric $kindRubric -Name $key)
                if ($value) { $real[$key] = $value }
            }
            $props = @($kindRubric.properties | ForEach-Object { @{ key = $_.name; value = (ConvertTo-SynthScrubbedValue -Key $_.name -Value $_.value) } })
            $prepared[$kind] = @{
                HasVcenter = [bool](Get-SynthRubricValue -Rubric $kindRubric -Name 'summary|parentVcenter')
                Real       = $real
                Stats      = Split-SynthRubricEntry -Entry @($kindRubric.latest | ForEach-Object { @{ key = $_.key; value = $_.value } }) -Family $families
                Properties = Split-SynthRubricEntry -Entry $props -Family $families
            }
        }
        $prep = $prepared[$kind]
        if ($vcenter -and $prep.HasVcenter) { $set['summary|parentVcenter'] = $vcenter }

        # The reference object's own and parent names, wherever else they appear (policy names, descriptions), become the synthetic ones.
        $rename = [ordered]@{}
        foreach ($key in $prep.Real.Keys) {
            $target = if ($key -eq '@self') { $record.name } elseif ($set.Contains($key)) { [string]$set[$key] } else { '' }
            if ($target -and $prep.Real[$key] -ne $target) { $rename[$prep.Real[$key]] = $target }
        }
        $renameOrder = @($rename.Keys | Sort-Object { $_.Length } -Descending)

        $record.identifiers = @(Get-SynthSeedIdentifier -Kind $kind -Record $record -VcId $VcId)
        $record.stats = @(Join-SynthRubricEntry -Split $prep.Stats -Family $families)
        $record.properties = @(foreach ($p in (Join-SynthRubricEntry -Split $prep.Properties -Family $families)) {
                if ($set.Contains($p.key)) { @{ key = $p.key; value = $set[$p.key] }; continue }
                $value = $p.value
                if ($value -is [string] -and $renameOrder.Count) {
                    foreach ($old in $renameOrder) { if ($value.Contains($old)) { $value = $value.Replace($old, $rename[$old]) } }
                }
                @{ key = $p.key; value = $value }
            })
    }

    # Links, parent to children, only between objects in this plan.
    foreach ($record in $objects) {
        $item = $record.item
        switch ($record.kind) {
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
                [ordered]@{ key = $_.key; kind = $_.kind; name = $_.name; moid = $_.moid; identifiers = $_.identifiers; stats = $_.stats; properties = $_.properties }
            })
        links   = @(foreach ($parentId in $children.Keys) { [ordered]@{ parent = $parentId; children = @($children[$parentId]) } })
        skipped = [ordered]@{
            standardNetworks = @($Inventory.networks | Where-Object { $_.kind -ne 'distributed' }).Count
            standardSwitches = @($Inventory.switches | Where-Object { $_.kind -ne 'distributed' }).Count
            resourcePools    = @($Inventory.resourcePools).Count
        }
    }
}

function Invoke-SynthSeed {
    <#
    .SYNOPSIS
        Creates the objects of a seed plan in VCF Operations and links them.

    .DESCRIPTION
        For each object in the plan, in parent-first order: if an object of that
        kind and name already exists, it is skipped and only used for links;
        otherwise it is created under the adapter instance, then its stats and
        properties are pushed. Numbers go as data and text as values. Last, each
        parent is linked to its children, all of them objects from the plan.

        Run Connect-SynthOps first.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER AdapterInstanceId
        The vCenter adapter instance to create the objects under.

    .EXAMPLE
        Invoke-SynthSeed -Plan $plan -AdapterInstanceId $adapterId
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$AdapterInstanceId
    )

    $result = [ordered]@{ created = [ordered]@{}; existing = [ordered]@{}; failed = [System.Collections.Generic.List[string]]::new(); links = 0 }
    $ids = @{}
    $objects = @($Plan.objects)
    $total = $objects.Count
    $done = 0

    foreach ($kind in Get-SynthSeedKind) {
        $ofKind = @($objects | Where-Object { $_.kind -eq $kind })
        $result.created[$kind] = 0
        $result.existing[$kind] = 0
        if (-not $ofKind.Count) { continue }
        $prefix = if ($Plan.Contains('prefix') -and $Plan.prefix) { $Plan.prefix } else { 'Synth-' }
        $existing = Get-SynthExistingResource -Kind $kind -AdapterInstanceId $AdapterInstanceId -Name @($ofKind | ForEach-Object { $_.name }) -Prefix $prefix
        foreach ($object in $ofKind) {
            $done++
            if ($done % 50 -eq 0) { Write-Progress -Activity 'Seeding VCF Operations' -Status "$done of $total" -PercentComplete ($done / $total * 100) }
            if ($existing.ContainsKey($object.name)) {
                $ids[$object.key] = $existing[$object.name]
                $result.existing[$kind]++
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("$kind $($object.name)", 'Create')) { continue }
            try {
                $created = Invoke-SynthOpsRequest -Method Post -Path "resources/adapters/$AdapterInstanceId" -Body (ConvertTo-SynthResourceBody -Object $object)
                $id = $created.identifier
                $ids[$object.key] = $id
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $null = Invoke-SynthOpsRequest -Method Post -Path "resources/$id/stats" -Body @{ 'stat-content' = @(ConvertTo-SynthSampleList -Entry $object.stats -Timestamp $now) }
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
    <# The VMWARE resource kinds the seed creates, parents first. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Datacenter', 'ClusterComputeResource', 'HostSystem', 'Datastore', 'VmwareDistributedVirtualSwitch', 'DistributedVirtualPortgroup', 'VMFolder', 'VirtualMachine'
}
