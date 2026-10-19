function Get-SynthSla {
    <#
    .SYNOPSIS
        The SLA matrix the tier policies are built from: the plan's section 6 values, or a file in the same shape.

    .DESCRIPTION
        The matrix is the portable part of the policy design: it says what each
        tier is promised, not which VMs are in it (that is the customer's tier
        rules). Each tier has a VM time remaining warning and critical in days, a
        cluster capacity buffer in percent (0 to 99, as the settings API takes it),
        and the names of Synth- alerts (without the prefix) to switch off for that
        tier. Synth-Base switches every Synth- alert on; a tier inherits the rest.
        config/sla.example.json holds the same values to copy for a customer.

    .PARAMETER Path
        A JSON file in the same shape. Empty means the built-in matrix.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "SLA matrix '$Path' does not exist." }
        $sla = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        # Critical time remaining is a third of the warning, the ratio of the Default Policy's VM values (30 and 10 days).
        $sla = [ordered]@{ tiers = [ordered]@{
                Gold   = [ordered]@{ timeRemainingDays = [ordered]@{ warning = 120; critical = 40 }; capacityBufferPercent = 20; disableAlerts = @() }
                Silver = [ordered]@{ timeRemainingDays = [ordered]@{ warning = 90; critical = 30 }; capacityBufferPercent = 10; disableAlerts = @() }
                Bronze = [ordered]@{ timeRemainingDays = [ordered]@{ warning = 30; critical = 10 }; capacityBufferPercent = 0; disableAlerts = @('VM memory pressure') }
            } }
    }
    foreach ($tier in 'Gold', 'Silver', 'Bronze') {
        if (-not ($sla.Contains('tiers') -and $sla.tiers.Contains($tier))) { throw "The SLA matrix has no $tier tier." }
        $t = $sla.tiers[$tier]
        $days = if ($t.Contains('timeRemainingDays')) { $t.timeRemainingDays }
        if ($days -and -not ($days.warning -gt $days.critical -and $days.critical -ge 0)) { throw "$tier time remaining: the warning must be more days than the critical, and the critical 0 or more." }
        $buffer = if ($t.Contains('capacityBufferPercent')) { $t.capacityBufferPercent }
        if ($null -ne $buffer -and ($buffer -lt 0 -or $buffer -gt 99)) { throw "$tier capacity buffer must be 0 to 99 percent." }
    }
    $sla
}

function Get-SynthPolicyDefinition {
    <#
    .SYNOPSIS
        The policies the toolset publishes: Synth-Base and one per tier inheriting it.

    .DESCRIPTION
        Synth-Base switches on every alert definition with the content prefix, on
        whichever kind it is defined for, so host and datastore alerts work for the
        whole synthetic estate. The Synth- alerts already carry the tier thresholds
        (through the vcfops-synth|tier property), so a tier policy only switches off
        what its tier is not promised, and sets its capacity values. Each definition
        has Key (Base or the tier), Name, Parent (a Key), Alerts and Settings.

    .PARAMETER Sla
        From Get-SynthSla.

    .PARAMETER AlertDefinition
        Alert definitions as GET alertdefinitions lists them (id, name, adapterKindKey, resourceKindKey).

    .PARAMETER Prefix
        The content prefix (lab.json prefix).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Sla,
        [AllowEmptyCollection()][object[]]$AlertDefinition = @(),
        [string]$Prefix = 'Synth-'
    )

    $mine = @($AlertDefinition | Where-Object { $_ -and ([string]$_.name).StartsWith($Prefix) })
    $alert = { param($d, $on) [ordered]@{ Id = [string]$d.id; AdapterKind = [string]$d.adapterKindKey; ResourceKind = [string]$d.resourceKindKey; Enabled = $on } }
    [ordered]@{
        Key = 'Base'; Name = "${Prefix}Base"; Parent = $null
        Description = 'vcfops-synth: switches on the Synth- alerts for the synthetic estate. Made by the content command; reset removes it.'
        Alerts = @($mine | ForEach-Object { & $alert $_ $true }); Settings = [ordered]@{}
    }
    $n = 0
    foreach ($tier in 'Gold', 'Silver', 'Bronze') {
        $n++
        $t = $Sla.tiers[$tier]
        $off = @(if ($t.Contains('disableAlerts')) { $t.disableAlerts })
        $alerts = foreach ($name in $off) {
            $d = @($mine | Where-Object name -eq "$Prefix$name")
            if (-not $d) { throw "The SLA matrix switches off '$name' for $tier, but there is no alert definition named '$Prefix$name'. Publish the alerts first, or fix the name." }
            $d | ForEach-Object { & $alert $_ $false }
        }
        $settings = [ordered]@{}
        if ($t.Contains('timeRemainingDays') -and $t.timeRemainingDays) { $settings.TimeRemainingDays = $t.timeRemainingDays }
        if ($t.Contains('capacityBufferPercent') -and $null -ne $t.capacityBufferPercent) { $settings.CapacityBufferPercent = $t.capacityBufferPercent }
        [ordered]@{
            Key = $tier; Name = "${Prefix}Tier-$n-$tier"; Parent = 'Base'
            Description = "vcfops-synth: what the $tier tier is promised (time remaining, capacity buffer, alert set). Made by the content command; reset removes it."
            Alerts = @($alerts); Settings = $settings
        }
    }
}

