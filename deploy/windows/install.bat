@echo off
rem Installs Zemi and what it uses on Windows, for this account only: no administrator rights needed.
rem
rem   install.bat               the released Zemi
rem   install.bat BRANCH        Zemi from a branch of github.com/kahliburke/Zemi.jl
rem   install.bat C:\path\Zemi  Zemi from a checkout on this machine
rem
rem Each part is skipped where this account already has it: Julia, MuPDF's mutool (reads papers),
rem Ollama (search by meaning), Git and Claude Code (agents that summarize), then Kaimon and Zemi.
rem Programs go in %LOCALAPPDATA%\Programs, and their folders on this account's PATH.
rem The rest of this file is PowerShell, run as a command rather than a script file, which policies
rem against running scripts leave alone.
set "ZEMI_SOURCE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = [IO.File]::ReadAllText('%~f0'); iex $t.Substring($t.IndexOf('#' + '#POWERSHELL'))"
exit /b %errorlevel%

##POWERSHELL
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'                  # downloads are many times slower with it
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Programs = Join-Path $env:LOCALAPPDATA 'Programs'
$Work = Join-Path $env:TEMP 'zemi-install'
New-Item -ItemType Directory -Force $Programs, $Work | Out-Null
$Done = @()

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Have($command) { [bool](Get-Command $command -ErrorAction SilentlyContinue) }
function Get-File($url, $name) {
    $out = Join-Path $Work $name
    Write-Host "Downloading $url"
    Invoke-WebRequest -UseBasicParsing $url -OutFile $out
    return $out
}
# This account's PATH, for new terminals, and this one's, for the steps after.
function Add-Path($dir) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $user) { $user = '' }
    if (($user -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', (($dir, $user) -join ';').TrimEnd(';'), 'User')
    }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}
# The one folder a zip holds, moved to $Programs.
function Install-Zip($zip, $name) {
    $tmp = Join-Path $Work $name
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Expand-Archive $zip $tmp
    $inner = Get-ChildItem $tmp | Select-Object -First 1
    $dest = Join-Path $Programs $inner.Name
    Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
    Move-Item $inner.FullName $dest
    return $dest
}

Step 'Julia'
if (Have julia) { Write-Host "Found $((Get-Command julia).Source)" } else {
    $versions = Invoke-RestMethod https://julialang-s3.julialang.org/bin/versions.json
    $latest = $versions.PSObject.Properties | Where-Object { $_.Value.stable } |
        Sort-Object { [version]$_.Name } | Select-Object -Last 1
    $file = $latest.Value.files | Where-Object { $_.os -eq 'winnt' -and $_.arch -eq 'x86_64' -and $_.extension -eq 'zip' } |
        Select-Object -First 1
    $dir = Install-Zip (Get-File $file.url 'julia.zip') 'julia'
    Add-Path (Join-Path $dir 'bin')
    $Done += "Julia $($latest.Name)"
}

Step "MuPDF's mutool"
if (Have mutool) { Write-Host "Found $((Get-Command mutool).Source)" } else {
    $names = [regex]::Matches((Invoke-WebRequest -UseBasicParsing https://mupdf.com/releases).Content, 'mupdf-(\d+\.\d+\.\d+)-windows\.zip') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object { [version]$_ } -Unique
    $version = $names | Select-Object -Last 1
    $dir = Install-Zip (Get-File "https://mupdf.com/downloads/archive/mupdf-$version-windows.zip" 'mupdf.zip') 'mupdf'
    Add-Path $dir
    $Done += "MuPDF $version"
}

Step 'Ollama'
if (Have ollama) { Write-Host "Found $((Get-Command ollama).Source)" } else {
    # Its installer installs for this account when it has no administrator rights, and starts it.
    $setup = Get-File https://ollama.com/download/OllamaSetup.exe 'OllamaSetup.exe'
    Start-Process -Wait $setup '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES'
    Add-Path (Join-Path $Programs 'Ollama')
    $Done += 'Ollama'
}

Step 'Git'
# Claude Code runs its commands in Git's bash.
if (Have git) { $git = Split-Path (Split-Path (Get-Command git).Source) } else {
    $release = Invoke-RestMethod https://api.github.com/repos/git-for-windows/git/releases/latest
    $asset = $release.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
    $exe = Get-File $asset.browser_download_url 'PortableGit.7z.exe'
    $git = Join-Path $Programs 'PortableGit'
    Start-Process -Wait $exe "-o`"$git`"", '-y'
    Add-Path (Join-Path $git 'cmd')
    $Done += $asset.name -replace '\.7z\.exe$'
}
$bash = Join-Path $git 'bin\bash.exe'
if (Test-Path $bash) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'User')
    $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
}

Step 'Claude Code'
Add-Path (Join-Path $HOME '.local\bin')
if (Have claude) { Write-Host "Found $((Get-Command claude).Source)" } else {
    # In a PowerShell of its own, which its exit on a failure ends rather than this one.
    & powershell -NoProfile -Command 'irm https://claude.ai/install.ps1 | iex'
    if ($LASTEXITCODE -ne 0) { throw 'Installing Claude Code failed' }
    $Done += 'Claude Code'
}

Step 'Kaimon and Zemi'
Add-Path (Join-Path $HOME '.julia\bin')
$source = $env:ZEMI_SOURCE
$zemi = if (-not $source) { 'Pkg.Apps.add("Zemi")' }
        elseif (Test-Path $source) { "Pkg.Apps.develop(path = raw`"$((Resolve-Path $source).Path)`")" }
        else { "Pkg.Apps.add(PackageSpec(url = `"https://github.com/kahliburke/Zemi.jl`", rev = raw`"$source`"))" }
$script = Join-Path $Work 'apps.jl'
Set-Content $script "using Pkg`nPkg.Apps.add(`"Kaimon`")`n$zemi`n"
& julia $script
if ($LASTEXITCODE -ne 0) { throw "Installing Kaimon and Zemi failed" }
$Done += 'Kaimon', 'Zemi'

Write-Host "`nInstalled: $(if ($Done) { $Done -join ', ' } else { 'nothing new' })" -ForegroundColor Green
Write-Host @"

In a new terminal, which has the PATH this set:
  claude        once, to sign in to Claude Code, for agents that summarize
  kaimon        once, to set it up; then
  zemi kaimon   to have Kaimon run the knowledge base, or zemi to run it on its own
"@
