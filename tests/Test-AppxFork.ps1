$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Format-ByteSize',
    'Require-File',
    'Align-4',
    'Get-UInt32LE',
    'Get-Int32LE',
    'Get-Sha256Hex',
    'Read-AsarHeader',
    'Read-AsarHeaderFromFile',
    'Get-AsarEntryPaths',
    'Get-AsarFileIntegrity',
    'Get-AsarIntegrityFromBytes',
    'Get-AsarEntryNode',
    'Read-AsarEntryBytes',
    'Test-FileReplaceable',
    'Assert-AsarReplaceable',
    'Move-FileWithRetry',
    'Write-AsarArchiveWithHeader',
    'Set-AsarEntryContent',
    'Get-AsarHeaderHash',
    'New-AsarArchive',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Backup-AppFile',
    'Get-ClaudeAppPathFromResources',
    'Get-ClaudeExePathFromResources',
    'Get-ClaudeExeIntegrityMarker',
    'Sync-ClaudeExeAsarIntegrity',
    'Get-AppxForkRoot',
    'Get-AppxForkRoots',
    'Get-AppxForkProfilePath',
    'Get-AppxForkUserDataBootstrap',
    'Set-AppxForkUserDataIsolation',
    'Get-AppxForkDirectories',
    'Remove-AppxForkTemporaryDirectories',
    'Remove-AppxForkDirectory',
    'Test-ClaudeDesktopProcessPath',
    'Save-JsonNoBom',
    'Get-ClaudeAppxPackages',
    'Get-ClaudeConfigPaths',
    'Restore-StoreClaudeLocale',
    'Remove-LegacyAppxForkArtifacts',
    'Remove-AppxForkRegistryLeftovers',
    'Test-PackageItemAclModified'
)

$script:AppxForkUserDataMarker = "/*claude-zh-cn:appx-fork-userdata*/"
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-appx-fork-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$AsarIntegrityBlockSize = 4MB
$savedLocalAppData = $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA

function Get-EntryText {
    param([string]$AsarPath, [string]$EntryPath)
    $parsed = Read-AsarHeaderFromFile $AsarPath
    return [Text.Encoding]::UTF8.GetString((Read-AsarEntryBytes $AsarPath $parsed $EntryPath))
}

