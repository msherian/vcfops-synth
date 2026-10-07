function Get-SynthRvCell {
    <# Returns a field's value from a row, or $null when the tab has no column for it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Row,
        [Parameter(Mandatory, Position = 1)][hashtable]$Columns,
        [Parameter(Mandatory, Position = 2)][string]$Field
    )

    if (-not $Columns.ContainsKey($Field)) { return $null }
    $value = $Row[$Columns[$Field]]
    if ($value -is [string]) { $value = $value.Trim() }
    $value
}

function Get-SynthRvVmKey {
    <#
    .SYNOPSIS
        Returns the key that joins a VM's rows across RVTools tabs.

    .DESCRIPTION
        The vCenter managed object ID (vm-123) is unique within a vCenter, so it is
        used with the vCenter name when present. Older exports without it fall
        back to the VM UUID, then to the VM name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Row,
        [Parameter(Mandatory)][hashtable]$Columns
    )

    $server = [string](Get-SynthRvCell $Row $Columns 'server')
    $vmId = Get-SynthRvCell $Row $Columns 'vmId'
    if ($vmId) { return "$server|id:$vmId" }
    $uuid = Get-SynthRvCell $Row $Columns 'vmUuid'
    if ($uuid) { return "uuid:$uuid" }
    "$server|name:$(Get-SynthRvCell $Row $Columns 'vm')"
}

function ConvertTo-SynthPercent {
    <# Clamps a percentage to 0 to 100 and rounds it to one decimal place; $null stays $null. #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    # Double literals throughout: with an int first argument, PowerShell picks the int overloads and truncates.
    [math]::Round([math]::Min([double]100, [math]::Max([double]0, [double]$Value)), 1)
}

function ConvertTo-SynthLimit {
    <# RVTools writes -1 for "unlimited"; the model uses $null. #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -lt 0) { return $null }
    $Value
}

function Resolve-SynthVmClass {
    <#
    .SYNOPSIS
        Gives one VM its tier, application and workload profile.

    .DESCRIPTION
        For each of the three, the first rule that sets it and matches wins. A VM
        that is not powered on is profiled "off", because it has no usage to draw.
        Otherwise a VM no rule profiles is idle, saturated or business-hours by its
        RVTools usage against the thresholds in the tiering rules.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Fact,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rule,
        [Parameter(Mandatory)][hashtable]$TieringRules,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline,
        [Parameter(Mandatory)][bool]$PoweredOn
    )

    $result = @{ tier = $null; application = $null; profile = $null }
    foreach ($compiled in $Rule) {
        $matched = $true
        foreach ($test in $compiled.Tests) {
            $value = if ($Fact.ContainsKey($test.Field)) { [string]$Fact[$test.Field] } else { '' }
            if (-not $test.Regex.IsMatch($value)) { $matched = $false; break }
        }
        if (-not $matched) { continue }
        foreach ($name in 'tier', 'application', 'profile') {
            if ($null -eq $result[$name] -and $compiled.Rule.ContainsKey($name)) { $result[$name] = $compiled.Rule[$name] }
        }
    }

    if (-not $result.tier) { $result.tier = $TieringRules.defaultTier }
    if (-not $PoweredOn) {
        $result.profile = 'off'
    }
    elseif (-not $result.profile) {
        $limits = $TieringRules.profiles
        $cpu = $Baseline.cpuUsagePct
        $mem = $Baseline.memActivePct
        $result.profile = if (($null -ne $cpu -and $cpu -ge $limits.saturatedCpuPct) -or ($null -ne $mem -and $mem -ge $limits.saturatedMemPct)) {
            'saturated'
        }
        elseif ($null -ne $cpu -and $cpu -lt $limits.idleCpuPct -and ($null -eq $mem -or $mem -lt $limits.idleMemPct)) {
            'idle'
        }
        else {
            'business-hours'
        }
    }
    $result
}
