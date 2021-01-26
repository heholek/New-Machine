function Invoke-FromTask {
<#
.SYNOPSIS
Invokes a command inside of a scheduled task

.DESCRIPTION
This invokes the boxstarter scheduled task.
The task is run in an elevated session using the provided
credentials. If the processes started by the task become idle for
more that the specified timeout, the task will be terminated. All
output and any errors from the task will be streamed to the calling
session.

 .PARAMETER Command
 The command to run in the task.

.PARAMETER IdleTimeout
The number of seconds after which the task will be terminated if it
becomes idle. The value 0 is an indefinite timeout and 120 is the
default.

.PARAMETER TotalTimeout
The number of seconds after which the task will be terminated whether
it is idle or active.

.EXAMPLE
Invoke-FromTask Install-WindowsUpdate -AcceptEula

This will install Windows Updates in a scheduled task

.EXAMPLE
Invoke-FromTask "DISM /Online /NoRestart /Enable-Feature:TelnetClient" -IdleTimeout 20

This will use DISM.exe to install the telnet client and will kill
the task if it becomes idle for more that 20 seconds.

.LINK
https://boxstarter.org
Create-BoxstarterTask
Remove-BoxstarterTask
#>
    param(
        $command,
        $DotNetVersion = $null,
        $idleTimeout=120,
        $totalTimeout=3600
    )
    Write-BoxstarterMessage "Invoking $command in scheduled task" -Verbose
    $runningCommand = Add-TaskFiles $command $DotNetVersion

    $taskProc = start-Task $runningCommand

    if($taskProc -ne $null){
        Write-BoxstarterMessage "Command launched in process $taskProc" -Verbose
        try {
            $waitProc=Get-Process -id $taskProc -ErrorAction Stop
            Write-BoxstarterMessage "Waiting on $($waitProc.Id)" -Verbose
        } catch { $global:error.RemoveAt(0) }
    }

    try {
        Wait-ForTask $waitProc $idleTimeout $totalTimeout
    }
    catch {
        Write-BoxstarterMessage "error thrown managing task" -verbose
        Write-BoxstarterMessage "$($_ | fl * -force | Out-String)" -verbose
        throw $_
    }
    Write-BoxstarterMessage "Task has completed" -Verbose

    $verboseStream = Get-CliXmlStream (Get-ErrorFileName) 'verbose'
    if($verboseStream -ne $null) {
        Write-BoxstarterMessage "Warnings and Verbose output from task:"
        $verboseStream | % { Write-Host $_ }
    }

    $errorStream = Get-CliXmlStream (Get-ErrorFileName) 'error'
    if($errorStream -ne $null -and $errorStream.length -gt 0) {
        throw $errorStream
    }
}

function Get-ErrorFileName { "$env:temp\BoxstarterError.stream" }

function Get-CliXmlStream($cliXmlFile, $stream) {
    $content = Get-Content $cliXmlFile
    if($content.count -lt 2) { return $null }

    # Strip the first line containing '#< CLIXML'
    [xml]$xml = $content[1..($content.count-1)]

    # return stream stripping carriage retuens and linefeeds
    $xml.DocumentElement.ChildNodes |
      ? { $_.S -eq $stream } |
      % { $_.'#text'.Replace('_x000D_','').Replace('_x000A_','') } |
      Out-String
}

function Get-ChildProcessMemoryUsage {
    param(
        $ID=$PID,
        [int]$res=0
    )
    Get-WmiObject -Class Win32_Process -Filter "ParentProcessID=$ID" | % {
        if($_.ProcessID -ne $null) {
            try {
                $proc = Get-Process -ID $_.ProcessID -ErrorAction Stop
                Write-BoxstarterMessage "$($_.Name) $($proc.PrivateMemorySize + $proc.WorkingSet)" -Verbose
                $res += $proc.PrivateMemorySize + $proc.WorkingSet
                $res += (Get-ChildProcessMemoryUsage $_.ProcessID $res)
            } catch { $global:error.RemoveAt(0) }
        }
    }
    $res
}

function Add-TaskFiles($command, $DotNetVersion) {
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("`$ProgressPreference='SilentlyContinue';$command"))
    $fileContent=@"
