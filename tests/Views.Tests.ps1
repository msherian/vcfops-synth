# Pester 5 tests for the views, reports and content bundle. Invented data; Invoke-SynthOpsRequest is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    Add-Type -AssemblyName System.IO.Compression
    $script:sm = @{ 'Synth-VM CPU demand over allocation' = 'sm-1'; 'Synth-Cluster worst VM CPU ready' = 'sm-2' }
    $script:content = Get-SynthViewContent -Prefix 'Synth-' -SuperMetricId $script:sm
    # Entries of a zip held as bytes: name to bytes.
    $script:unzip = {
        param([byte[]]$bytes)
        $archive = [System.IO.Compression.ZipArchive]::new([System.IO.MemoryStream]::new($bytes))
        $out = [ordered]@{}
        foreach ($e in $archive.Entries) {
            $ms = [System.IO.MemoryStream]::new(); $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
            $out[$e.FullName] = $ms.ToArray()
        }
        $archive.Dispose()
        $out
    }
    $script:text = { param([byte[]]$b) [System.Text.Encoding]::UTF8.GetString($b) }
}

Describe 'Get-SynthContentId' {
    It 'gives the same GUID for the same kind and name, and a different one otherwise' {
        $a = Get-SynthContentId -Kind 'view' -Name 'Synth-VM tier list'
        $a | Should -Be (Get-SynthContentId -Kind 'view' -Name 'Synth-VM tier list')
        $a | Should -Not -Be (Get-SynthContentId -Kind 'report' -Name 'Synth-VM tier list')
        { [guid]::Parse($a) } | Should -Not -Throw
    }
}

