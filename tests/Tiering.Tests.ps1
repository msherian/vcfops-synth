# Pester 5 tests for tiering rules and profile assignment. No lab needed.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that writes into the Pester TestDrive.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force

    function New-TieringFile {
        param([hashtable]$Content)
        $path = Join-Path $TestDrive "tiering-$([guid]::NewGuid()).json"
        $Content | ConvertTo-Json -Depth 10 | Set-Content -Path $path
        $path
    }
}

Describe 'Get-SynthTieringRule' {
    It 'returns the defaults when there is no file' {
        $rules = Get-SynthTieringRule -Path (Join-Path $TestDrive 'absent.json')
        $rules.defaultTier | Should -Be 'Bronze'
        @($rules.rules).Count | Should -Be 0
        $rules.profiles.idleCpuPct | Should -Be 5
    }

    It 'loads the shipped example' {
        $rules = Get-SynthTieringRule -Path (Join-Path $PSScriptRoot '../config/tiering.example.json')
        @($rules.rules).Count | Should -BeGreaterThan 0
    }

    It 'keeps default thresholds the file leaves out' {
        $rules = Get-SynthTieringRule -Path (New-TieringFile @{ profiles = @{ idleCpuPct = 2 } })
        $rules.profiles.idleCpuPct | Should -Be 2
        $rules.profiles.saturatedCpuPct | Should -Be 80
    }

    It 'lists every problem in a bad file' {
        $path = New-TieringFile @{
            defaultTier = 'Platinum'
            rules       = @(
                @{ match = @{ cluster = '^PROD' }; tier = 'Copper' }
                @{ match = @{ colour = 'red' }; tier = 'Gold' }
                @{ match = @{ name = '(' }; profile = 'busy' }
                @{ tier = 'Gold' }
                @{ match = @{ name = 'x' } }
            )
        }
        $err = { Get-SynthTieringRule -Path $path } | Should -Throw -PassThru
        $message = $err.Exception.Message
        $message | Should -BeLike '*7 problem(s)*'
        $message | Should -BeLike "*defaultTier 'Platinum'*"
        $message | Should -BeLike '*rules`[1`] tier ''Copper''*'
        $message | Should -BeLike "*unknown field 'colour'*"
        $message | Should -BeLike '*rules`[3`] match.name is not a valid regular expression*'
        $message | Should -BeLike '*rules`[3`] profile ''busy''*'
        $message | Should -BeLike '*rules`[4`] needs a match block*'
        $message | Should -BeLike '*rules`[5`] sets none of tier, application or profile*'
    }

    It 'reports invalid JSON' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -Path $path -Value '{ "rules": [ '
        { Get-SynthTieringRule -Path $path } | Should -Throw '*not valid JSON*'
    }
}

Describe 'Resolve-SynthVmClass' {
    BeforeAll {
        $script:rules = Get-SynthTieringRule -Path (New-TieringFile @{
                rules = @(
                    @{ match = @{ cluster = '^prod'; annotation = 'gold' }; tier = 'Gold' }
                    @{ match = @{ cluster = '^prod' }; tier = 'Silver'; application = 'Shop' }
                    @{ match = @{ 'attribute:AppOwner' = 'payments' }; application = 'Payments' }
                    @{ match = @{ name = 'batch' }; profile = 'batch' }
                )
            })
    }

    It 'gives <Case>' -ForEach @(
        @{ Case = 'the first matching tier, matching case-insensitively'; Fact = @{ name = 'a'; cluster = 'PROD-1'; annotation = 'GOLD app' }; Expect = 'Gold|Shop|business-hours' }
        @{ Case = 'each attribute from its own first match';              Fact = @{ name = 'batch1'; cluster = 'prod-2'; 'attribute:AppOwner' = 'Payments' }; Expect = 'Silver|Shop|batch' }
        @{ Case = 'the default tier when nothing matches';                Fact = @{ name = 'x'; cluster = 'dev' }; Expect = 'Bronze||business-hours' }
        @{ Case = 'a match on a custom attribute column';                 Fact = @{ name = 'x'; cluster = 'dev'; 'attribute:AppOwner' = 'Payments' }; Expect = 'Bronze|Payments|business-hours' }
    ) {
        $baseline = [ordered]@{ cpuUsagePct = 30; memActivePct = 30 }
        $result = InModuleScope VcfOpsSynth -Parameters @{ Fact = $Fact; Rules = $script:rules; Baseline = $baseline } {
            param($Fact, $Rules, $Baseline)
            $compiled = @(foreach ($rule in $Rules.rules) {
                    @{ Rule = $rule; Tests = @(foreach ($f in $rule.match.Keys) { @{ Field = $f; Regex = [regex]::new($rule.match[$f], 'IgnoreCase') } }) }
                })
            Resolve-SynthVmClass -Fact $Fact -Rule $compiled -TieringRules $Rules -Baseline $Baseline -PoweredOn $true
        }
        "$($result.tier)|$($result.application)|$($result.profile)" | Should -Be $Expect
    }

    It 'profiles <Cpu>% CPU and <Mem>% memory as <Profile>' -ForEach @(
        @{ Cpu = 2;     Mem = 4;     Profile = 'idle' }
        @{ Cpu = 2;     Mem = 40;    Profile = 'business-hours' }
        @{ Cpu = 2;     Mem = $null; Profile = 'idle' }
        @{ Cpu = 85;    Mem = 20;    Profile = 'saturated' }
        @{ Cpu = 20;    Mem = 90;    Profile = 'saturated' }
        @{ Cpu = $null; Mem = $null; Profile = 'business-hours' }
    ) {
        $result = InModuleScope VcfOpsSynth -Parameters @{ Baseline = [ordered]@{ cpuUsagePct = $Cpu; memActivePct = $Mem } } {
            param($Baseline)
            Resolve-SynthVmClass -Fact @{} -Rule @() -TieringRules (Get-SynthTieringRule) -Baseline $Baseline -PoweredOn $true
        }
        $result.profile | Should -Be $Profile
    }

    It 'profiles a VM that is not powered on as off, whatever the rules say' {
        $result = InModuleScope VcfOpsSynth -Parameters @{ Rules = $script:rules } {
            param($Rules)
            $compiled = @(@{ Rule = @{ profile = 'batch' }; Tests = @() })
            Resolve-SynthVmClass -Fact @{} -Rule $compiled -TieringRules $Rules -Baseline ([ordered]@{ cpuUsagePct = 0; memActivePct = 0 }) -PoweredOn $false
        }
        $result.profile | Should -Be 'off'
    }
}
