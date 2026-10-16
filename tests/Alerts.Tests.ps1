# Pester 5 tests for the alert content: symptoms, recommendations, alerts and super metrics. Invented data; Invoke-SynthOpsRequest is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:content = Get-SynthAlertContent -Prefix 'Synth-'
    $script:ids = @{}
    $n = 0
    foreach ($s in $script:content.Symptoms) { $n++; $script:ids[$s.Name] = "sym-$n" }
}

Describe 'Get-SynthAlertContent' {
    It 'puts the prefix on every name and every recommendation' {
        foreach ($list in 'Symptoms', 'Alerts', 'SuperMetrics') {
            @($script:content[$list] | Where-Object { $_.Name -notlike 'Synth-*' }).Count | Should -Be 0
        }
        @($script:content.Recommendations | Where-Object { $_.Text -notlike 'Synth-*' }).Count | Should -Be 0
        @($script:content.Symptoms | ForEach-Object Name | Sort-Object -Unique).Count | Should -Be $script:content.Symptoms.Count
    }

    It 'refers only to symptoms and recommendations it defines' {
        $keys = @($script:content.Recommendations | ForEach-Object Key)
        foreach ($a in $script:content.Alerts) {
            foreach ($s in $a.States) {
                foreach ($item in $s.All) { foreach ($name in @($item)) { $script:ids.ContainsKey($name) | Should -BeTrue -Because "$($a.Name) needs $name" } }
                $s.Recommendation | Should -BeIn $keys
            }
        }
    }

    It 'sets thresholds the scenarios cross' {
        # S1 sets ready 12 %, S2 balloon 25 % and swap-in 4096 KBps, S3 latency 45 ms, S4 guest file systems 97 %, S8 notResponding.
        $by = @{}; foreach ($s in $script:content.Symptoms) { $by[$s.Name] = $s }
        foreach ($case in @(
                @('Synth-VM CPU ready above 10 %', 12), @('Synth-VM memory ballooning above 10 %', 25), @('Synth-VM swapping in', 4096),
                @('Synth-VM disk read latency above 40 ms', 45), @('Synth-Datastore read latency above 30 ms', 45),
                @('Synth-VM guest file system above 95 %', 97), @('Synth-Host CPU demand above 100 %', 115))) {
            $by[$case[0]].Operator | Should -Be 'GT'
            $case[1] | Should -BeGreaterThan $by[$case[0]].Value -Because $case[0]
        }
        $by['Synth-Host not responding'].Value | Should -Be 'notResponding'
    }
}

Describe 'ConvertTo-SynthSymptomBody' {
    It 'writes a static metric condition' {
        $d = $script:content.Symptoms | Where-Object Name -eq 'Synth-VM CPU ready above 5 %'
        $json = ConvertTo-SynthSymptomBody -Definition $d | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        "$($json.adapterKindKey)/$($json.resourceKindKey) $($json.state.severity)" | Should -Be 'VMWARE/VirtualMachine CRITICAL'
        $c = $json.state.condition
        "$($c.type) $($c.key) $($c.operator) $($c.value) $($c.thresholdType)" | Should -Be 'CONDITION_HT cpu|readyPct GT 5 STATIC'
        $json.PSObject.Properties['id'] | Should -BeNullOrEmpty
    }

    It 'writes a property condition, with the id on an update' {
        $d = $script:content.Symptoms | Where-Object Name -eq 'Synth-VM tier is Gold'
        $json = ConvertTo-SynthSymptomBody -Definition $d -Id 'sym-9' | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $c = $json.state.condition
        "$($json.id) $($c.type) $($c.key) $($c.operator) $($c.stringValue)" | Should -Be 'sym-9 CONDITION_PROPERTY_STRING vcfops-synth|tier EQ Gold'
    }
}

Describe 'ConvertTo-SynthAlertBody' {
    It 'makes one AND set when every symptom must hold' {
        $d = $script:content.Alerts | Where-Object Name -eq 'Synth-Gold VM CPU contention'
        $json = ConvertTo-SynthAlertBody -Definition $d -SymptomId $script:ids -RecommendationId @{ cpu = 'rec-1' } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        "$($json.type)/$($json.subType) $($json.resourceKindKey)" | Should -Be '15/19 VirtualMachine'
        $json.states.Count | Should -Be 2
        $set = $json.states[0].'base-symptom-set'
        "$($set.type) $($set.symptomSetOperator) $($set.symptomDefinitionIds -join ',')" | Should -Be ("SYMPTOM_SET AND {0},{1}" -f $script:ids['Synth-VM tier is Gold'], $script:ids['Synth-VM CPU ready above 5 %'])
        $json.states[0].recommendationPriorityMap.'rec-1' | Should -Be 1
        $json.states[0].impact.detail | Should -Be 'HEALTH'
    }

    It 'joins a tier symptom and an any-of group with a composite AND' {
        $d = $script:content.Alerts | Where-Object Name -eq 'Synth-Silver VM disk latency'
        $json = ConvertTo-SynthAlertBody -Definition $d -SymptomId $script:ids | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $base = $json.states[0].'base-symptom-set'
        "$($base.type) $($base.operator)" | Should -Be 'SYMPTOM_SET_COMPOSITE AND'
        $sets = @($base.'symptom-sets')
        "$($sets[0].symptomSetOperator) $($sets[0].symptomDefinitionIds -join ',')" | Should -Be "AND $($script:ids['Synth-VM tier is Silver'])"
        "$($sets[1].symptomSetOperator) $($sets[1].symptomDefinitionIds -join ',')" | Should -Be ('OR {0},{1}' -f $script:ids['Synth-VM disk read latency above 40 ms'], $script:ids['Synth-VM disk write latency above 40 ms'])
        $json.states[0].PSObject.Properties['recommendationPriorityMap'] | Should -BeNullOrEmpty
    }

    It 'makes one OR set for a lone any-of group' {
        $d = $script:content.Alerts | Where-Object Name -eq 'Synth-Datastore latency'
        $set = (ConvertTo-SynthAlertBody -Definition $d -SymptomId $script:ids | ConvertTo-Json -Depth 20 | ConvertFrom-Json).states[0].'base-symptom-set'
        "$($set.type) $($set.symptomSetOperator) $(@($set.symptomDefinitionIds).Count)" | Should -Be 'SYMPTOM_SET OR 2'
    }

    It 'names a missing symptom' {
        $d = $script:content.Alerts | Where-Object Name -eq 'Synth-Host not responding'
        { ConvertTo-SynthAlertBody -Definition $d -SymptomId @{} } | Should -Throw "*needs symptom 'Synth-Host not responding'*"
    }
}

