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
        seed              Creates the inventory in VCF Operations under the holder adapter instance,
                          foundations first: an optional Physical Data Center (seed.physicalDatacenter),
                          datacenters, clusters, datastores, hosts, distributed and standard switches,
                          port groups, VM folders and VMs. Objects keep their inventory names and carry
                          the seed.tag and project vSphere tags; values come from the inventory only.
                          Standard switches and port groups go under the toolset's adapter kind.
                          Every relationship is worked out first, datacenters go under the holder adapter
                          instance, and objects that already exist (by identifier) are skipped. The holder
                          is a VMWARE instance of its own, created if missing and never started: a vCenter
                          adapter marks objects its vCenter lacks as not existing when it restarts.
                          -Adapter       holder adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)
                          -Refresh       also push planned properties and current stats to objects already there
                                         (VCFOPS_SYNTH_REFRESH)
                          -DryRun        build and summarise the plan; create nothing (VCFOPS_SYNTH_DRY_RUN)
        backfill          Pushes backfillDays of history at intervalMinutes for every numeric stat key of the
                          seeded objects, with analytics processing off. Keys with LiveOptics figures match
                          their average and peak; the rest follow each object's workload curve around its
                          current value, grow (space in use), stay flat (capacity) or stay at zero. A host,
                          cluster or datastore follows the sum of its VMs' curves. Resumes from paths.state.
                          -Adapter       holder adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)
                          -Days          days of history (VCFOPS_SYNTH_DAYS; default backfillDays)
                          -Kinds         only these kinds, comma-separated: VirtualMachine,HostSystem,...
                                         (VCFOPS_SYNTH_KINDS)
                          -MaxVms        only the first n VMs by key, for a pilot (VCFOPS_SYNTH_MAX_VMS)
                          -Concurrency   objects posted at once (VCFOPS_SYNTH_CONCURRENCY; default 4)
                          -MaxSamples    samples per post, halved when refused (VCFOPS_SYNTH_MAX_SAMPLES; default 100000)
                          -Restart       forget saved progress and start over on a new range (VCFOPS_SYNTH_RESTART)
                          -DryRun        count objects, series and samples; push nothing (VCFOPS_SYNTH_DRY_RUN)

    Every command:
        -Command          the command (VCFOPS_SYNTH_COMMAND; default help)
        -ConfigPath       lab.json (VCFOPS_SYNTH_CONFIG; default /config/lab.json)

    Signing in to VCF Operations (config, connect-test, plan, seed, backfill, content, feed, scenario, reset;
    the password only for connect-test, seed, backfill, content, feed, scenario and reset):
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

        content           Publishes the toolset's custom groups (the synthetic estate, one per tier, one per
                          application from the tier rules, and the scenario targets), by name with the prefix;
                          existing ones are updated. Membership follows the synthetic tag and the vcfops-synth|tier
                          and |application properties seed writes. Then the symptoms, alerts (with tier thresholds),
                          recommendations and super metrics the scenarios raise, then the policies (Synth-Base
                          on the estate switches on every Synth- alert, a tier policy on each tier group, from the
                          SLA matrix in content.sla). Last the list views and reports (VM tier list, oversized and
                          undersized VMs, configuration hygiene, cluster tier pressure; weekly tier compliance and
                          rightsizing reports), written to <paths.data>/content-bundle.zip and imported with force,
                          so a re-run overwrites them by name. The same bundle carries two dashboards (service tiers;
                          rightsizing and hygiene) that show those views on the estate group. Exit code 1 when any
                          item is rejected; the rest are still published.
                          -DryRun        list what would be created or updated, and write the bundle without
                                         importing it (VCFOPS_SYNTH_DRY_RUN)
                          -ImportField   multipart field the bundle is sent in (VCFOPS_SYNTH_IMPORT_FIELD;
                                         default contentFile)

        feed              Pushes a live point for every seeded object each intervalMinutes, with analytics on, so
                          capacity, symptoms and alerts run on it. Each series carries on from the backfill at the
                          same levels; a gap since the last push (or the backfill's end) is filled first, with
                          analytics off, up to 24 hours. Running scenarios are read every cycle. Runs until stopped.
                          -Adapter       holder adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)
                          -Cycles        stop after n cycles, e.g. 1 from a scheduled task (VCFOPS_SYNTH_CYCLES)
                          -Concurrency   objects posted at once (VCFOPS_SYNTH_CONCURRENCY; default 8)
                          -DryRun        prepare the feed and show the next point; push nothing (VCFOPS_SYNTH_DRY_RUN)
        scenario          Lists the scenarios and the running ones; starts or stops one. A running feed picks the
                          change up on its next cycle. S1 noisy neighbour, S2 memory pressure, S3 storage latency,
                          S4 guest disk filling, S8 host failure.
                          -Start         scenario to start: S1, S2, S3, S4 or S8 (VCFOPS_SYNTH_START)
                          -Stop          scenario to stop, or all (VCFOPS_SYNTH_STOP)
                          -Target        object to run it on, by inventory ID or name; default a busy one
                                         (VCFOPS_SYNTH_TARGET)
                          -RampMinutes   minutes to full effect (VCFOPS_SYNTH_RAMP_MINUTES; default 10)
                          -Adapter       holder adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)

        reset             Deletes the objects seed created, VMs first, found by kind and unique identifier and
                          deleted only when they carry the synthetic tag (seed.tag); then forgets the backfill,
                          feed and scenario state. Reports only, unless -Force is given.
                          -Force          delete for real (VCFOPS_SYNTH_FORCE)
                          -IncludeContent also delete the prefixed policies, alerts, symptoms, recommendations,
                                          super metrics and custom groups (VCFOPS_SYNTH_INCLUDE_CONTENT); with
                                          -ApplianceSsh also the views, reports and dashboards, by exact name with
                                          ops-cli on the appliance; without it, lists them to delete in the UI
                                          and writes <data>/content-delete.json for bin/ops-content-delete.py
                          -ApplianceSsh   user@host of the Operations appliance; key first, else ssh asks for the password
                                          (VCFOPS_SYNTH_APPLIANCE_SSH)
                          -SshKey         private key for -ApplianceSsh (VCFOPS_SYNTH_SSH_KEY; default /keys/id_ssh if it exists,
                                          else ssh's own)
                          -DryRun         report only, even with -Force (VCFOPS_SYNTH_DRY_RUN)
                          -Adapter        holder adapter instance (VCFOPS_SYNTH_ADAPTER; default seed.adapterInstance)

    Commands still to come, by build phase:
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
    seed, backfill, feed, scenario: the holder adapter instance. VCFOPS_SYNTH_ADAPTER.

.PARAMETER Refresh
    seed: push planned properties and stats to objects already there. VCFOPS_SYNTH_REFRESH.

.PARAMETER DryRun
    seed, backfill, content, feed, reset: report what would be done; change nothing. VCFOPS_SYNTH_DRY_RUN.

.PARAMETER Force
    reset: delete for real; without it reset only reports. VCFOPS_SYNTH_FORCE.

.PARAMETER IncludeContent
    reset: also delete the prefixed policies, alerts, symptoms, recommendations, super metrics and custom groups.
    VCFOPS_SYNTH_INCLUDE_CONTENT.

.PARAMETER ApplianceSsh
    reset -IncludeContent: user@host of the VCF Operations appliance; reset signs in with a key and deletes the
    views, reports and dashboards with ops-cli, in one SSH session; if the key is refused, ssh asks for the password on the terminal. VCFOPS_SYNTH_APPLIANCE_SSH.

.PARAMETER SshKey
    reset: the private key for -ApplianceSsh; default /keys/id_ssh when that file exists (the container's key mount).
    VCFOPS_SYNTH_SSH_KEY.

.PARAMETER ImportField
    content: the multipart field name for the content bundle import. VCFOPS_SYNTH_IMPORT_FIELD.

.PARAMETER Days
    backfill: days of history. VCFOPS_SYNTH_DAYS.

.PARAMETER Kinds
    backfill: only these resource kinds, comma-separated. VCFOPS_SYNTH_KINDS.

.PARAMETER MaxVms
    backfill: only the first n VMs. VCFOPS_SYNTH_MAX_VMS.

.PARAMETER Concurrency
    backfill: objects posted at once. VCFOPS_SYNTH_CONCURRENCY.

.PARAMETER MaxSamples
    backfill: samples per post; a post Operations refuses with HTTP 500 is halved. VCFOPS_SYNTH_MAX_SAMPLES.

.PARAMETER Restart
    backfill: forget saved progress. VCFOPS_SYNTH_RESTART.

.PARAMETER Cycles
    feed: stop after this many cycles. VCFOPS_SYNTH_CYCLES.

.PARAMETER Start
    scenario: the scenario to start. VCFOPS_SYNTH_START.

.PARAMETER Stop
    scenario: the scenario to stop, or all. VCFOPS_SYNTH_STOP.

.PARAMETER Target
    scenario: the object to run it on. VCFOPS_SYNTH_TARGET.

.PARAMETER RampMinutes
    scenario: minutes to full effect. VCFOPS_SYNTH_RAMP_MINUTES.

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
    pwsh ./bin/vcfops-synth.ps1 scenario -Start S1 -ConfigPath ./config/lab.json

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
    [switch]$Force,
    [switch]$IncludeContent,
    [string]$ApplianceSsh,
    [string]$SshKey,
    [string]$ImportField,

    # Numbers are taken as text and checked here, so a bad value is exit code 2, not a binding failure.
    [string]$Days,
    [string[]]$Kinds,
    [string]$MaxVms,
    [string]$Concurrency,
    [string]$MaxSamples,
    [switch]$Restart,
    [string]$Cycles,
    [string]$Start,
    [string]$Stop,
    [string]$Target,
    [string]$RampMinutes,

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
    'live-load' = 9
}

# Each command parameter: its environment variable, its type, and the commands that take it.
$optionSpec = [ordered]@{
    Source      = @{ Env = 'VCFOPS_SYNTH_SOURCE'; Type = 'text'; Commands = @('import') }
    Output      = @{ Env = 'VCFOPS_SYNTH_OUTPUT'; Type = 'text'; Commands = @('import') }
    Tiering     = @{ Env = 'VCFOPS_SYNTH_TIERING'; Type = 'text'; Commands = @('import') }
    Performance = @{ Env = 'VCFOPS_SYNTH_PERFORMANCE'; Type = 'text'; Commands = @('import') }
    NoAnonymise = @{ Env = 'VCFOPS_SYNTH_NO_ANONYMISE'; Type = 'switch'; Commands = @('import') }
    Adapter     = @{ Env = 'VCFOPS_SYNTH_ADAPTER'; Type = 'text'; Commands = @('seed', 'backfill', 'feed', 'scenario', 'reset') }
    Refresh     = @{ Env = 'VCFOPS_SYNTH_REFRESH'; Type = 'switch'; Commands = @('seed') }
    Force       = @{ Env = 'VCFOPS_SYNTH_FORCE'; Type = 'switch'; Commands = @('reset') }
    IncludeContent = @{ Env = 'VCFOPS_SYNTH_INCLUDE_CONTENT'; Type = 'switch'; Commands = @('reset') }
    ApplianceSsh = @{ Env = 'VCFOPS_SYNTH_APPLIANCE_SSH'; Type = 'text'; Commands = @('reset') }
    SshKey      = @{ Env = 'VCFOPS_SYNTH_SSH_KEY'; Type = 'text'; Commands = @('reset') }
    ImportField = @{ Env = 'VCFOPS_SYNTH_IMPORT_FIELD'; Type = 'text'; Commands = @('content') }
    DryRun      = @{ Env = 'VCFOPS_SYNTH_DRY_RUN'; Type = 'switch'; Commands = @('seed', 'backfill', 'content', 'feed', 'reset') }
    Days        = @{ Env = 'VCFOPS_SYNTH_DAYS'; Type = 'count'; Commands = @('backfill') }
    Kinds       = @{ Env = 'VCFOPS_SYNTH_KINDS'; Type = 'list'; Commands = @('backfill') }
    MaxVms      = @{ Env = 'VCFOPS_SYNTH_MAX_VMS'; Type = 'count'; Commands = @('backfill') }
    Concurrency = @{ Env = 'VCFOPS_SYNTH_CONCURRENCY'; Type = 'count'; Commands = @('backfill', 'feed') }
    MaxSamples  = @{ Env = 'VCFOPS_SYNTH_MAX_SAMPLES'; Type = 'count'; Commands = @('backfill') }
    Restart     = @{ Env = 'VCFOPS_SYNTH_RESTART'; Type = 'switch'; Commands = @('backfill') }
    Cycles      = @{ Env = 'VCFOPS_SYNTH_CYCLES'; Type = 'count'; Commands = @('feed') }
    Start       = @{ Env = 'VCFOPS_SYNTH_START'; Type = 'text'; Commands = @('scenario') }
    Stop        = @{ Env = 'VCFOPS_SYNTH_STOP'; Type = 'text'; Commands = @('scenario') }
    Target      = @{ Env = 'VCFOPS_SYNTH_TARGET'; Type = 'text'; Commands = @('scenario') }
    RampMinutes = @{ Env = 'VCFOPS_SYNTH_RAMP_MINUTES'; Type = 'count'; Commands = @('scenario') }
    # The module reads these variables itself, so only a parameter is passed on ('module').
    Fqdn             = @{ Env = 'VCFOPS_FQDN'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    Username         = @{ Env = 'VCFOPS_USERNAME'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    AuthSource       = @{ Env = 'VCFOPS_AUTHSOURCE'; Type = 'module'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    Password         = @{ Env = 'VCFOPS_PASSWORD'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    PasswordFile     = @{ Env = 'VCFOPS_PASSWORD_FILE'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    SecretName       = @{ Env = 'VCFOPS_SECRET_NAME'; Type = 'module'; Commands = @('connect-test', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
    CredentialFile   = @{ Env = 'VCFOPS_CREDENTIAL_FILE'; Type = 'text'; Commands = @('config', 'connect-test', 'plan', 'seed', 'backfill', 'content', 'feed', 'scenario', 'reset') }
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

function Get-CliSeededPlan {
    # Signs in, then the seed plan and the Operations ID of each planned object, for feed and scenario.
    param($Config, $Inventory, [switch]$NoIds)
    $adapterName = if ($options.Adapter) { $options.Adapter } else { $Config.seed.adapterInstance }
    if (-not $adapterName) { throw 'No adapter instance. Set seed.adapterInstance in lab.json or pass -Adapter <name> (VCFOPS_SYNTH_ADAPTER).' }
    $rubricPath = if ($Config.seed.rubrics) { $Config.seed.rubrics } else { Join-Path $Config.paths.data 'rubrics' }
    $rubrics = Get-SynthRubric -Path $rubricPath
    $null = Connect-Cli -Config $Config
    $target = Resolve-SynthSeedTarget -Name $adapterName
    $plan = (New-CliSeedPlan -Config $Config -Inventory $Inventory -Rubrics $rubrics -Target $target).Plan
    $ids = if ($NoIds) { @{} } else { Resolve-SynthPlanId -Plan $plan -AdapterInstanceId $target.AdapterInstanceId }
    @{ Plan = $plan; Ids = $ids; Adapter = $adapterName; Target = $target }
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

        'content' {
            $config = Get-CliConfig
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $groups = @(Get-SynthGroupDefinition -Inventory $inventory -Prefix $config.prefix -Tag $config.seed.tag)
            $sla = Get-SynthSla -Path $config.content.sla
            $alertContent = Get-SynthAlertContent -Prefix $config.prefix
            Write-Host ("Content for {0}: {1} custom groups, {2} symptoms, {3} recommendations, {4} alerts, {5} super metrics, 4 policies" -f $config.operations.fqdn, $groups.Count,
                $alertContent.Symptoms.Count, $alertContent.Recommendations.Count, $alertContent.Alerts.Count, $alertContent.SuperMetrics.Count)
            $null = Connect-Cli -Config $config
            $failed = 0
            try {
                $results = @(Publish-SynthGroup -Definition $groups -Prefix $config.prefix -WhatIf:([bool]$options.DryRun))
                foreach ($r in $results) { Write-Host ('  {0,-14} {1}' -f $r.Action, $r.Name) }
                $superMetricId = @{}
                foreach ($r in @(Publish-SynthAlertContent -Content $alertContent -Prefix $config.prefix -WhatIf:([bool]$options.DryRun))) {
                    Write-Host ('  {0,-14} {1,-14} {2}' -f $r.Action, $r.Kind, $r.Name)
                    if ($r.Error) { $failed++; Write-Host "    $($r.Error)" }
                    if ($r.Kind -eq 'super metric' -and $r.Id) { $superMetricId[$r.Name] = $r.Id }
                }
                # Policies after the alerts, so Synth-Base switches on the alerts this run created.
                $alerts = @((Invoke-SynthOpsRequest -Method Get -Path 'alertdefinitions' -Query @{ pageSize = 5000 }).alertDefinitions)
                $policies = @(Get-SynthPolicyDefinition -Sla $sla -AlertDefinition $alerts -Prefix $config.prefix)
                $groupIdByKey = @{}
                foreach ($g in $groups) {
                    $id = @($results | Where-Object Name -eq $g.Name)[0].Id
                    if ($g.Policy -and $id) { $groupIdByKey[$g.Policy] = @($id) }
                }
                Write-Host "Policies: Synth- alerts switched on in the base: $(@($policies[0].Alerts).Count)"
                foreach ($r in @(Publish-SynthPolicy -Definition $policies -GroupIdByKey $groupIdByKey -Prefix $config.prefix -WhatIf:([bool]$options.DryRun))) {
                    Write-Host ('  {0,-14} {1} (groups: {2})' -f $r.Action, $r.Name, $r.Groups)
                }

                # Views and reports go in through a content bundle; a view refers to a super metric by id.
                $viewContent = Get-SynthViewContent -Prefix $config.prefix -SuperMetricId $superMetricId
                $views = @($viewContent.Views | ForEach-Object { ConvertTo-SynthViewXml -Definition $_ })
                $reports = @($viewContent.Reports | ForEach-Object { ConvertTo-SynthReportXml -Definition $_ -View $viewContent.Views })
                # The signed-in user owns the content; a directory user's @domain is not part of the Operations user name.
                $ownerName = ([string]$config.operations.username) -replace '@.*$'
                $ownerId = Get-SynthOpsUserId -UserName $ownerName
                # Dashboards show the views on the estate group, so they need its id; a dry run that would create the group has none yet.
                $estate = @($groups | Where-Object { $_.Policy -eq 'Base' })[0]
                $estateId = if ($estate) { @($results | Where-Object Name -eq $estate.Name)[0].Id }
                $dashboards = @()
                if ($estateId) {
                    $dashboards = @(Get-SynthDashboardContent -Prefix $config.prefix | ForEach-Object {
                            ConvertTo-SynthDashboard -Definition $_ -OwnerId $ownerId -ResourceId $estateId -ResourceName $estate.Name -ResourceKind $estate.Type
                        })
                }
                $bundle = New-SynthContentBundle -Path (Join-Path $config.paths.data 'content-bundle.zip') -OwnerId $ownerId -UserName $ownerName -View $views -Report $reports -Dashboard $dashboards
                $verb = if ($options.DryRun) { 'would import' } else { 'import' }
                foreach ($v in $viewContent.Views) { Write-Host ('  {0,-14} {1,-14} {2}' -f $verb, 'view', $v.Name) }
                foreach ($r in $viewContent.Reports) { Write-Host ('  {0,-14} {1,-14} {2}' -f $verb, 'report', $r.Name) }
                foreach ($d in $dashboards) { Write-Host ('  {0,-14} {1,-14} {2}' -f $verb, 'dashboard', $d.name) }
                if (-not $estateId) { Write-Host "  Dashboards left out: the $($estate.Name) group does not exist yet, and they show their views on it." }
                Write-Host "  Bundle: $($bundle.Path) ($($bundle.Views) views, $($bundle.Reports) reports, $($bundle.Dashboards) dashboards)"
                if (-not $options.DryRun) {
                    $field = if ($options.ImportField) { $options.ImportField } else { 'contentFile' }
                    $import = Import-SynthContentBundle -Path $bundle.Path -Force -FieldName $field
                    Write-Host "  Import $($import.State.ToLowerInvariant())"
                    # Printed as Operations returns them: one summary per content type, with its counts.
                    foreach ($s in $import.Summaries) { Write-Host "    $($s | ConvertTo-Json -Depth 5 -Compress)" }
                    foreach ($m in $import.Errors) { Write-Host "    $m" }
                    if ($import.State -ne 'FINISHED' -or $import.Errors.Count) { $failed++ }
                }
                if ($options.DryRun) { Write-Host 'Dry run: nothing was changed in Operations.' }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            if ($failed) { Write-Host "$failed item(s) failed; the rest were published."; exit 1 }
            exit 0
        }

        'seed' {
            $config = Get-CliConfig
            $adapterName = if ($options.Adapter) { $options.Adapter } else { $config.seed.adapterInstance }
            if (-not $adapterName) { throw 'No adapter instance to seed under. Set seed.adapterInstance in lab.json or pass -Adapter <name> (VCFOPS_SYNTH_ADAPTER).' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath

            $null = Connect-Cli -Config $config
            try {
                $seedTarget = Resolve-SynthSeedTarget -Name $adapterName -Create:(-not $options.DryRun)
                if ($seedTarget.Created) { Write-Host "Created holder adapter instance '$adapterName'. Do not start it." }
                if ($seedTarget.Collecting) { Write-Host "Warning: '$adapterName' collects from a vCenter. When it restarts it marks every seeded object its vCenter lacks as not existing, and groups and policies leave them out. Seed under a holder instance instead (seed.adapterInstance)." }
                $built = New-CliSeedPlan -Config $config -Inventory $inventory -Rubrics $rubrics -Target $seedTarget
                $plan = $built.Plan
                Write-Host "Tags: $(($built.Tags | ForEach-Object { "$($_.Category): $($_.Name)" }) -join '; ')"
                $objects = @($plan.objects)
                Write-Host "Seed plan for adapter instance $adapterName ($($seedTarget.AdapterInstanceId)), vCenter $($seedTarget.VcId):"
                $objects | Group-Object { $_.kind } | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
                $edges = ($plan.links | ForEach-Object { @($_.children).Count } | Measure-Object -Sum).Sum
                Write-Host "  $($objects.Count) objects, $edges links"
                Write-Host "  Not created: $($plan.skipped.rootResourcePools) root resource pools (not shown in Operations)"
                if ($plan.skipped.userResourcePools) { Write-Host "  Not created yet: $($plan.skipped.userResourcePools) user-created resource pools" }
                if ($options.DryRun) {
                    Write-Host 'Dry run: nothing was created.'
                    exit 0
                }

                $result = Invoke-SynthSeed -Plan $plan -AdapterInstanceId $seedTarget.AdapterInstanceId -Refresh:$options.Refresh
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
            if (-not $adapterName) { throw 'No adapter instance to backfill under. Set seed.adapterInstance in lab.json or pass -Adapter <name> (VCFOPS_SYNTH_ADAPTER).' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath
            $days = if ($options.Days) { $options.Days } else { $config.backfillDays }
            $range = Get-SynthBackfillRange -Days $days -IntervalMinutes $config.intervalMinutes

            $null = Connect-Cli -Config $config
            try {
                $seedTarget = Resolve-SynthSeedTarget -Name $adapterName
                $plan = (New-CliSeedPlan -Config $config -Inventory $inventory -Rubrics $rubrics -Target $seedTarget).Plan
                if ($options.Kinds) {
                    $unknown = @($options.Kinds | Where-Object { $_ -notin @($plan.objects | ForEach-Object { $_.kind }) })
                    if ($unknown.Count) { Write-Host "No planned objects of kind $($unknown -join ', '). Run 'help' for usage."; exit 2 }
                    $plan.objects = @($plan.objects | Where-Object { $_.kind -in $options.Kinds })
                }
                if ($options.MaxVms) {
                    $keep = @($plan.objects | Where-Object { $_.kind -eq 'VirtualMachine' } | Sort-Object { $_.key } | Select-Object -First $options.MaxVms | ForEach-Object { $_.key })
                    $plan.objects = @($plan.objects | Where-Object { $_.kind -ne 'VirtualMachine' -or $_.key -in $keep })
                }
                $ids = Resolve-SynthPlanId -Plan $plan -AdapterInstanceId $seedTarget.AdapterInstanceId
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
                $result = Invoke-SynthBackfill -Spec $spec -Range $range -StatePath $config.paths.state -TimeZone $config.timeZone -Concurrency $(if ($options.Concurrency) { $options.Concurrency } else { 4 }) -MaxSamplesPerCall $(if ($options.MaxSamples) { $options.MaxSamples } else { 100000 }) -Verbose
                Write-Host ('  {0} objects pushed, {1:N0} samples in {2:N0} calls, {3} s ({4:N0} samples/s); {5} already done; {6} posts halved after a refusal; {7} objects had a post refused; {8} answered but not stored' -f $result.objects, $result.samples, $result.calls, $result.seconds, $(if ($result.seconds) { $result.samples / $result.seconds } else { 0 }), $result.skipped, $result.splits, $result.refused.Count, $result.unstored)
                foreach ($failure in $result.failed) { Write-Host "Failed: $failure" }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            exit $(if ($result.failed.Count) { 1 } else { 0 })
        }

        'feed' {
            $config = Get-CliConfig
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            try {
                $seeded = Get-CliSeededPlan -Config $config -Inventory $inventory
                $step = $config.intervalMinutes * 60000
                # The backfill's own range, so the live points carry on at the levels it set.
                $range = Get-SynthBackfillRange -Days $config.backfillDays -IntervalMinutes $config.intervalMinutes
                $range = (Read-SynthBackfillState -Path $config.paths.state -Range $range).range
                $concurrency = if ($options.Concurrency) { $options.Concurrency } else { 8 }
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $feed = [VcfOpsSynth.FeedObject[]]@(New-SynthFeedObject -Plan $seeded.Plan -Inventory $inventory -Ids $seeded.Ids -Range $range -TimeZone $config.timeZone -Concurrency $concurrency)
                $series = ($feed | ForEach-Object { $_.Spec.Series.Count } | Measure-Object -Sum).Sum
                Write-Host ('Feed for adapter instance {0}: {1} objects, {2:N0} series every {3} minutes (prepared in {4:N0} s)' -f $seeded.Adapter, $feed.Count, $series, $config.intervalMinutes, $clock.Elapsed.TotalSeconds)
                $running = @(Read-SynthScenarioState -Path $config.paths.state)
                foreach ($s in $running) { Write-Host "  Scenario $($s.id) $($s.name) on $($s.targetName)" }
                $state = if (Test-Path -LiteralPath $config.paths.state) { Get-Content -LiteralPath $config.paths.state -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
                $last = if ($state -and $state.ContainsKey('feed') -and $state.feed.lastMs) { [long]$state.feed.lastMs } elseif ($state -and $state.ContainsKey('backfill')) { [long]$state.backfill.range.EndMs } else { 0 }
                $times = Get-SynthFeedTime -LastMs $last -StepMs $step
                Write-Host ('  Next point {0:u}; {1} catch-up points first' -f [DateTimeOffset]::FromUnixTimeMilliseconds($times.Live), $times.CatchUp.Count)
                if ($options.DryRun) {
                    Write-Host 'Dry run: nothing was pushed.'
                    exit 0
                }
                $result = Invoke-SynthFeed -Feed $feed -Inventory $inventory -Plan $seeded.Plan -StatePath $config.paths.state -StepMs $step -TimeZone $config.timeZone -Cycles $(if ($options.Cycles) { $options.Cycles } else { 0 }) -Concurrency $concurrency -Verbose
                Write-Host ('  {0} cycles, {1:N0} samples, {2} failed pushes' -f $result.cycles, $result.samples, $result.failed)
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            exit $(if ($result.failed) { 1 } else { 0 })
        }

        'scenario' {
            $config = Get-CliConfig
            $catalogue = Get-SynthScenarioCatalogue
            if ($options.Start -and $options.Stop) { Write-Host "Give -Start or -Stop, not both. Run 'help' for usage."; exit 2 }
            $wanted = if ($options.Start) { $options.Start } elseif ($options.Stop) { $options.Stop } else { $null }
            if ($wanted -and -not $catalogue.Contains($wanted.ToUpperInvariant()) -and -not ($options.Stop -and $wanted -ieq 'all')) {
                Write-Host "Unknown scenario '$wanted'. Scenarios: $($catalogue.Keys -join ', ')."
                exit 2
            }
            if ($options.Target -and -not $options.Start) { Write-Host "-Target goes with -Start. Run 'help' for usage."; exit 2 }
            if (-not $wanted) {
                foreach ($id in $catalogue.Keys) { Write-Host ('  {0}  {1,-20} {2}' -f $id, $catalogue[$id].Name, $catalogue[$id].Description) }
                $running = @(Read-SynthScenarioState -Path $config.paths.state)
                Write-Host ''
                if ($running.Count) { foreach ($s in $running) { Write-Host ('Running: {0} {1} on {2} since {3:u}' -f $s.id, $s.name, $s.targetName, [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s.startedMs)) } }
                else { Write-Host 'No scenario is running.' }
                exit 0
            }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            try {
                $seeded = Get-CliSeededPlan -Config $config -Inventory $inventory
                if ($options.Start) {
                    $ramp = if ($options.RampMinutes) { $options.RampMinutes } else { 10 }
                    $s = Start-SynthScenario -Id $options.Start -Inventory $inventory -Plan $seeded.Plan -StatePath $config.paths.state -Target $options.Target -RampMinutes $ramp -Ids $seeded.Ids
                    Write-Host "Started $($s.id) $($s.name) on $($s.targetName), full effect after $ramp minutes. The feed applies it from its next cycle."
                }
                else {
                    $stopped = @(Stop-SynthScenario -Id $options.Stop -Inventory $inventory -Plan $seeded.Plan -StatePath $config.paths.state -Ids $seeded.Ids)
                    if ($stopped.Count) { foreach ($s in $stopped) { Write-Host "Stopped $($s.id) $($s.name) on $($s.targetName)." } }
                    else { Write-Host "$($options.Stop) is not running." }
                }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            exit 0
        }

        'reset' {
            $config = Get-CliConfig
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $report = -not $options.Force -or $options.DryRun
            $failed = 0
            try {
                $seeded = Get-CliSeededPlan -Config $config -Inventory $inventory -NoIds
                $tag = "$($config.seed.tag.category)-$($config.seed.tag.name)"
                $found = @(Get-SynthSeededObject -Plan $seeded.Plan -AdapterInstanceId $seeded.Target.AdapterInstanceId -Tag $tag)
                Write-Host "Reset under adapter instance $($seeded.Adapter): $($found.Count) of $(@($seeded.Plan.objects).Count) planned objects found, $(@($found | Where-Object Tagged).Count) with the $tag tag"
                $results = @(Remove-SynthSeededObject -Object $found -WhatIf:$report -Confirm:$false)
                foreach ($group in ($results | Group-Object Kind)) {
                    $counts = ($group.Group | Group-Object Action | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
                    Write-Host ('  {0,-32} {1}' -f $group.Name, $counts)
                }
                # Ids only: an untagged object's name may be a real one.
                foreach ($r in @($results | Where-Object Action -eq 'untagged')) { Write-Host "  Left alone, no synthetic tag: $($r.Kind) $($r.Id)" }
                foreach ($r in @($results | Where-Object Action -eq 'failed')) { $failed++; Write-Host "  Failed: $($r.Kind) $($r.Id): $($r.Error)" }
                if ($options.IncludeContent) {
                    foreach ($r in @(Remove-SynthContent -Prefix $config.prefix -WhatIf:$report -Confirm:$false)) {
                        Write-Host ('  {0,-14} {1,-14} {2}' -f $r.Action, $r.Kind, $r.Name)
                        if ($r.Error) { $failed++; Write-Host "    $($r.Error)" }
                    }
                    # The API cannot delete views, reports or dashboards; ops-cli on the appliance can, by name.
                    # Dashboards belong to the user content imported them as.
                    $owner = ([string]$config.operations.username) -replace '@.*$'
                    if ($options.ApplianceSsh) {
                        foreach ($r in @(Remove-SynthApplianceContent -Prefix $config.prefix -SshTarget $options.ApplianceSsh -IdentityFile (Resolve-SynthSshKey -SshKey $options.SshKey) -Owner $owner -WhatIf:$report -Confirm:$false)) {
                            Write-Host ('  {0,-14} {1,-14} {2}' -f $r.Action, $r.Kind, $r.Name)
                            if ($r.Error) { $failed++; Write-Host "    $($r.Error)" }
                        }
                    }
                    else {
                        $names = Get-SynthContentName -Prefix $config.prefix
                        $payload = Save-SynthContentDeletePayload -Prefix $config.prefix -Path (Join-Path $config.paths.data 'content-delete.json') -Owner $owner -Confirm:$false
                        Write-Host '  Views, reports and dashboards cannot be deleted through the API. Add -ApplianceSsh to delete them with ops-cli, or delete these in the UI:'
                        foreach ($kind in 'View', 'Report', 'Dashboard') { foreach ($n in $names.$kind) { Write-Host ('    {0,-14} {1}' -f $kind.ToLowerInvariant(), $n) } }
                        Write-Host "  Or copy $payload and bin/ops-content-delete.py to the appliance and run there: `$VMWARE_PYTHON_BIN ops-content-delete.py content-delete.json --apply"
                    }
                }
                if ($report) { Write-Host 'Report only: nothing was deleted. Add -Force to delete.' }
                else { Clear-SynthState -Path $config.paths.state -Confirm:$false }
            }
            finally {
                Disconnect-SynthOps -Confirm:$false
            }
            exit $(if ($failed) { 1 } else { 0 })
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