function ConvertTo-SynthPolicyXml {
    <#
    .SYNOPSIS
        The exportedPolicies.xml that POST policies/import takes, for the whole family in one file.

    .DESCRIPTION
        Operations refuses a policy whose parent is not in the same file, so the
        base and its tiers always go together. A policy's key becomes its id, so an
        existing policy keeps its id when its key is given.

    .PARAMETER Definition
        From Get-SynthPolicyDefinition.

    .PARAMETER IdByKey
        Definition key to policy id (existing ones, or new GUIDs).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary[]]$Definition,
        [Parameter(Mandatory)][hashtable]$IdByKey
    )

    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $sb = [System.Text.StringBuilder]::new('<?xml version="1.0" encoding="UTF-8"?><PolicyContent><Policies>')
    foreach ($d in $Definition) {
        $parent = if ($d.Parent) { " parentPolicy=`"$($IdByKey[$d.Parent])`"" } else { '' }
        $null = $sb.Append("<Policy key=`"$($IdByKey[$d.Key])`" name=`"$(& $esc $d.Name)`" description=`"$(& $esc $d.Description)`"$parent><PackageSettings>")
        foreach ($kind in ($d.Alerts | Group-Object { "$($_.AdapterKind)|$($_.ResourceKind)" })) {
            $first = $kind.Group[0]
            $null = $sb.Append("<Alerts adapterKind=`"$(& $esc $first.AdapterKind)`" resourceKind=`"$(& $esc $first.ResourceKind)`">")
            foreach ($a in $kind.Group) { $null = $sb.Append("<Alert enabled=`"$(([string]$a.Enabled).ToLowerInvariant())`" id=`"$(& $esc $a.Id)`"/>") }
            $null = $sb.Append('</Alerts>')
        }
        $null = $sb.Append('</PackageSettings></Policy>')
    }
    $null = $sb.Append('</Policies><alertContent/></PolicyContent>')
    $sb.ToString()
}

function ConvertTo-SynthPolicySettingsBody {
    <#
    .SYNOPSIS
        The PATCH policies/{id}/settings body for one definition, or $null when it sets nothing.

    .DESCRIPTION
        Time remaining is set on VMs, the kind the tier groups hold. The capacity
        buffer is a cluster setting (the API refuses it on VMs), so it only takes
        effect on clusters the policy is assigned to.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $s = $Definition.Settings
    $capacity = [ordered]@{}
    if ($s.Contains('TimeRemainingDays')) {
        $capacity.criticalityThresholds = [ordered]@{ timeRemainingSettings = @([ordered]@{
                    criticalityThresholdsConfig = [ordered]@{ warning = [double]$s.TimeRemainingDays.warning; critical = [double]$s.TimeRemainingDays.critical }
                    resourceKindKey             = [ordered]@{ adapterKind = 'VMWARE'; resourceKind = 'VirtualMachine' }
                }) }
    }
    if ($s.Contains('CapacityBufferPercent')) {
        $pct = [double]$s.CapacityBufferPercent
        $capacity.capacity = [ordered]@{ capacityBufferSettings = @([ordered]@{
                    capacityBuffer  = [ordered]@{ cpu = [ordered]@{ demand = $pct; allocation = $pct }; memory = [ordered]@{ demand = $pct; allocation = $pct }; diskspace = [ordered]@{ demand = $pct; allocation = $pct } }
                    resourceKindKey = [ordered]@{ adapterKind = 'VMWARE'; resourceKind = 'ClusterComputeResource' }
                }) }
    }
    if ($capacity.Count) { [ordered]@{ capacitySettings = $capacity } }
}

