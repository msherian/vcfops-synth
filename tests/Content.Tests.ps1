# Pester 5 tests for the content stage: custom group definitions and publishing. Invented data; Invoke-SynthOpsRequest is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:inventory = @{ vms = @(
            @{ id = 'vm-1'; tier = 'Gold'; application = 'Payments' }
            @{ id = 'vm-2'; tier = 'Bronze'; application = 'Payments' }
            @{ id = 'vm-3'; tier = 'Silver'; application = 'Web Shop' }
            @{ id = 'vm-4'; tier = 'Bronze'; application = $null }
        ) }
}

Describe 'Get-SynthGroupDefinition' {
    It 'makes one group per tier, one per application and the scenario target group, all with the prefix' {
        $defs = @(Get-SynthGroupDefinition -Inventory $script:inventory -Prefix 'Synth-')
        ($defs | ForEach-Object Name) -join ',' | Should -Be 'Synth-Tier-1-Gold,Synth-Tier-2-Silver,Synth-Tier-3-Bronze,Synth-App-Payments,Synth-App-Web Shop,Synth-Noisy-Neighbours'
        $gold = $defs[0]
        "$($gold.Type)|$($gold.Tier)|$($gold.Rule.Key)|$($gold.Rule.Value)" | Should -Be 'Service Level Objective|Gold|vcfops-synth|tier|Gold'
        "$($defs[3].Type)|$($defs[3].Rule.Key)|$($defs[3].Rule.Value)" | Should -Be 'Function|vcfops-synth|application|Payments'
    }
}

Describe 'ConvertTo-SynthGroupBody' {
    It 'writes a dynamic property rule on VMWARE VMs, with the policy when given' {
        $d = @(Get-SynthGroupDefinition -Inventory $script:inventory)[0]
        $body = ConvertTo-SynthGroupBody -Definition $d -PolicyId 'pol-1' -Id 'grp-1'
        $json = $body | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $json.resourceKey.adapterKindKey | Should -Be 'Container'
        $json.resourceKey.resourceKindKey | Should -Be 'Service Level Objective'
        $json.autoResolveMembership | Should -BeTrue
        $rule = $json.membershipDefinition.rules[0]
        "$($rule.resourceKindKey.adapterKind)/$($rule.resourceKindKey.resourceKind)" | Should -Be 'VMWARE/VirtualMachine'
        "$($rule.propertyConditionRules[0].key) $($rule.propertyConditionRules[0].compareOperator) $($rule.propertyConditionRules[0].stringValue)" | Should -Be 'vcfops-synth|tier EQ Gold'
        "$($json.policy) $($json.id)" | Should -Be 'pol-1 grp-1'
        (ConvertTo-SynthGroupBody -Definition $d).Contains('policy') | Should -BeFalse
    }
}

Describe 'Publish-SynthGroup' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'Get') {
                return @{ groups = @(
                        @{ id = 'grp-gold'; resourceKey = @{ name = 'Synth-Tier-1-Gold' } }
                        @{ id = 'grp-hand'; resourceKey = @{ name = 'Tier-1-Gold' } }
                    ); pageInfo = @{ totalCount = 2 } }
            }
            @{ id = "new-$($Body.resourceKey.name)" }
        }
        $script:defs = @(Get-SynthGroupDefinition -Inventory $script:inventory -Prefix 'Synth-')
    }

    It 'updates groups it made, keeping their id, and creates the rest' {
        $out = @(Publish-SynthGroup -Definition $script:defs -Prefix 'Synth-' -PolicyByTier @{ Gold = 'pol-gold' })
        ($out | Where-Object Name -eq 'Synth-Tier-1-Gold').Action | Should -Be 'updated'
        $put = @($script:calls | Where-Object Method -eq 'Put')
        $put.Count | Should -Be 1
        "$($put[0].Body.id) $($put[0].Body.policy)" | Should -Be 'grp-gold pol-gold'
        @($script:calls | Where-Object Method -eq 'Post').Count | Should -Be ($script:defs.Count - 1)
    }

    It 'copes with a group list that has no pageInfo, as the lab returns' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest { if ($Method -eq 'Get') { return [pscustomobject]@{ groups = @([pscustomobject]@{ id = 'grp-gold'; resourceKey = [pscustomobject]@{ name = 'Synth-Tier-1-Gold' } }) } }; [pscustomobject]@{ id = 'x' } }
        (@(Publish-SynthGroup -Definition $script:defs -Prefix 'Synth-' -WhatIf) | Where-Object Name -eq 'Synth-Tier-1-Gold').Action | Should -Be 'would update'
    }
    It 'never touches a group outside the prefix, and changes nothing on a dry run' {
        $out = @(Publish-SynthGroup -Definition $script:defs -Prefix 'Synth-' -WhatIf)
        @($script:calls | Where-Object Method -ne 'Get').Count | Should -Be 0
        ($out | Where-Object Name -eq 'Synth-Tier-1-Gold').Action | Should -Be 'would update'
        @($out | Where-Object Name -eq 'Tier-1-Gold').Count | Should -Be 0
    }
}
