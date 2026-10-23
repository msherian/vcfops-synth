# Pester 5 tests for the container entrypoint, run as a separate pwsh process the way Docker runs it.

BeforeAll {
    $script:cli = Join-Path $PSScriptRoot '../bin/vcfops-synth.ps1'
    $script:example = Join-Path $PSScriptRoot '../config/lab.example.json'

    # Runs the CLI as Docker does; Environment sets variables for that run only, as `docker run -e` would.
    function Invoke-Cli {
        param([string[]]$CliArgs, [hashtable]$Environment = @{})
        $saved = @{}
        foreach ($name in $Environment.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
        try { $output = & pwsh -NoProfile -NonInteractive -File $script:cli @CliArgs 2>&1 }
        finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
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

    It 'adds the image version and short revision when run in the image' {
        $result = Invoke-Cli @('version') -Environment @{ VCFOPS_SYNTH_IMAGE_VERSION = '0.1.1'; VCFOPS_SYNTH_IMAGE_REVISION = '9cc7e5910218bd9c141b79bba4663ca68486e0c8' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*image 0.1.1 (revision 9cc7e59)*'
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
        $result = Invoke-Cli @('live-load')
        $result.ExitCode | Should -Be 3
        $result.Output | Should -BeLike '*Phase 9*'
    }

    It 'lists the scenarios and that none is running, without signing in' {
        $config = Join-Path $TestDrive 'lab.json'
        $lab = Get-Content -LiteralPath $script:example -Raw | ConvertFrom-Json -AsHashtable
        $lab.paths = @{ data = "$TestDrive"; state = (Join-Path $TestDrive 'state.json'); inventory = (Join-Path $TestDrive 'inventory.json') }
        $lab | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
        $result = Invoke-Cli @('scenario', '-ConfigPath', $config)
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*S1*noisy-neighbour*S8*host-failure*No scenario is running.*'
    }

    It 'refuses an unknown scenario, -Target without -Start, and scenario options on other commands' {
        (Invoke-Cli @('scenario', '-Start', 'S9', '-ConfigPath', $script:example)).Output | Should -BeLike "*Unknown scenario 'S9'*"
        (Invoke-Cli @('scenario', '-Start', 'S9', '-ConfigPath', $script:example)).ExitCode | Should -Be 2
        (Invoke-Cli @('scenario', '-Target', 'x', '-ConfigPath', $script:example)).ExitCode | Should -Be 2
        (Invoke-Cli @('feed', '-Start', 'S1')).Output | Should -BeLike "*'feed' does not take -Start*"
    }

    It 'builds seed now, so it no longer reports Phase 3' {
        $result = Invoke-Cli @('seed', '-Bogus')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*Unexpected argument(s) for 'seed': -Bogus*"
        $result.Output | Should -Not -BeLike '*not built yet*'
    }

    It 'refuses --options as unknown and names the parameter meant' {
        $result = Invoke-Cli @('backfill', '--dry-run', '--max-vms', '5')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*Unknown option '--dry-run'. Did you mean -DryRun?*Unknown option '--max-vms'. Did you mean -MaxVms?*"
    }

    It 'refuses a --option that pwsh -File would otherwise bind to its parameter' {
        # pwsh -File binds --concurrency 4 as -Concurrency 4; it must still be refused.
        $result = Invoke-Cli @('backfill', '-DryRun', '--concurrency', '4')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*Unknown option '--concurrency'. Did you mean -Concurrency?*"
    }

    It 'refuses a --option given to the script directly, where it lands in -Source' {
        $output = & $script:cli backfill -DryRun --concurrency 4 6>&1
        $LASTEXITCODE | Should -Be 2
        ($output -join "`n") | Should -BeLike "*Unknown option '--concurrency'. Did you mean -Concurrency?*"
    }

    It 'refuses --help, pointing at help' {
        $result = Invoke-Cli @('--help')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*Unknown option '--help'. Did you mean 'help'?*"
    }

    It 'refuses a parameter the command does not take' {
        $result = Invoke-Cli @('config', '-Adapter', 'vc-01', '-ConfigPath', $script:example)
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*'config' does not take -Adapter*"
    }

    It 'checks numbers and switches, whether a parameter or a variable' {
        $result = Invoke-Cli @('backfill', '-Days', 'thirty')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*-Days needs a whole number of at least 1; got 'thirty'*"
        $result = Invoke-Cli @('seed') -Environment @{ VCFOPS_SYNTH_DRY_RUN = 'maybe' }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*VCFOPS_SYNTH_DRY_RUN must be true or false; got 'maybe'*"
    }

    It 'takes the command from VCFOPS_SYNTH_COMMAND, as a container would' {
        $result = Invoke-Cli @() -Environment @{ VCFOPS_SYNTH_COMMAND = 'version' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match '^vcfops-synth \d+\.\d+\.\d+'
    }

    It 'takes the host and account from -CredentialFile, with single values winning in the same tier' {
        $creds = Join-Path $TestDrive 'creds.json'
        @{ components = @(@{ componentName = 'VCF Operations'; FQDN = 'ops-creds.example.test'
                    credentials = @(@{ type = 'Administrator credentials'; user = 'creds-admin'; password = 'not-shown-1' }) }) } |
            ConvertTo-Json -Depth 10 | Set-Content -Path $creds
        # The parameter beats lab.json and the variables.
        $result = Invoke-Cli @('config', '-CredentialFile', $creds, '-ConfigPath', $script:example) -Environment @{ VCFOPS_FQDN = 'ops-env.example.test' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*ops-creds.example.test*'
        $result.Output | Should -BeLike '*creds-admin*'
        $result.Output | Should -Not -BeLike '*not-shown-1*'
        # -Fqdn beats the file among parameters.
        $result = Invoke-Cli @('config', '-CredentialFile', $creds, '-Fqdn', 'ops-param.example.test', '-ConfigPath', $script:example)
        $result.Output | Should -BeLike '*ops-param.example.test*'
        $result.Output | Should -BeLike '*creds-admin*'
        # VCFOPS_FQDN beats VCFOPS_CREDENTIAL_FILE among variables.
        $result = Invoke-Cli @('config', '-ConfigPath', $script:example) -Environment @{ VCFOPS_CREDENTIAL_FILE = $creds; VCFOPS_FQDN = 'ops-env.example.test' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*ops-env.example.test*'
        $result.Output | Should -BeLike '*creds-admin*'
    }
    It 'takes the sign-in settings as parameters, and keeps the password out of commands that do not sign in' {
        $result = Invoke-Cli @('config', '-Fqdn', 'ops-param.example.test', '-ConfigPath', $script:example) -Environment @{ VCFOPS_FQDN = 'ops-env.example.test' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeLike '*ops-param.example.test*'
        $result.Output | Should -Not -BeLike '*ops-env.example.test*'
        $result = Invoke-Cli @('config', '-SecretName', 'vcfops_password', '-ConfigPath', $script:example)
        $result.ExitCode | Should -Be 2
        $result.Output | Should -BeLike "*'config' does not take -SecretName*"
    }

    It 'ignores variables meant for other commands' {
        $result = Invoke-Cli @('config', '-ConfigPath', $script:example) -Environment @{ VCFOPS_SYNTH_ADAPTER = 'vc-01'; VCFOPS_SYNTH_DAYS = 'not a number' }
        $result.ExitCode | Should -Be 0
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

        It 'keeps real names with -NoAnonymise and says so' {
            $output = Join-Path $TestDrive 'named.json'
            $result = Invoke-Cli @('import', $script:fixture, '-NoAnonymise', '-Output', $output, '-ConfigPath', $script:lab)
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

        It 'reads import.source from lab.json when no source is given' {
            $labConfig = Get-Content -Path $script:lab -Raw | ConvertFrom-Json -AsHashtable
            $labConfig.import.source = $script:fixture
            $defaultLab = Join-Path $TestDrive 'lab-default-source.json'
            $labConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $defaultLab
            $result = Invoke-Cli @('import', '-ConfigPath', $defaultLab)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeLike '*8 VMs (7 powered on) on 3 hosts*'
        }

        It 'joins LiveOptics performance with -Performance' -Skip:(-not (Get-Module -ListAvailable -Name ImportExcel)) {
            Import-Module ImportExcel -WarningAction SilentlyContinue
            $perf = Join-Path $TestDrive 'liveoptics.xlsx'
            [pscustomobject]@{ 'VM Name' = 'app-pay-01'; 'MOB ID' = 'vm-1001'; 'Average vCPU %' = 30; 'Peak vCPU %' = 90 } |
                Export-Excel -Path $perf -WorksheetName 'VM Performance'
            [pscustomobject]@{ Host = 'esx01.example.test'; 'Average CPU %' = 35; 'Peak CPU %' = 80 } |
                Export-Excel -Path $perf -WorksheetName 'ESX Performance'
            $output = Join-Path $TestDrive 'with-perf.json'
            $result = Invoke-Cli @('import', $script:fixture, '-Performance', $perf, '-Output', $output, '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeLike '*Performance: LiveOptics for 1 of 8 VMs and 1 of 3 hosts*'
        }

        It 'rejects an unknown option' {
            $result = Invoke-Cli @('import', '-Frobnicate', '-ConfigPath', $script:lab)
            $result.ExitCode | Should -Be 2
            $result.Output | Should -BeLike "*Unexpected argument(s) for 'import': -Frobnicate*"
        }

        It 'takes the anonymisation key as -AnonymisationKey, the same as VCFOPS_SYNTH_ANON_KEY' {
            $byParam = Join-Path $TestDrive 'key-param.json'
            $byEnv = Join-Path $TestDrive 'key-env.json'
            (Invoke-Cli @('import', $script:fixture, '-AnonymisationKey', 'k-1', '-Output', $byParam, '-ConfigPath', $script:lab)).ExitCode | Should -Be 0
            (Invoke-Cli @('import', $script:fixture, '-Output', $byEnv, '-ConfigPath', $script:lab) -Environment @{ VCFOPS_SYNTH_ANON_KEY = 'k-1' }).ExitCode | Should -Be 0
            $ids = { param($f) ((Get-Content $f -Raw | ConvertFrom-Json).vms | ForEach-Object id | Sort-Object) -join ',' }
            & $ids $byParam | Should -Be (& $ids $byEnv)
        }

        It 'reads its paths from VCFOPS_SYNTH_* variables, and a parameter wins over its variable' {
            $fromEnv = Join-Path $TestDrive 'from-env.json'
            $result = Invoke-Cli @('import', '-ConfigPath', $script:lab) -Environment @{ VCFOPS_SYNTH_SOURCE = $script:fixture; VCFOPS_SYNTH_OUTPUT = $fromEnv; VCFOPS_SYNTH_NO_ANONYMISE = 'true' }
            $result.ExitCode | Should -Be 0
            (Get-Content -Path $fromEnv -Raw) | Should -Match 'app-pay-01'
            $fromParam = Join-Path $TestDrive 'from-param.json'
            $result = Invoke-Cli @('import', '-Output', $fromParam, '-ConfigPath', $script:lab) -Environment @{ VCFOPS_SYNTH_SOURCE = $script:fixture; VCFOPS_SYNTH_OUTPUT = (Join-Path $TestDrive 'not-this.json') }
            $result.ExitCode | Should -Be 0
            Test-Path $fromParam | Should -BeTrue
            Test-Path (Join-Path $TestDrive 'not-this.json') | Should -BeFalse
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
