# Pester 5 tests for configuration loading and validation. No lab needed.
#   Invoke-Pester -Path ./tests
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that writes into the Pester TestDrive.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixture passwords, not secrets.')]
param()

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

    It 'lets -Fqdn, -Username and -AuthSource win over the file and the variables' {
        $path = New-LabFile @{ operations = @{ fqdn = 'from-file.example.test' } }
        $env:VCFOPS_FQDN = 'from-env.example.test'
        try {
            $config = Get-SynthConfig -Path $path -Fqdn 'from-param.example.test' -Username 'svc-synth' -AuthSource 'vIDMAuthSource'
            $config.operations.fqdn | Should -Be 'from-param.example.test'
            $config.operations.username | Should -Be 'svc-synth'
            $config.operations.authSource | Should -Be 'vIDMAuthSource'
            (Get-SynthConfig -Path $path).operations.fqdn | Should -Be 'from-env.example.test'
        }
        finally { Remove-Item Env:VCFOPS_FQDN -ErrorAction SilentlyContinue }
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

Describe 'Read-SynthCredentialFile' {
    BeforeAll {
        function New-CredFile {
            param([object[]]$Components)
            $path = Join-Path $TestDrive "creds-$([guid]::NewGuid()).json"
            @{ components = $Components } | ConvertTo-Json -Depth 10 | Set-Content -Path $path
            $path
        }
        function New-Component {
            param([string]$Name, [string]$Fqdn, [hashtable[]]$Credentials)
            @{ componentName = $Name; FQDN = $Fqdn; credentials = $Credentials }
        }
        $script:admin = @{ type = 'Administrator credentials'; user = 'admin'; password = 'ops-pass-1' }
        $script:root = @{ type = 'Root credentials'; user = 'root'; password = 'root-pass-1' }
    }

    It 'takes the host, account and password from the VCF Operations entry' {
        $path = New-CredFile @(
            (New-Component 'vCenter' 'vc.example.test' @(@{ type = 'Administrator credentials'; user = 'administrator@vsphere.local'; password = 'vc-pass' })),
            (New-Component 'VCF Operations' 'ops.example.test' @($script:root, $script:admin)))
        $cred = Read-SynthCredentialFile -Path $path
        $cred.Fqdn | Should -Be 'ops.example.test'
        $cred.Username | Should -Be 'admin'
        ConvertFrom-SecureString $cred.Password -AsPlainText | Should -Be 'ops-pass-1'
    }

    It 'cuts a URL down to its host name' {
        $path = New-CredFile @(, (New-Component 'VCF Operations' 'https://ops.example.test/ui/' @($script:admin)))
        (Read-SynthCredentialFile -Path $path).Fqdn | Should -Be 'ops.example.test'
    }

    It 'picks one of several VCF Operations by -Fqdn, and asks for it otherwise' {
        $other = @{ type = 'Administrator credentials'; user = 'admin'; password = 'ops-pass-2' }
        $path = New-CredFile @(
            (New-Component 'VCF Operations' 'ops-a.example.test' @($script:admin)),
            (New-Component 'VCF Operations' 'ops-b.example.test' @($other)))
        ConvertFrom-SecureString (Read-SynthCredentialFile -Path $path -Fqdn 'OPS-B.example.test').Password -AsPlainText | Should -Be 'ops-pass-2'
        { Read-SynthCredentialFile -Path $path } | Should -Throw '*lists 2 VCF Operations (ops-a.example.test, ops-b.example.test); choose one with -Fqdn*'
    }

    It 'tells an unreadable file from one that is not JSON' {
        # A folder passes the existence check but cannot be read, as an unreadable mount cannot.
        $folder = Join-Path $TestDrive 'creds-folder.json'
        $null = New-Item -ItemType Directory -Path $folder
        { Read-SynthCredentialFile -Path $folder } | Should -Throw '*cannot be read*uid 999*'
        $broken = Join-Path $TestDrive 'broken-creds.json'
        Set-Content -Path $broken -Value '{ "components": '
        { Read-SynthCredentialFile -Path $broken } | Should -Throw '*not valid JSON*'
    }

    It 'says what is missing' {
        { Read-SynthCredentialFile -Path (Join-Path $TestDrive 'absent.json') } | Should -Throw '*does not exist*'
        { Read-SynthCredentialFile -Path (New-CredFile @(, (New-Component 'vCenter' 'vc.example.test' @($script:admin)))) } | Should -Throw '*has no VCF Operations entry*'
        { Read-SynthCredentialFile -Path (New-CredFile @(, (New-Component 'VCF Operations' 'ops.example.test' @($script:root)))) } | Should -Throw "*no Administrator credentials for VCF Operations at 'ops.example.test'*"
        $notCreds = Join-Path $TestDrive 'not-creds.json'
        Set-Content -Path $notCreds -Value '{ "operations": {} }'
        { Read-SynthCredentialFile -Path $notCreds } | Should -Throw '*not a VCF installer credentials file*'
    }

    It 'stops -PasswordFile sending a whole credentials file as the password' {
        $path = New-CredFile @(, (New-Component 'VCF Operations' 'ops.example.test' @($script:admin)))
        { Get-SynthSecret -PasswordFile $path } | Should -Throw '*a VCF installer credentials file, not a password; pass it as -CredentialFile*'
    }
}
Describe 'Get-SynthSecret' {
    BeforeEach {
        Remove-Item Env:VCFOPS_PASSWORD, Env:VCFOPS_PASSWORD_FILE, Env:VCFOPS_SECRET_NAME -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item Env:VCFOPS_PASSWORD, Env:VCFOPS_PASSWORD_FILE, Env:VCFOPS_SECRET_NAME -ErrorAction SilentlyContinue
    }

    It 'reads a Docker secret by name from the secrets folder' {
        Set-Content -Path (Join-Path $TestDrive 'vcfops_password') -Value 'from-secret'
        $env:VCFOPS_SECRET_NAME = 'vcfops_password'
        InModuleScope VcfOpsSynth -Parameters @{ Folder = $TestDrive } { param($Folder) ConvertFrom-SecureString (Get-SynthSecret -SecretsPath $Folder) -AsPlainText } | Should -Be 'from-secret'
        InModuleScope VcfOpsSynth -Parameters @{ Folder = $TestDrive } { param($Folder) ConvertFrom-SecureString (Get-SynthSecret -SecretName 'vcfops_password' -SecretsPath $Folder) -AsPlainText } | Should -Be 'from-secret'
    }

    It 'refuses a secret name that is a path' {
        { InModuleScope VcfOpsSynth { Get-SynthSecret -SecretName '../etc/passwd' } } | Should -Throw '*must be a secret name, not a path*'
    }

    It 'lets any parameter win over every variable' {
        $env:VCFOPS_PASSWORD = 'from-env'
        $file = Join-Path $TestDrive 'pw.txt'
        Set-Content -Path $file -Value 'from-param-file'
        InModuleScope VcfOpsSynth -Parameters @{ File = $file } { param($File) ConvertFrom-SecureString (Get-SynthSecret -PasswordFile $File) -AsPlainText } | Should -Be 'from-param-file'
        InModuleScope VcfOpsSynth { ConvertFrom-SecureString (Get-SynthSecret -Password 'from-param') -AsPlainText } | Should -Be 'from-param'
        $secure = ConvertTo-SecureString 'secure-param' -AsPlainText -Force
        InModuleScope VcfOpsSynth -Parameters @{ S = $secure } { param($S) ConvertFrom-SecureString (Get-SynthSecret -Password $S) -AsPlainText } | Should -Be 'secure-param'
    }

    It 'takes the password before the file before the secret' {
        $file = Join-Path $TestDrive 'pw2.txt'
        Set-Content -Path $file -Value 'from-file'
        $env:VCFOPS_PASSWORD_FILE = $file
        $env:VCFOPS_SECRET_NAME = 'absent'
        InModuleScope VcfOpsSynth { ConvertFrom-SecureString (Get-SynthSecret) -AsPlainText } | Should -Be 'from-file'
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
