# Pester 5 tests for the container entrypoint, run as a separate pwsh process the way Docker runs it.

BeforeAll {
    $script:cli = Join-Path $PSScriptRoot '../bin/vcfops-synth.ps1'
    $script:example = Join-Path $PSScriptRoot '../config/lab.example.json'

    function Invoke-Cli {
        param([string[]]$CliArgs)
        $output = & pwsh -NoProfile -NonInteractive -File $script:cli @CliArgs 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}

Describe 'vcfops-synth CLI' {
    It 'shows help by default' {
        $result = Invoke-Cli @()
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*Commands available now*'
    }

    It 'prints its version' {
        $result = Invoke-Cli @('version')
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^vcfops-synth \d+\.\d+\.\d+'
    }

    It 'validates the example configuration' {
        $result = Invoke-Cli @('config', '-ConfigPath', $script:example)
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*Configuration is valid.*'
    }

    It 'lists every problem in a bad configuration and fails' {
        $bad = Join-Path $TestDrive 'bad.json'
        '{ "operations": { "fqdn": "" }, "intervalMinutes": 7 }' | Set-Content -Path $bad
        $result = Invoke-Cli @('config', '-ConfigPath', $bad)
        $result.ExitCode | Should -Be 1
        $result.Output | Should -BeLike '*2 problem(s) found*'
    }

    It 'plans a dry run from the example configuration' {
        $result = Invoke-Cli @('plan', '-ConfigPath', $script:example)
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*8640 samples per metric per object*'
    }

    It 'names the phase for a command not built yet' {
        $result = Invoke-Cli @('backfill')
        $result.ExitCode | Should -Be 3
        $result.Output | Should -BeLike '*Phase 4*'
    }

    It 'rejects an unknown command' {
        (Invoke-Cli @('frobnicate')).ExitCode | Should -Be 2
    }
}
