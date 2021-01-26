Function Set-BoxstarterPageFile {
<#
    .SYNOPSIS
        This can be used to manage the Windows page file.
    .DESCRIPTION
        This can be used to manage the Windows page file.
    .PARAMETER InitialSizeMB
        Initial size of the page file.
    .PARAMETER MaximumSizeMB
        Maximum size of the page file.
    .PARAMETER DriveLetter
        The drive used for the holding the page file.
    .PARAMETER SystemManagedSize
        Allow Windows to manage the page files.
    .PARAMETER Disable
        Disable the use of the page file.
    .EXAMPLE
        C:\PS> Set-PageFile -InitialSizeMB 1024 -MaximumSizeMB 4096 -DriveLetter "C","D"

        Execution Results: Set page file size on "C" successful.
        Execution Results: Set page file size on "D:" successful.

        Name            InitialSize(MB) MaximumSize(MB)
        ----            --------------- ---------------
        C:\pagefile.sys            1024            4096
        D:\pagefile.sys            1024            4096
        E:\pagefile.sys            2048            4096
#>
    [cmdletbinding(SupportsShouldProcess,DefaultParameterSetName="SetPageFileSize")]
    Param
    (
        [Parameter(Mandatory,ParameterSetName="SetPageFileSize")]
        [Alias('is')]
        [Int32]$InitialSizeMB,

        [Parameter(Mandatory,ParameterSetName="SetPageFileSize")]
        [Alias('ms')]
        [Int32]$MaximumSizeMB,

        [Parameter(Mandatory)]
        [Alias('dl')]
        [ValidatePattern('^[A-Z]$')]
        [String[]]$DriveLetter,

        [Parameter(Mandatory,ParameterSetName="Disable")]
        [Switch]$Disable,

        [Parameter(Mandatory,ParameterSetName="SystemManagedSize")]
        [Switch]$SystemManagedSize
    )

    Function Set-PageFileSize {
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory)]
            [ValidatePattern('^[A-Z]$')]
            [String]$DriveLetter,

            [Parameter(Mandatory)]
            [ValidateRange(0, [int32]::MaxValue)]
            [Int32]$InitialSizeMB,

            [Parameter(Mandatory)]
            [ValidateRange(0, [int32]::MaxValue)]
            [Int32]$MaximumSizeMB
        )
        # There is a bug in earlier versions of PowerShell when using put() in
        # that it would throw an exception but actually make the change. The
        # EnableAllPrivileges switch for Get-WmiObject seems to stop this
        # exception being thrown.
        $pfStatus = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction Stop
        if ($pfStatus.AutomaticManagedPagefile -eq $true) {
            # disable automatic management of the pagefile
            $pfStatus.AutomaticManagedPagefile = $false

            # we use put() to keep comatibility with PowerShell 2
            $null = $pfStatus.Put()

            # when we disable the AutomaticManagedPagefile it starts to use the
            # $env:SystemDrive for the page file so lets remove that
            Get-WmiObject -Class Win32_PageFileSetting -Filter "SettingID='pagefile.sys @ $($env:SystemDrive)'" -ErrorAction Stop | Remove-WmiObject -ErrorAction Stop
        }

        # if the pagefile exists on $DriveLetter then remove it
        Get-WmiObject -Class Win32_PageFileSetting -Filter "SettingID='pagefile.sys @ $($DriveLetter):'" -EnableAllPrivileges -ErrorAction Stop | Remove-WmiObject -ErrorAction Stop

        # create a new instance of a the Wwin32_PageFileSetting object
        $newPf = (New-Object -TypeName System.Management.ManagementClass('root\cimv2', 'Win32_PageFileSetting', $null)).CreateInstance()

        # we appear to have do do this in bits rather than all at once
        # See https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/win32-pagefilesetting
        # set the name first which is simply the path of the pagefile
        $newPf.Name = "$($DriveLetter):\pagefile.sys"
        $null = $newPf.Put()

        # now we need to set teh initial and maximum pagefile sizes
        $newPf.InitialSize = $InitialSizeMB
        $newPf.MaximumSize = $MaximumSizeMB
        $null = $newPf.Put()
    } #function

    # check that maximum is above or equal minimum before we start
    if ($MaximumSizeMB -lt $InitialSizeMB) {
        Write-BoxstarterMessage "You have set the maximum pagefile size to be lower than the minimum. Exiting." -color red
        return
    }

    ForEach ($dl in $DriveLetter) {
        # adding DriveType to the WMI Filter doesn't appear to work :(
        $vol = Get-WmiObject -Class CIM_StorageVolume -Filter "Name='$($dl):\\'" -ErrorAction Stop | Where-Object { $_.DriveType -eq 3 }
        if ($null -eq $vol) {
            Write-BoxstarterMessage "Could not find volume '$($dl):'. Either it does not exist or it is not a fixed local volume." -color red
            return
        }

        Switch ($PsCmdlet.ParameterSetName) {
            Disable {
                try {
                    Get-WmiObject -Class Win32_PageFileSetting -Filter "Name='$($dl):\\pagefile.sys'" -ErrorAction Stop | Remove-WmiObject -ErrorAction Stop
                }
                catch {
                    Write-BoxStarterMessage "Unable to disable the pagefile on '$($dl):'. (Error: $($_.Exception.Message))"
                    return
                }
            }

            SystemManagedSize {
                try {
                    Set-PageFileSize -DriveLetter $dl -InitialSizeMB 0 -MaximumSizeMB 0
                }
                catch {
                    Write-BoxstarterMessage "Unable to set the pagefile size to be managed by the System. (Error: $($_.Exception.Message))"
                    return
                }
                break
            }

            Default {
                # $vol stores it's freespace in bytes but we need to compare MB
                $freespace = $vol.FreeSpace / 1MB
                if ($freespace -gt $MaximumSizeMB) {
                    try {
                        Set-PageFileSize -DriveLetter $dl -InitialSizeMB $InitialSizeMB -MaximumSizeMB $MaximumSizeMB
                    }
                    catch {
                        $msg = "Failed to set pagefile on '{0}:' to {1}MB / {2}MB. (Error: $($_.Exception.Message))." -f $dl, $InitialSizeMB, $MaximumSizeMB
                        Write-BoxstarterMessage $msg -color red
                    }
                }
                else {
                    $msg = "Failed to set pagefile on '{0}:' to {1}MB / {2}MB. The maximum pagefile size exceeds the free space on the volume." -f $dl, $InitialSizeMB, $MaximumSizeMB
                    Write-BoxstarterMessage $msg -color red
                    return
                }
            } #switch - default
        } #switch
    } #foreach

    Write-BoxstarterMessage "A reboot is required before the pagefile changes will take effect."
    Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop |Select-Object Name,
        @{Name = "InitialSize(MB)"; Expression={ if ($_.InitialSizeMB -eq 0) { "System Managed" } else { $_.InitialSizeMB }}},
        @{Name = "MaximumSize(MB)"; Expression={ if ($_.MaximumSizeMB -eq 0) { "System Managed" } else { $_.MaximumSizeMB }}} |
        Format-Table -AutoSize
}

