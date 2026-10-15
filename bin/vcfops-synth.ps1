<#
.SYNOPSIS
    Command-line entry point for the vcfops-synth container.

.DESCRIPTION
    Builds a synthetic estate in VCF Operations from an RVTools export and pushes
    history, live metrics and Day-2 content to it through the Suite API. The image
    runs this script as its entrypoint, so the first argument to `docker run` is the
    command:

        docker run --rm -v ./config:/config -e VCFOPS_PASSWORD ghcr.io/msherian/vcfops-synth <command>

    Commands available now:
        help              This text.
        version           Toolset and PowerShell versions.
        config            Validates lab.json and prints the merged settings (password never shown).
        connect-test      Signs in to VCF Operations and prints its version.
        plan              Validates settings and lists what each stage will do. Dry run.
        import [source]   Reads an RVTools export into the inventory model.
                          source: an .xlsx, or a folder of RVTools CSV files
                          (default import.source in lab.json).
                          --output <path>    where to write the model (default paths.inventory)
                          --tiering <path>   tiering rules (default import.tiering)
                          --perf <path>      LiveOptics VMware workbook: per-VM and per-host
                                             averages and peaks (default import.performance)
                          --no-anonymise     keep real names; only for exports you may share as is
        seed              Creates the inventory in VCF Operations under a vCenter adapter instance,
                          foundations first: an optional Physical Data Center (seed.physicalDatacenter),
                          datacenters, clusters, datastores, hosts, distributed and standard switches,
                          port groups, VM folders and VMs. Objects keep their inventory names and carry
                          the seed.tag vSphere tag; VMWARE kinds get every metric and property of their
                          rubric. Standard switches and port groups go under the toolset's adapter kind.
                          Every relationship is worked out first, datacenters go under the vCenter, and
                          objects that already exist (by identifier) are skipped.
                          --adapter <name>   vCenter adapter instance (default seed.adapterInstance)
                          --dry-run          build and summarise the plan; create nothing
                          --refresh          also push planned properties and current stats to objects already there
        backfill          Pushes backfillDays of history at intervalMinutes for every numeric stat key of the
                          seeded objects, with analytics processing off. Keys with LiveOptics figures match
                          their average and peak; the rest follow each object's workload curve around its
                          current value, grow (space in use), stay flat (capacity) or stay at zero. A host,
                          cluster or datastore follows the sum of its VMs' curves. Resumes from paths.state.
                          --days <n>         days of history (default backfillDays)
                          --kinds <a,b>      only these kinds (VirtualMachine, HostSystem, ...)
                          --max-vms <n>      only the first n VMs by key, for a pilot
                          --concurrency <n>  objects posted at once (default 4)
                          --restart          forget saved progress and start over on a new range
                          --dry-run          count objects, series and samples; push nothing

    Commands still to come, by build phase:
        reset             Phase 3   Remove the objects seed created
        content           Phase 5-7 Groups, policies, alerts, dashboards
        feed, scenario    Phase 6   Live metrics and scenario overlays
        live-load         Phase 9   Optional UPSA and load VMs

.PARAMETER Command
    The command to run. Defaults to help.

.PARAMETER ConfigPath
    Path to lab.json. Defaults to $env:VCFOPS_SYNTH_CONFIG, then /config/lab.json.

.PARAMETER Arguments
    Further arguments for the command.

.EXAMPLE
    pwsh ./bin/vcfops-synth.ps1 config -ConfigPath ./config/lab.json

.NOTES
    Exit codes: 0 success, 1 failure, 2 unknown command or unexpected arguments,
    3 command not built yet.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [string]$ConfigPath = $(if ($env:VCFOPS_SYNTH_CONFIG) { $env:VCFOPS_SYNTH_CONFIG } else { '/config/lab.json' }),

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments
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

# Commands that read their own arguments; every other built command refuses them rather than ignore a typo.
$takesArguments = @('import', 'seed', 'backfill')

