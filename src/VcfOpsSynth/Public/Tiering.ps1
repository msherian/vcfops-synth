function Get-SynthTieringRule {
    <#
    .SYNOPSIS
        Loads tiering.json, fills in defaults and validates it.

    .DESCRIPTION
        Rules give each VM a tier (Gold, Silver or Bronze), an application name and
        a workload profile. They run in file order against the VM's values as they
        are in the RVTools export, before anonymisation. For each of tier,
        application and profile, the first matching rule that sets it wins.

        A rule matches when every regular expression in its "match" block matches
        (case-insensitive). Match fields: name, cluster, host, datacenter, folder,
        resourcePool, annotation, guestOs, powerState, and attribute:<column> for
        any other vInfo column, such as a vCenter custom attribute.

        A VM no rule gives a profile is profiled from its RVTools usage: idle below
        the idle thresholds, saturated above the saturated ones, business-hours
        otherwise, and off when powered off.

        Without a file, every VM is Bronze and profiles come from usage alone.

    .PARAMETER Path
        Path to tiering.json. A missing file gives the defaults.

    .EXAMPLE
        Get-SynthTieringRule -Path ./config/tiering.json
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)

    $defaults = @{
        defaultTier = 'Bronze'
        rules       = @()
        profiles    = @{
            idleCpuPct      = 5
            idleMemPct      = 10
            saturatedCpuPct = 80
            saturatedMemPct = 85
        }
        sourcePath  = $null
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $defaults }

    try {
        $fromFile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Tiering file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $fromFile) { $fromFile = @{} }

    $rules = Merge-SynthHashtable -Base $defaults -Override $fromFile
    $rules.rules = @($rules.rules)
    $rules.sourcePath = (Resolve-Path -LiteralPath $Path).Path

    $problems = @(Test-SynthTieringRule -Rules $rules)
    if ($problems.Count -gt 0) {
        throw "Tiering file '$Path' has $($problems.Count) problem(s):`n  - $($problems -join "`n  - ")"
    }
    $rules
}

function Test-SynthTieringRule {
    <#
    .SYNOPSIS
        Returns one line per problem in a set of tiering rules; nothing when they are valid.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Rules)

    $tiers = Get-SynthTierName
    $profiles = Get-SynthProfileName
    $fields = 'name', 'cluster', 'host', 'datacenter', 'folder', 'resourcePool', 'annotation', 'guestOs', 'powerState'

    if ($Rules.defaultTier -notin $tiers) {
        "defaultTier '$($Rules.defaultTier)' must be one of $($tiers -join ', ')."
    }
    foreach ($name in 'idleCpuPct', 'idleMemPct', 'saturatedCpuPct', 'saturatedMemPct') {
        $value = $Rules.profiles[$name]
        if ($null -eq (ConvertTo-SynthNumber $value) -or $value -lt 0 -or $value -gt 100) {
            "profiles.$name must be a number from 0 to 100."
        }
    }

    $index = 0
    foreach ($rule in $Rules.rules) {
        $index++
        $label = "rules[$index]"
        if ($rule -isnot [hashtable]) { "$label must be an object."; continue }
        if (-not ($rule.ContainsKey('tier') -or $rule.ContainsKey('application') -or $rule.ContainsKey('profile'))) {
            "$label sets none of tier, application or profile."
        }
        if ($rule.ContainsKey('tier') -and $rule.tier -notin $tiers) {
            "$label tier '$($rule.tier)' must be one of $($tiers -join ', ')."
        }
        if ($rule.ContainsKey('profile') -and $rule.profile -notin $profiles) {
            "$label profile '$($rule.profile)' must be one of $($profiles -join ', ')."
        }
        if ($rule.ContainsKey('application') -and [string]::IsNullOrWhiteSpace($rule.application)) {
            "$label application is empty."
        }
        $match = $rule['match']
        if ($match -isnot [hashtable] -or $match.Count -eq 0) {
            "$label needs a match block with at least one field."
            continue
        }
        foreach ($field in $match.Keys) {
            if ($field -notin $fields -and $field -notmatch '^attribute:.+') {
                "$label matches on unknown field '$field'; use $($fields -join ', ') or attribute:<column>."
            }
            try { $null = [regex]::new([string]$match[$field]) }
            catch { "$label match.$field is not a valid regular expression: $($_.Exception.InnerException.Message)" }
        }
    }
}

function Get-SynthTierName {
    <# The tiers the tiered policies in Phase 5 are built for, best first. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Gold', 'Silver', 'Bronze'
}

function Get-SynthProfileName {
    <# Workload profiles the generator in Phase 4 knows how to draw. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'steady', 'business-hours', 'batch', 'bursty', 'idle', 'saturated'
}
