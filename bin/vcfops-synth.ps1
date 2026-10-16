<#
.SYNOPSIS
    Command-line entry point for the vcfops-synth container.

.DESCRIPTION
    Builds a synthetic estate in VCF Operations from an RVTools export and pushes
    history, live metrics and Day-2 content to it through the Suite API. The image
    runs this script as its entrypoint, so the first argument to `docker run` is the
    command and the rest are its parameters:

        docker run --rm -v ./config:/config -e VCFOPS_PASSWORD ghcr.io/msherian/vcfops-synth seed -DryRun

    Every parameter can also come from an environment variable, which suits the
    container: VCFOPS_SYNTH_<NAME> (shown with each parameter below). A parameter on
    the command line wins over its variable, which wins over lab.json. Switches take
    true/false, yes/no, on/off or 1/0 in a variable.

    Commands available now:
        help              This text.
        version           Toolset and PowerShell versions.
        config            Validates lab.json and prints the merged settings (password never shown).
        connect-test      Signs in to VCF Operations and prints its version.
        plan              Validates settings and lists what each stage will do. Dry run.
        import [-Source] <path>
                          Reads an RVTools export into the inventory model.
                          -Source        an .xlsx, or a folder of RVTools CSV files
                                         (VCFOPS_SYNTH_SOURCE; default import.source)
                          -Output        where to write the model (VCFOPS_SYNTH_OUTPUT; default paths.inventory)
                          -Tiering       tiering rules (VCFOPS_SYNTH_TIERING; default import.tiering)
                          -Performance   LiveOptics VMware workbook: per-VM and per-host averages and peaks
                                         (VCFOPS_SYNTH_PERFORMANCE; default import.performance)
                          -NoAnonymise   keep real names; only for exports you may share as is
                                         (VCFOPS_SYNTH_NO_ANONYMISE; default: import.anonymise)
        seed              Creates the inventory in VCF Operations under a vCenter adapter instance,
                          foundations first: an optional Physical Data Center (seed.physicalDatacenter),
                          datacenters, clusters, datastores, hosts, distributed and standard switches,
                          port groups, VM folders and VMs. Objects keep their inventory names and carry
                          the seed.tag and project vSphere tags; values come from the inventory only.
                          Standard switches and port groups go under the toolset's adapter kind.
                          Every relationship is worked out first, datacenters go under the vCenter, and
                          objects that already exist (by identifier) are skipped.
                          -Adapter       vCenter adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)
                          -Refresh       also push planned properties and current stats to objects already there
                                         (VCFOPS_SYNTH_REFRESH)
                          -DryRun        build and summarise the plan; create nothing (VCFOPS_SYNTH_DRY_RUN)
        backfill          Pushes backfillDays of history at intervalMinutes for every numeric stat key of the
                          seeded objects, with analytics processing off. Keys with LiveOptics figures match
                          their average and peak; the rest follow each object's workload curve around its
                          current value, grow (space in use), stay flat (capacity) or stay at zero. A host,
                          cluster or datastore follows the sum of its VMs' curves. Resumes from paths.state.
                          -Adapter       vCenter adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)
                          -Days          days of history (VCFOPS_SYNTH_DAYS; default backfillDays)
                          -Kinds         only these kinds, comma-separated: VirtualMachine,HostSystem,...
                                         (VCFOPS_SYNTH_KINDS)
                          -MaxVms        only the first n VMs by key, for a pilot (VCFOPS_SYNTH_MAX_VMS)
                          -Concurrency   objects posted at once (VCFOPS_SYNTH_CONCURRENCY; default 4)
                          -Restart       forget saved progress and start over on a new range (VCFOPS_SYNTH_RESTART)
                          -DryRun        count objects, series and samples; push nothing (VCFOPS_SYNTH_DRY_RUN)

    Every command:
        -Command          the command (VCFOPS_SYNTH_COMMAND; default help)
        -ConfigPath       lab.json (VCFOPS_SYNTH_CONFIG; default /config/lab.json)

    Signing in to VCF Operations (config, connect-test, plan, seed, backfill; the password only for
    connect-test, seed and backfill):
        -Fqdn             VCF Operations host name (VCFOPS_FQDN; default operations.fqdn)
        -Username         account (VCFOPS_USERNAME; default operations.username)
        -AuthSource       authentication source (VCFOPS_AUTHSOURCE; default operations.authSource)
        -Password         the password (VCFOPS_PASSWORD). On a command line it shows in process lists
                          and shell history; prefer one of the two below.
        -PasswordFile     a file holding the password (VCFOPS_PASSWORD_FILE)
        -SecretName       a Docker secret holding the password, read from /run/secrets/<name>
                          (VCFOPS_SECRET_NAME)
        -CredentialFile   the VCF installer credentials file (JSON); its VCF Operations entry gives the
                          host, and its Administrator credentials the account and password
                          (VCFOPS_CREDENTIAL_FILE). With several VCF Operations, -Fqdn picks one.
        A parameter wins over every variable. Among parameters, and again among variables, a single
        value (-Fqdn, -Username, -Password, -PasswordFile, -SecretName) beats the credentials file,
        and the password beats the file, which beats the secret.

    import also takes:
        -AnonymisationKey key for stable IDs and pseudonyms, for runs that keep no state
                          (VCFOPS_SYNTH_ANON_KEY; default <paths.data>/anonymise.key)

    Commands still to come, by build phase:
        reset             Phase 3   Remove the objects seed created
        content           Phase 5-7 Groups, policies, alerts, dashboards
        feed, scenario    Phase 6   Live metrics and scenario overlays
        live-load         Phase 9   Optional UPSA and load VMs