function Read-ImportArgument {
    param([string[]]$Argument)
    # Plain 'import' passes no arguments at all, and StrictMode refuses .Count on $null.
    if (-not $Argument) { $Argument = @() }
    $parsed = @{ Source = $null; Output = $null; Tiering = $null; Perf = $null; Anonymise = $null }
    for ($i = 0; $i -lt $Argument.Count; $i++) {
        $arg = $Argument[$i]
        switch -Regex ($arg) {
            '^--(output|tiering|perf)$' {
                if ($i + 1 -ge $Argument.Count) { throw [System.ArgumentException]::new("$arg needs a path.") }
                $parsed[(Get-Culture).TextInfo.ToTitleCase($Matches[1])] = $Argument[++$i]
                break
            }
            '^--no-anonymi[sz]e$' { $parsed.Anonymise = $false; break }
            '^--anonymi[sz]e$' { $parsed.Anonymise = $true; break }
            '^-' { throw [System.ArgumentException]::new("Unknown option '$arg' for import.") }
            default {
                if ($parsed.Source) { throw [System.ArgumentException]::new("import takes one source; got '$($parsed.Source)' and '$arg'.") }
                $parsed.Source = $arg
            }
        }
    }
    $parsed
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

function Read-BackfillArgument {
    param([string[]]$Argument)
    if (-not $Argument) { $Argument = @() }
    $parsed = @{ Days = $null; Kinds = @(); MaxVms = 0; Concurrency = 4; Restart = $false; DryRun = $false }
    $number = {
        param($name, $index)
        if ($index -ge $Argument.Count -or $Argument[$index] -notmatch '^\d+$' -or [int]$Argument[$index] -lt 1) { throw [System.ArgumentException]::new("$name needs a whole number of at least 1.") }
        [int]$Argument[$index]
    }
    for ($i = 0; $i -lt $Argument.Count; $i++) {
        $arg = $Argument[$i]
        switch -Regex ($arg) {
            '^--days$' { $parsed.Days = & $number $arg (++$i); break }
            '^--max-vms$' { $parsed.MaxVms = & $number $arg (++$i); break }
            '^--concurrency$' { $parsed.Concurrency = & $number $arg (++$i); break }
            '^--kinds$' {
                if ($i + 1 -ge $Argument.Count) { throw [System.ArgumentException]::new("$arg needs a comma-separated list of kinds.") }
                $parsed.Kinds = @($Argument[++$i] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                break
            }
            '^--restart$' { $parsed.Restart = $true; break }
            '^--dry-run$' { $parsed.DryRun = $true; break }
            default { throw [System.ArgumentException]::new("Unknown option '$arg' for backfill.") }
        }
    }
    $parsed
}

function Read-SeedArgument {
    param([string[]]$Argument)
    if (-not $Argument) { $Argument = @() }
    $parsed = @{ Adapter = $null; DryRun = $false; Refresh = $false }
    for ($i = 0; $i -lt $Argument.Count; $i++) {
        $arg = $Argument[$i]
        switch -Regex ($arg) {
            '^--adapter$' {
                if ($i + 1 -ge $Argument.Count) { throw [System.ArgumentException]::new("$arg needs an adapter instance name.") }
                $parsed.Adapter = $Argument[++$i]
                break
            }
            '^--dry-run$' { $parsed.DryRun = $true; break }
            '^--refresh$' { $parsed.Refresh = $true; break }
            default { throw [System.ArgumentException]::new("Unknown option '$arg' for seed.") }
        }
    }
    $parsed
}

try {
    if ($Arguments -and $Command.ToLowerInvariant() -notin $planned.Keys -and $Command.ToLowerInvariant() -notin $takesArguments) {
        Write-Host "'$Command' takes no further arguments; got: $($Arguments -join ' '). Run 'help' for usage."
        exit 2
    }

    switch ($Command.ToLowerInvariant()) {
        { $_ -in 'help', '-h', '--help' } {
            Show-Help
            exit 0
        }

        'version' {
            Write-Host "vcfops-synth $toolVersion (PowerShell $($PSVersionTable.PSVersion))"
            exit 0
        }

        'config' {
            $config = Get-SynthConfig -Path $ConfigPath -SkipValidation
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
            $config = Get-SynthConfig -Path $ConfigPath
            $session = Connect-SynthOps -Config $config
            $version = Get-SynthOpsVersion
            $release = if ($version.PSObject.Properties['releaseName']) { $version.releaseName } else { $version | ConvertTo-Json -Compress }
            Write-Host "Signed in to $($config.operations.fqdn) as $($config.operations.username)."
            Write-Host "VCF Operations: $release"
            if ($session.Expires) { Write-Host "Token valid until $($session.Expires.ToString('u'))." }
            Disconnect-SynthOps -Confirm:$false
            exit 0
        }

        'plan' {
            $config = Get-SynthConfig -Path $ConfigPath
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
            try { $options = Read-ImportArgument -Argument $Arguments }
            catch [System.ArgumentException] {
                Write-Host "$($_.Exception.Message) Run 'help' for usage."
                exit 2
            }
            $config = Get-SynthConfig -Path $ConfigPath
            $source = if ($options.Source) { $options.Source } else { $config.import.source }
            $output = if ($options.Output) { $options.Output } else { $config.paths.inventory }
            $anonymise = if ($null -ne $options.Anonymise) { $options.Anonymise } else { $config.import.anonymise }

            $tieringPath = if ($options.Tiering) { $options.Tiering } else { $config.import.tiering }
            if ($options.Tiering -and -not (Test-Path -LiteralPath $tieringPath)) {
                throw "Tiering file '$tieringPath' was not found."
            }
            if (-not (Test-Path -LiteralPath $tieringPath)) {
                Write-Host "No tiering rules at $tieringPath, so every VM is Bronze. Start from config/tiering.example.json."
            }
            $rules = Get-SynthTieringRule -Path $tieringPath

            $perfPath = if ($options.Perf) { $options.Perf } else { $config.import.performance }
            $perfData = if ($perfPath) { Read-SynthLiveOptics -Path $perfPath } else { $null }

            $key = Get-SynthAnonymisationKey -DataPath $config.paths.data
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
            try { $options = Read-SeedArgument -Argument $Arguments }
            catch [System.ArgumentException] {
                Write-Host "$($_.Exception.Message) Run 'help' for usage."
                exit 2
            }
            $config = Get-SynthConfig -Path $ConfigPath
            $adapterName = if ($options.Adapter) { $options.Adapter } else { $config.seed.adapterInstance }
            if (-not $adapterName) { throw 'No vCenter adapter instance to seed under. Set seed.adapterInstance in lab.json or pass --adapter <name>.' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath

            $null = Connect-SynthOps -Config $config
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
            try { $options = Read-BackfillArgument -Argument $Arguments }
            catch [System.ArgumentException] {
                Write-Host "$($_.Exception.Message) Run 'help' for usage."
                exit 2
            }
            $config = Get-SynthConfig -Path $ConfigPath
            $adapterName = $config.seed.adapterInstance
            if (-not $adapterName) { throw 'No vCenter adapter instance to backfill under. Set seed.adapterInstance in lab.json.' }
            $rubricPath = if ($config.seed.rubrics) { $config.seed.rubrics } else { Join-Path $config.paths.data 'rubrics' }
            $inventory = Get-SynthInventory -Path $config.paths.inventory
            $rubrics = Get-SynthRubric -Path $rubricPath
            $days = if ($options.Days) { $options.Days } else { $config.backfillDays }
            $range = Get-SynthBackfillRange -Days $days -IntervalMinutes $config.intervalMinutes

            $null = Connect-SynthOps -Config $config
            try {
                $target = Resolve-SynthSeedTarget -Name $adapterName
                $plan = (New-CliSeedPlan -Config $config -Inventory $inventory -Rubrics $rubrics -Target $target).Plan
                if ($options.Kinds.Count) {
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
                $result = Invoke-SynthBackfill -Spec $spec -Range $range -StatePath $config.paths.state -TimeZone $config.timeZone -Concurrency $options.Concurrency -Verbose
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
