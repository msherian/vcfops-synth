# Pester 5 tests for the Suite API client. Invoke-RestMethod is mocked; no lab needed.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/VcfOpsSynth/VcfOpsSynth.psd1') -Force
    $script:config = Get-SynthConfig -Path (Join-Path $PSScriptRoot '../config/lab.example.json')
    $script:password = ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force

    # An error shaped like the one Invoke-RestMethod throws for an HTTP failure.
    function New-HttpError {
        param([int]$Status)
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status)
        $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new("HTTP $Status", $response)
        [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null)
    }
}

Describe 'Connect-SynthOps' {
    It 'posts the credentials to token/acquire and keeps the token' {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { [pscustomobject]@{ token = 'tok-1'; validity = 1893456000000 } }

        $session = Connect-SynthOps -Config $script:config -Password $script:password

        $session.BaseUri | Should -Be 'https://ops-a.site-a.vcf.lab/suite-api'
        $session.Expires.Year | Should -Be 2030
        Should -Invoke -ModuleName VcfOpsSynth Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://ops-a.site-a.vcf.lab/suite-api/api/auth/token/acquire' -and
            $Method -eq 'Post' -and
            ($Body | ConvertFrom-Json).authSource -eq 'LOCAL' -and
            ($Body | ConvertFrom-Json).password -eq 'not-a-real-password' -and
            $SkipCertificateCheck
        }
    }

    It 'refuses to sign in without a password' {
        Remove-Item Env:VCFOPS_PASSWORD, Env:VCFOPS_PASSWORD_FILE -ErrorAction SilentlyContinue
        { Connect-SynthOps -Config $script:config } | Should -Throw '*VCFOPS_PASSWORD*'
    }

    It 'says which server and account failed' {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { throw 'connection refused' }
        { Connect-SynthOps -Config $script:config -Password $script:password } |
            Should -Throw '*ops-a.site-a.vcf.lab as admin (LOCAL)*connection refused*'
    }
}

Describe 'Invoke-SynthOpsRequest' {
    BeforeEach {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { [pscustomobject]@{ token = 'tok-1' } } -ParameterFilter { $Uri -like '*/auth/token/acquire' }
        Mock -ModuleName VcfOpsSynth Start-Sleep { }
        $null = Connect-SynthOps -Config $script:config -Password $script:password
    }

    It 'sends the OpsToken header, a JSON body and an encoded query' {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { 'ok' } -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }

        Invoke-SynthOpsRequest -Method Post -Path '/resources/stats' -Query @{ disableAnalyticsProcessing = 'true'; name = 'a b' } -Body @{ x = 1 } |
            Should -Be 'ok'

        Should -Invoke -ModuleName VcfOpsSynth Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://ops-a.site-a.vcf.lab/suite-api/api/resources/stats?disableAnalyticsProcessing=true&name=a%20b' -and
            $Headers.Authorization -eq 'OpsToken tok-1' -and
            $ContentType -eq 'application/json' -and
            $Body -eq '{"x":1}'
        }
    }

    It 'retries a 503 and then succeeds' {
        $script:calls = 0
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 3) { throw (New-HttpError 503) }
            'ok'
        } -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }

        Invoke-SynthOpsRequest -Method Get -Path 'adapterkinds' | Should -Be 'ok'
        $script:calls | Should -Be 3
        Should -Invoke -ModuleName VcfOpsSynth Start-Sleep -Times 2
    }

    It 'gives up after MaxRetries and reports the status' {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { throw (New-HttpError 429) } -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }

        { Invoke-SynthOpsRequest -Method Get -Path 'adapterkinds' -MaxRetries 2 } | Should -Throw '*HTTP 429*'
        Should -Invoke -ModuleName VcfOpsSynth Invoke-RestMethod -Times 3 -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }
    }

    It 'does not retry a 400' {
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod { throw (New-HttpError 400) } -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }

        { Invoke-SynthOpsRequest -Method Post -Path 'resources' -Body @{} } | Should -Throw '*HTTP 400*'
        Should -Invoke -ModuleName VcfOpsSynth Start-Sleep -Times 0
    }

    It 'signs in again once when the token is rejected' {
        $script:calls = 0
        Mock -ModuleName VcfOpsSynth Invoke-RestMethod {
            $script:calls++
            if ($script:calls -eq 1) { throw (New-HttpError 401) }
            'ok'
        } -ParameterFilter { $Uri -notlike '*/auth/token/acquire' }

        Invoke-SynthOpsRequest -Method Get -Path 'adapterkinds' | Should -Be 'ok'
        Should -Invoke -ModuleName VcfOpsSynth Invoke-RestMethod -Times 2 -ParameterFilter { $Uri -like '*/auth/token/acquire' }
    }

    It 'refuses to run before Connect-SynthOps' {
        InModuleScope VcfOpsSynth { $script:OpsSession = $null }
        { Invoke-SynthOpsRequest -Method Get -Path 'adapterkinds' } | Should -Throw '*Connect-SynthOps*'
    }
}

Describe 'Get-SynthRetryDelay' {
    It 'doubles from 2 seconds and caps at 60' {
        InModuleScope VcfOpsSynth -Parameters @{ Err = (New-HttpError 503) } {
            param($Err)
            (1..7 | ForEach-Object { Get-SynthRetryDelay -ErrorRecord $Err -Attempt $_ }) -join ',' | Should -Be '2,4,8,16,32,60,60'
        }
    }
}
