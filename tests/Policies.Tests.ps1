# Pester 5 tests for the tier policies: SLA matrix, definitions, import XML, settings body and publishing. Invented data; Invoke-SynthOpsRequest is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:alerts = @(
        [pscustomobject]@{ id = 'AlertDefinition-1'; name = 'Synth-Gold VM CPU contention'; adapterKindKey = 'VMWARE'; resourceKindKey = 'VirtualMachine' }
        [pscustomobject]@{ id = 'AlertDefinition-2'; name = 'Synth-VM memory pressure'; adapterKindKey = 'VMWARE'; resourceKindKey = 'VirtualMachine' }
        [pscustomobject]@{ id = 'AlertDefinition-3'; name = 'Synth-Host not responding'; adapterKindKey = 'VMWARE'; resourceKindKey = 'HostSystem' }
        [pscustomobject]@{ id = 'AlertDefinition-4'; name = 'Stock alert'; adapterKindKey = 'VMWARE'; resourceKindKey = 'VirtualMachine' }
    )
}

Describe 'Get-SynthSla' {
    It 'has the plan''s values built in, and the example file says the same' {
        $sla = Get-SynthSla
        $g = $sla.tiers.Gold
        "$($g.timeRemainingDays.warning)/$($g.timeRemainingDays.critical) $($g.capacityBufferPercent)" | Should -Be '120/40 20'
        $file = Get-SynthSla -Path (Join-Path $PSScriptRoot '../config/sla.example.json')
        ($file | ConvertTo-Json -Depth 5 -Compress) | Should -Be ($sla | ConvertTo-Json -Depth 5 -Compress)
    }

    It 'refuses a matrix with a missing tier or values the API would refuse' {
        $dir = Join-Path $TestDrive 'sla'; $null = New-Item -ItemType Directory $dir -Force
        $bad = { param($json) $p = Join-Path $dir "$([guid]::NewGuid()).json"; Set-Content -LiteralPath $p -Value $json; { Get-SynthSla -Path $p }.GetNewClosure() }
        & $bad '{ "tiers": { "Gold": {}, "Silver": {} } }' | Should -Throw '*no Bronze tier*'
        & $bad '{ "tiers": { "Gold": { "capacityBufferPercent": 120 }, "Silver": {}, "Bronze": {} } }' | Should -Throw '*0 to 99*'
        & $bad '{ "tiers": { "Gold": { "timeRemainingDays": { "warning": 10, "critical": 30 } }, "Silver": {}, "Bronze": {} } }' | Should -Throw '*more days*'
    }
}

Describe 'Get-SynthPolicyDefinition' {
    It 'switches on every prefixed alert in the base, and only switches off in a tier' {
        $defs = @(Get-SynthPolicyDefinition -Sla (Get-SynthSla) -AlertDefinition $script:alerts -Prefix 'Synth-')
        ($defs | ForEach-Object { "$($_.Name)<$($_.Parent)" }) -join ',' | Should -Be 'Synth-Base<,Synth-Tier-1-Gold<Base,Synth-Tier-2-Silver<Base,Synth-Tier-3-Bronze<Base'
        ($defs[0].Alerts | ForEach-Object { "$($_.Id)=$($_.Enabled)" }) -join ',' | Should -Be 'AlertDefinition-1=True,AlertDefinition-2=True,AlertDefinition-3=True'
        $defs[1].Alerts.Count | Should -Be 0
        ($defs[3].Alerts | ForEach-Object { "$($_.Id)=$($_.Enabled)" }) -join ',' | Should -Be 'AlertDefinition-2=False'
        "$($defs[3].Settings.TimeRemainingDays.warning) $($defs[3].Settings.CapacityBufferPercent)" | Should -Be '30 0'
    }

    It 'names the alert when the matrix switches off one that does not exist' {
        $sla = Get-SynthSla
        $sla.tiers.Silver.disableAlerts = @('No such alert')
        { Get-SynthPolicyDefinition -Sla $sla -AlertDefinition $script:alerts } | Should -Throw "*'Synth-No such alert'*"
    }
}

Describe 'ConvertTo-SynthPolicyXml' {
    It 'puts the family in one file, each policy keyed by its id, children naming the base as parent' {
        $defs = @(Get-SynthPolicyDefinition -Sla (Get-SynthSla) -AlertDefinition $script:alerts)
        $ids = @{ Base = 'id-base'; Gold = 'id-gold'; Silver = 'id-silver'; Bronze = 'id-bronze' }
        [xml]$x = ConvertTo-SynthPolicyXml -Definition $defs -IdByKey $ids
        $p = @($x.PolicyContent.Policies.Policy)
        ($p | ForEach-Object { "$($_.key)<$($_.parentPolicy)" }) -join ',' | Should -Be 'id-base<,id-gold<id-base,id-silver<id-base,id-bronze<id-base'
        ($p[0].PackageSettings.Alerts | ForEach-Object { "$($_.resourceKind):$(@($_.Alert).Count)" }) -join ',' | Should -Be 'HostSystem:1,VirtualMachine:2'
        $p[3].PackageSettings.Alerts.Alert.enabled | Should -Be 'false'
        $x.PolicyContent.SelectSingleNode('alertContent') | Should -Not -BeNullOrEmpty -Because 'the lab accepts an empty alertContent'
    }
}