.PARAMETER Command
    The command to run. Defaults to $env:VCFOPS_SYNTH_COMMAND, then help.

.PARAMETER Source
    import: the RVTools export (an .xlsx, or a folder of CSV files). VCFOPS_SYNTH_SOURCE.

.PARAMETER ConfigPath
    Path to lab.json. Defaults to $env:VCFOPS_SYNTH_CONFIG, then /config/lab.json.

.PARAMETER Output
    import: where to write the inventory model. VCFOPS_SYNTH_OUTPUT.

.PARAMETER Tiering
    import: the tiering rules file. VCFOPS_SYNTH_TIERING.

.PARAMETER Performance
    import: the LiveOptics VMware workbook. VCFOPS_SYNTH_PERFORMANCE.

.PARAMETER NoAnonymise
    import: keep real names. VCFOPS_SYNTH_NO_ANONYMISE.

.PARAMETER Adapter
    seed, backfill: the vCenter adapter instance. VCFOPS_SYNTH_ADAPTER.

.PARAMETER Refresh
    seed: push planned properties and stats to objects already there. VCFOPS_SYNTH_REFRESH.

.PARAMETER DryRun
    seed, backfill: report what would be done; change nothing. VCFOPS_SYNTH_DRY_RUN.

.PARAMETER Days
    backfill: days of history. VCFOPS_SYNTH_DAYS.

.PARAMETER Kinds
    backfill: only these resource kinds, comma-separated. VCFOPS_SYNTH_KINDS.

.PARAMETER MaxVms
    backfill: only the first n VMs. VCFOPS_SYNTH_MAX_VMS.

.PARAMETER Concurrency
    backfill: objects posted at once. VCFOPS_SYNTH_CONCURRENCY.

.PARAMETER Restart
    backfill: forget saved progress. VCFOPS_SYNTH_RESTART.

.PARAMETER Fqdn
    VCF Operations host name. VCFOPS_FQDN.

.PARAMETER Username
    Account to sign in with. VCFOPS_USERNAME.

.PARAMETER AuthSource
    Authentication source. VCFOPS_AUTHSOURCE.

.PARAMETER Password
    The password, as text or a SecureString. VCFOPS_PASSWORD. Prefer -PasswordFile or -SecretName.

.PARAMETER PasswordFile
    A file holding the password. VCFOPS_PASSWORD_FILE.

.PARAMETER SecretName
    A Docker secret holding the password (/run/secrets/<name>). VCFOPS_SECRET_NAME.

.PARAMETER CredentialFile
    The VCF installer credentials file: host, account and password for VCF Operations. VCFOPS_CREDENTIAL_FILE.

.PARAMETER AnonymisationKey
    import: key for stable IDs and pseudonyms. VCFOPS_SYNTH_ANON_KEY.

.PARAMETER Unrecognised
    Anything else on the command line; refused with exit code 2.

.EXAMPLE
    pwsh ./bin/vcfops-synth.ps1 config -ConfigPath ./config/lab.json