$(if($DotNetVersion -ne $null){"`$env:COMPLUS_version='$DotNetVersion'"})
Start-Process powershell -NoNewWindow -Wait -RedirectStandardError $(Get-ErrorFileName) -RedirectStandardOutput $env:temp\BoxstarterOutput.stream -WorkingDirectory '$PWD' -ArgumentList "-noprofile -ExecutionPolicy Bypass -EncodedCommand $encoded"
Remove-Item $env:temp\BoxstarterTask.ps1 -ErrorAction SilentlyContinue
"@
    Set-Content $env:temp\BoxstarterTask.ps1 -value $fileContent -force
    New-Item $env:temp\BoxstarterOutput.stream -Type File -Force | Out-Null
    New-Item (Get-ErrorFileName) -Type File -Force | Out-Null
    $encoded
}

function start-Task($encoded){
    $tasks=@()
    $tasks+=gwmi Win32_Process -Filter "name = 'powershell.exe' and CommandLine like '%$encoded%'" | select ProcessId | % { $_.ProcessId }
    Write-BoxstarterMessage "Found $($tasks.Length) tasks already running" -Verbose
    $taskResult = schtasks /RUN /I /TN 'Boxstarter Task'
    if($LastExitCode -gt 0){
        throw "Unable to run scheduled task. Message from task was $taskResult"
    }
    Write-BoxstarterMessage "Launched task. Waiting for task to launch command..." -Verbose
    do{
        if(!(Test-Path $env:temp\BoxstarterTask.ps1)){
            Write-BoxstarterMessage "Task Completed before its process was captured." -Verbose
            break
        }
        $taskProc=gwmi Win32_Process -Filter "name = 'powershell.exe' and CommandLine like '%$encoded%'" | select ProcessId | % { $_.ProcessId } | ? { !($tasks -contains $_) }

        Start-Sleep -Second 1
    }
    Until($taskProc -ne $null)

    return $taskProc
}

function Test-TaskTimeout($waitProc, $idleTimeout) {
    if($memUsageStack -eq $null){
        $script:memUsageStack=New-Object -TypeName System.Collections.Stack
    }
    if($idleTimeout -gt 0){
        $lastMemUsageCount=Get-ChildProcessMemoryUsage $waitProc.ID
        Write-BoxstarterMessage "Memory read: $lastMemUsageCount" -Verbose
        Write-BoxstarterMessage "Memory count: $($memUsageStack.Count)" -Verbose
        $memUsageStack.Push($lastMemUsageCount)
        if($lastMemUsageCount -eq 0 -or (($memUsageStack.ToArray() | ? { $_ -ne $lastMemUsageCount }) -ne $null)){
            $memUsageStack.Clear()
        }
        if($memUsageStack.Count -gt $idleTimeout){
            Write-BoxstarterMessage "Task has exceeded its timeout with no activity. Killing task..."
            KillTree $waitProc.ID
            throw "TASK:`r`n$command`r`n`r`nIs likely in a hung state."
        }
    }
    Start-Sleep -Second 1
}

function Wait-ForTask($waitProc, $idleTimeout, $totalTimeout){
    $reader=New-Object -TypeName System.IO.FileStream -ArgumentList @(
        "$env:temp\BoxstarterOutput.Stream",
        [system.io.filemode]::Open,[System.io.FileAccess]::ReadWrite,
        [System.IO.FileShare]::ReadWrite)
    try{
        $procStartTime = $waitProc.StartTime
        while($waitProc -ne $null -and !($waitProc.HasExited)) {
            $timeTaken = [DateTime]::Now.Subtract($procStartTime)
            if($totalTimeout -gt 0 -and $timeTaken.TotalSeconds -gt $totalTimeout){
                Write-BoxstarterMessage "Task has exceeded its total timeout. Killing task..."
                KillTree $waitProc.ID
                throw "TASK:`r`n$command`r`n`r`nIs likely in a hung state."
            }

            $byte = New-Object Byte[] 100
            $count=$reader.Read($byte,0,100)
            if($count -ne 0){
                $text = [System.Text.Encoding]::Default.GetString($byte,0,$count)
                $text | Write-Host -NoNewline
            }
            else {
                Test-TaskTimeout $waitProc $idleTimeout
            }
        }
        Start-Sleep -Second 1
        Write-BoxstarterMessage "Proc has exited: $($waitProc.HasExited) or Is Null: $($waitProc -eq $null)" -Verbose
        $byte=$reader.ReadByte()
        $text=$null
        while($byte -ne -1){
            $text += [System.Text.Encoding]::Default.GetString($byte)
            $byte=$reader.ReadByte()
        }
        if($text -ne $null){
            $text | Write-Host -NoNewline
        }
    }
    finally{
        $reader.Dispose()
        if($waitProc -ne $null -and !$waitProc.HasExited){
            KillTree $waitProc.ID
        }
    }
}