Describe 'ConvertTo-SynthPolicySettingsBody' {
    It 'sets time remaining on VMs and the buffer on clusters, and nothing for the base' {
        $defs = @(Get-SynthPolicyDefinition -Sla (Get-SynthSla) -AlertDefinition $script:alerts)
        ConvertTo-SynthPolicySettingsBody -Definition $defs[0] | Should -BeNullOrEmpty
        $json = ConvertTo-SynthPolicySettingsBody -Definition $defs[1] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $tr = $json.capacitySettings.criticalityThresholds.timeRemainingSettings[0]
        "$($tr.resourceKindKey.resourceKind) $($tr.criticalityThresholdsConfig.warning)/$($tr.criticalityThresholdsConfig.critical)" | Should -Be 'VirtualMachine 120/40'
        $buf = $json.capacitySettings.capacity.capacityBufferSettings[0]
        "$($buf.resourceKindKey.resourceKind) $($buf.capacityBuffer.cpu.demand) $($buf.capacityBuffer.memory.allocation) $($buf.capacityBuffer.diskspace.demand)" | Should -Be 'ClusterComputeResource 20 20 20'
    }
}

Describe 'Publish-SynthPolicy' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Query = $Query; Body = $Body; Form = $Form })
            if ($Method -eq 'Get' -and $Query -and $Query.activesOnly) {
                return [pscustomobject]@{ policySummaries = @(
                        [pscustomobject]@{ id = 'pol-default'; name = 'Default Policy'; defaultPolicy = $true }
                        [pscustomobject]@{ id = 'pol-stock'; name = 'Stock'; defaultPolicy = $false }
                        [pscustomobject]@{ id = 'pol-base'; name = 'Synth-Base'; defaultPolicy = $false }
                    ) }
            }
            if ($Method -eq 'Get') {
                return [pscustomobject]@{ policySummaries = @(
                        [pscustomobject]@{ id = 'pol-default'; name = 'Default Policy'; defaultPolicy = $true }
                        [pscustomobject]@{ id = 'pol-base'; name = 'Synth-Base'; defaultPolicy = $false }
                        [pscustomobject]@{ id = 'pol-hand'; name = 'Tier-1-Gold'; defaultPolicy = $false }
                    ) }
            }
            if ($Path -eq 'policies/import') {
                # The zip is gone once Publish returns, so read it here.
                $dir = Join-Path $TestDrive ([guid]::NewGuid()); Expand-Archive -LiteralPath $Form.policy.FullName -DestinationPath $dir
                $script:imported = [xml](Get-Content (Join-Path $dir 'exportedPolicies.xml') -Raw)
            }
            ''
        }
        $script:defs = @(Get-SynthPolicyDefinition -Sla (Get-SynthSla) -AlertDefinition $script:alerts -Prefix 'Synth-')
    }

    It 'keeps the id of a policy it made, imports with force, then sets values, assigns and ranks' {
        $out = @(Publish-SynthPolicy -Definition $script:defs -Prefix 'Synth-' -GroupIdByKey @{ Base = @('grp-estate'); Gold = @('grp-gold') })
        ($out | ForEach-Object { "$($_.Name)=$($_.Action)" }) -join ',' | Should -Be 'Synth-Base=updated,Synth-Tier-1-Gold=created,Synth-Tier-2-Silver=created,Synth-Tier-3-Bronze=created'
        $out[0].Id | Should -Be 'pol-base'
        $import = @($script:calls | Where-Object Path -eq 'policies/import')
        $import.Count | Should -Be 1
        $import[0].Query.forceImport | Should -Be 'true'
        @($script:imported.PolicyContent.Policies.Policy)[0].key | Should -Be 'pol-base'
        @($script:imported.PolicyContent.Policies.Policy)[1].parentPolicy | Should -Be 'pol-base'
        $paths = @($script:calls | Where-Object Method -ne 'Get' | ForEach-Object { "$($_.Method) $($_.Path -replace '[0-9a-f-]{36}', '<new>')" })
        $paths -join ',' | Should -Be 'Post policies/import,Put policies/pol-base/assign,Patch policies/<new>/settings,Put policies/<new>/assign,Patch policies/<new>/settings,Patch policies/<new>/settings,Put policies/priorities'
        ($script:calls | Where-Object Path -eq 'policies/pol-base/assign').Body.groupIds | Should -Be @('grp-estate')
    }

    It 'ranks the toolset''s active policies first, tiers before the base, and keeps every other active one' {
        $null = Publish-SynthPolicy -Definition $script:defs -Prefix 'Synth-'
        ($script:calls | Where-Object Path -eq 'policies/priorities').Body.policyIds -join ',' | Should -Be 'pol-base,pol-stock'
    }

    It 'changes nothing on a dry run, and never matches a policy outside the prefix' {
        $out = @(Publish-SynthPolicy -Definition $script:defs -Prefix 'Synth-' -WhatIf)
        @($script:calls | Where-Object Method -ne 'Get').Count | Should -Be 0
        ($out | Where-Object Name -eq 'Synth-Base').Action | Should -Be 'would update'
        ($out | Where-Object Name -eq 'Synth-Tier-1-Gold').Action | Should -Be 'would create'
    }
}