.EXAMPLE
    pwsh ./bin/vcfops-synth.ps1 backfill -Kinds VirtualMachine -MaxVms 25 -ConfigPath ./config/lab.json

.EXAMPLE
    docker run --rm -v ./config:/config -v ./data:/data -e VCFOPS_PASSWORD -e VCFOPS_SYNTH_DRY_RUN=true ghcr.io/msherian/vcfops-synth seed

.EXAMPLE
    docker service create --secret vcfops_password -e VCFOPS_SECRET_NAME=vcfops_password ... ghcr.io/msherian/vcfops-synth backfill

.EXAMPLE
    pwsh ./bin/vcfops-synth.ps1 backfill -CredentialFile ~/Documents/vcf-installer-creds.json -ConfigPath ./config/lab.json

.NOTES
    Exit codes: 0 success, 1 failure, 2 unknown command, parameter or value,
    3 command not built yet.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are read through PSBoundParameters by Resolve-CliOption.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'pwsh -File passes text; Get-SynthSecret turns it into a SecureString at once, and the help steers to -PasswordFile and -SecretName.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = $(if ($env:VCFOPS_SYNTH_COMMAND) { $env:VCFOPS_SYNTH_COMMAND } else { 'help' }),

    [Parameter(Position = 1)]
    [string]$Source,

    [string]$ConfigPath = $(if ($env:VCFOPS_SYNTH_CONFIG) { $env:VCFOPS_SYNTH_CONFIG } else { '/config/lab.json' }),

    [string]$Output,
    [string]$Tiering,
    [Alias('Perf')][string]$Performance,
    [Alias('NoAnonymize')][switch]$NoAnonymise,

    [string]$Adapter,
    [switch]$Refresh,
    [switch]$DryRun,

    # Numbers are taken as text and checked here, so a bad value is exit code 2, not a binding failure.
    [string]$Days,
    [string[]]$Kinds,
    [string]$MaxVms,
    [string]$Concurrency,
    [switch]$Restart,

    [string]$Fqdn,
    [string]$Username,
    [string]$AuthSource,
    # Text from pwsh -File, or a SecureString when the script is called from PowerShell.
    [object]$Password,
    [string]$PasswordFile,
    [string]$SecretName,
    [string]$CredentialFile,
    [Alias('AnonKey')][string]$AnonymisationKey,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Unrecognised
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/VcfOpsSynth/VcfOpsSynth.psd1'
Import-Module $moduleRoot -Force
$toolVersion = (Import-PowerShellDataFile -Path $moduleRoot).ModuleVersion

$planned = [ordered]@{
    'reset'     = 3
    'content'   = 5
    'feed'      = 6
    'scenario'  = 6
    'live-load' = 9
}

