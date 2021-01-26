function Set-BoxstarterTaskbarOptions {
<#
.SYNOPSIS
Sets options for the Windows Task Bar.

.PARAMETER Lock
Locks the taskbar.

.PARAMETER UnLock
Unlocks the taskbar.

.PARAMETER AutoHide
Autohides the taskbar.

.PARAMETER NoAutoHide
No autohiding on the taskbar.

.PARAMETER Size
Changes the size of the taskbar icons.  Valid inputs are Small and Large.

.PARAMETER Dock
Changes the location in which the taskbar is docked. Valid inputs are Top, Left, Bottom and Right.

.PARAMETER Combine
Changes the taskbar icon combination style. Valid inputs are Always, Full, and Never.

.PARAMETER AlwaysShowIconsOn
Turn on always show all icons in the notification area.

.PARAMETER AlwaysShowIconsOff
Turn off always show all icons in the notification area.

.PARAMETER MultiMonitorOn
Turn on Show tasbkar on all displays.

.PARAMETER MultiMonitorOff
Turn off Show taskbar on all displays.

.PARAMETER MultiMonitorMode
Changes the behavior of the taskbar when using multiple displays. Valid inputs are All, MainAndOpen, and Open.

.PARAMETER MultiMonitorCombine
Changes the taskbar icon combination style for non-primary displays. Valid inputs are Always, Full, and Never.

.EXAMPLE
Set-BoxstarterTaskbarOptions -Lock -AutoHide -AlwaysShowIconsOff -MultiMonitorOff

Locks the taskbar, enabled auto-hiding of the taskbar, turns off showing icons
in the notification area and turns off showing the taskbar on multiple monitors.
.EXAMPLE
Set-BoxstarterTaskbarOptions -Unlock -AlwaysShowIconsOn -Size Large -MultiMonitorOn -MultiMonitorCombine Always

Unlocks the taskbar and always shows large notification icons. Sets
multi-monitor support and always combine icons on non-primary monitors.
#>
    [CmdletBinding(DefaultParameterSetName='unlock')]
    param(
        [Parameter(ParameterSetName='lockhide')]
        [Parameter(ParameterSetName='locknohide')]
        [switch]
        $Lock,

        [Parameter(ParameterSetName='unlock')]
        [Parameter(ParameterSetName='unlockhide')]
        [Parameter(ParameterSetName='unlocknohide')]
        [switch]
        $UnLock,

        [Parameter(ParameterSetName='lockhide')]
        [Parameter(ParameterSetName='unlockhide')]
        [switch]
        $AutoHide,

        [Parameter(ParameterSetName='locknohide')]
        [Parameter(ParameterSetName='unlocknohide')]
        [switch]
        $NoAutoHide,

        [Parameter(ParameterSetName='AlwaysShowIconsOn')]
        [switch]
        $AlwaysShowIconsOn,

        [Parameter(ParameterSetName='AlwaysShowIconsOff')]
        [switch]
        $AlwaysShowIconsOff,

        [ValidateSet('Small','Large')]
        [String]
        $Size,

        [ValidateSet('Top','Left','Bottom','Right')]
        [String]
        $Dock,

        [ValidateSet('Always','Full','Never')]
        [String]
        $Combine,

        [Parameter(ParameterSetName='MultiMonitorOff')]
        [switch]
        $MultiMonitorOff,

        [Parameter(ParameterSetName='MultiMonitorOn')]
        [switch]
        $MultiMonitorOn,

        [Parameter(ParameterSetName='MultiMonitorOn')]
        [ValidateSet('All', 'MainAndOpen', 'Open')]
        [String]
        $MultiMonitorMode,

        [Parameter(ParameterSetName='MultiMonitorOn')]
        [ValidateSet('Always','Full','Never')]
        [String]
        $MultiMonitorCombine
    )

    $explorerKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $settingKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects2'

    if (-not (Test-Path -Path $settingKey)) {
        $settingKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    }

    if (Test-Path -Path $key) {
        if ($Lock) {
            Set-ItemProperty -Path $key -Name TaskbarSizeMove -Value 0
        }

        if ($UnLock) {
            Set-ItemProperty -Path $key -Name TaskbarSizeMove -Value 1
        }

        switch ($Size) {
            "Small" {
                Set-ItemProperty -Path $key -Name TaskbarSmallIcons -Value 1
            }

            "Large" {
                Set-ItemProperty -Path $key -Name TaskbarSmallIcons -Value 0
            }
        }

        switch ($Combine) {
            "Always" {
                Set-ItemProperty -Path $key -Name TaskbarGlomLevel -Value 0
            }

            "Full" {
                Set-ItemProperty -Path $key -Name TaskbarGlomLevel -Value 1
            }

            "Never" {
                Set-ItemProperty -Path $key -Name TaskbarGlomLevel -Value 2
            }
        }

        if ($MultiMonitorOn) {
            Set-ItemProperty -Path $key -Name MMTaskbarEnabled -Value 1

            switch ($MultiMonitorMode) {
                "All" {
                    Set-ItemProperty -Path $key -Name MMTaskbarMode -Value 0
                }

                "MainAndOpen" {
                    Set-ItemProperty -Path $key -Name MMTaskbarMode -Value 1
                }

                "Open" {
                    Set-ItemProperty -Path $key -Name MMTaskbarMode -Value 2
                }
            }

            switch ($MultiMonitorCombine) {
                "Always" {
                    Set-ItemProperty -Path $key -Name MMTaskbarGlomLevel -Value 0
                }

                "Full" {
                    Set-ItemProperty -Path $key -Name MMTaskbarGlomLevel -Value 1
                }

                "Never" {
                    Set-ItemProperty -Path $key -Name MMTaskbarGlomLevel -Value 2
                }
            }
        }

        if ($MultiMonitorOff) {
            Set-ItemProperty -Path $key -Name MMTaskbarEnabled -Value 0
        }
    }

    if (Test-Path -Path $settingKey) {
        $settings = (Get-ItemProperty -Path $settingKey -Name Settings).Settings

        switch ($Dock) {
            "Top" {
                $settings[12] = 0x01
            }

            "Left" {
                $settings[12] = 0x00
            }

            "Bottom" {
                $settings[12] = 0x03
            }

            "Right" {
                $settings[12] = 0x02
            }
        }

        if ($AutoHide) {
            $settings[8] = $settings[8] -bor 1
        }

        if ($NoAutoHide) {
            $settings[8] = $settings[8] -band 0
            Set-ItemProperty -Path $settingKey -Name Settings -Value $settings
        }

        Set-ItemProperty -Path $settingKey -Name Settings -Value $settings
    }

    if (Test-Path -Path $explorerKey) {
        if ($AlwaysShowIconsOn) {
            Set-ItemProperty -Path $explorerKey -Name 'EnableAutoTray' -Value 0
        }

        if ($alwaysShowIconsOff) {
            Set-ItemProperty -Path $explorerKey -Name 'EnableAutoTray' -Value 1
        }
    }

    Restart-Explorer
}