function Publish-SynthPolicy {
    <#
    .SYNOPSIS
        Creates or updates the toolset's policies, sets their capacity values, assigns them to their groups and ranks them.

    .DESCRIPTION
        Policies are matched by name only within the content prefix. The family is
        imported in one file with forceImport, which keeps each existing policy's id
        but resets it to the file, so the capacity values are set again after every
        import. Each policy is then assigned to the groups that name it, and the
        tier policies are ranked above Synth-Base (a VM is in both its tier group
        and the estate group) and above any other active policy.

    .PARAMETER Definition
        From Get-SynthPolicyDefinition.

    .PARAMETER GroupIdByKey
        Definition key to the ids of the groups that get that policy.

    .PARAMETER Prefix
        The content prefix; only policies whose names start with it are matched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary[]]$Definition,
        [hashtable]$GroupIdByKey = @{},
        [string]$Prefix = 'Synth-'
    )

    $existing = @{}
    foreach ($p in @((Invoke-SynthOpsRequest -Method Get -Path 'policies').policySummaries)) {
        if ($p -and ([string]$p.name).StartsWith($Prefix)) { $existing[[string]$p.name] = $p }
    }
    $idByKey = @{}
    foreach ($d in $Definition) { $idByKey[$d.Key] = if ($existing[$d.Name]) { [string]$existing[$d.Name].id } else { [guid]::NewGuid().ToString() } }

    if (-not $PSCmdlet.ShouldProcess("$($Definition.Count) policies ($(($Definition | ForEach-Object { $_.Name }) -join ', '))", 'Import, set capacity values, assign and rank')) {
        foreach ($d in $Definition) {
            $groups = @($GroupIdByKey[$d.Key] | Where-Object { $_ })
            [pscustomobject]@{ Name = $d.Name; Action = "would $(if ($existing[$d.Name]) { 'update' } else { 'create' })"; Id = $(if ($existing[$d.Name]) { $idByKey[$d.Key] }); Groups = $groups.Count }
        }
        return
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) "vcfops-synth-policies-$([guid]::NewGuid())"
    $null = New-Item -ItemType Directory -Path $work
    try {
        $xmlPath = Join-Path $work 'exportedPolicies.xml'
        [IO.File]::WriteAllText($xmlPath, (ConvertTo-SynthPolicyXml -Definition $Definition -IdByKey $idByKey), [Text.UTF8Encoding]::new($false))
        $zip = Join-Path $work 'policies.zip'
        Compress-Archive -LiteralPath $xmlPath -DestinationPath $zip
        $null = Invoke-SynthOpsRequest -Method Post -Path 'policies/import' -Query @{ forceImport = 'true' } -Form @{ policy = (Get-Item -LiteralPath $zip) } -MaxRetries 0
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

    foreach ($d in $Definition) {
        $body = ConvertTo-SynthPolicySettingsBody -Definition $d
        if ($body) { $null = Invoke-SynthOpsRequest -Method Patch -Path "policies/$($idByKey[$d.Key])/settings" -Body $body }
        $groups = @($GroupIdByKey[$d.Key] | Where-Object { $_ })
        if ($groups.Count) { $null = Invoke-SynthOpsRequest -Method Put -Path "policies/$($idByKey[$d.Key])/assign" -Body @{ groupIds = $groups } }
    }

    # Every active policy but the default must be listed; ours go first, tiers before the base, the rest keep their order.
    $ours = @($Definition | Where-Object { $_.Key -ne 'Base' }) + @($Definition | Where-Object { $_.Key -eq 'Base' }) | ForEach-Object { $idByKey[$_.Key] }
    $active = @((Invoke-SynthOpsRequest -Method Get -Path 'policies' -Query @{ activesOnly = 'true' }).policySummaries | Where-Object { $_ -and -not $_.defaultPolicy } | ForEach-Object { [string]$_.id })
    $order = @($ours | Where-Object { $_ -in $active }) + @($active | Where-Object { $_ -notin $ours })
    if ($order.Count) { $null = Invoke-SynthOpsRequest -Method Put -Path 'policies/priorities' -Body @{ policyIds = $order } }

    foreach ($d in $Definition) {
        [pscustomobject]@{ Name = $d.Name; Action = $(if ($existing[$d.Name]) { 'updated' } else { 'created' }); Id = $idByKey[$d.Key]; Groups = @($GroupIdByKey[$d.Key] | Where-Object { $_ }).Count }
    }
}
