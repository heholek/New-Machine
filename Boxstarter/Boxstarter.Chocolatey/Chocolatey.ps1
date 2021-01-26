
function Install-ChocolateyInstallPackageOverride {
    param(
        [string]
        $packageName,
        
        [string]
        $fileType = 'exe',
        
        [string]
        $silentArgs = '',

        [alias("fileFullPath")]
        [string] 
        $file,

        [alias("fileFullPath64")]
        [string] 
        $file64,

        [Int64[]]
        $validExitCodes = @(0)
    )

    Wait-ForMSIEXEC
    if (Get-IsRemote) {
        Invoke-FromTask @"
Import-Module $env:chocolateyinstall\helpers\chocolateyInstaller.psm1 -Global -DisableNameChecking
Install-ChocolateyInstallPackage $(Expand-Splat $PSBoundParameters)
"@
    }
    else {
        chocolateyInstaller\Install-ChocolateyInstallPackage @PSBoundParameters
    }
}

function Write-HostOverride {
    param(
        [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
        [object] 
        $Object,

        [Parameter()]
        [switch]
        $NoNewLine,

        [Parameter(Mandatory = $false)]
        [ConsoleColor]
        $ForegroundColor,

        [Parameter(Mandatory = $false)]
        [ConsoleColor]
        $BackgroundColor,
        
        [Parameter(Mandatory = $false)]
        [Object]
        $Separator
    )

    if ($null -ne $Boxstarter.ScriptToCall) { 
        Log-BoxStarterMessage $object 
    }

    if ($Boxstarter.SuppressLogging) {
        $caller = (Get-Variable MyInvocation -Scope 1).Value.MyCommand.Name
        if ("Describe", "Context", "Write-PesterResult" -contains $caller) {
            Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
        }
        return;
    }
    $chocoWriteHost = Get-Command -Module chocolateyInstaller | Where-Object { $_.Name -eq "Write-Host" }

    if ($chocoWriteHost) {
        &($chocoWriteHost) @PSBoundParameters
    }
    else {
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
}

new-alias Install-ChocolateyInstallPackage Install-ChocolateyInstallPackageOverride -force
new-alias Write-Host Write-HostOverride -force

<#
.SYNOPSIS
    Intercepts Chocolatey install call to check for reboots
    See function 'chocolatey' for more detail.
#>
function cinst {
    chocolatey -Command "Install" @args
}

<#
.SYNOPSIS
    Intercepts Chocolatey call to check for reboots
    See function 'chocolatey' for more detail.
#>
function choco {  
    param(
        [string]
        $Command
    )

    chocolatey -Command $Command @args
}

<#
.SYNOPSIS
    Intercepts Chocolatey upgrade call to check for reboots
    See function 'chocolatey' for more detail.
#>
function cup {
    chocolatey -Command "Upgrade" @args
}

<#
.SYNOPSIS
    Intercepts Chocolatey call to check for reboots

.DESCRIPTION
    This function wraps a Chocolatey command and provides additional features.
    - Enables the user to specify additonal RebootCodes
    - Detects pending reboots and restarts the machine when necessary to avoid installation failures
    - Provides Reboot Resiliency by ensuring the package installation is immediately restarted up on reboot if there is a reboot during the installation.

.PARAMETER Command
    The Chocolatey command to run.
    Only "install", "uninstall", "upgrade" and "update" will check for pending reboots.

.PARAMETER RebootCodes
    An array of additional return values that will yield in rebooting the machine if Chocolatey
    returns that value. These values will add to the default list of @(3010, -2067919934).
#>
function chocolatey {
    param(
        [string]
        $Command
    )

    $rebootProtectedCommands = @("install", "uninstall", "upgrade", "update")
    if ($rebootProtectedCommands -notcontains $command) {
        Call-Chocolatey @PSBoundParameters @args
        return
    }
    $argsExpanded = $args | Foreach-Object { "$($_); " }
    Write-BoxstarterMessage "Parameters to be passed to Chocolatey: Command='$Command', args='$argsExpanded'" -Verbose

    $stopOnFirstError = (Get-PassedSwitch -SwitchName "StopOnPackageFailure" -OriginalArgs $args) -Or $Boxstarter.StopOnPackageFailure
    Write-BoxstarterMessage "Will stop on first package error: $stopOnFirstError" -Verbose

    $rebootCodes = Get-PassedArg -ArgumentName 'RebootCodes' -OriginalArgs $args
    # if a 'pure Boxstarter' parameter has been specified, 
    # we need to remove it from the command line arguments that 
    # will be passed to Chocolatey, as only Boxstarter is able to handle it
    if ($null -ne $rebootCodes) {
        $argsWithoutBoxstarterSpecials = @()
        $skipNextArg = $false
        foreach ($a in $args) {
            if ($skipNextArg) {
                $skipNextArg = $false;
                continue;
            }

            if (@("-RebootCodes", "--RebootCodes") -contains $a) {
                $skipNextArg = $true
                continue;
            }
            if (@("-StopOnPackageFailure", "--StopOnPackageFailure") -contains $a) {
                continue;
            }
            $argsWithoutBoxstarterSpecials += $a
        }
        $args = $argsWithoutBoxstarterSpecials
    }
    $rebootCodes = Add-DefaultRebootCodes -Codes $rebootCodes
    Write-BoxstarterMessage "RebootCodes: '$rebootCodes' ($($rebootCodes.Count) elements)" -Verbose

    $PackageNames = Get-PackageNamesFromInvocationLine -InvocationArguments $args
    $argsWithoutPackageNames = @()
    # we need to separate package names from remaining arguments,
    # as we're going to install packages one after another,
    # checking for required reboots in between the installs
    $args | ForEach-Object { 
        if ($PackageNames -notcontains $_) { 
            $argsWithoutPackageNames += $_
        } 
    }
    $args = $argsWithoutPackageNames
    Write-BoxstarterMessage "Installing $($PackageNames.Count) packages" -Verbose

    foreach ($packageName in $PackageNames) {
        $PSBoundParameters.PackageNames = $packageName
        if ((Get-PassedArg -ArgumentName @("source", "s") -OriginalArgs $args) -eq "WindowsFeatures") {
            $dismInfo = (DISM /Online /Get-FeatureInfo /FeatureName:$packageName)
            if ($dismInfo -contains "State : Enabled" -or $dismInfo -contains "State : Enable Pending") {
                Write-BoxstarterMessage "$packageName is already installed"
                return
            }
        }
        if (((Test-PendingReboot) -or $Boxstarter.IsRebooting) -and $Boxstarter.RebootOk) {
            return Invoke-Reboot
        }
        $session = Start-TimedSection "Calling Chocolatey to install $packageName. This may take several minutes to complete..."
        $currentErrorCount = 0
        $rebootable = $false
        try {
            [System.Environment]::ExitCode = 0
            Call-Chocolatey -Command $Command -PackageNames $PackageNames @args
            $ec = [System.Environment]::ExitCode
            # suppress errors from enabled features that need a reboot
            if ((Test-WindowsFeatureInstall $args) -and $ec -eq 3010) { 
                $ec = 0
            }
            # Chocolatey reassembles environment variables after an install
            # but does not add the machine PSModule value to the user Online
            $machineModPath = [System.Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
            if (!$env:PSModulePath.EndsWith($machineModPath)) {
                $env:PSModulePath += ";" + $machineModPath
            }

            Write-BoxstarterMessage "Exit Code: $ec" -Verbose
            if ($ec -ne 0) {
                Write-Error "Chocolatey reported an unsuccessful exit code of $ec. See $($Boxstarter.Log) for details."
                $currentErrorCount += 1
            }
        }
        catch {
            Write-BoxstarterMessage "Exception: $($_.Exception.Message)" -Verbose
            #Only write the error to the error stream if it was not previously
            #written by Chocolatey
            $currentErrorCount += 1
            $chocoErrors = $currentErrorCount
            if ($chocoErrors -gt 0) {
                $idx = 0
                $errorWritten = $false
                while ($idx -lt $chocoErrors) {
                    if (($global:error[$idx].Exception.Message | Out-String).Contains($_.Exception.Message)) {
                        $errorWritten = $true
                    }
                    if (!$errorWritten) {
                        Write-Error $_
                    }
                    $idx += 1
                }
            }
        }
        $chocoErrors = $currentErrorCount
        if ($chocoErrors -gt 0) {
            Write-BoxstarterMessage "There was an error calling Chocolatey" -Verbose
            $idx = 0
            while ($idx -lt $chocoErrors) {
                Write-BoxstarterMessage "Error from Chocolatey: $($global:error[$idx].Exception | fl * -Force | Out-String)"
                if ($global:error[$idx] -match "code (was '(?'ecwas'-?\d+)'|of (?'ecof'-?\d+)\.)") {
                    if ($matches["ecwas"]) {
                        $errorCode = $matches["ecwas"]
                    }
                    else {
                        $errorCode = $matches["ecof"]
                    }
                    if ($rebootCodes -contains $errorCode) {
                        Write-BoxstarterMessage "Chocolatey install returned a rebootable exit code ($errorCode)" -Verbose
                        $rebootable = $true
                    }
                    else {
                        Write-BoxstarterMessage "Exit Code '$errorCode' is no reason to reboot" -Verbose 
                        if ($stopOnFirstError) {
                            Write-BoxstarterMessage "Exiting because 'StopOnPackageFailure' is set."
                            Stop-Timedsection $session
                            Remove-ChocolateyPackageInProgress $packageName
                            exit 1
                        }
                    }
                }
                $idx += 1
            }
        }
        Stop-Timedsection $session
        if ($Boxstarter.IsRebooting -or $rebootable) {
            Remove-ChocolateyPackageInProgress $packageName
            Invoke-Reboot
        }
    }
}

<#
.SYNOPSIS
check if a parameter/switch is present in a list of arguments
(1-to many dashes followed by the parameter name)

#>
function Get-PassedSwitch {
    [CmdletBinding()]
    param(
        # the name of the argument switch to look for in $OriginalArgs
        [Parameter(Mandatory = $True)]
        [string]$SwitchName,

        # the full list of original parameters (probably $args)
        [Parameter(Mandatory = $False)]
        [string[]]$OriginalArgs
    )
    return [bool]($OriginalArgs | Where-Object { $_ -match "^-+$SwitchName$" })
}

<#
.SYNOPSIS
    Guess what parts of a choco invocation line are package names.
    (capture everything but named parameters and swtiches)
.EXAMPLE
    PS C:\> Get-PackageNamesFromInvocationLine @("-y", "foo", "bar", "-source", "https://myserver.org/choco")
    will
        * ignore '-y' (as it's not in the known named parameter set)
        * accept "foo" as first package name
        * accept "bar" as second package name
        * ignore '-source' as it's a known named parameter and therefore also skip 'https://myserver.org.choco'
    finally returning @("foo", "bar")
#>
function Get-PackageNamesFromInvocationLine {
    [CmdletBinding()]
    param(
        [PSObject[]]
        $InvocationArguments
    )

    $packageNames = @()

    # NOTE: whenever a new named parameter is added to chocolatey, make sure to update this list ...
    # we somehow need to know what parameters are named and can take a value
    # - if we don't know, the parameter's value will be treated as package name
    $namedParameters = @("force:", # -force:$bool is a zebra
        "s", "source", 
        "log-file",
        "version",
        "ia", "installargs", "installarguments", "install-arguments",
        "override", "overrideargs", "overridearguments", "override-arguments",
        "params", "parameters", "pkgparameters", "packageparameters", "package-parameters",
        "user", "password", "cert", "cp", "certpassword",
        "checksum", "downloadchecksum", "checksum64", "checksumx64", "downloadchecksumx64",
        "checksumtype", "checksum-type", "downloadchecksumtype",
        "checksumtype64", "checksumtypex64", "checksum-type-x64", "downloadchecksumtypex64",
        "timeout", "execution-timeout",
        "cache", "cachelocation", "cache-location",
        "proxy", "proxy-user", "proxy-password", "proxy-bypass-list",
        "viruspositivesmin", "virus-positives-minimum",
        "install-arguments-sensitive", "package-parameters-sensitive",
        "dir", "directory", "installdir", "installdirectory", "install-dir", "install-directory",
        "bps", "maxdownloadrate", "max-download-rate", "maxdownloadbitspersecond", "max-download-bits-per-second", 
        "maximumdownloadbitspersecond", "maximum-download-bits-per-second")

    $skipNext = $false
    foreach ($a in $InvocationArguments) {
        if ($skipNext) {
            # the last thing we've seen is a named parameter
            # skip it's value and continue
            $skipNext = $false
            continue
        }

        # we try to match anything starting with dashes, 
        # as it will always be a parameter or switch
        # (and thus is not a package name)
        if ($a -match "^-.+") {
            $param = $a -replace "^-+"
            if ($namedParameters -contains $param) {
                $skipNext = $true
            }
            elseif ($param.IndexOf('=') -eq $param.Length - 1) {
                $skipNext = $true
            }
        }
        elseif ($a -eq '=') {
            $skipNext = $true
        }
        else {
            $packageNames += $a
        }
    }
    $packageNames
}

function Get-PassedArg {
    [CmdletBinding()]
    param(
        [string[]]
        $ArgumentName,

        [PSObject[]]
        $OriginalArgs
    )

    $candidateKeys = @()
    $ArgumentName | Foreach-Object {
        $candidateKeys += "-$_"
        $candidateKeys += "--$_"
    }
    $nextIsValue = $false
    $val = $null

    foreach ($a in $OriginalArgs) {
        if ($nextIsValue) {
            $nextIsValue = $false
            $val = $a
            break;
        }

        if ($candidateKeys -contains $a) {
            $nextIsValue = $true
        }
        elseif ($a.ToString().Contains("=")) {
            $parts = $a.split("=", 2)
            $nextIsValue = $false
            $val = $parts[1]
        }
    }

    return $val
}

function Test-WindowsFeatureInstall($passedArgs) {
    (Get-PassedArg -ArgumentName @("source", "s") -OriginalArgs $passedArgs) -eq "WindowsFeatures"
}

function Call-Chocolatey {
    param(
        [string]
        $Command,

        [string[]]
        $PackageNames = @('')
    )

    $chocoArgs = @($Command, $PackageNames)
    $chocoArgs += Format-ExeArgs -Command $Command @args
    $chocoArgsExpanded = $chocoArgs | Foreach-Object { "$($_); " }
    Write-BoxstarterMessage "Passing the following args to Chocolatey: @($chocoArgsExpanded)" -Verbose

    $currentLogging = $Boxstarter.Suppresslogging
    try {
        if (Test-WindowsFeatureInstall $args) { 
            $Boxstarter.SuppressLogging = $true 
        }
        if (($PSVersionTable.CLRVersion.Major -lt 4 -or (Test-WindowsFeatureInstall $args)) -and (Get-IsRemote)) {
            Invoke-ChocolateyFromTask $chocoArgs
        }
        else {
            Invoke-LocalChocolatey $chocoArgs
        }
    }
    finally {
        $Boxstarter.SuppressLogging = $currentLogging
    }

    $restartFile = "$(Get-BoxstarterTempDir)\Boxstarter.$PID.restart"
    if (Test-Path $restartFile) {
        Write-BoxstarterMessage "found $restartFile we are restarting"
        $Boxstarter.IsRebooting = $true
        remove-item $restartFile -Force
    }
}

function Invoke-ChocolateyFromTask($chocoArgs) {
    Invoke-BoxstarterFromTask "Invoke-Chocolatey $(Serialize-Array $chocoArgs)"
}

function Invoke-LocalChocolatey($chocoArgs) {
    if (Get-IsRemote) {
        $global:Boxstarter.DisableRestart = $true
    }
    Export-BoxstarterVars

    Enter-DotNet4 {
        if ($env:BoxstarterVerbose -eq 'true') {
            $global:VerbosePreference = "Continue"
        }

        Import-Module "$($args[1].BaseDir)\Boxstarter.chocolatey\Boxstarter.chocolatey.psd1" -DisableNameChecking
        Invoke-Chocolatey $args[0]
    } $chocoArgs, $Boxstarter
}

function Format-ExeArgs {
    param(
        [string]
        $Command
    )

    $newArgs = @()
    $forceArg = $false
    $args | ForEach-Object {
        $p = [string]$_
        Write-BoxstarterMessage  "p: $p" -Verbose
        if ($forceArg) {
            $forceArg = $false
            if ($p -eq "True") {
                $p = "-f"
            } 
            else {
                return
            }
        }
        elseif ($p -eq "-force:") {
            $forceArg = $true
            return
        }
        elseif ($p.StartsWith("-") -and $p.Contains("=")) {
            $pts = $p.split("=", 2)
            $newArgs += $pts[0]
            $p = $pts[1]
        }

        $newArgs += $p
    }

    if ($null -eq (Get-PassedArg -ArgumentName @("source", "s") -OriginalArgs $args)) {
        if (@("Install", "Upgrade") -contains $Command) {
            $newArgs += "-Source"
            $newArgs += "$($Boxstarter.LocalRepo);$((Get-BoxstarterConfig).NugetSources)"
        }
    }

    if ($newArgs -notcontains "-Verbose") {
        if ($global:VerbosePreference -eq "Continue") {
            $newArgs += "-Verbose"
        }
    }

    if ($newArgs -notcontains "-y") {
        $newArgs += '-y'
    }
    $newArgs
}

function Add-DefaultRebootCodes {
    [CmdletBinding()]
    param(
        [PSObject[]]
        $Codes
    )

    if ($Codes -notcontains 3010) {
        $Codes += 3010 #common MSI reboot needed code
    }
    if ($Codes -notcontains -2067919934) {
        $Codes += -2067919934 #returned by SQL Server when it needs a reboot
    }
    return $Codes
}

function Remove-ChocolateyPackageInProgress($packageName) {
    $pkgDir = "$env:ChocolateyInstall\lib\$packageName"
    if (Test-Path $pkgDir) {
        Write-BoxstarterMessage "Removing $pkgDir in progress" -Verbose
        remove-item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Expand-Splat($splat) {
    $ret = ""
    ForEach ($item in $splat.KEYS.GetEnumerator()) {
        $ret += "-$item$(Resolve-SplatValue $splat[$item]) "
    }
    Write-BoxstarterMessage "Expanded splat to $ret"
    return $ret
}

function Resolve-SplatValue($val) {
    if ($val -is [switch]) {
        if ($val.IsPresent) {
            return ":`$True"
        }
        else {
            return ":`$False"
        }
    }
    return " $(ConvertTo-PSString $val)"
}

function Wait-ForMSIEXEC {
    Write-BoxstarterMessage "Checking for other running MSIEXEC installers..." -Verbose
    Do {
        Get-Process | Where-Object { $_.Name -eq "MSIEXEC" } | Foreach-Object {
            if (!($_.HasExited)) {
                $proc = Get-WmiObject -Class Win32_Process -Filter "ProcessID=$($_.Id)"
                if ($null -ne $proc.CommandLine -and $proc.CommandLine.EndsWith(" /V")) { 
                    break 
                }
                Write-BoxstarterMessage "Another installer is running: $($proc.CommandLine). Waiting for it to complete..."
                $_.WaitForExit()
            }
        }
    } Until ($null -eq (Get-Process | Where-Object { $_.Name -eq "MSIEXEC" } ))
}

function Export-BoxstarterVars {
    $boxstarter.keys | ForEach-Object {
        Export-ToEnvironment "Boxstarter.$_"
    }
    if ($script:BoxstarterPassword) {
        Export-ToEnvironment "BoxstarterPassword" script
    }
    Export-ToEnvironment "VerbosePreference" global
    Export-ToEnvironment "DebugPreference" global
    $env:BoxstarterSourcePID = $PID
}

function Export-ToEnvironment($varToExport, $scope) {
    $val = Invoke-Expression "`$$($scope):$varToExport"
    if ($val -is [string] -or $val -is [boolean]) {
        Set-Item -Path "Env:\BEX.$varToExport" -Value $val.ToString() -Force
    }
    elseif ($null -eq $val) {
        Set-Item -Path "Env:\BEX.$varToExport" -Value '$null' -Force
    }
    Write-BoxstarterMessage "Exported $varToExport from $PID to `$env:BEX.$varToExport with value $val" -verbose
}

function Serialize-BoxstarterVars {
    $res = ""
    $boxstarter.keys | Foreach-Object {
        $res += "`$global:Boxstarter['$_']=$(ConvertTo-PSString $Boxstarter[$_])`r`n"
    }
    if ($script:BoxstarterPassword) {
        $res += "`$script:BoxstarterPassword='$($script:BoxstarterPassword)'`r`n"
    }
    $res += "`$global:VerbosePreference='$global:VerbosePreference'`r`n"
    $res += "`$global:DebugPreference='$global:DebugPreference'`r`n"
    Write-BoxstarterMessage "Serialized boxstarter vars to:" -verbose
    Write-BoxstarterMessage $res -verbose
    $res
}

function Import-FromEnvironment ($varToImport, $scope) {
    if (!(Test-Path "Env:\$varToImport")) { 
        return 
    }
    [object]$ival = (Get-Item "Env:\$varToImport").Value.ToString()

    if ($ival.ToString() -eq 'True') { 
        $ival = $true 
    }
    if ($ival.ToString() -eq 'False') {
        $ival = $false 
    }
    if ($ival.ToString() -eq '$null') {
        $ival = $null 
    }

    Write-BoxstarterMessage "Importing $varToImport from $env:BoxstarterSourcePID to $PID with value $ival" -Verbose

    $newVar = $varToImport.Substring('BEX.'.Length)
    Invoke-Expression "`$$($scope):$newVar=$(ConvertTo-PSString $ival)"

    remove-item "Env:\$varToImport"
}

function Import-BoxstarterVars {
    Write-BoxstarterMessage "Importing Boxstarter vars into pid $PID from pid: $($env:BoxstarterSourcePID)" -verbose
    Import-FromEnvironment "BEX.BoxstarterPassword" script

    $varsToImport = @()
    Get-ChildItem -Path env: | Where-Object { $_.Name.StartsWith('BEX.') } | ForEach-Object { $varsToImport += $_.Name }

    $varsToImport | ForEach-Object { Import-FromEnvironment $_ global }

    $boxstarter.SourcePID = $env:BoxstarterSourcePID
}

function ConvertTo-PSString($originalValue) {
    if ($originalValue -is [int] -or $originalValue -is [int64]) {
        "$originalValue"
    }
    elseif ($originalValue -is [Array]) {
        Serialize-Array $originalValue
    }
    elseif ($originalValue -is [boolean]) {
        "`$$($originalValue.ToString())"
    }
    elseif ($null -ne $originalValue) {
        "`"$($originalValue.ToString().Replace('"','`' + '"'))`""
    }
    else {
        "`$null"
    }
}

function Serialize-Array($chocoArgs) {
    $first = $false
    $res = "@("
    $chocoArgs | Foreach-Object {
        if ($first) { 
            $res += "," 
        }
        $res += ConvertTo-PSString $_
        $first = $true
    }
    $res += ")"
    $res
}

# SIG # Begin signature block
# MIIcpwYJKoZIhvcNAQcCoIIcmDCCHJQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD7ZfLPFum7nftb
# /vnvXTbnFpP/Uw1XP5addQVAZlVdkqCCF7EwggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggU6MIIEIqADAgECAhAH+0XZ9wtVKQNgl7T04UNwMA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTgwMzMwMDAwMDAw
# WhcNMjEwNDE0MTIwMDAwWjB3MQswCQYDVQQGEwJVUzEPMA0GA1UECBMGS2Fuc2Fz
# MQ8wDQYDVQQHEwZUb3Bla2ExIjAgBgNVBAoTGUNob2NvbGF0ZXkgU29mdHdhcmUs
# IEluYy4xIjAgBgNVBAMTGUNob2NvbGF0ZXkgU29mdHdhcmUsIEluYy4wggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC4irdLWVJryfKSgPPCyMN+nBmxtZIm
# mTBhJMaYVJ6gtfvHcFakH7IC8TcjcEIrkK7wB/2vEJkEqiOTgbVQPZLnfX8ZAxhd
# UiJmwQHEiSwLzoo2B35ROQ9qdOsn1bYIEzDpaqm/XwYH925LLpxhr9oCkBNf5dZs
# e5bc/s1J5sQ9HRYwpb3MimmNHGpNP/YhjXX/kNFCZIv3mUadFHi+talYIN5dp6ai
# /k+qgZeL5klPdmjyIgf3JiDywCf7j5nSbm3sWarYjM5vLe/oD+eK70fez30a17Cy
# 97Jtqmdz6WUV1BcbMWeb9b8x369UJq5vt7vGwVFDOeGjwffuVHLRvWLnAgMBAAGj
# ggHFMIIBwTAfBgNVHSMEGDAWgBRaxLl7KgqjpepxA8Bg+S32ZXUOWDAdBgNVHQ4E
# FgQUqRlYCMLOvsDUS4mx9UA1avD3fvgwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMHcGA1UdHwRwMG4wNaAzoDGGL2h0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9zaGEyLWFzc3VyZWQtY3MtZzEuY3JsMDWgM6Axhi9odHRwOi8vY3Js
# NC5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDBMBgNVHSAERTBD
# MDcGCWCGSAGG/WwDATAqMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2Vy
# dC5jb20vQ1BTMAgGBmeBDAEEATCBhAYIKwYBBQUHAQEEeDB2MCQGCCsGAQUFBzAB
# hhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wTgYIKwYBBQUHMAKGQmh0dHA6Ly9j
# YWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFNIQTJBc3N1cmVkSURDb2RlU2ln
# bmluZ0NBLmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQA+ddcs
# z/NB/+V+AIlUNOVTlGDNCtn1AfvwoRZg9XMmx0/S0EKayfVFTk/x96WMQgxL+/5x
# B8Uhw6anlhbPC6bjBcIxRj/IUgR7yJ/NAykyM1x+pWvkPZV3slwe0GDPwhaqGUTU
# aG8njO4EvA682a1o7wqQFR1MIltjtuPB2gp311LLxP1k5dpUMgaA0lAfnbRr+5dc
# QOFWslkho1eBf0xlzSrhRGPy0e/IYWpl+/sEwXhD88QUkN7dSXY0fMlyGQfn6H4f
# ozBQvCk37eoE0uAtkUrWAlJxO/4Esi83ko4hokwQJHaN64/7NdNaKlG3shC9+2QM
# kY3j3BU+Ym2GZgtBMIIGajCCBVKgAwIBAgIQAwGaAjr/WLFr1tXq5hfwZjANBgkq
# hkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5j
# MRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBB
# c3N1cmVkIElEIENBLTEwHhcNMTQxMDIyMDAwMDAwWhcNMjQxMDIyMDAwMDAwWjBH
# MQswCQYDVQQGEwJVUzERMA8GA1UEChMIRGlnaUNlcnQxJTAjBgNVBAMTHERpZ2lD
# ZXJ0IFRpbWVzdGFtcCBSZXNwb25kZXIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
# ggEKAoIBAQCjZF38fLPggjXg4PbGKuZJdTvMbuBTqZ8fZFnmfGt/a4ydVfiS457V
# WmNbAklQ2YPOb2bu3cuF6V+l+dSHdIhEOxnJ5fWRn8YUOawk6qhLLJGJzF4o9GS2
# ULf1ErNzlgpno75hn67z/RJ4dQ6mWxT9RSOOhkRVfRiGBYxVh3lIRvfKDo2n3k5f
# 4qi2LVkCYYhhchhoubh87ubnNC8xd4EwH7s2AY3vJ+P3mvBMMWSN4+v6GYeofs/s
# jAw2W3rBerh4x8kGLkYQyI3oBGDbvHN0+k7Y/qpA8bLOcEaD6dpAoVk62RUJV5lW
# MJPzyWHM0AjMa+xiQpGsAsDvpPCJEY93AgMBAAGjggM1MIIDMTAOBgNVHQ8BAf8E
# BAMCB4AwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCCAb8G
# A1UdIASCAbYwggGyMIIBoQYJYIZIAYb9bAcBMIIBkjAoBggrBgEFBQcCARYcaHR0
# cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzCCAWQGCCsGAQUFBwICMIIBVh6CAVIA
# QQBuAHkAIAB1AHMAZQAgAG8AZgAgAHQAaABpAHMAIABDAGUAcgB0AGkAZgBpAGMA
# YQB0AGUAIABjAG8AbgBzAHQAaQB0AHUAdABlAHMAIABhAGMAYwBlAHAAdABhAG4A
# YwBlACAAbwBmACAAdABoAGUAIABEAGkAZwBpAEMAZQByAHQAIABDAFAALwBDAFAA
# UwAgAGEAbgBkACAAdABoAGUAIABSAGUAbAB5AGkAbgBnACAAUABhAHIAdAB5ACAA
# QQBnAHIAZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgAIABsAGkAbQBpAHQAIABsAGkA
# YQBiAGkAbABpAHQAeQAgAGEAbgBkACAAYQByAGUAIABpAG4AYwBvAHIAcABvAHIA
# YQB0AGUAZAAgAGgAZQByAGUAaQBuACAAYgB5ACAAcgBlAGYAZQByAGUAbgBjAGUA
# LjALBglghkgBhv1sAxUwHwYDVR0jBBgwFoAUFQASKxOYspkH7R7for5XDStnAs0w
# HQYDVR0OBBYEFGFaTSS2STKdSip5GoNL9B6Jwcp9MH0GA1UdHwR2MHQwOKA2oDSG
# Mmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRENBLTEu
# Y3JsMDigNqA0hjJodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1
# cmVkSURDQS0xLmNybDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEQ0EtMS5jcnQwDQYJKoZIhvcN
# AQEFBQADggEBAJ0lfhszTbImgVybhs4jIA+Ah+WI//+x1GosMe06FxlxF82pG7xa
# FjkAneNshORaQPveBgGMN/qbsZ0kfv4gpFetW7easGAm6mlXIV00Lx9xsIOUGQVr
# NZAQoHuXx/Y/5+IRQaa9YtnwJz04HShvOlIJ8OxwYtNiS7Dgc6aSwNOOMdgv420X
# Ewbu5AO2FKvzj0OncZ0h3RTKFV2SQdr5D4HRmXQNJsQOfxu19aDxxncGKBXp2JPl
# VRbwuwqrHNtcSCdmyKOLChzlldquxC5ZoGHd2vNtomHpigtt7BIYvfdVVEADkitr
# wlHCCkivsNRu4PQUCjob4489yq9qjXvc2EQwggbNMIIFtaADAgECAhAG/fkDlgOt
# 6gAK6z8nu7obMA0GCSqGSIb3DQEBBQUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0wNjExMTAwMDAwMDBa
# Fw0yMTExMTAwMDAwMDBaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IEFzc3VyZWQgSUQgQ0EtMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
# ggEBAOiCLZn5ysJClaWAc0Bw0p5WVFypxNJBBo/JM/xNRZFcgZ/tLJz4FlnfnrUk
# FcKYubR3SdyJxArar8tea+2tsHEx6886QAxGTZPsi3o2CAOrDDT+GEmC/sfHMUiA
# fB6iD5IOUMnGh+s2P9gww/+m9/uizW9zI/6sVgWQ8DIhFonGcIj5BZd9o8dD3QLo
# Oz3tsUGj7T++25VIxO4es/K8DCuZ0MZdEkKB4YNugnM/JksUkK5ZZgrEjb7Szgau
# rYRvSISbT0C58Uzyr5j79s5AXVz2qPEvr+yJIvJrGGWxwXOt1/HYzx4KdFxCuGh+
# t9V3CidWfA9ipD8yFGCV/QcEogkCAwEAAaOCA3owggN2MA4GA1UdDwEB/wQEAwIB
# hjA7BgNVHSUENDAyBggrBgEFBQcDAQYIKwYBBQUHAwIGCCsGAQUFBwMDBggrBgEF
# BQcDBAYIKwYBBQUHAwgwggHSBgNVHSAEggHJMIIBxTCCAbQGCmCGSAGG/WwAAQQw
# ggGkMDoGCCsGAQUFBwIBFi5odHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9zc2wtY3Bz
# LXJlcG9zaXRvcnkuaHRtMIIBZAYIKwYBBQUHAgIwggFWHoIBUgBBAG4AeQAgAHUA
# cwBlACAAbwBmACAAdABoAGkAcwAgAEMAZQByAHQAaQBmAGkAYwBhAHQAZQAgAGMA
# bwBuAHMAdABpAHQAdQB0AGUAcwAgAGEAYwBjAGUAcAB0AGEAbgBjAGUAIABvAGYA
# IAB0AGgAZQAgAEQAaQBnAGkAQwBlAHIAdAAgAEMAUAAvAEMAUABTACAAYQBuAGQA
# IAB0AGgAZQAgAFIAZQBsAHkAaQBuAGcAIABQAGEAcgB0AHkAIABBAGcAcgBlAGUA
# bQBlAG4AdAAgAHcAaABpAGMAaAAgAGwAaQBtAGkAdAAgAGwAaQBhAGIAaQBsAGkA
# dAB5ACAAYQBuAGQAIABhAHIAZQAgAGkAbgBjAG8AcgBwAG8AcgBhAHQAZQBkACAA
# aABlAHIAZQBpAG4AIABiAHkAIAByAGUAZgBlAHIAZQBuAGMAZQAuMAsGCWCGSAGG
# /WwDFTASBgNVHRMBAf8ECDAGAQH/AgEAMHkGCCsGAQUFBwEBBG0wazAkBggrBgEF
# BQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAChjdodHRw
# Oi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0Eu
# Y3J0MIGBBgNVHR8EejB4MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMDqgOKA2hjRodHRwOi8vY3JsNC5k
# aWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMB0GA1UdDgQW
# BBQVABIrE5iymQftHt+ivlcNK2cCzTAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYun
# pyGd823IDzANBgkqhkiG9w0BAQUFAAOCAQEARlA+ybcoJKc4HbZbKa9Sz1LpMUer
# Vlx71Q0LQbPv7HUfdDjyslxhopyVw1Dkgrkj0bo6hnKtOHisdV0XFzRyR4WUVtHr
# uzaEd8wkpfMEGVWp5+Pnq2LN+4stkMLA0rWUvV5PsQXSDj0aqRRbpoYxYqioM+Sb
# OafE9c4deHaUJXPkKqvPnHZL7V/CSxbkS3BMAIke/MV5vEwSV/5f4R68Al2o/vsH
# OE8Nxl2RuQ9nRc3Wg+3nkg2NsWmMT/tZ4CMP0qquAHzunEIOz5HXJ7cW7g/DvXwK
# oO4sCFWFIrjrGBpN/CohrUkxg0eVd3HcsRtLSxwQnHcUwZ1PL1qVCCkQJjGCBEww
# ggRIAgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0IFNI
# QTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAf7Rdn3C1UpA2CXtPThQ3Aw
# DQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkq
# hkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGC
# NwIBFTAvBgkqhkiG9w0BCQQxIgQgVfIFRBJT4J8V0DVat/mGQcGmEXLGLhXSLtNg
# QAcz4dUwDQYJKoZIhvcNAQEBBQAEggEAUlRbbkUF1nym6Q7VqOzIsn18IHkogjBV
# B0Y4uCH5d14tKAjj8qZjmiDc/ONRjizja+d3LT71IIvQ9iUAIhwBMX3vF2tSlPOr
# IXdXuJwpI8vI3jVqy7Atal3JXnlMHYuvYwJR6uREuZcc372UUBuS0AJ+FaqpHkbw
# rqNrjY2nbDw7vduEj6x9ChKSIoT9MGNQtyuXg+EsalM4bcALBBlYoosWCVmhR0Cj
# +n8M42uBlsnmslmMZ50mba6EYhR+zb+mLyQfDFXtp1igcrOvfWdK6c7yTQoHW1tw
# 4fGRj08G0bggaVHQtaDOpLD5Ak1itCC+9udtKHTRBXwypDPAiky6i6GCAg8wggIL
# BgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq5hfwZjAJ
# BgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0B
# CQUxDxcNMjAxMDE1MTAxMTQ0WjAjBgkqhkiG9w0BCQQxFgQUknrErNTx3QEKJ5nA
# kvmdrT6FnsowDQYJKoZIhvcNAQEBBQAEggEAK15vo2C/PZrE6aWs3/lnm6PRVaUb
# ITm1/1tVV0n9FqFoRWZXHaPC8nkgpXNCAAlmOSSDl07L8dIOiMedYXpwdhw7ZV2a
# jo3iepwxgjOl6YOL+AfDHwL4DxQNb4LrqysCLrGlXRzWrKYeiRb9Q/mDzS/+k1Th
# 8tKVQcI0ZSPtZ5IoOk+CVfQa+DNE77vNEu0XZBEFezA6265V0xwa8HeqiHXRxGPI
# HFeUDoujwf8wSx3DHb7NE9GpHe9mum3gmF6KQq0C6JOqunHR4IcqLrC3/BcL9stQ
# M0VP8kcrcH5iO19tMiIZJmqjTx+15Vq7TeNOQ5rFzAezM2dtV70gQNDNGw==
# SIG # End signature block
