# Pester 5 tests for reset: finding seeded objects by identifier and tag, deleting them, content and state. Invented data; Invoke-SynthOpsRequest is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $id = { param($value) , @(@{ name = 'VMEntityObjectID'; value = $value; unique = $true }) }
    $script:plan = @{ objects = @(
            @{ kind = 'ClusterComputeResource'; key = 'cl-1'; name = 'Cluster A'; identifiers = (& $id 'domain-c1') }
            @{ kind = 'HostSystem'; key = 'esx-1'; name = 'esx-a'; identifiers = (& $id 'host-1') }
            @{ kind = 'VirtualMachine'; key = 'vm-1'; name = 'app-01'; identifiers = (& $id 'vm-1') }
            @{ kind = 'VirtualMachine'; key = 'vm-2'; name = 'app-02'; identifiers = (& $id 'vm-2') }
            @{ kind = 'VirtualMachine'; key = 'vm-3'; name = 'not-seeded'; identifiers = (& $id 'vm-3') }
        ) }
    # What Operations holds: vm-2 shares an identifier but has no synthetic tag (a real VM); vm-3 is not there.
    $script:resources = @{
        ClusterComputeResource = @(@{ id = 'r-cl'; moid = 'domain-c1'; name = 'Cluster A' })
        HostSystem             = @(@{ id = 'r-esx'; moid = 'host-1'; name = 'esx-a' })
        VirtualMachine         = @(@{ id = 'r-vm1'; moid = 'vm-1'; name = 'app-01' }, @{ id = 'r-vm2'; moid = 'vm-2'; name = 'app-02' }, @{ id = 'r-real'; moid = 'vm-9'; name = 'real' })
    }
    $script:tags = @{ 'r-cl' = '[vcfops-synth-synthetic, Project-Demo]'; 'r-esx' = '[vcfops-synth-synthetic]'; 'r-vm1' = '[Project-Demo, vcfops-synth-synthetic]'; 'r-vm2' = '[vcfops-synth-synthetic-old]' }
}

Describe 'Get-SynthSeededObject and Remove-SynthSeededObject' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Query = $Query })
            if ($Method -eq 'Get' -and $Path -eq 'resources') {
                $list = @($script:resources[$Query.resourceKind] | Where-Object { $_ } | ForEach-Object {
                        [pscustomobject]@{ identifier = $_.id; resourceKey = [pscustomobject]@{ name = $_.name; resourceIdentifiers = @([pscustomobject]@{ identifierType = [pscustomobject]@{ name = 'VMEntityObjectID' }; value = $_.moid }) } }
                    })
                return [pscustomobject]@{ resourceList = $list; pageInfo = [pscustomobject]@{ totalCount = $list.Count } }
            }
            if ($Method -eq 'Get' -and $Path -like 'resources/properties?*') {
                $ids = @([regex]::Matches($Path, 'resourceId=([^&]+)') | ForEach-Object { $_.Groups[1].Value })
                return [pscustomobject]@{ resourcePropertiesList = @($ids | Where-Object { $script:tags.ContainsKey($_) } | ForEach-Object {
                            [pscustomobject]@{ resourceId = $_; property = @([pscustomobject]@{ name = 'summary|parentVcenter'; value = 'vc' }, [pscustomobject]@{ name = 'summary|tag'; value = $script:tags[$_] }) }
                        }) }
            }
            if ($Method -eq 'Delete' -and $Path -eq 'resources/r-esx') { throw 'VCF Operations Delete resources/r-esx failed with HTTP 500: busy' }
        }
    }

    It 'finds planned objects by identifier, children first, and marks only those with the synthetic tag' {
        $found = @(Get-SynthSeededObject -Plan $script:plan -AdapterInstanceId 'ai-1')
        ($found | ForEach-Object { "$($_.Key)=$($_.Tagged)" }) -join ',' | Should -Be 'vm-1=True,vm-2=False,esx-1=True,cl-1=True'
        @($script:calls | Where-Object { $_.Path -eq 'resources' -and $_.Query.adapterInstanceId -ne 'ai-1' }).Count | Should -Be 0
        @($script:calls | Where-Object { $_.Path -like 'resources/properties?*' }).Count | Should -Be 1
    }

    It 'deletes only tagged objects and reports untagged ones and failures' {
        $found = @(Get-SynthSeededObject -Plan $script:plan -AdapterInstanceId 'ai-1')
        $out = @(Remove-SynthSeededObject -Object $found -Confirm:$false)
        ($out | ForEach-Object { "$($_.Key)=$($_.Action)" }) -join ',' | Should -Be 'vm-1=deleted,vm-2=untagged,esx-1=failed,cl-1=deleted'
        ($out | Where-Object Action -eq 'failed').Error | Should -BeLike '*HTTP 500*'
        (@($script:calls | Where-Object Method -eq 'Delete') | ForEach-Object Path) -join ',' | Should -Be 'resources/r-vm1,resources/r-esx,resources/r-cl'
    }

    It 'deletes nothing with -WhatIf' {
        $found = @(Get-SynthSeededObject -Plan $script:plan -AdapterInstanceId 'ai-1')
        $out = @(Remove-SynthSeededObject -Object $found -WhatIf)
        @($script:calls | Where-Object Method -eq 'Delete').Count | Should -Be 0
        @($out | Where-Object Action -eq 'would delete').Count | Should -Be 3
    }

    It 'asks for properties in batches of 100' {
        $many = @(1..250 | ForEach-Object { "r-$_" })
        InModuleScope VcfOpsSynth -Parameters @{ Many = $many } { param($Many) $null = Get-SynthResourceProperty -Id $Many -Key 'summary|tag' }
        @($script:calls | Where-Object { $_.Path -like 'resources/properties?*' }).Count | Should -Be 3
    }
}

