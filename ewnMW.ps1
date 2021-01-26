

Invoke-Expression ((new-object net.webclient).DownloadString('https://raw.githubusercontent.com/mwrock/boxstarter/master/BuildScripts/bootstrapper.ps1'))
Get-Boxstarter -Force

#~~~
Set-ExecutionPolicy Bypass -Scope Process -Force; 

if(-not $env:ChocolateyInstall -or -not (Test-Path "$env:ChocolateyInstall")){
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

#~~~~
$features = choco list --source windowsfeatures
if ($features | Where-Object {$_ -like "*Linux*"})
{
  choco install Microsoft-Windows-Subsystem-Linux           --source windowsfeatures --limitoutput
}


Enable-WindowsOptionalFeature -Online -FeatureName containers -All
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
Set-ExplorerOptions -showFileExtensions
Enable-RemoteDesktop
Disable-BingSearch # Disables the Bing Internet Search when searching from the search field in the taskbar or Start Menu
#Write-Host "Hiding Taskbar Search box / button..."
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Type DWord -Value 0
#Write-Host "Hiding Task View button..."
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowTaskViewButton" -Type DWord -Value 0
Write-Output "Enabling and Running Windows Update"
Enable-MicrosoftUpdate


## Web Browsers

if (!(test-path $profile)) 
{
    New-Item -path $profile -type file -force
}

mkdir "$($env:USERPROFILE)\Code"

Add-Content $profile ("PushD " + "$($env:USERPROFILE)\Code")