Describe 'Get-SynthViewContent' {
    It 'prefixes every view and report, and every report lists views that exist' {
        @($script:content.Views | Where-Object { $_.Name -notlike 'Synth-*' }).Count | Should -Be 0
        @($script:content.Reports | Where-Object { $_.Name -notlike 'Synth-*' }).Count | Should -Be 0
        $names = @($script:content.Views | ForEach-Object Name)
        foreach ($r in $script:content.Reports) { foreach ($v in $r.Views) { $v | Should -BeIn $names } }
    }

    It 'adds super metric columns by id only for the super metrics it knows' {
        $tier = @($script:content.Views | Where-Object Name -eq 'Synth-VM tier list')[0]
        @($tier.Columns | ForEach-Object Key) | Should -Contain 'Super Metric|sm_sm-1'
        $cluster = @($script:content.Views | Where-Object Name -eq 'Synth-Cluster tier pressure')[0]
        $keys = @($cluster.Columns | ForEach-Object Key)
        $keys | Should -Contain 'Super Metric|sm_sm-2'
        @($keys | Where-Object { $_ -like 'Super Metric|*' }).Count | Should -Be 1
        $bare = Get-SynthViewContent -Prefix 'Synth-'
        @($bare.Views | ForEach-Object { $_.Columns } | Where-Object { $_.Key -like 'Super Metric|*' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-SynthViewXml' {
    It 'writes a list view with both subject types, the filter as JSON and one item per column' {
        $d = @($script:content.Views | Where-Object Name -eq 'Synth-Oversized VMs')[0]
        $v = ConvertTo-SynthViewXml -Definition $d
        [xml]$x = "<Content><Views>$($v.Xml)</Views></Content>"
        $def = $x.Content.Views.ViewDef
        $def.id | Should -Be (Get-SynthContentId -Kind 'view' -Name 'Synth-Oversized VMs')
        $def.Title.InnerText | Should -Be 'Synth-Oversized VMs'
        @($def.SubjectType | ForEach-Object type) -join ',' | Should -Be 'descendant,self'
        $f = $def.SubjectType[0].filter | ConvertFrom-Json -NoEnumerate
        $f.Count | Should -Be 1
        $f[0][0].metricKey | Should -Be 'summary|oversized'
        $f[0][0].metricValue.value | Should -Be 1
        $f[0][0].filterType | Should -Be 'metrics'
        $items = $def.Controls.Control | Where-Object type -eq 'attributes-selector' | ForEach-Object { $_.Property.List.Item }
        @($items).Count | Should -Be $d.Columns.Count
        $count = ($def.Controls.Control | Where-Object type -eq 'time-interval-selector').Property | Where-Object name -eq 'count'
        $count.value | Should -Be '30'
        $v.Properties | Should -Contain "view.$($def.id).title=Synth-Oversized VMs"
    }

    It 'leaves the filter out when a view has none, and marks text properties' {
        $d = @($script:content.Views | Where-Object Name -eq 'Synth-VM configuration hygiene')[0]
        [xml]$x = (ConvertTo-SynthViewXml -Definition $d).Xml
        $x.ViewDef.SubjectType[0].HasAttribute('filter') | Should -BeFalse
        $first = $x.ViewDef.Controls.Control[1].Property.List.Item[0].Value.Property
        ($first | Where-Object name -eq 'attributeKey').value | Should -Be 'vcfops-synth|tier'
        ($first | Where-Object name -eq 'isStringAttribute').value | Should -Be 'true'
        ($first | Where-Object name -eq 'isProperty').value | Should -Be 'true'
    }

    It 'escapes text that is not valid in XML' {
        $d = @{ Name = 'Synth-A & <B>'; Description = 'x "y"'; AdapterKind = 'VMWARE'; ResourceKind = 'VirtualMachine'; Days = 1; Filter = @()
            Columns = @(@{ Key = 'a|b'; Name = 'C & D'; Transform = 'CURRENT'; Unit = $null; Property = $false; String = $false }) }
        [xml]$x = (ConvertTo-SynthViewXml -Definition $d).Xml
        $x.ViewDef.Title.InnerText | Should -Be 'Synth-A & <B>'
    }
}

Describe 'ConvertTo-SynthReportXml' {
    It 'puts a cover page, then each view by id, on the kinds its views list' {
        $d = @($script:content.Reports | Where-Object Name -eq 'Synth-Weekly tier compliance')[0]
        [xml]$x = (ConvertTo-SynthReportXml -Definition $d -View $script:content.Views).Xml
        $sections = @($x.ReportDef.Sections.Section)
        $sections[0].ContentType | Should -Be 'CoverPage'
        $sections[1].ContentKey | Should -Be (Get-SynthContentId -Kind 'view' -Name 'Synth-VM tier list')
        $sections[2].ContentKey | Should -Be (Get-SynthContentId -Kind 'view' -Name 'Synth-Cluster tier pressure')
        @($x.ReportDef.SubjectType | ForEach-Object { "$($_.resourceKind)/$($_.type)" }) -join ',' |
            Should -Be 'VirtualMachine/descendant,VirtualMachine/self,ClusterComputeResource/descendant,ClusterComputeResource/self'
        @($x.ReportDef.Settings.OutputFormat) -join ',' | Should -Be 'pdf,csv'
    }

    It 'refuses a report that lists an unknown view' {
        { ConvertTo-SynthReportXml -Definition @{ Name = 'Synth-R'; Description = ''; Views = @('Synth-Nope') } -View $script:content.Views } | Should -Throw '*Synth-Nope*'
    }
}

Describe 'New-SynthContentBundle' {
    BeforeAll {
        $script:views = @($script:content.Views | ForEach-Object { ConvertTo-SynthViewXml -Definition $_ })
        $script:reports = @($script:content.Reports | ForEach-Object { ConvertTo-SynthReportXml -Definition $_ -View $script:content.Views })
    }

    It 'lays the bundle out as an export does' {
        $path = Join-Path $TestDrive 'out/bundle.zip'
        $dash = [ordered]@{ id = 'd-1'; name = 'Synth-Overview'; userId = 'owner-1'; widgets = @() }
        $r = New-SynthContentBundle -Path $path -OwnerId 'owner-1' -View $script:views -Report $script:reports -Dashboard $dash
        "$($r.Views) $($r.Reports) $($r.Dashboards)" | Should -Be "$($script:views.Count) $($script:reports.Count) 1"
        $root = & $script:unzip ([System.IO.File]::ReadAllBytes($path))
        @($root.Keys) -join ',' | Should -Be 'configuration.json,usermappings.json,6844548499441080431L.v1,views.zip,reports.zip,dashboards/owner-1'
        (& $script:text $root['6844548499441080431L.v1']) | Should -Be 'owner-1'
        $config = (& $script:text $root['configuration.json']) | ConvertFrom-Json
        "$($config.type) $($config.views) $($config.reports) $($config.dashboards) $($config.dashboardsByOwner[0].owner)" | Should -Be "CUSTOM $($script:views.Count) $($script:reports.Count) 1 owner-1"
        ((& $script:text $root['usermappings.json']) | ConvertFrom-Json).users[0].userId | Should -Be 'owner-1'

        $viewZip = & $script:unzip $root['views.zip']
        @($viewZip.Keys) -join ',' | Should -Be 'content.xml,resources/content.properties'
        [xml]$x = & $script:text $viewZip['content.xml']
        @($x.Content.Views.ViewDef).Count | Should -Be $script:views.Count
        [xml]$rx = & $script:text (& $script:unzip $root['reports.zip'])['content.xml']
        @($rx.Content.Reports.ReportDef).Count | Should -Be $script:reports.Count

        $dashZip = & $script:unzip $root['dashboards/owner-1']
        @($dashZip.Keys) -join ',' | Should -Be 'dashboard/dashboard.json,dashboard/resources/resources.properties'
        $dj = (& $script:text $dashZip['dashboard/dashboard.json']) | ConvertFrom-Json
        $dj.dashboards[0].name | Should -Be 'Synth-Overview'
        $dj.PSObject.Properties.Name -join ',' | Should -Be 'entries,dashboards,uuid'
    }

    It 'leaves out what it is not given, and writes nothing with -WhatIf' {
        $path = Join-Path $TestDrive 'views-only.zip'
        $null = New-SynthContentBundle -Path $path -OwnerId 'owner-1' -View $script:views
        $root = & $script:unzip ([System.IO.File]::ReadAllBytes($path))
        $root.Contains('reports.zip') | Should -BeFalse
        $config = (& $script:text $root['configuration.json']) | ConvertFrom-Json
        $config.PSObject.Properties.Name -join ',' | Should -Be 'type,views'
        $none = Join-Path $TestDrive 'none.zip'
        $null = New-SynthContentBundle -Path $none -OwnerId 'owner-1' -View $script:views -WhatIf
        Test-Path $none | Should -BeFalse
    }
}

Describe 'Get-SynthOpsUserId' {
    It 'finds the user by name, ignoring case, and fails clearly when there is none' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest { @{ users = @(@{ id = 'u-1'; username = 'someone' }, @{ id = 'u-2'; username = 'Admin' }) } }
        Get-SynthOpsUserId -UserName 'admin' | Should -Be 'u-2'
        { Get-SynthOpsUserId -UserName 'nobody' } | Should -Throw '*nobody*'
    }
}

Describe 'Import-SynthContentBundle' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:polls = 0
        Mock -ModuleName VcfOpsSynth Start-Sleep { }
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Path = $Path; Query = $Query; Form = $Form })
            if ($Method -eq 'Post') { return $null }
            $script:polls++
            if ($script:polls -lt 3) { return @{ state = 'RUNNING' } }
            @{ state = 'FINISHED'; operationSummaries = @(@{ contentType = 'VIEW_DEFINITIONS'; imported = 5 }) }
        }
        $script:bundle = Join-Path $TestDrive 'b.zip'
        [System.IO.File]::WriteAllBytes($script:bundle, [byte[]](1, 2, 3))
    }

    It 'posts the zip in the named field with force, then polls until it has finished' {
        $r = Import-SynthContentBundle -Path $script:bundle -Force -FieldName 'file'
        $post = $script:calls[0]
        "$($post.Method) $($post.Path) force=$($post.Query.force)" | Should -Be 'Post content/operations/import force=true'
        @($post.Form.Keys) -join ',' | Should -Be 'file'
        $post.Form.file.FullName | Should -Be (Get-Item $script:bundle).FullName
        $script:polls | Should -Be 3
        $r.State | Should -Be 'FINISHED'
        $r.Summaries[0].imported | Should -Be 5
        $r.Errors.Count | Should -Be 0
    }

    It 'sends force=false by default, and stops waiting at the timeout' {
        Mock -ModuleName VcfOpsSynth Invoke-SynthOpsRequest { $script:calls.Add([pscustomobject]@{ Method = $Method; Query = $Query }); if ($Method -eq 'Get') { @{ state = 'RUNNING' } } }
        { Import-SynthContentBundle -Path $script:bundle -TimeoutSec 0 } | Should -Throw "*still 'RUNNING'*"
        $script:calls[0].Query.force | Should -Be 'false'
    }

    It 'refuses a missing bundle' {
        { Import-SynthContentBundle -Path (Join-Path $TestDrive 'missing.zip') } | Should -Throw '*was not found*'
    }
}
