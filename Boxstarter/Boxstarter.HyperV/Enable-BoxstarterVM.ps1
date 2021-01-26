function Enable-BoxstarterVM {
<#
.SYNOPSIS
Opens WMI ports and LocalAccountTokenFilterPolicy for Workgroup Hyper-V VMs

.DESCRIPTION
Prepares a Hyper-V VM for Boxstarter Installation. Opening WMI
ports if remoting is not enabled and enabling
LocalAccountTokenFilterPolicy if the VM is not in a domain so
that Boxstarter can later enable PowerShell Remoting.

Enable-BoxstarterVM will also restore the VM to a specified
checkpoint or create a new checkpoint if the given checkpoint
does not exist.

.Parameter Provider
The VM Provider to use.

.PARAMETER VMName
The name of the VM to enable.

.PARAMETER Credential
The Credential to use to test PSRemoting.

.PARAMETER CheckpointName
If a Checkpoint exists by this name, it will be restored. Otherwise one will be created.

.NOTES
PSRemoting must be enabled in order for Boxstarter to install to a remote machine. Bare
Metal machines require a manual step of enabling it before remote Boxstarter installs
will work. However, on a Hyper-V VM, Boxstarter can manage this by mounting and
manipulating the VM's VHD. Boxstarter can open the WMI ports which enable it to create a
Scheduled Task that will enable PSRemoting. For VMs that are not domain joined,
Boxstarter will also enable LocalAccountTokenFilterPolicy so that local accounts can
authenticate remotely.

For Non-HyperV VMs, use Enable-BoxstarterVHD to perform these adjustments on the VHD of
the VM. The VM must be powered off and accessible.

.OUTPUTS
A BoxstarterConnectionConfig that contains the ConnectionURI of the VM Computer and
the PSCredential needed to authenticate.

.EXAMPLE
$cred=Get-Credential domain\username
Enable-BoxstarterVM -Provider HyperV -VMName MyVM $cred

Prepares MyVM for a Boxstarter Installation

.EXAMPLE
Enable-BoxstarterVM -Provider HyperV -VMName MyVM $cred | Install-BoxstarterPackage MyPackage

Prepares MyVM and then installs MyPackage

.EXAMPLE
Enable-BoxstarterVM -Provider HyperV -VMName MyVM $cred ExistingSnapshot | Install-BoxstarterPackage MyPackage

Prepares MyVM, Restores ExistingSnapshot and then installs MyPackage

.EXAMPLE
Enable-BoxstarterVM -Provider HyperV -VMName MyVM $cred NewSnapshot | Install-BoxstarterPackage MyPackage

Prepares MyVM, Creates a new snapshot named NewSnapshot and then installs MyPackage

.LINK
https://boxstarter.org
Enable-BoxstarterVHD
Install-BoxstarterPackage
#>
    [CmdletBinding()]
    [OutputType([BoxstarterConnectionConfig])]
    param(
        [parameter(Mandatory=$true, ValueFromPipeline=$True, Position=0)]
        [string[]]$VMName,
        [parameter(Mandatory=$true, Position=1)]
        [Management.Automation.PsCredential]$Credential,
        [parameter(Mandatory=$false, Position=2)]
        [string]$CheckpointName
    )
    Begin {
        ##Cannot run remotely unelevated. Look into self elevating
        if(!(Test-Admin)) {
            Write-Error "You must be running as an administrator. Please open a PowerShell console as Administrator and rerun Install-BoxstarperPackage."
            return
        }

        if(!(Get-Command -Name Get-VM -ErrorAction SilentlyContinue)){
            Write-Error "Boxstarter could not find the Hyper-V PowerShell Module installed. This is required for use with Boxstarter.HyperV. Run Install-windowsfeature -name hyper-v -IncludeManagementTools."
            return
        }

        $CurrentVerbosity=$global:VerbosePreference

        if($PSBoundParameters["Verbose"] -eq $true) {
            $global:VerbosePreference="Continue"
        }
    }

    Process {
        $VMName | % {

            $vm=Get-VM $_ -ErrorAction SilentlyContinue
            if($vm -eq $null){
                throw New-Object -TypeName InvalidOperationException -ArgumentList "Could not find VM: $_"
            }

            if($CheckpointName -ne $null -and $CheckpointName.Length -gt 0){
                $point = Get-VMSnapshot -VMName $_ -Name $CheckpointName -ErrorAction SilentlyContinue
                $origState=$vm.State
                if($point -ne $null) {
                    Restore-VMSnapshot -VMName $_ -Name $CheckpointName -Confirm:$false
                    Write-BoxstarterMessage "$checkpointName restored on $_ waiting to complete..."
                    $restored=$true
                }
            }

            if($vm.State -eq "saved"){
                Remove-VMSavedState $_
            }

            if($vm.State -ne "running"){
                Start-VM $_ -ErrorAction SilentlyContinue
                Wait-HeartBeat $_
            }

            do {
                Start-Sleep -milliseconds 100
                $ComputerName=Get-VMGuestComputerName $_
            }
            until ($ComputerName -ne $null)
            $clientRemoting = Enable-BoxstarterClientRemoting $ComputerName
            Write-BoxstarterMessage "Testing remoting access on $ComputerName..."
            $remotingTest = Invoke-Command $ComputerName { Get-WmiObject Win32_ComputerSystem } -Credential $Credential -ErrorAction SilentlyContinue

            $params=@{}
            if(!$remotingTest) {
                Log-BoxstarterMessage "PowerShell remoting connection failed:"
                if($global:Error.Count -gt 0) { Log-BoxstarterMessage $global:Error[0] }
                Write-BoxstarterMessage "Testing WSMAN..."
                $WSManResponse = Test-WSMan $ComputerName -ErrorAction SilentlyContinue
                if($WSManResponse) {
                    Write-BoxstarterMessage "WSMAN responded. Will not enable WMI." -verbose
                    $params["IgnoreWMI"]=$true
                }
                else {
                    Log-BoxstarterMessage "WSMan connection failed:"
                    if($global:Error.Count -gt 0) { Log-BoxstarterMessage $global:Error[0] }
                    Write-BoxstarterMessage "Testing WMI..."
                    $wmiTest=try { Invoke-WmiMethod -ComputerName $ComputerName -Credential $Credential Win32_Process Create -Args "cmd.exe" -ErrorAction SilentlyContinue } catch {$ex=$_}
                    if($wmiTest -or ($ex -ne $null -and $ex.CategoryInfo.Reason -eq "UnauthorizedAccessException")) {
                        Write-BoxstarterMessage "WMI responded. Will not enable WMI." -verbose
                        $params["IgnoreWMI"]=$true
                    }
                    else {
                        Log-BoxstarterMessage "WMI connection failed:"
                        if($global:Error.Count -gt 0) { Log-BoxstarterMessage $global:Error[0] }
                    }
                }
                $credParts = $Credential.UserName.Split("\\")
                if(($credParts.Count -eq 1 -and $credParts[0] -eq "administrator") -or `
                  ($credParts.Count -eq 2 -and $credParts[0] -eq $ComputerName -and $credParts[1] -eq "administrator") -or`
                  ($credParts.Count -eq 2 -and $credParts[0] -ne $ComputerName)){
                    $params["IgnoreLocalAccountTokenFilterPolicy"]=$true
                }
                if($credParts.Count -eq 2 -and $credParts[0] -eq $ComputerName -and $credParts[1] -eq "administrator"){
                    $params["IgnoreLocalAccountTokenFilterPolicy"]=$true
                }

            }

            if(!$remotingTest -and ($params.Count -lt 2)) {
                Write-BoxstarterMessage "Stopping $_"
                Stop-VM $_ -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                $vhd=Get-VMHardDiskDrive -VMName $_
                Enable-BoxstarterVHD $vhd.Path @params | Out-Null
                Start-VM $_
                Write-BoxstarterMessage "Started $_. Waiting for Heartbeat..."
                Wait-HeartBeat $_
            }

            if(!$restored -and $CheckpointName -ne $null -and $CheckpointName.Length -gt 0) {
                Write-BoxstarterMessage "Creating Checkpoint $CheckpointName"
                Checkpoint-VM -Name $_ -SnapshotName $CheckpointName
            }

            $res=new-Object -TypeName BoxstarterConnectionConfig -ArgumentList "http://$($computerName):5985/wsman",$Credential,$null
            return $res
        }
    }

    End {
        $global:VerbosePreference=$CurrentVerbosity
    }
}