try {
    $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA = Join-Path $temp 'Local'
    $forkRoot = Get-AppxForkRoot
    $fork = Join-Path $forkRoot 'AnthropicPBC.Claude_9.9.9.0_x64__test'
    $app = Join-Path $fork 'app'
    $resources = Join-Path $app 'resources'
    $fixture = Join-Path $temp 'fixture'
    $build = Join-Path $fixture '.vite\build'
    New-Item -ItemType Directory -Path $resources, $build -Force | Out-Null

    # --- 独立数据目录注入 ---
    $entrySource = '"use strict";var e=process.env;(function(e){delete e.CLAUDE_USER_DATA_DIR})(process.env);console.log(process.env.CLAUDE_USER_DATA_DIR||"MISSING");'
    [IO.File]::WriteAllText((Join-Path $fixture 'package.json'), '{"name":"@ant/desktop","productName":"Claude","main":".vite/build/index.pre.js"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $build 'index.pre.js'), $entrySource, $utf8NoBom)
    $appAsar = Join-Path $resources 'app.asar'
    New-AsarArchive $fixture $appAsar

    $exe = Join-Path $app 'Claude.exe'
    $marker = 'resources\\app.asar","alg":"SHA256","value":"'
    [IO.File]::WriteAllText($exe, ($marker + (Get-AsarHeaderHash $appAsar) + '"}PAD'), [Text.Encoding]::ASCII)

    Set-AppxForkUserDataIsolation $resources
    $patched = Get-EntryText $appAsar '.vite/build/index.pre.js'
    if (-not $patched.StartsWith('"use strict";' + $script:AppxForkUserDataMarker)) {
        throw 'Bootstrap must be inserted right after the "use strict" directive.'
    }
    if (-not $patched.EndsWith($entrySource.Substring('"use strict";'.Length))) {
        throw 'Original entry code was altered.'
    }
    $exeText = [IO.File]::ReadAllText($exe, [Text.Encoding]::ASCII)
    $hashIndex = $exeText.IndexOf($marker, [StringComparison]::Ordinal) + $marker.Length
    if ($exeText.Substring($hashIndex, 64) -ne (Get-AsarHeaderHash $appAsar)) {
        throw 'Claude.exe app.asar integrity hash was not synchronized after the bootstrap was injected.'
    }

    $headerBefore = (Read-AsarHeaderFromFile $appAsar)["HeaderString"]
    Set-AppxForkUserDataIsolation $resources
    if ((Read-AsarHeaderFromFile $appAsar)["HeaderString"] -ne $headerBefore) {
        throw 'Set-AppxForkUserDataIsolation is not idempotent.'
    }

    # 正式包会删掉外部传入的 CLAUDE_USER_DATA_DIR；注入代码必须挡住这次删除。
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $script = Join-Path $temp 'entry.js'
        [IO.File]::WriteAllText($script, $patched, $utf8NoBom)
        $savedProcessLocal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = 'C:\FakeLocal'
        try {
            $output = (& $node.Source $script | Out-String).Trim()
        }
        finally {
            $env:LOCALAPPDATA = $savedProcessLocal
        }
        if ($output -ne 'C:\FakeLocal\ClaudeDesktopZhCn\profile') {
            throw "Bootstrap did not keep CLAUDE_USER_DATA_DIR for the fork, got: $output"
        }
        if ((Join-Path $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA 'ClaudeDesktopZhCn\profile') -ne (Get-AppxForkProfilePath)) {
            throw 'Installer profile path must match the runtime profile path.'
        }
    }
    else {
        Write-Host 'SKIP: node not found, bootstrap runtime check skipped.' -ForegroundColor DarkYellow
    }

    $noEnvAsar = Join-Path $temp 'noenv\resources'
    New-Item -ItemType Directory -Path $noEnvAsar -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $build 'index.pre.js'), '"use strict";console.log(1);', $utf8NoBom)
    New-AsarArchive $fixture (Join-Path $noEnvAsar 'app.asar')
    $threw = $false
    try { Set-AppxForkUserDataIsolation $noEnvAsar } catch { $threw = $true }
    if (-not $threw) {
        throw 'Isolation must abort when the entry no longer reads CLAUDE_USER_DATA_DIR.'
    }

    # --- 进程作用域 ---
    $forkExe = Join-Path $app 'claude.exe'
    $storeExe = 'C:\Program Files\WindowsApps\AnthropicPBC.Claude_9.9.9.0_x64__test\app\claude.exe'
    $script:ClaudeProcessScopePaths = $null
    $script:ExplicitClaudePath = ''
    if (-not (Test-ClaudeDesktopProcessPath $forkExe)) {
        throw 'Fork processes must be recognized as Claude Desktop.'
    }
    $script:ClaudeProcessScopePaths = @([IO.Path]::GetFullPath($forkRoot).TrimEnd('\') + '\')
    if (-not (Test-ClaudeDesktopProcessPath $forkExe)) {
        throw 'Scoped detection must keep the current user fork.'
    }
    if (Test-ClaudeDesktopProcessPath $storeExe) {
        throw 'Scoped detection must not touch the original Store package.'
    }
    $script:ClaudeProcessScopePaths = $null

    # --- 删除副本：有文件被占用时不能删掉一半 ---
    $lockedFile = Join-Path $app 'claude.exe'
    $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $threw = $false
    try {
        try { Remove-AppxForkDirectory $fork } catch { $threw = $true }
    }
    finally {
        $lock.Dispose()
    }
    if (-not $threw) {
        throw 'Removing a fork with a file in use must fail.'
    }
    if (-not (Test-Path -LiteralPath $appAsar) -or -not (Test-Path -LiteralPath $lockedFile)) {
        throw 'A failed removal must leave the fork intact.'
    }
    if (@(Get-ChildItem -LiteralPath $forkRoot -Force).Count -ne 1) {
        throw 'A failed removal must not leave a partial copy next to the fork.'
    }

    Remove-AppxForkDirectory $fork
    if (Test-Path -LiteralPath $fork) {
        throw 'Fork directory should be removed once nothing holds it.'
    }
    if (@(Get-ChildItem -LiteralPath $forkRoot -Force).Count -ne 0) {
        throw 'Fork removal left temporary directories behind.'
    }

    # --- 卸载：恢复原 Store 版语言配置 ---
    $Utf8NoBom = $utf8NoBom
    $savedAppData = $env:CLAUDE_ZH_ORIGINAL_APPDATA
    $savedSid = $env:CLAUDE_ZH_ORIGINAL_USER_SID
    $env:CLAUDE_ZH_ORIGINAL_APPDATA = Join-Path $temp 'Roaming'
    $env:CLAUDE_ZH_ORIGINAL_USER_SID = ''
    try {
        $userConfig = Join-Path $env:CLAUDE_ZH_ORIGINAL_APPDATA 'Claude\config.json'
        $createdConfig = Join-Path $env:CLAUDE_ZH_ORIGINAL_APPDATA 'Claude-3p\config.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $userConfig), (Split-Path -Parent $createdConfig) -Force | Out-Null
        [IO.File]::WriteAllText($userConfig, '{"updaterLastSeenVersion":"5.1","locale":"zh-CN"}', $utf8NoBom)
        [IO.File]::WriteAllText($createdConfig, '{"locale":"en-US"}', $utf8NoBom)
        $script:ClaudeConfigPathsOverride = @('C:\should-not-be-used\config.json')
        Restore-StoreClaudeLocale
        if ($script:ClaudeConfigPathsOverride[0] -ne 'C:\should-not-be-used\config.json') {
            throw 'Restore-StoreClaudeLocale must restore the fork config override.'
        }
        $script:ClaudeConfigPathsOverride = $null
        $restored = Get-Content -LiteralPath $userConfig -Raw | ConvertFrom-Json
        if ($restored.locale -ne 'en-US' -or $restored.updaterLastSeenVersion -ne '5.1') {
            throw 'Store config locale was not reset to en-US, or other settings were lost.'
        }
        if (Test-Path -LiteralPath (Split-Path -Parent $createdConfig)) {
            throw 'Installer-created locale-only config folder should be removed.'
        }
    }
    finally {
        $env:CLAUDE_ZH_ORIGINAL_APPDATA = $savedAppData
        $env:CLAUDE_ZH_ORIGINAL_USER_SID = $savedSid
    }

    # --- 卸载：按名字和按目标删除快捷方式，不碰无关快捷方式 ---
    $savedProfile = $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE
    $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE = Join-Path $temp 'Profile'
    try {
        $desktop = Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE 'Desktop'
        $taskbar = Join-Path $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
        New-Item -ItemType Directory -Path $desktop, $taskbar -Force | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $links = @{
            (Join-Path $desktop 'Claude Desktop 中文补丁.lnk') = 'C:\Windows\notepad.exe'
            (Join-Path $taskbar 'Claude 中文.lnk') = (Join-Path $temp 'Local\ClaudeDesktopZhCn\appx-fork\AnthropicPBC.Claude_1\app\claude.exe')
            (Join-Path $desktop 'Other.lnk') = 'C:\Windows\notepad.exe'
        }
        foreach ($entry in $links.GetEnumerator()) {
            $link = $shell.CreateShortcut($entry.Key)
            $link.TargetPath = $entry.Value
            $link.Save()
        }
        Remove-LegacyAppxForkArtifacts -Folders @($desktop, $taskbar)
        if ((Test-Path -LiteralPath (Join-Path $desktop 'Claude Desktop 中文补丁.lnk')) -or
            (Test-Path -LiteralPath (Join-Path $taskbar 'Claude 中文.lnk'))) {
            throw 'Fork shortcuts (by name or by target) must be removed.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $desktop 'Other.lnk'))) {
            throw 'Unrelated shortcuts must be kept.'
        }
    }
    finally {
        $env:CLAUDE_ZH_ORIGINAL_USER_PROFILE = $savedProfile
    }

    # --- 卸载：清掉副本写进注册表的 claude:// 协议、COM 组件和开机启动 ---
    $regRoot = "Registry::HKEY_CURRENT_USER\Software\ClaudeZhCnTest-" + [guid]::NewGuid().ToString('N')
    try {
        $forkExePath = 'C:\Users\x\AppData\Local\ClaudeDesktopZhCn\appx-fork\AnthropicPBC.Claude_1\app\claude.exe'
        $command = Join-Path $regRoot 'Software\Classes\claude\shell\open\command'
        New-Item -Path $command -Force | Out-Null
        Set-Item -LiteralPath $command -Value ('"' + $forkExePath + '" -- "%1"')
        $forkClsid = Join-Path $regRoot 'Software\Classes\CLSID\{11111111-1111-1111-1111-111111111111}\LocalServer32'
        $otherClsid = Join-Path $regRoot 'Software\Classes\CLSID\{22222222-2222-2222-2222-222222222222}\LocalServer32'
        New-Item -Path $forkClsid, $otherClsid -Force | Out-Null
        Set-Item -LiteralPath $forkClsid -Value $forkExePath
        Set-Item -LiteralPath $otherClsid -Value 'C:\Program Files\Other\other.exe'
        $run = Join-Path $regRoot 'Software\Microsoft\Windows\CurrentVersion\Run'
        New-Item -Path $run -Force | Out-Null
        New-ItemProperty -LiteralPath $run -Name 'electron.app.Claude' -Value ('"' + $forkExePath + '" --startup') | Out-Null
        New-ItemProperty -LiteralPath $run -Name 'Other' -Value 'C:\Program Files\Other\other.exe' | Out-Null

        Remove-AppxForkRegistryLeftovers -RegistryRoot $regRoot
        if (Test-Path -LiteralPath (Join-Path $regRoot 'Software\Classes\claude')) {
            throw 'claude:// handler pointing at the fork must be removed.'
        }
        if (Test-Path -LiteralPath (Split-Path -Parent $forkClsid)) {
            throw 'COM server pointing at the fork must be removed.'
        }
        if (-not (Test-Path -LiteralPath $otherClsid)) {
            throw 'Unrelated COM servers must be kept.'
        }
        $runValues = @((Get-Item -LiteralPath $run).GetValueNames())
        if ($runValues -contains 'electron.app.Claude' -or $runValues -notcontains 'Other') {
            throw 'Only the fork startup entry must be removed.'
        }
    }
    finally {
        Remove-Item -LiteralPath $regRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 当前用户新建的文件所有者不是 SYSTEM，必须被识别为改动过的权限。
    $aclProbe = Join-Path $temp 'acl-probe.txt'
    [IO.File]::WriteAllText($aclProbe, 'x')
    if (-not (Test-PackageItemAclModified $aclProbe)) {
        throw 'A file not owned by SYSTEM must be reported as modified.'
    }

    Write-Host 'PASS: Store fork uses its own data folder and keeps it after the packaged-build env cleanup.' -ForegroundColor Green
    Write-Host 'PASS: fork process scope and all-or-nothing fork removal.' -ForegroundColor Green
    Write-Host 'PASS: uninstall restores Store config locale and removes fork shortcuts only.' -ForegroundColor Green
}
finally {
    $env:CLAUDE_ZH_ORIGINAL_LOCALAPPDATA = $savedLocalAppData
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
