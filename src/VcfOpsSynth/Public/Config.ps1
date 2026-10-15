function Get-SynthConfig {
    <#
    .SYNOPSIS
        Loads lab.json, fills in defaults and environment overrides, and validates it.

    .DESCRIPTION
        Values left out of the file come from the defaults. These environment
        variables then override the file, so one image can target different labs
        without editing it:

            VCFOPS_FQDN       operations.fqdn
            VCFOPS_USERNAME   operations.username
            VCFOPS_AUTHSOURCE operations.authSource

        The password is never read from the file; see Get-SynthSecret.

    .PARAMETER Path
        Path to lab.json. Defaults to $env:VCFOPS_SYNTH_CONFIG, then /config/lab.json.

    .PARAMETER SkipValidation
        Returns the merged settings even when they fail validation, so they can be
        shown to the person fixing them.

    .EXAMPLE
        $cfg = Get-SynthConfig -Path ./config/lab.json
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path = $(if ($env:VCFOPS_SYNTH_CONFIG) { $env:VCFOPS_SYNTH_CONFIG } else { '/config/lab.json' }),
        [switch]$SkipValidation
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file '$Path' was not found. Copy config/lab.example.json to lab.json and mount its folder at /config."
    }

    try {
        $fromFile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $fromFile) { $fromFile = @{} }

    $config = Merge-SynthHashtable -Base (Get-SynthConfigDefault) -Override $fromFile

    if ($env:VCFOPS_FQDN)       { $config.operations.fqdn = $env:VCFOPS_FQDN }
    if ($env:VCFOPS_USERNAME)   { $config.operations.username = $env:VCFOPS_USERNAME }
    if ($env:VCFOPS_AUTHSOURCE) { $config.operations.authSource = $env:VCFOPS_AUTHSOURCE }
    $config['sourcePath'] = (Resolve-Path -LiteralPath $Path).Path

    if (-not $SkipValidation) {
        $problems = @(Test-SynthConfig -Config $config)
        if ($problems.Count -gt 0) {
            throw "Configuration file '$Path' has $($problems.Count) problem(s):`n  - $($problems -join "`n  - ")"
        }
    }
    $config
}

function Test-SynthConfig {
    <#
    .SYNOPSIS
        Returns one line per problem found in a merged configuration; nothing when it is valid.

    .EXAMPLE
        Test-SynthConfig -Config (Get-SynthConfig -SkipValidation)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config)

    $ops = $Config.operations
    if ([string]::IsNullOrWhiteSpace($ops.fqdn)) {
        'operations.fqdn is empty; set it in lab.json or with VCFOPS_FQDN.'
    }
    elseif ($ops.fqdn -match '^\w+://|/') {
        "operations.fqdn '$($ops.fqdn)' must be a host name only, without a scheme or path."
    }
    if ([string]::IsNullOrWhiteSpace($ops.username)) { 'operations.username is empty.' }
    if ([string]::IsNullOrWhiteSpace($ops.authSource)) { 'operations.authSource is empty; use LOCAL for the built-in admin account.' }
    if (-not (Test-SynthWholeNumber $ops.timeoutSeconds) -or $ops.timeoutSeconds -lt 5) {
        'operations.timeoutSeconds must be a whole number of 5 or more.'
    }

    if ($Config.adapterKind.key -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        "adapterKind.key '$($Config.adapterKind.key)' must start with a letter and hold only letters, digits and underscores."
    }
    if ([string]::IsNullOrWhiteSpace($Config.prefix)) {
        'prefix is empty; reset relies on it to find what the toolset created.'
    }

    if ($Config.intervalMinutes -notin 1, 5, 10, 15) {
        "intervalMinutes is $($Config.intervalMinutes); use 1, 5, 10 or 15 to line up with collection cycles."
    }
    if (-not (Test-SynthWholeNumber $Config.backfillDays) -or $Config.backfillDays -lt 0 -or $Config.backfillDays -gt 365) {
        'backfillDays must be a whole number from 0 to 365.'
    }

    try { $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($Config.timeZone) }
    catch { "timeZone '$($Config.timeZone)' is not a known time zone; use an IANA name such as Europe/Dublin." }

    foreach ($name in 'data', 'state', 'inventory') {
        if ([string]::IsNullOrWhiteSpace($Config.paths[$name])) { "paths.$name is empty." }
    }
    if ([string]::IsNullOrWhiteSpace($Config.import.source)) {
        'import.source is empty; name the RVTools xlsx, or a folder of its CSV files.'
    }
    if ($Config.import.anonymise -isnot [bool]) {
        'import.anonymise must be true or false.'
    }

    $live = $Config.liveLoad
    if ($live.maxLoadVms -lt 0 -or $live.maxUpsaPairs -lt 0) { 'liveLoad caps cannot be negative.' }
}