New-Alias -Name Set-TaskbarOptions -Value Set-BoxstarterTaskbarOptions
# SIG # Begin signature block
# MIIcpwYJKoZIhvcNAQcCoIIcmDCCHJQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAgKKzF9TQe4DGY
# Kw9/3JodiUq7UMGqDzGchtAkOtuY4qCCF7EwggUwMIIEGKADAgECAhAECRgbX9W7
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
# NwIBFTAvBgkqhkiG9w0BCQQxIgQg8vgYkr+hhk7IA+vbhsNkrfDKe4W61N9aBQ6A
# XwejooEwDQYJKoZIhvcNAQEBBQAEggEAA4c4JilMH135QLeSaQ51bY+V22OUf+bY
# BRxriRvO2tBXNcwx3L4u0CjgfKnH9V+S3jckJXblZzvvpZaeCFXaZo0BMv7/vRpG
# cULVsigKeWiDrUy5TEhn0wC7fp+sJQoHTWxrtzC+fQbMVyU1BQxhDmpdjcmJ/7zs
# rxE6qmylHxof7cjQnAreXnuikw3pyHrenQyZh37SWUUSDv8xJOp+FFisorhs2Q1f
# HUOr7JIDhfBU2rh4wTXWjXB5+HnHEpgiHIXJkALx18P2JRW3fitBDFT3Eb9Df8iC
# bymJqgtFHxIY5qJmu93FkMrBNIjzv3dnFwDy3YPIebJsy2wYMGlPhqGCAg8wggIL
# BgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq5hfwZjAJ
# BgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0B
# CQUxDxcNMjAxMDE1MTAxMjExWjAjBgkqhkiG9w0BCQQxFgQUZjnZu5QJ2UyhIvYd
# bQKddrppVnkwDQYJKoZIhvcNAQEBBQAEggEAiQBmEI7rC87oBs3JcX1NQmIE2pKF
# BwtgeIX4Q9M1ktkohmpGVBLO8+NbVn+jHSEYdHhdfcCSCdH3CSjbpkRAx6AyI+0g
# S7mDCSi42j4Pm7JYpL2i9walgW5l2etswvJj541tnCgq6HFvAxsVJaTTU6Nv9odI
# pnZq/xER8bdc/6AevzT9O3nmctuGmn38u7eHMnuTf+zps7QPZOdAwQqtATmhSi/8
# AZ2ZwNkOVeLRjvkcFLdaBpHj4DbVk5n2imNCKRlUyTMFXulpwWx5EP6T6y8qyc19
# tjT7e8C3trbRU8XXeUJPM1VBbqaIvsOk8z1F6mZwDHQH3NGwFBqmoi1M4A==
# SIG # End signature block
