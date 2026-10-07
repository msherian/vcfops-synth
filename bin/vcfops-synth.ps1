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

    Commands still to come, by build phase:
        import            Phase 2   RVTools export to inventory model
        seed, reset       Phase 3   Create and remove objects in VCF Operations
        backfill          Phase 4   Push generated history
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
    Exit codes: 0 success, 1 failure, 2 unknown command, 3 command not built yet.
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
    'import'    = 2
    'seed'      = 3
    'reset'     = 3
    'backfill'  = 4
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

try {
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
            Write-Host 'No RVTools inventory is loaded yet (import arrives in Phase 2), so nothing would be created.'
            exit 0
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