Describe 'Remove-SynthContent' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path })
            if ($Method -ne 'Get') { return }
            $item = { param($id, $name) [pscustomobject]@{ id = $id; name = $name } }
            switch ($Path) {
                'policies' { [pscustomobject]@{ policySummaries = @((& $item 'p0' 'Synth-Base'), (& $item 'p1' 'Synth-Tier-1-Gold'), (& $item 'p2' 'Default Policy')) } }
                'alertdefinitions' { [pscustomobject]@{ alertDefinitions = @((& $item 'a1' 'Synth-Host not responding'), (& $item 'a2' 'Host down')) } }
                'symptomdefinitions' { [pscustomobject]@{ symptomDefinitions = @(& $item 's1' 'Synth-Host not responding') } }
                'recommendations' { [pscustomobject]@{ recommendations = @([pscustomobject]@{ id = 'rc1'; description = 'Synth-Check the host.' }, [pscustomobject]@{ id = 'rc2'; description = 'Check the host.' }) } }
                'supermetrics' { [pscustomobject]@{ superMetrics = @() } }
                'resources/groups' { [pscustomobject]@{ groups = @([pscustomobject]@{ id = 'g1'; resourceKey = [pscustomobject]@{ name = 'Synth-Tier-1-Gold' } }, [pscustomobject]@{ id = 'g2'; resourceKey = [pscustomobject]@{ name = 'Tier-1-Gold' } }) } }
            }
        }
    }

    It 'deletes prefixed items only: tier policies, then the base policy, then alerts before the symptoms they use' {
        $out = @(Remove-SynthContent -Prefix 'Synth-' -Confirm:$false)
        (@($script:calls | Where-Object Method -eq 'Delete') | ForEach-Object Path) -join ',' | Should -Be 'policies/p1,policies/p0,alertdefinitions/a1,symptomdefinitions/s1,recommendations/rc1,resources/groups/g1'
        @($out | Where-Object Action -eq 'deleted').Count | Should -Be 6
    }

    It 'deletes nothing with -WhatIf, and refuses an empty prefix' {
        $null = Remove-SynthContent -Prefix 'Synth-' -WhatIf
        @($script:calls | Where-Object Method -eq 'Delete').Count | Should -Be 0
        { Remove-SynthContent -Prefix '' -Confirm:$false } | Should -Throw
    }
}

Describe 'Clear-SynthState' {
    It 'forgets backfill, feed and scenarios and keeps the rest' {
        $path = Join-Path $TestDrive 'state.json'
        '{"backfill":{"done":["vm-1"]},"feed":{"lastMs":1},"scenarios":[{"id":"S1"}],"other":{"keep":true}}' | Set-Content -LiteralPath $path
        Clear-SynthState -Path $path -Confirm:$false
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        @($state.Keys) -join ',' | Should -Be 'other'
    }

    It 'does nothing when there is no state file' {
        { Clear-SynthState -Path (Join-Path $TestDrive 'none.json') -Confirm:$false } | Should -Not -Throw
    }
}