# SIG # Begin signature block
# MIIcpwYJKoZIhvcNAQcCoIIcmDCCHJQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDRx1qGV6CKPVhr
# sGh/ucVEUv4aqzQVOcQgcpSJSoJQzaCCF7EwggUwMIIEGKADAgECAhAECRgbX9W7
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
# NwIBFTAvBgkqhkiG9w0BCQQxIgQgfGlqbOduD+kKVBE9N6pyAk7peB6QhaPfjFyO
# kYNLkwEwDQYJKoZIhvcNAQEBBQAEggEAWaQ79TqG43SdHUdJsdV9QdkbAJuQjwGE
# uD0VtT0YQVUdloiwn/tBSV02NJX3X4BC8bGnLgQyouG9NPr4EsgSTvXLpLYxKpGv
# JAlpnzG/BB12FhrtiF2K38rspRfnPa3BS3JNTSe10RSmVC1kMEb6w5aWlxLpFqrN
# xz6OKzMOXVF70j5DhSQOor7WYjFkWYCAKELGmBlgu7xFiTsp2bTb9yMvjqc9549n
# PvecT6WgTYZbM/wvngCyBZ97r9xwRzWpEsC4xAFeGB5g/rwVSFwI4RmNQZXlWlsb
# y0AHd0JL39D42cFljwwVkJJjihdQfK/NEn5HLkDptJdp3E26gHPrwaGCAg8wggIL
# BgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq5hfwZjAJ
# BgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0B
# CQUxDxcNMjAxMDE1MTAxMjExWjAjBgkqhkiG9w0BCQQxFgQUfuh57W4YMQdAyirn
# ywCpmpbPFy8wDQYJKoZIhvcNAQEBBQAEggEAKQlKjegE2ad/lxt0p2C2622ooocz
# DGnmZC8B68C25sw0foSTnbr7h47zpsGMK9MR0uISuGsNcvlXabhttB12eDxnM5IB
# PsWe7o4tGnKLmgXFFrXpDWP4wAjHxfjO9SqvbPFTk25hPuczxLB10xeb3JqmhDSk
# pN8qWmSbEJ6wLX6NxGq3xPbtgIZHbT4VodvV25AVsdoFqX6EUXMCIXiLfGMGkFpK
# /NUn+XYmT9t/ZVoM92o+bVLLU8dZGVZLbudRqHCA5kr8g0q+kv51ZGvRF69y4wKG
# AURjTQV4e2MhKYOWj+3eOwyeeP28b2tkCmPZ7OPArs9jmytdGRRpbjlUlg==
# SIG # End signature block