# Each command parameter: its environment variable, its type, and the commands that take it.
$optionSpec = [ordered]@{
    Source      = @{ Env = 'VCFOPS_SYNTH_SOURCE'; Type = 'text'; Commands = @('import') }
    Output      = @{ Env = 'VCFOPS_SYNTH_OUTPUT'; Type = 'text'; Commands = @('import') }
    Tiering     = @{ Env = 'VCFOPS_SYNTH_TIERING'; Type = 'text'; Commands = @('import') }
    Performance = @{ Env = 'VCFOPS_SYNTH_PERFORMANCE'; Type = 'text'; Commands = @('import') }
    NoAnonymise = @{ Env = 'VCFOPS_SYNTH_NO_ANONYMISE'; Type = 'switch'; Commands = @('import') }
    Adapter     = @{ Env = 'VCFOPS_SYNTH_ADAPTER'; Type = 'text'; Commands = @('seed', 'backfill') }
    Refresh     = @{ Env = 'VCFOPS_SYNTH_REFRESH'; Type = 'switch'; Commands = @('seed') }
    DryRun      = @{ Env = 'VCFOPS_SYNTH_DRY_RUN'; Type = 'switch'; Commands = @('seed', 'backfill') }
    Days        = @{ Env = 'VCFOPS_SYNTH_DAYS'; Type = 'count'; Commands = @('backfill') }
    Kinds       = @{ Env = 'VCFOPS_SYNTH_KINDS'; Type = 'list'; Commands = @('backfill') }
    MaxVms      = @{ Env = 'VCFOPS_SYNTH_MAX_VMS'; Type = 'count'; Commands = @('backfill') }
    Concurrency = @{ Env = 'VCFOPS_SYNTH_CONCURRENCY'; Type = 'count'; Commands = @('backfill') }
    Restart     = @{ Env = 'VCFOPS_SYNTH_RESTART'; Type = 'switch'; Commands = @('backfill') }
    # The module reads these variables itself, so only a parameter is passed on ('module').
    Fqdn             = @{ Env = 'VCFOPS_FQDN'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill') }
    Username         = @{ Env = 'VCFOPS_USERNAME'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill') }
    AuthSource       = @{ Env = 'VCFOPS_AUTHSOURCE'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill') }
    Password         = @{ Env = 'VCFOPS_PASSWORD'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill') }
    PasswordFile     = @{ Env = 'VCFOPS_PASSWORD_FILE'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill') }
    SecretName       = @{ Env = 'VCFOPS_SECRET_NAME'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill') }
    CredentialFile   = @{ Env = 'VCFOPS_CREDENTIAL_FILE'; Type = 'text'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill') }
    AnonymisationKey = @{ Env = 'VCFOPS_SYNTH_ANON_KEY'; Type = 'module'; Commands = @('import') }
}

function Show-Help {
    $help = Get-Help -Name $PSCommandPath -Full
    Write-Host $help.Synopsis
    Write-Host ''
    Write-Host ($help.Description.Text -join "`n")
}

function ConvertTo-RedactedConfig {
    param([hashtable]$Config)
    # Nothing secret lives in the file today; this keeps it that way if a field is added.
    $copy = $Config | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
    foreach ($key in @($copy.operations.Keys)) {
        if ($key -match 'password|secret|token') { $copy.operations[$key] = '***' }
    }
    $copy
}

function Resolve-CliOption {
    <#
        The options for one command: each from its parameter when given, else its
        environment variable, else $null (the command falls back to lab.json).
        A parameter the command does not take, or a value of the wrong kind, is an
        ArgumentException, which the caller turns into exit code 2. Variables for
        other commands are ignored, since a container may set several.
    #>
    param([string]$Name, [hashtable]$Bound)
    $options = @{}
    foreach ($key in $optionSpec.Keys) {
        $spec = $optionSpec[$key]
        $takes = $Name -in $spec.Commands
        if ($Bound.ContainsKey($key) -and -not $takes) {
            # A stray word after a command lands in the positional -Source.
            if ($key -eq 'Source') { throw [System.ArgumentException]::new("'$Name' takes no further arguments; got: $($Bound[$key]).") }
            throw [System.ArgumentException]::new("'$Name' does not take -$key.")
        }
        if (-not $takes) { continue }
        if ($spec.Type -eq 'module') { $options[$key] = if ($Bound.ContainsKey($key)) { $Bound[$key] } else { $null }; continue }
        $raw = $null
        $from = ''
        if ($Bound.ContainsKey($key)) { $raw = $Bound[$key]; $from = "-$key" }
        elseif ([Environment]::GetEnvironmentVariable($spec.Env)) { $raw = [Environment]::GetEnvironmentVariable($spec.Env); $from = $spec.Env }
        if ($null -eq $raw) { $options[$key] = $null; continue }
        $options[$key] = switch ($spec.Type) {
            'switch' {
                if ($raw -is [System.Management.Automation.SwitchParameter] -or $raw -is [bool]) { [bool]$raw }
                elseif ("$raw" -match '^(?i:true|yes|on|1)$') { $true }
                elseif ("$raw" -match '^(?i:false|no|off|0)$') { $false }
                else { throw [System.ArgumentException]::new("$from must be true or false; got '$raw'.") }
            }
            'count' {
                if ("$raw" -notmatch '^\d+$' -or [int]"$raw" -lt 1) { throw [System.ArgumentException]::new("$from needs a whole number of at least 1; got '$raw'.") }
                [int]"$raw"
            }
            'list' { , @(@($raw) -join ',' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            default { [string]$raw }
        }
    }
    $options
}

function Get-CliOption {
    # An option of the current command, or $null when the command does not take it.
    param([string]$Name)
    if ($options.ContainsKey($Name)) { $options[$Name] } else { $null }
}

function Get-CliCredential {
    # The VCF installer credentials file (-CredentialFile, else VCFOPS_CREDENTIAL_FILE), read once.
    $path = Get-CliOption 'CredentialFile'
    if (-not $path) { return $null }
    if (-not $script:cliCredential) {
        # With several VCF Operations in the file, the host named elsewhere picks one.
        $pick = Get-CliOption 'Fqdn'
        if (-not $pick) { $pick = (Get-SynthConfig -Path $ConfigPath -SkipValidation).operations.fqdn }
        $script:cliCredential = Read-SynthCredentialFile -Path $path -Fqdn $pick
        $script:cliCredential.FromParameter = $cliBound.ContainsKey('CredentialFile')
    }
    $script:cliCredential
}

function Get-CliConfig {
    # lab.json with the sign-in parameters, then the credentials file, on top.
    param([switch]$SkipValidation)
    $fqdn = Get-CliOption 'Fqdn'
    $username = Get-CliOption 'Username'
    $cred = Get-CliCredential
    # The file beats lab.json, and a single value beats the file when both are parameters or both variables.
    if ($cred -and -not $fqdn -and ($cred.FromParameter -or -not $env:VCFOPS_FQDN)) { $fqdn = $cred.Fqdn }
    if ($cred -and -not $username -and ($cred.FromParameter -or -not $env:VCFOPS_USERNAME)) { $username = $cred.Username }
    Get-SynthConfig -Path $ConfigPath -Fqdn $fqdn -Username $username -AuthSource (Get-CliOption 'AuthSource') -SkipValidation:$SkipValidation
}

function Connect-Cli {
    # Signs in with -Password, -PasswordFile or -SecretName when given, else the credentials file or the environment's.
    param($Config)
    $given = @('Password', 'PasswordFile', 'SecretName' | Where-Object { Get-CliOption $_ })
    $cred = Get-CliCredential
    $fromEnv = $env:VCFOPS_PASSWORD -or $env:VCFOPS_PASSWORD_FILE -or $env:VCFOPS_SECRET_NAME
    $secret = if (-not $given.Count -and $cred -and ($cred.FromParameter -or -not $fromEnv)) { $cred.Password }
    else { Get-SynthSecret -Password (Get-CliOption 'Password') -PasswordFile (Get-CliOption 'PasswordFile') -SecretName (Get-CliOption 'SecretName') }
    Connect-SynthOps -Config $Config -Password $secret
}

function New-CliSeedPlan {
    # The seed plan both seed and backfill work from, with the synthetic and project tags.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a plan in memory.')]
    param($Config, $Inventory, $Rubrics, $Target)
    # The synthetic marker, then the project: seed.project, else the project folder the import came from.
    $tags = @(@{ Category = $Config.seed.tag.category; Name = $Config.seed.tag.name })
    $project = if ($Config.seed.project) { $Config.seed.project } elseif ($Inventory.source -and $Inventory.source.Contains('project')) { $Inventory.source.project } else { $null }
    if ($project) { $tags += @{ Category = 'Project'; Name = $project } }
    $plan = New-SynthSeedPlan -Inventory $Inventory -Rubric $Rubrics -VcId $Target.VcId -Prefix $Config.seed.prefix -Tag $tags -CustomAdapterKind $Config.adapterKind.key -PhysicalDatacenter $Config.seed.physicalDatacenter
    @{ Plan = $plan; Tags = $tags }
}

try {
    # --name is not an option. pwsh -File would quietly bind --concurrency to -Concurrency, and a
    # direct call puts it in -Source, so look at the raw arguments after this script as well.
    $argv = [Environment]::GetCommandLineArgs()
    $self = [array]::FindIndex($argv, [Predicate[string]] { param($a) try { [IO.Path]::GetFullPath($a) -ieq $PSCommandPath } catch { $false } })
    $raw = @(if ($self -ge 0) { $argv | Select-Object -Skip ($self + 1) }) + @($Command, $Source) + @($Unrecognised)
    $dashed = @($raw | Where-Object { $_ -match '^--' } | Select-Object -Unique)
    if ($dashed.Count) {
        $parameters = $MyInvocation.MyCommand.Parameters.Values | Where-Object Name -NE 'Unrecognised'
        foreach ($token in $dashed) {
            $name = ($token -replace '^-+', '') -replace '-', ''
            $match = @($parameters | Where-Object { $_.Name -ieq $name -or $_.Aliases -icontains $name } | Select-Object -ExpandProperty Name)
            $suggestion = if ($match.Count) { " Did you mean -$($match[0])?" } elseif ($name -ieq 'help') { " Did you mean 'help'?" } else { '' }
            Write-Host "Unknown option '$token'.$suggestion"
        }
        Write-Host "Run 'help' for usage."
        exit 2
    }
    if ($Unrecognised) {
        Write-Host "Unexpected argument(s) for '$Command': $($Unrecognised -join ' '). Run 'help' for usage."
        exit 2
    }
    $commandName = $Command.ToLowerInvariant()
    $cliBound = $PSBoundParameters
    $script:cliCredential = $null
    try { $options = Resolve-CliOption -Name $commandName -Bound $PSBoundParameters }
    catch [System.ArgumentException] {
        Write-Host "$($_.Exception.Message) Run 'help' for usage."
        exit 2
    }

    switch ($commandName) {
        'help' {
            Show-Help
            exit 0
        }

        'version' {
            Write-Host "vcfops-synth $toolVersion (PowerShell $($PSVersionTable.PSVersion))"
            exit 0
        }

        'config' {
            $config = Get-CliConfig -SkipValidation
            ConvertTo-RedactedConfig -Config $config | ConvertTo-Json -Depth 10 | Write-Host
            $problems = @(Test-SynthConfig -Config $config)
            if ($problems.Count -gt 0) {
                Write-Host ''
                Write-Host "$($problems.Count) problem(s) found:"
                $problems | ForEach-Object { Write-Host "  - $_" }
                exit 1
            }
            Write-Host ''
            Write-Host 'Configuration is valid.'
            exit 0
        }

        'connect-test' {
            $config = Get-CliConfig
            $session = Connect-Cli -Config $config
            $version = Get-SynthOpsVersion
            $release = if ($version.PSObject.Properties['releaseName']) { $version.releaseName } else { $version | ConvertTo-Json -Compress }
            Write-Host "Signed in to $($config.operations.fqdn) as $($config.operations.username)."
            Write-Host "VCF Operations: $release"
            if ($session.Expires) { Write-Host "Token valid until $($session.Expires.ToString('u'))." }
            Disconnect-SynthOps -Confirm:$false
            exit 0
        }

        'plan' {
            $config = Get-CliConfig
            $samplesPerObject = [int]($config.backfillDays * 24 * 60 / $config.intervalMinutes)
            Write-Host "Target:      https://$($config.operations.fqdn) as $($config.operations.username) ($($config.operations.authSource))"
            Write-Host "Adapter:     $($config.adapterKind.key) ('$($config.adapterKind.name)'), objects prefixed '$($config.prefix)'"
            Write-Host "Backfill:    $($config.backfillDays) days at $($config.intervalMinutes)-minute intervals, $samplesPerObject samples per metric per object"
            Write-Host "Live load:   $(if ($config.liveLoad.enabled) { "on, up to $($config.liveLoad.maxLoadVms) load VMs and $($config.liveLoad.maxUpsaPairs) UPSA pairs" } else { 'off' })"
            Write-Host ''
            if (Test-Path -LiteralPath $config.paths.inventory) {
                $inventory = Get-SynthInventory -Path $config.paths.inventory
                $objects = @($inventory.vms).Count + @($inventory.hosts).Count + @($inventory.clusters).Count + @($inventory.datastores).Count
                Write-Host "Inventory:   $($config.paths.inventory), imported $($inventory.importedAt)"
                Get-SynthInventorySummary -Inventory $inventory | ForEach-Object { Write-Host "             $_" }
                Write-Host "Seed:        $objects objects, $(@($inventory.datacenters).Count) datacenters (Phase 3)"
                Write-Host "History:     about $('{0:N0}' -f ($objects * $samplesPerObject)) samples per metric across all objects (Phase 4)"
            }
            else {
                Write-Host "No inventory at $($config.paths.inventory) yet; run 'import' first, so nothing would be created."
            }
            exit 0
        }

        'import' {
            $config = Get-CliConfig
            $source = if ($options.Source) { $options.Source } else { $config.import.source }
            $output = if ($options.Output) { $options.Output } else { $config.paths.inventory }
            $anonymise = if ($null -ne $options.NoAnonymise) { -not $options.NoAnonymise } else { $config.import.anonymise }

            $tieringPath = if ($options.Tiering) { $options.Tiering } else { $config.import.tiering }
            if ($options.Tiering -and -not (Test-Path -LiteralPath $tieringPath)) {
                throw "Tiering file '$tieringPath' was not found."
            }
            if (-not (Test-Path -LiteralPath $tieringPath)) {
                Write-Host "No tiering rules at $tieringPath, so every VM is Bronze. Start from config/tiering.example.json."
            }
            $rules = Get-SynthTieringRule -Path $tieringPath

            $perfPath = if ($options.Performance) { $options.Performance } else { $config.import.performance }
            $perfData = if ($perfPath) { Read-SynthLiveOptics -Path $perfPath } else { $null }

            $key = Get-SynthAnonymisationKey -DataPath $config.paths.data -Key (Get-CliOption 'AnonymisationKey')
            $inventory = Import-SynthRvtools -Path $source -Key $key -TieringRules $rules -Anonymise:$anonymise -Performance $perfData
            Save-SynthInventory -Inventory $inventory -Path $output

            Write-Host "Imported $source to $output."
            Get-SynthInventorySummary -Inventory $inventory | ForEach-Object { Write-Host "  $_" }
            $skipped = @($inventory.report.skipped)
            if ($skipped.Count) {
                $reasons = $skipped | Group-Object { $_.reason } | ForEach-Object { "$($_.Count) $($_.Name)" }
                Write-Host "Skipped $($skipped.Count) row(s): $($reasons -join ', ')."
            }
            foreach ($warning in $inventory.report.warnings) { Write-Host "Warning: $warning" }
            if (-not $anonymise) { Write-Host 'Real names were kept. Do not share this inventory outside the customer.' }
            exit 0
        }

        'seed' {
            $config = Get-CliConfig
            $adapterName = if ($options.Adapter) { $options.Adapter } else { $config.seed.adapterInstance }
            if (-not $adapterName) { throw 'No vCenter adapter instance to seed under. Set seed.adapterInstance in lab.json or pass -Adapter <name> (VCFOPS_SYNTH_ADAPTER).' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath

            $null = Connect-Cli -Config $config
            try {
                $target = Resolve-SynthSeedTarget -Name $adapterName
                $built = New-CliSeedPlan -Config $config -Inventory $inventory -Rubrics $rubrics -Target $target
                $plan = $built.Plan
                Write-Host "Tags: $(($built.Tags | ForEach-Object { "$($_.Category): $($_.Name)" }) -join '; ')"
                $objects = @($plan.objects)
                Write-Host "Seed plan for adapter instance $adapterName ($($target.AdapterInstanceId)), vCenter $($target.VcId):"
                $objects | Group-Object { $_.kind } | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
                $edges = ($plan.links | ForEach-Object { @($_.children).Count } | Measure-Object -Sum).Sum
                Write-Host "  $($objects.Count) objects, $edges links"
                Write-Host "  Not created: $($plan.skipped.rootResourcePools) root resource pools (not shown in Operations)"
                if ($plan.skipped.userResourcePools) { Write-Host "  Not created yet: $($plan.skipped.userResourcePools) user-created resource pools" }
                if ($options.DryRun) {
                    Write-Host 'Dry run: nothing was created.'
                    exit 0
                }

                $result = Invoke-SynthSeed -Plan $plan -AdapterInstanceId $target.AdapterInstanceId -Refresh:$options.Refresh
                foreach ($kind in $result.created.Keys) {
                    Write-Host "  $($kind): $($result.created[$kind]) created, $($result.existing[$kind]) already there"
                }
                Write-Host "  $($result.links) links made"
                if ($options.Refresh) { Write-Host "  $($result.refreshed) existing objects had their properties and stats refreshed" }
                foreach ($note in $result.renamed) { Write-Host "Not renamed: $note" }
                foreach ($failure in $result.failed) { Write-Host "Failed: $failure" }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            # Stale names mean Ops does not match the plan, so later phases should not carry on as if it did.
            exit $(if ($result.failed.Count -or $result.renamed.Count) { 1 } else { 0 })
        }

        'backfill' {
            $config = Get-CliConfig
            $adapterName = if ($options.Adapter) { $options.Adapter } else { $config.seed.adapterInstance }
            if (-not $adapterName) { throw 'No vCenter adapter instance to backfill under. Set seed.adapterInstance in lab.json or pass -Adapter <name> (VCFOPS_SYNTH_ADAPTER).' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath
            $days = if ($options.Days) { $options.Days } else { $config.backfillDays }
            $range = Get-SynthBackfillRange -Days $days -IntervalMinutes $config.intervalMinutes

            $null = Connect-Cli -Config $config
            try {
                $target = Resolve-SynthSeedTarget -Name $adapterName
                $plan = (New-CliSeedPlan -Config $config -Inventory $inventory -Rubrics $rubrics -Target $target).Plan
                if ($options.Kinds) {
                    $unknown = @($options.Kinds | Where-Object { $_ -notin @($plan.objects | ForEach-Object { $_.kind }) })
                    if ($unknown.Count) { Write-Host "No planned objects of kind $($unknown -join ', '). Run 'help' for usage."; exit 2 }
                    $plan.objects = @($plan.objects | Where-Object { $_.kind -in $options.Kinds })
                }
                if ($options.MaxVms) {
                    $keep = @($plan.objects | Where-Object { $_.kind -eq 'VirtualMachine' } | Sort-Object { $_.key } | Select-Object -First $options.MaxVms | ForEach-Object { $_.key })
                    $plan.objects = @($plan.objects | Where-Object { $_.kind -ne 'VirtualMachine' -or $_.key -in $keep })
                }
                $ids = Resolve-SynthPlanId -Plan $plan -AdapterInstanceId $target.AdapterInstanceId
                $missing = @($plan.objects | Where-Object { -not $ids.ContainsKey($_.key) }).Count
                $spec = @(New-SynthBackfillSpec -Plan $plan -Inventory $inventory -Ids $ids)
                $series = ($spec | ForEach-Object { $_.Series.Count } | Measure-Object -Sum).Sum
                $samples = [long]$series * $range.Points
                # A saved range of the same length is resumed, so show the one that will be written.
                if (-not $options.Restart) { $range = (Read-SynthBackfillState -Path $config.paths.state -Range $range).range }
                $from = [DateTimeOffset]::FromUnixTimeMilliseconds($range.StartMs).ToString('u')
                $to = [DateTimeOffset]::FromUnixTimeMilliseconds($range.EndMs).ToString('u')
                Write-Host "Backfill for adapter instance ${adapterName}: $days days at $($config.intervalMinutes) minutes, $from to $to ($($range.Points) points)"
                $spec | Group-Object { ($plan.objects | Where-Object key -eq $_.Key | Select-Object -First 1).kind } | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) objects, $(($_.Group | ForEach-Object { $_.Series.Count } | Measure-Object -Sum).Sum) series" }
                Write-Host ('  {0} objects, {1:N0} series, {2:N0} samples (about {3:N1} GB of JSON)' -f $spec.Count, $series, $samples, ($samples * 19 / 1e9))
                if ($missing) { Write-Host "  $missing planned objects are not in Operations; run seed first. They are skipped." }
                if ($options.DryRun) {
                    Write-Host 'Dry run: nothing was pushed.'
                    exit 0
                }
                if ($options.Restart -and (Test-Path -LiteralPath $config.paths.state)) {
                    $state = Get-Content -LiteralPath $config.paths.state -Raw | ConvertFrom-Json -AsHashtable
                    if ($state -and $state.ContainsKey('backfill')) { $state.Remove('backfill'); $state | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $config.paths.state -Encoding utf8 }
                }
                $result = Invoke-SynthBackfill -Spec $spec -Range $range -StatePath $config.paths.state -TimeZone $config.timeZone -Concurrency $(if ($options.Concurrency) { $options.Concurrency } else { 4 }) -Verbose
                Write-Host ('  {0} objects pushed, {1:N0} samples in {2:N0} calls, {3} s ({4:N0} samples/s); {5} already done' -f $result.objects, $result.samples, $result.calls, $result.seconds, $(if ($result.seconds) { $result.samples / $result.seconds } else { 0 }), $result.skipped)
                foreach ($failure in $result.failed) { Write-Host "Failed: $failure" }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            exit $(if ($result.failed.Count) { 1 } else { 0 })
        }

        { $planned.Contains($_) } {
            Write-Host "'$Command' is not built yet; it arrives in Phase $($planned[$_]) of the build order."
            exit 3
        }

        default {
            Write-Host "Unknown command '$Command'. Run 'help' for the list."
            exit 2
        }
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
    exit 1
}