Describe 'Get-SynthContentName' {
    It 'names every view, report and dashboard content publishes, all with the prefix' {
        $names = Get-SynthContentName -Prefix 'Synth-'
        $names.View.Count | Should -Be 5
        $names.Report.Count | Should -Be 2
        $names.Dashboard.Count | Should -Be 2
        @($names.View + $names.Report + $names.Dashboard | Where-Object { -not $_.StartsWith('Synth-') }).Count | Should -Be 0
        $names.Dashboard | Should -Contain 'Synth-Service tiers'
    }
}

Describe 'Save-SynthContentDeletePayload' {
    It 'writes the prefix and every name for ops-content-delete.py' {
        $path = Join-Path $TestDrive 'content-delete.json'
        Save-SynthContentDeletePayload -Prefix 'Synth-' -Path $path | Should -Be $path
        $payload = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $names = Get-SynthContentName -Prefix 'Synth-'
        $payload.prefix | Should -Be 'Synth-'
        $payload.owner | Should -BeNullOrEmpty
        $payload.view | Should -Be $names.View
        $payload.report | Should -Be $names.Report
        $payload.dashboard | Should -Be $names.Dashboard
    }

    It 'names the dashboard owner when given' {
        $path = Join-Path $TestDrive 'owner.json'
        $null = Save-SynthContentDeletePayload -Prefix 'Synth-' -Path $path -Owner 'opsadmin'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).owner | Should -Be 'opsadmin'
    }

    It 'writes nothing with -WhatIf' {
        $path = Join-Path $TestDrive 'whatif.json'
        $null = Save-SynthContentDeletePayload -Prefix 'Synth-' -Path $path -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'Remove-SynthApplianceContent' {
    BeforeEach {
        $script:ssh = [System.Collections.Generic.List[object]]::new()
        $script:refuseKey = $false
        # Stands in for ssh and bin/ops-content-delete.py on the appliance: reads the payload from the command, answers per name.
        Mock -ModuleName VcfOpsSynth Invoke-SynthSsh {
            $script:ssh.Add([pscustomobject]@{ Target = $Target; Command = $Command; IdentityFile = $IdentityFile; Interactive = [bool]$Interactive })
            if ($script:refuseKey -and -not $Interactive) { return [pscustomobject]@{ ExitCode = 255; Output = 'root@ops.example.invalid: Permission denied (publickey,password).' } }
            $b64 = [regex]::Matches($Command, 'echo (\S+) \| base64 -d')[1].Groups[1].Value
            $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
            $out = foreach ($kind in 'view', 'report', 'dashboard') {
                foreach ($name in @($payload.$kind)) {
                    $action = switch ($name) { 'Synth-Rightsizing' { 'not there' } 'Synth-Service tiers' { 'failed' } default { 'deleted' } }
                    @{ action = $action; kind = $kind; name = $name; error = $(if ($action -eq 'failed') { 'exit 1: permission denied' }) } | ConvertTo-Json -Compress
                }
            }
            [pscustomobject]@{ ExitCode = 1; Output = ($out -join "`n") }
        }
    }

    It 'deletes every named item in one SSH session, dashboards for all users, with the key first' {
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -IdentityFile '/keys/id' -Confirm:$false)
        $script:ssh.Count | Should -Be 1
        $script:ssh[0].Target | Should -Be 'root@ops.example.invalid'
        $script:ssh[0].IdentityFile | Should -Be '/keys/id'
        $script:ssh[0].Interactive | Should -BeFalse
        $script:ssh[0].Command | Should -BeLike '*--apply --jsonl*'
        $script:ssh[0].Command | Should -Not -Match ' -all'
        $out.Count | Should -Be 9
        @($out | Where-Object Action -eq 'deleted').Count | Should -Be 7
        ($out | Where-Object Name -eq 'Synth-Rightsizing').Action | Should -Be 'not there'
        ($out | Where-Object Name -eq 'Synth-Service tiers').Action | Should -Be 'failed'
        ($out | Where-Object Name -eq 'Synth-Service tiers').Kind | Should -Be 'dashboard'
    }

    It 'sends the dashboard owner with the names' {
        $null = Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Owner 'opsadmin' -Confirm:$false
        $b64 = [regex]::Matches($script:ssh[0].Command, 'echo (\S+) \| base64 -d')[1].Groups[1].Value
        ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json).owner | Should -Be 'opsadmin'
    }

    It 'deletes reports and dashboards before the views they use' {
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        ($out.Kind | Select-Object -Unique) -join ',' | Should -Be 'report,dashboard,view'
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../bin/ops-content-delete.py') -Raw
        $script | Should -Match "for kind in \('report', 'dashboard', 'view'\)"
    }

    It 'sends the appliance script itself, with Unix line endings' {
        $null = Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Confirm:$false
        $b64 = [regex]::Matches($script:ssh[0].Command, 'echo (\S+) \| base64 -d')[0].Groups[1].Value
        $code = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $code | Should -BeLike '*def refusal(prefix, name)*'
        $code | Should -BeLike '*def missing_jar_options(opscli_dir)*'
        $code | Should -Not -Match "`r"
    }

    It 'falls back to a password prompt from ssh when the key is refused' {
        Mock -ModuleName VcfOpsSynth Test-SynthTerminal { $true }
        $script:refuseKey = $true
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        $script:ssh.Count | Should -Be 2
        $script:ssh[0].Interactive | Should -BeFalse
        $script:ssh[1].Interactive | Should -BeTrue
        @($out | Where-Object Action -eq 'deleted').Count | Should -Be 7
    }

    It 'fails clearly, without a prompt, when the key is refused and there is no terminal' {
        Mock -ModuleName VcfOpsSynth Test-SynthTerminal { $false }
        $script:refuseKey = $true
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        $script:ssh.Count | Should -Be 1
        @($out | Where-Object Action -eq 'failed').Count | Should -Be 9
        $out[0].Error | Should -BeLike '*no terminal to ask for the password. Run the container with -it, or with -dit and then docker attach*'
    }

    It 'marks every item failed when the appliance gives no result' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthSsh { [pscustomobject]@{ ExitCode = 255; Output = 'ssh: connect to host ops.example.invalid port 22: Connection timed out' } }
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        @($out | Where-Object Action -eq 'failed').Count | Should -Be 9
        $out[0].Error | Should -BeLike 'exit 255: *timed out'
    }

    It 'refuses a prefix that would make a name with a comma or a leading dash' {
        $out = @(Remove-SynthApplianceContent -Prefix 'A,B-' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        $script:ssh.Count | Should -Be 0
        @($out | Where-Object Action -ne 'refused').Count | Should -Be 0
        $out = @(Remove-SynthApplianceContent -Prefix '-all ' -SshTarget 'root@ops.example.invalid' -Confirm:$false)
        $script:ssh.Count | Should -Be 0
    }

    It 'signs in to nothing with -WhatIf' {
        $out = @(Remove-SynthApplianceContent -Prefix 'Synth-' -SshTarget 'root@ops.example.invalid' -WhatIf)
        $script:ssh.Count | Should -Be 0
        @($out | Where-Object Action -eq 'would delete').Count | Should -Be 9
    }
}

Describe 'Resolve-SynthSshKey' {
    It 'takes the key given' {
        Resolve-SynthSshKey -SshKey '/home/me/.ssh/id_ed25519' -Default (Join-Path $TestDrive 'none') | Should -Be '/home/me/.ssh/id_ed25519'
    }

    It 'takes the key mount when it holds a file' {
        $mount = Join-Path $TestDrive 'id_ssh'; Set-Content -LiteralPath $mount -Value 'key'
        Resolve-SynthSshKey -Default $mount | Should -Be $mount
        Resolve-SynthSshKey -SshKey '' -Default $mount | Should -Be $mount
    }

    It 'leaves the choice to ssh when there is neither' {
        Resolve-SynthSshKey -Default (Join-Path $TestDrive 'missing') | Should -BeNullOrEmpty
    }

    It 'defaults to /keys/id_ssh' {
        $ast = (Get-Command Resolve-SynthSshKey).ScriptBlock.Ast
        $ast.Body.ParamBlock.Parameters.Where({ $_.Name.VariablePath.UserPath -eq 'Default' })[0].DefaultValue.Value | Should -Be '/keys/id_ssh'
    }
}