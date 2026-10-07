# Pester 5 tests for configuration loading and validation. No lab needed.
#   Invoke-Pester -Path ./tests

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:example = Join-Path $PSScriptRoot '../config/lab.example.json'

    function New-LabFile {
        param([hashtable]$Content)
        $path = Join-Path $TestDrive "lab-$([guid]::NewGuid()).json"
        $Content | ConvertTo-Json -Depth 10 | Set-Content -Path $path
        $path
    }
}

Describe 'Get-SynthConfig' {
    BeforeEach {
        foreach ($name in 'VCFOPS_FQDN', 'VCFOPS_USERNAME', 'VCFOPS_AUTHSOURCE') {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    It 'loads the shipped example without problems' {
        $config = Get-SynthConfig -Path $script:example
        $config.operations.fqdn | Should -Be 'ops-a.site-a.vcf.lab'
        $config.backfillDays | Should -Be 30
    }

    It 'fills in defaults for values the file leaves out' {
        $path = New-LabFile @{ operations = @{ fqdn = 'ops.example.test' } }
        $config = Get-SynthConfig -Path $path
        $config.operations.username | Should -Be 'admin'
        $config.operations.authSource | Should -Be 'LOCAL'
        $config.adapterKind.key | Should -Be 'VcfOpsSynth'
        $config.intervalMinutes | Should -Be 5
        $config.liveLoad.enabled | Should -BeFalse
    }

    It 'lets environment variables override the file' {
        $path = New-LabFile @{ operations = @{ fqdn = 'ops.example.test'; username = 'admin' } }
        $env:VCFOPS_FQDN = 'other.example.test'
        $env:VCFOPS_USERNAME = 'svc-synth'
        $config = Get-SynthConfig -Path $path
        $config.operations.fqdn | Should -Be 'other.example.test'
        $config.operations.username | Should -Be 'svc-synth'
    }

    It 'names the missing file and how to create it' {
        { Get-SynthConfig -Path (Join-Path $TestDrive 'absent.json') } | Should -Throw '*lab.example.json*'
    }

    It 'reports invalid JSON' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -Path $path -Value '{ "operations": '
        { Get-SynthConfig -Path $path } | Should -Throw '*not valid JSON*'
    }

    It 'refuses an invalid file unless validation is skipped' {
        $path = New-LabFile @{ operations = @{ fqdn = '' } }
        { Get-SynthConfig -Path $path } | Should -Throw '*operations.fqdn is empty*'
        (Get-SynthConfig -Path $path -SkipValidation).operations.fqdn | Should -Be ''
    }
}

Describe 'Test-SynthConfig' {
    BeforeAll {
        function Get-ValidConfig { Get-SynthConfig -Path $script:example }
    }

    It 'returns nothing for a valid configuration' {
        @(Test-SynthConfig -Config (Get-ValidConfig)).Count | Should -Be 0
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a URL as the FQDN';        Set = { param($c) $c.operations.fqdn = 'https://ops.example.test' };  Expect = '*host name only*' }
        @{ Name = 'an adapter key with dashes'; Set = { param($c) $c.adapterKind.key = 'vcf-ops-synth' };           Expect = '*adapterKind.key*' }
        @{ Name = 'an empty prefix';          Set = { param($c) $c.prefix = '' };                                  Expect = '*prefix is empty*' }
        @{ Name = 'a 7-minute interval';      Set = { param($c) $c.intervalMinutes = 7 };                          Expect = '*intervalMinutes*' }
        @{ Name = 'a year and a day of history'; Set = { param($c) $c.backfillDays = 366 };                        Expect = '*backfillDays*' }
        @{ Name = 'fractional history';       Set = { param($c) $c.backfillDays = 1.5 };                           Expect = '*backfillDays*' }
        @{ Name = 'an unknown time zone';     Set = { param($c) $c.timeZone = 'Mars/Olympus_Mons' };               Expect = '*timeZone*' }
        @{ Name = 'a short timeout';          Set = { param($c) $c.operations.timeoutSeconds = 2 };                Expect = '*timeoutSeconds*' }
        @{ Name = 'negative live-load caps';  Set = { param($c) $c.liveLoad.maxLoadVms = -1 };                     Expect = '*liveLoad*' }
    ) {
        $config = Get-ValidConfig
        & $Set $config
        (Test-SynthConfig -Config $config) -join "`n" | Should -BeLike $Expect
    }
}

Describe 'Get-SynthSecret' {
    BeforeEach {
        Remove-Item Env:VCFOPS_PASSWORD, Env:VCFOPS_PASSWORD_FILE -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item Env:VCFOPS_PASSWORD, Env:VCFOPS_PASSWORD_FILE -ErrorAction SilentlyContinue
    }

    It 'prefers VCFOPS_PASSWORD' {
        $env:VCFOPS_PASSWORD = 'from-env'
        InModuleScope VcfOpsSynth { ConvertFrom-SecureString (Get-SynthSecret) -AsPlainText } | Should -Be 'from-env'
    }

    It 'reads a Docker secret file and drops the trailing newline' {
        $file = Join-Path $TestDrive 'vcfops_password'
        Set-Content -Path $file -Value 'from-file'
        $env:VCFOPS_PASSWORD_FILE = $file
        InModuleScope VcfOpsSynth { ConvertFrom-SecureString (Get-SynthSecret) -AsPlainText } | Should -Be 'from-file'
    }

    It 'returns nothing when neither is set' {
        InModuleScope VcfOpsSynth { Get-SynthSecret } | Should -BeNullOrEmpty
    }
}