Describe 'Publish-SynthAlertContent' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Body = $Body })
            if ($Method -eq 'Get') {
                switch ($Path) {
                    'symptomdefinitions' { return [pscustomobject]@{ symptomDefinitions = @([pscustomobject]@{ id = 'sym-old'; name = 'Synth-VM tier is Gold' }, [pscustomobject]@{ id = 'sym-hand'; name = 'VM tier is Gold' }); pageInfo = [pscustomobject]@{ totalCount = 2 } } }
                    'recommendations' { return [pscustomobject]@{ recommendations = @([pscustomobject]@{ id = 'rec-hand'; description = 'Restart it.' }); pageInfo = [pscustomobject]@{ totalCount = 1 } } }
                    'alertdefinitions' { return [pscustomobject]@{ alertDefinitions = @([pscustomobject]@{ id = 'al-old'; name = 'Synth-Host not responding' }); pageInfo = [pscustomobject]@{ totalCount = 1 } } }
                    default { return [pscustomobject]@{ pageInfo = [pscustomobject]@{ totalCount = 0 } } }
                }
            }
            if ($Path -eq 'alertdefinitions' -and $Body.name -eq 'Synth-VM memory pressure') { throw 'VCF Operations Post alertdefinitions failed with HTTP 400: bad state' }
            if ($Method -eq 'Put') { return $null }
            [pscustomobject]@{ id = "new-$($script:calls.Count)" }
        }
    }

    It 'updates its own items in place, creates the rest, and reports a failure without stopping' {
        $out = @(Publish-SynthAlertContent -Content $script:content -Prefix 'Synth-')
        $total = $script:content.Symptoms.Count + $script:content.Recommendations.Count + $script:content.Alerts.Count + $script:content.SuperMetrics.Count
        $out.Count | Should -Be $total
        $gold = $out | Where-Object Name -eq 'Synth-VM tier is Gold'
        "$($gold.Action) $($gold.Id)" | Should -Be 'updated sym-old'
        $put = @($script:calls | Where-Object Method -eq 'Put')
        ($put | ForEach-Object { "$($_.Path) $($_.Body.id)" }) -join ',' | Should -Be 'symptomdefinitions sym-old,alertdefinitions al-old'
        $failed = @($out | Where-Object Action -eq 'failed')
        "$($failed.Name) $($failed.Error)" | Should -BeLike 'Synth-VM memory pressure *HTTP 400*'
        @($out | Where-Object { $_.Kind -eq 'super metric' -and $_.Action -eq 'created' }).Count | Should -Be $script:content.SuperMetrics.Count
    }

    It 'sends alerts the ids of the symptoms and recommendations it just published' {
        $null = Publish-SynthAlertContent -Content $script:content -Prefix 'Synth-'
        $alert = ($script:calls | Where-Object { $_.Path -eq 'alertdefinitions' -and $_.Method -eq 'Post' -and $_.Body.name -eq 'Synth-Gold VM CPU contention' }).Body
        $json = $alert | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $json.states[0].'base-symptom-set'.symptomDefinitionIds[0] | Should -Be 'sym-old'
        $json.states[0].'base-symptom-set'.symptomDefinitionIds[1] | Should -BeLike 'new-*'
        @($json.states[0].recommendationPriorityMap.PSObject.Properties.Name)[0] | Should -BeLike 'new-*'
        $sm = ($script:calls | Where-Object { $_.Path -eq 'supermetrics' -and $_.Body.name -eq 'Synth-Tier VM health' }).Body
        "$($sm.resourceKinds[0].adapterKindKey)/$($sm.resourceKinds[0].resourceKindKey)" | Should -Be 'Container/Service Level Objective'
    }

    It 'never touches content outside the prefix, and changes nothing on a dry run' {
        $out = @(Publish-SynthAlertContent -Content $script:content -Prefix 'Synth-' -WhatIf)
        @($script:calls | Where-Object Method -ne 'Get').Count | Should -Be 0
        ($out | Where-Object Name -eq 'Synth-VM tier is Gold').Action | Should -Be 'would update'
        @($out | Where-Object { $_.Id -in 'sym-hand', 'rec-hand' }).Count | Should -Be 0
    }
}
