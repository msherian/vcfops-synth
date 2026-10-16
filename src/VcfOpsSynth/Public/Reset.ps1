function Get-SynthResourceProperty {
    <#
    .SYNOPSIS
        The latest value of one property for many resources, keyed by resource ID.

    .DESCRIPTION
        Asks for 100 resources per call (GET resources/properties with one
        resourceId per resource). A resource without the property is left out.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Id,
        [Parameter(Mandatory)][string]$Key
    )
    $values = @{}
    for ($i = 0; $i -lt $Id.Count; $i += 100) {
        $batch = $Id[$i..([Math]::Min($i + 99, $Id.Count - 1))]
        $query = ($batch | ForEach-Object { 'resourceId=' + [uri]::EscapeDataString($_) }) -join '&'
        $r = Invoke-SynthOpsRequest -Method Get -Path "resources/properties?$query"
        foreach ($entry in @(Get-SynthResponseField $r 'resourcePropertiesList' | Where-Object { $null -ne $_ })) {
            foreach ($p in @(Get-SynthResponseField $entry 'property' | Where-Object { $null -ne $_ })) {
                if ((Get-SynthResponseField $p 'name') -eq $Key) { $values[[string](Get-SynthResponseField $entry 'resourceId')] = [string](Get-SynthResponseField $p 'value') }
            }
        }
    }
    $values
}

function Get-SynthSeededObject {
    <#
    .SYNOPSIS
        The planned objects that exist in Operations, each with whether it carries the synthetic tag.

    .DESCRIPTION
        Objects are found as seed finds them, by kind and unique identifier
        (never by name), then their summary|tag property is read. Only an
        object whose tag holds the synthetic marker is one the toolset made;
        anything else with a matching identifier is reported as untagged and
        left alone. Children come before parents (VMs first, the Physical
        Datacenter last), the order they can be removed in.

    .PARAMETER Plan
        A plan from New-SynthSeedPlan.

    .PARAMETER AdapterInstanceId
        The vCenter adapter instance the VMWARE objects sit under.

    .PARAMETER Tag
        The synthetic marker as summary|tag shows it, Category-Name (lab.json seed.tag).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$AdapterInstanceId,
        [string]$Tag = 'vcfops-synth-synthetic'
    )
    $kinds = @(Get-SynthSeedKind)
    [array]::Reverse($kinds)
    $found = foreach ($kind in $kinds) {
        $ofKind = @($Plan.objects | Where-Object { $_.kind -eq $kind })
        if (-not $ofKind.Count) { continue }
        $adapterKind = if ($ofKind[0].Contains('adapterKind') -and $ofKind[0].adapterKind) { $ofKind[0].adapterKind } else { 'VMWARE' }
        $lookup = @{ Kind = $kind; AdapterKind = $adapterKind }
        if ($adapterKind -eq 'VMWARE') { $lookup.AdapterInstanceId = $AdapterInstanceId }
        $unique = @($ofKind[0].identifiers | Where-Object { $_.unique })
        if ($unique.Count) { $lookup.IdentifierName = $unique[0].name }
        $existing = Get-SynthExistingResource @lookup
        foreach ($object in $ofKind) {
            $match = $existing[(Get-SynthSeedUniqueKey -Object $object)]
            if ($match) { [pscustomobject]@{ Kind = $kind; Key = $object.key; Id = [string]$match.id; Name = $match.name; Tagged = $false } }
        }
    }
    $found = @($found)
    if (-not $found.Count) { return }
    $tags = Get-SynthResourceProperty -Id @($found | ForEach-Object Id) -Key 'summary|tag'
    $marker = [regex]::new('(^|[\[,]\s*)' + [regex]::Escape($Tag) + '\s*($|[\],])')
    foreach ($o in $found) {
        $o.Tagged = $tags.ContainsKey($o.Id) -and $marker.IsMatch($tags[$o.Id])
        $o
    }
}

function Remove-SynthSeededObject {
    <#
    .SYNOPSIS
        Deletes the objects seed created, children first; an object without the synthetic tag is never deleted.

    .PARAMETER Object
        From Get-SynthSeededObject, in its order.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Object)

    foreach ($o in $Object) {
        $result = [pscustomobject]@{ Kind = $o.Kind; Key = $o.Key; Id = $o.Id; Action = ''; Error = $null }
        if (-not $o.Tagged) { $result.Action = 'untagged'; $result; continue }
        if (-not $PSCmdlet.ShouldProcess("$($o.Kind) $($o.Id)", 'Delete')) { $result.Action = 'would delete'; $result; continue }
        try {
            $null = Invoke-SynthOpsRequest -Method Delete -Path "resources/$($o.Id)"
            $result.Action = 'deleted'
        }
        catch { $result.Action = 'failed'; $result.Error = $_.Exception.Message }
        $result
    }
}

function Remove-SynthContent {
    <#
    .SYNOPSIS
        Deletes the toolset's alerts, symptoms, recommendations, super metrics and custom groups, by the content prefix.

    .DESCRIPTION
        Alerts go first, since they refer to symptoms and recommendations.
        Only items whose names (a recommendation's text) start with the prefix
        are touched. Views and dashboards cannot be listed or deleted through
        the API, so they stay; the next content run overwrites them by name.

    .PARAMETER Prefix
        The content prefix (lab.json prefix). It must not be empty.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prefix)

    $lists = @(
        @{ Kind = 'alert'; Path = 'alertdefinitions'; Property = 'alertDefinitions'; Name = { $_.name } }
        @{ Kind = 'symptom'; Path = 'symptomdefinitions'; Property = 'symptomDefinitions'; Name = { $_.name } }
        @{ Kind = 'recommendation'; Path = 'recommendations'; Property = 'recommendations'; Name = { $_.description } }
        @{ Kind = 'super metric'; Path = 'supermetrics'; Property = 'superMetrics'; Name = { $_.name } }
        @{ Kind = 'custom group'; Path = 'resources/groups'; Property = 'groups'; Name = { $_.resourceKey.name } }
    )
    foreach ($list in $lists) {
        foreach ($item in @(Get-SynthPagedList -Path $list.Path -Property $list.Property)) {
            $name = [string](ForEach-Object -InputObject $item -Process $list.Name)
            if (-not $name.StartsWith($Prefix, [StringComparison]::Ordinal)) { continue }
            $id = [string]$item.id
            $result = [pscustomobject]@{ Kind = $list.Kind; Name = $name; Id = $id; Action = ''; Error = $null }
            if (-not $PSCmdlet.ShouldProcess($name, "Delete $($list.Kind)")) { $result.Action = 'would delete'; $result; continue }
            try {
                $null = Invoke-SynthOpsRequest -Method Delete -Path "$($list.Path)/$id"
                $result.Action = 'deleted'
            }
            catch { $result.Action = 'failed'; $result.Error = $_.Exception.Message }
            $result
        }
    }
}

function Clear-SynthState {
    <#
    .SYNOPSIS
        Forgets the backfill progress, the feed's last push and the running scenarios, after a reset.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $all = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $all) { return }
    foreach ($section in 'backfill', 'feed', 'scenarios') { $all.Remove($section) }
    if ($PSCmdlet.ShouldProcess($Path, 'Clear backfill, feed and scenario state')) {
        $temp = "$Path.tmp"
        $all | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}