function Get-VMGuestComputerName($vmName) {
    $vm = Get-WmiObject -Namespace root\virtualization\v2 -Class Msvm_ComputerSystem -Filter "ElementName='$vmName'"
    $vm.GetRelated("Msvm_KvpExchangeComponent").GuestIntrinsicExchangeItems | % {
        if(([XML]$_) -ne $null){
            $GuestExchangeItemXml = ([XML]$_).SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE[child::text()='FullyQualifiedDomainName']")

            if ($GuestExchangeItemXml -ne $null) {
                $GuestExchangeItemXml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE/child::text()").Value
            }
        }
    }
}

function Wait-HeartBeat($vmName) {
    do {Start-Sleep -milliseconds 100}
    until ((Get-VMIntegrationService -VMName $vmName | ?{$_.id.endswith("\\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47") -or ($_.name -eq "Heartbeat")}).PrimaryStatusDescription -eq "OK")
}

# SIG # Begin signature block
# MIIcpwYJKoZIhvcNAQcCoIIcmDCCHJQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCApsixaJoZ1kmlu
# rvPe6rp8KUNXu7mfaa/Z9st2ChTD7KCCF7EwggUwMIIEGKADAgECAhAECRgbX9W7
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
# NwIBFTAvBgkqhkiG9w0BCQQxIgQgNsyhCF4crXQQEd39D+RpjSw3SK5YiqjzVq0F
# BcnJ1mcwDQYJKoZIhvcNAQEBBQAEggEAMpTnEGByMDKB0SH+bTLu+n5dW8+j0Kvm
# rU/1p8maATdjlEznDcwy//eCt6L2JVoDcOBxxAlV+fLypN6wQzKi0yfCivNyDh1N
# iYNr/dc1pPcDL05SD0R/U4PzbcLa4p7SmOjeqbXbKjsSUuAY40HLlQ+FxTOdoAKs
# FCB2L428Pif62/GkOLM9k8F1pl9+QaodrvCKvi25IPPcOyOwzE5sBjU3wEJTRe7+
# 5XS0qkQzT8OB/DGVRRze3QSdSkiRhN/SI5nhjw5NuUh6zoKYNSsr+UXXs6DnEEKu
# qLRyiTyDo/iWk6q8N+366YuYLciBOq83tWEG5je8+gaR6q4yxpepTKGCAg8wggIL
# BgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq5hfwZjAJ
# BgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0B
# CQUxDxcNMjAxMDE1MTAxMjAwWjAjBgkqhkiG9w0BCQQxFgQU7kQOEWXqgXFqGxCJ
# DrTnrGx/JKIwDQYJKoZIhvcNAQEBBQAEggEAdJ67rjHqSboBmnD7dcdTBpn/xHrX
# 7BrUCkeRKYj78OcyvUSddzLEDWubFpFpKw1qlupGm3h4XDAp8qdQikmjn60bJbPE
# jFVwbzw7cKCAxCutap0XVPavesb1v10mzSWEzFBVfTCUkJD5I7Fx8Nu0ozTv6n92
# MMnkv8kQ9OvL945Hnl26/EI6OAP9o3yUG9e/EiZThYtagoxEXi2elgPUsx+nEZWS
# 4gvejE731MJ2mvVhmqsUCNstVlw6N6cDzgPMukEQKyIpIlHXrN3PY/kMk4KbpN8l
# TzL8AmFR/avYJRMJDga8McHrgvGsnbJlvsr216W03a4YpIMKWBS3h36bZg==
# SIG # End signature block
