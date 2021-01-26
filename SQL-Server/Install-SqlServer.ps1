Set-ExecutionPolicy Bypass -Scope Process -Force; 

if(-not $env:ChocolateyInstall -or -not (Test-Path "$env:ChocolateyInstall")){
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}
RefreshEnv.cmd
#choco feature enable -n allowGlobalConfirmation
choco install sql-server-2019
choco install sql-server-management-studio
Install-Module -Name SqlServer -Force -AllowClobber
