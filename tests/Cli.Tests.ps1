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

    It 'rejects arguments a command does not take' {
        $result = Invoke-Cli @('version', 'extra')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike '*takes no further arguments*extra*'
    }

    Context 'import' {
        BeforeAll {
            $script:fixture = Join-Path $PSScriptRoot 'fixtures/rvtools-4x'
            $script:lab = Join-Path $TestDrive 'lab.json'
            $script:inventoryPath = Join-Path $TestDrive 'data/inventory.json'
            $labConfig = Get-Content -Path $script:example -Raw | ConvertFrom-Json -AsHashtable
            $labConfig.paths.data = Join-Path $TestDrive 'data'
            $labConfig.paths.inventory = $script:inventoryPath
            $labConfig.import.tiering = Join-Path $PSScriptRoot '../config/tiering.example.json'
            $labConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:lab
        }

        It 'writes an anonymised inventory and summarises it' {
            $result = Invoke-Cli @('import', $script:fixture, '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeLike '*8 VMs (7 powered on) on 3 hosts*'
            $result.Output | Should -BeLike '*Tiers: Gold 2, Silver 3, Bronze 3*'
            $result.Output | Should -BeLike '*Skipped 2 row(s): 1 no VM name, 1 template.*'
            (Get-Content -Path $script:inventoryPath -Raw) | Should -Not -Match 'app-pay-01'
            Test-Path (Join-Path $TestDrive 'data/anonymise.key') | Should -BeTrue
        }

        It 'keeps real names with --no-anonymise and says so' {
            $output = Join-Path $TestDrive 'named.json'
            $result = Invoke-Cli @('import', $script:fixture, '--no-anonymise', '--output', $output, '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeLike '*Real names were kept*'
            (Get-Content -Path $output -Raw) | Should -Match 'app-pay-01'
        }

        It 'shows the inventory in the plan' {
            $result = Invoke-Cli @('plan', '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeLike '*Seed:        16 objects*'
            $result.Output | Should -BeLike '*about 138,240 samples per metric*'
        }

        It 'rejects an unknown option' {
            $result = Invoke-Cli @('import', '--frobnicate', '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 2
            $result.Output | Should -BeLike "*Unknown option '--frobnicate'*"
        }

        It 'fails clearly when the export is missing' {
            $result = Invoke-Cli @('import', (Join-Path $TestDrive 'absent.xlsx'), '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 1
            $result.Output | Should -BeLike '*was not found*'
        }
    }

    It 'rejects an unknown command' {
        (Invoke-Cli @('frobnicate')).ExitCode | Should -Be 2
    }
}
