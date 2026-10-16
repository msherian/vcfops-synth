function Get-SynthGroupDefinition {
    <#
    .SYNOPSIS
        The custom groups the toolset publishes: one per tier, one per application, and the scenario targets.

    .DESCRIPTION
        Membership is dynamic, on the vcfops-synth|tier and vcfops-synth|application
        properties seed writes on each VM, so a re-import with new tier rules followed
        by seed -Refresh moves VMs between groups without touching the groups. Names
        carry the content prefix so reset can find them; tiers are numbered so they
        sort Gold, Silver, Bronze.

    .PARAMETER Inventory
        The inventory model; its applications become groups.

    .PARAMETER Prefix
        The content prefix (lab.json prefix).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inventory,
        [string]$Prefix = 'Synth-'
    )

    $rule = { param($Key, $Value) [ordered]@{ Kind = 'VirtualMachine'; AdapterKind = 'VMWARE'; Key = $Key; Value = $Value } }
    $n = 0
    foreach ($tier in 'Gold', 'Silver', 'Bronze') {
        $n++
        [ordered]@{ Name = "${Prefix}Tier-$n-$tier"; Type = 'Service Level Objective'; Tier = $tier; Rule = (& $rule 'vcfops-synth|tier' $tier) }
    }
    $apps = @($Inventory.vms | ForEach-Object { if ($_.Contains('application') -and $_.application) { [string]$_.application } } | Sort-Object -Unique)
    foreach ($app in $apps) {
        [ordered]@{ Name = "${Prefix}App-$app"; Type = 'Function'; Tier = $null; Rule = (& $rule 'vcfops-synth|application' $app) }
    }
    # Scenario overlays (Phase 6) mark their targets with vcfops-synth|scenario.
    [ordered]@{ Name = "${Prefix}Noisy-Neighbours"; Type = 'Environment'; Tier = $null; Rule = (& $rule 'vcfops-synth|scenario' 'noisy-neighbour') }
}

function ConvertTo-SynthGroupBody {
    <#
    .SYNOPSIS
        The Suite API body for one custom group definition, with its policy when it has one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Definition,
        [string]$PolicyId,
        [string]$Id
    )

    $body = [ordered]@{
        resourceKey           = [ordered]@{ name = $Definition.Name; adapterKindKey = 'Container'; resourceKindKey = $Definition.Type }
        autoResolveMembership = $true
        membershipDefinition  = [ordered]@{
            includedResources         = @()
            excludedResources         = @()
            'custom-group-properties' = @()
            rules                     = @([ordered]@{
                    resourceKindKey        = [ordered]@{ resourceKind = $Definition.Rule.Kind; adapterKind = $Definition.Rule.AdapterKind }
                    propertyConditionRules = @([ordered]@{ key = $Definition.Rule.Key; stringValue = $Definition.Rule.Value; compareOperator = 'EQ' })
                })
        }
    }
    if ($PolicyId) { $body.policy = $PolicyId }
    if ($Id) { $body.id = $Id }
    $body
}

function Publish-SynthGroup {
    <#
    .SYNOPSIS
        Creates or updates each custom group by name, and assigns its tier policy when one is given.

    .DESCRIPTION
        Groups are matched by name only within the content prefix, so groups made by
        hand are never touched. An existing group is updated in place (same id), so
        its history and dashboard references survive.

    .PARAMETER Definition
        Definitions from Get-SynthGroupDefinition.

    .PARAMETER PolicyByTier
        Tier name to policy id, for the tier groups.

    .PARAMETER Prefix
        The content prefix; only groups whose names start with it are matched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary[]]$Definition,
        [hashtable]$PolicyByTier = @{},
        [string]$Prefix = 'Synth-'
    )

    $existing = @{}
    $page = 0
    do {
        $r = Invoke-SynthOpsRequest -Method Get -Path 'resources/groups' -Query @{ page = $page; pageSize = 1000 }
        # The list may come without groups or pageInfo (the module runs under strict mode).
        $field = { param($o, $name) if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($name)) { $o[$name] } } elseif ($o -and $o.PSObject.Properties[$name]) { $o.$name } }
        $groups = @(& $field $r 'groups')
        foreach ($g in $groups) { if ($g -and $g.resourceKey.name -like "$Prefix*") { $existing[$g.resourceKey.name] = $g } }
        $info = & $field $r 'pageInfo'
        $total = if ($info) { [int](& $field $info 'totalCount') } else { 0 }
        $page++
    } while ($groups.Count -and $page * 1000 -lt $total)

    foreach ($d in $Definition) {
        $policy = if ($d.Tier -and $PolicyByTier.ContainsKey($d.Tier)) { $PolicyByTier[$d.Tier] } else { $null }
        $found = $existing[$d.Name]
        $action = if ($found) { 'Update' } else { 'Create' }
        if (-not $PSCmdlet.ShouldProcess($d.Name, "$action custom group")) { [pscustomobject]@{ Name = $d.Name; Action = "would $($action.ToLowerInvariant())"; Id = $(if ($found) { $found.id }) }; continue }
        $body = ConvertTo-SynthGroupBody -Definition $d -PolicyId $policy -Id $(if ($found) { $found.id })
        $result = if ($found) { Invoke-SynthOpsRequest -Method Put -Path 'resources/groups' -Body $body } else { Invoke-SynthOpsRequest -Method Post -Path 'resources/groups' -Body $body }
        [pscustomobject]@{ Name = $d.Name; Action = $action.ToLowerInvariant() + 'd'; Id = $(if ($result.id) { $result.id } elseif ($found) { $found.id }) }
    }
}