function KillTree($id){
    Get-WmiObject -Class Win32_Process -Filter "ParentProcessID=$ID" | % {
        if($_.ProcessID -ne $null) {
            Invoke-SilentKill $_.ProcessID
            Write-BoxstarterMessage "Killing $($_.Name)" -Verbose
            KillTree $_.ProcessID
        }
    }
    Invoke-SilentKill $id -wait
}

function Invoke-SilentKill($id, [switch]$wait) {
    try {
        $p = Kill $id -ErrorAction Stop -Force
        if($wait) {
            while($p -ne $null -and !$p.HasExited){
                Start-Sleep 1
            }
        }
    }
    catch {
        $global:error.RemoveAt(0)
    }
}

# SIG # Begin signature block
# MIIcpwYJKoZIhvcNAQcCoIIcmDCCHJQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCD6QZ76yUWPeOv
# jIZm9H1TwZwElwLdxlQeD7ArfEZVZqCCF7EwggUwMIIEGKADAgECAhAECRgbX9W7
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
# NwIBFTAvBgkqhkiG9w0BCQQxIgQgEw3W+/8ztXW4ytOdssao2N0lFm8YsvLTA/jz
# SqM1ijkwDQYJKoZIhvcNAQEBBQAEggEAQVma25EShHQNXpVFupcFVeOzzjaBoAjh
# 6iVlYxyO8mB1x0zi6gngTMc2acWLOKdudEon8KUaXutvgLTcvqM4m/9QqjyQQ5S2
# jRx3WI/p24rmk3hEwjr3fCZXPIKSsPgraxJoAeeu5yEWN2Qxz6+VZI28IYO8z8eM
# dCUb/MQ1kSKjnczqclFznOsed6PBtjvxFrKNyMhDTZnsIocbxzCfhshs/5q+FTcG
# I+9dF9yUx1vtXdwjiyBu5yj3McJbPQXdx5/zVkZyyfuict/T+oyW972GDaIYiibf
# 4qqSKAOO/NpX1J58t5QuctAnsio5P/qu37Ft53yOuzWJaPz4N1g0aKGCAg8wggIL
# BgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq5hfwZjAJ
# BgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0B
# CQUxDxcNMjAxMDE1MTAxMTUzWjAjBgkqhkiG9w0BCQQxFgQUEMcyySqDCJvqQ8p/
# eeo9WFmV7RUwDQYJKoZIhvcNAQEBBQAEggEAnSZUq3tIqJdWwL8Nk/hifjoU8gsW
# SoPGaMJsexkrGzUkRZeo+VVDccG/M+lFNM96BNkrP1T2hO41LqSL0FjnR9Z+cR3R
# edqGuVkl5grxdTQsUJ7vRiGOqXyTnGqahQU4H2GUJj/LRTM8rD3+PXOnFDZ06OgR
# pvMvmIQfh8jvEQ4W2ImBHQ1OEGijZUk25pYMy7F4FEEhvUyZkohz3QZUewnyMHcp
# M0iP8QGjt+MAfIezmJgjmuBtocaTq1n7g49aRRFvhkBaliSfHtQ0zUye9GnaFSgS
# 5oonoMR2A2j7X/62k6zVFc43PXhATmK5JhiF7aLSXtB0vNDNY6EdqfOK9w==
# SIG # End signature block
