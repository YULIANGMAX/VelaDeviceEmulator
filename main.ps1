#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('menu','help','skins','images','list','create','repair','start','clean')][string]$Command='menu',
    [Parameter(Position=1)][string]$Name,
    [string]$Skin,
    [string]$Image='vela-watch-5.0',
    [ValidateRange(1024,65535)][int]$DebugPort=2512
)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
$VvdRoot=Join-Path $Root 'vvd'
$SdkRoot=Join-Path $Root 'sdk'
$SkinRoot=Join-Path $SdkRoot 'skins\builtin'
$ImageRoot=Join-Path $SdkRoot 'system-images'
$Utf8=[Text.UTF8Encoding]::new($false)

function Write-Text([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,$Utf8)
}
function Read-Ini([string]$Path) {
    $values=[ordered]@{}
    foreach($line in [IO.File]::ReadAllLines($Path)) {
        if($line -match '^\s*([^#;=]+?)\s*=(.*)$') { $values[$Matches[1].Trim()]=$Matches[2].Trim() }
    }
    return ,$values
}
function Write-Ini([string]$Path,$Values) {
    $text=($Values.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key,$_.Value }) -join "`r`n"
    Write-Text $Path ($text+"`r`n")
}
function Assert-Name([string]$Value) {
    if($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
        throw '实例名须为 1–64 位英文字母、数字、下划线或连字符，首位须为字母或数字。'
    }
}
function Get-Skins {
    foreach($dir in Get-ChildItem -LiteralPath $SkinRoot -Directory | Sort-Object Name) {
        $text=[IO.File]::ReadAllText((Join-Path $dir.FullName 'layout'))
        $display=[regex]::Match($text,'(?s)\bdisplay\s*\{(.*?)\}').Groups[1].Value
        $props=[regex]::Match($text,'(?s)\bprops\s*\{(.*?)\}').Groups[1].Value
        $width=[regex]::Match($display,'\bwidth\s+(\d+)').Groups[1].Value
        $height=[regex]::Match($display,'\bheight\s+(\d+)').Groups[1].Value
        $density=[regex]::Match($props,'\bdensity\s+(\d+)').Groups[1].Value
        $shape=[regex]::Match($props,'\bshape\s+([\w-]+)').Groups[1].Value
        $flavor=[regex]::Match($props,'\bflavor\s+(\w+)').Groups[1].Value
        if(!$width -or !$height -or !$density -or !$shape -or !$flavor) { throw "皮肤 layout 不完整：$($dir.Name)" }
        [pscustomobject]@{Skin=$dir.Name;Width=[int]$width;Height=[int]$height;Density=[int]$density;Shape=$shape;Flavor=$flavor}
    }
}
function Get-Images {
    foreach($dir in Get-ChildItem -LiteralPath $ImageRoot -Directory | Sort-Object Name) {
        $missing=@('nuttx','vela_system.bin','vela_data.bin') | Where-Object { !(Test-Path -LiteralPath (Join-Path $dir.FullName $_) -PathType Leaf) }
        [pscustomobject]@{Image=$dir.Name;Ready=($missing.Count -eq 0);Missing=($missing -join ',')}
    }
}
function Get-InstanceNames {
    if(Test-Path -LiteralPath $VvdRoot) {
        Get-ChildItem -LiteralPath $VvdRoot -Directory -Filter '*.vvd' | Sort-Object Name | ForEach-Object { $_.Name.Substring(0,$_.Name.Length-4) }
    }
}
function Get-Metadata([string]$InstanceName) {
    Assert-Name $InstanceName
    $dir=Join-Path $VvdRoot ($InstanceName+'.vvd')
    $metaPath=Join-Path $dir 'instance.json'
    if(Test-Path -LiteralPath $metaPath) {
        return Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    }
    $config=Read-Ini (Join-Path $dir 'config.ini')
    return [pscustomobject]@{Id=[guid]::NewGuid().ToString();Name=$InstanceName;Skin=$config['skin.name'];Image=$config['ide.image.type']}
}
function Get-RegistrationDirectory {
    $homeDir=[Environment]::GetFolderPath('UserProfile')
    return Join-Path $homeDir '.vela\vvd'
}
function Get-RegistrationPath([string]$InstanceName) {
    return Join-Path (Get-RegistrationDirectory) ($InstanceName+'.ini')
}
function Get-OrphanedRegistrations {
    $directory=Get-RegistrationDirectory
    if(!(Test-Path -LiteralPath $directory)) { return }
    if((Get-Item -LiteralPath $directory -Force).LinkType) { throw '默认 VVD 目录是联接，停止清理。' }
    foreach($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.ini') {
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try {
            $paths=@((Join-Path $directory ($file.BaseName+'.vvd')))
            $config=Read-Ini $file.FullName
            if($config['path']) {
                $target=[Environment]::ExpandEnvironmentVariables($config['path'])
                if($target -match '%[^%]+%') { continue }
                if(![IO.Path]::IsPathRooted($target)) { $target=Join-Path $directory $target }
                $paths+=[IO.Path]::GetFullPath($target)
            }
            if($config['path.rel']) {
                $paths+=Join-Path (Split-Path $directory) $config['path.rel']
                $paths+=Join-Path $directory $config['path.rel']
            }
            $orphan=$true
            foreach($target in $paths) {
                $target=[IO.Path]::GetFullPath($target)
                # 离线盘符、网络根不可访问时，不判作已删除的实例。
                if(!(Test-Path -LiteralPath ([IO.Path]::GetPathRoot($target)) -ErrorAction Stop)) { $orphan=$false; break }
                if(Test-Path -LiteralPath $target -ErrorAction Stop) { $orphan=$false; break }
            }
            if($orphan) { $file }
        } catch { Write-Host "跳过无法确认的索引：$($file.Name)" -ForegroundColor Yellow }
    }
}
function Clear-OrphanedRegistrations {
    $directory=Get-RegistrationDirectory
    $files=@(Get-OrphanedRegistrations)
    if(!$files.Count) { Write-Host '没有可清理的孤立实例索引。'; return }
    Write-Host "`n可清理的孤立索引（$directory）："
    foreach($file in $files) { Write-Host ('  '+$file.Name) }
    $answer=Read-MenuInput '仅删除以上 .ini，不删除任何实例目录。确认清理？[y/N]'
    if($answer -ne 'y') { Write-Host '已取消清理。'; return }
    $count=0
    foreach($file in $files) {
        # 删除前重新确认，保护刚恢复为有效实例的索引。
        $current=@(Get-OrphanedRegistrations | Where-Object FullName -eq $file.FullName)
        if(!$current.Count) { continue }
        if([IO.Path]::GetDirectoryName($file.FullName) -ne [IO.Path]::GetFullPath($directory)) { throw '索引路径越界，停止清理。' }
        Remove-Item -LiteralPath $file.FullName
        $count++
    }
    Write-Host "已清理 $count 个孤立索引。"
}
function Assert-Registration([string]$InstanceName,$Meta) {
    $path=Get-RegistrationPath $InstanceName
    $parent=Get-Item -LiteralPath (Split-Path $path) -Force -ErrorAction SilentlyContinue
    if($parent -and $parent.LinkType) { throw "默认 VVD 目录是目录联接，请先将其恢复为普通目录：$($parent.FullName)；工具不会修改其他联接的目标。" }
    if(Test-Path -LiteralPath $path) {
        $old=Read-Ini $path
        $expected=Join-Path $VvdRoot ($InstanceName+'.vvd')
        if($old['portable.instance.id'] -ne $Meta.Id -and $old['path'] -ne $expected) {
            throw "当前用户已有同名外部实例：$InstanceName，路径：$($old['path'])。请改用其他实例名。"
        }
    }
}
function Assert-Resources($Meta) {
    if($Meta.Skin -notin @(Get-Skins | ForEach-Object Skin)) { throw "无此 builtin 型号：$($Meta.Skin)，请运行 skins 查看。" }
    $imageInfo=Get-Images | Where-Object Image -eq $Meta.Image
    if(!$imageInfo -or !$imageInfo.Ready) { throw "镜像不存在或文件不完整：$($Meta.Image)，请运行 images 查看。" }
}
function Assert-NotRunning([string]$InstanceName) {
    $running=@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(emulator|qemu-system-armel)\.exe$' -and
        $_.CommandLine -match ('(?:^|\s)-avd\s+"?'+[regex]::Escape($InstanceName)+'"?(?:\s|$)')
    })
    if($running.Count) { throw "实例已在运行：$InstanceName。请先关闭该实例。" }
}
function Repair-Instance([string]$InstanceName) {
    $meta=Get-Metadata $InstanceName
    if($meta.Name -ne $InstanceName) { throw "实例元数据名称不符：$InstanceName" }
    Assert-NotRunning $InstanceName
    Assert-Resources $meta
    Assert-Registration $InstanceName $meta
    $dir=Join-Path $VvdRoot ($InstanceName+'.vvd')
    $configPath=Join-Path $dir 'config.ini'
    $config=Read-Ini $configPath
    $newSkin=Join-Path $SkinRoot $meta.Skin
    $newImage=Join-Path $ImageRoot $meta.Image
    if($config['skin.path'] -ne $newSkin -or $config['image.sysdir.1'] -ne $newImage -or $config['image.sysdir.2']) {
        $config['skin.path']=$newSkin
        $config['image.sysdir.1']=$newImage
        $config['image.sysdir.2']=''
        Write-Ini $configPath $config
    }
    # 仅补缺失文件；数据分区已有内容时绝不以源镜像覆盖。
    foreach($file in @('vela_system.bin','vela_data.bin','vela_resource.bin','coredump.core')) {
        $source=Join-Path $newImage $file
        $target=Join-Path $dir $file
        if((Test-Path -LiteralPath $source) -and !(Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source -Destination $target }
    }
    $modemSource=Join-Path $SdkRoot 'modem_simulator'
    $modemTarget=Join-Path $dir 'modem_simulator'
    if((Test-Path -LiteralPath $modemSource) -and !(Test-Path -LiteralPath $modemTarget)) { Copy-Item -LiteralPath $modemSource -Destination $modemTarget -Recurse }
    $metaPath=Join-Path $dir 'instance.json'
    if(!(Test-Path -LiteralPath $metaPath)) { Write-Text $metaPath ($meta | ConvertTo-Json) }
    $index=[ordered]@{path=$dir;'path.rel'=('avd\'+$InstanceName+'.vvd');'portable.instance.id'=$meta.Id}
    Write-Ini (Join-Path $VvdRoot ($InstanceName+'.ini')) $index
    $registration=Get-RegistrationPath $InstanceName
    New-Item -ItemType Directory -Path (Split-Path $registration) -Force | Out-Null
    Write-Ini $registration $index
    Write-Host "已修正并登记：$InstanceName → $dir"
}
function New-Instance([string]$InstanceName,[string]$SelectedSkin=$Skin,[string]$SelectedImage=$Image) {
    Assert-Name $InstanceName
    if(!$SelectedSkin) { throw '创建时须指定 -Skin；运行 skins 查看 builtin 型号。' }
    $meta=[pscustomobject]@{Id=[guid]::NewGuid().ToString();Name=$InstanceName;Skin=$SelectedSkin;Image=$SelectedImage}
    Assert-Resources $meta
    Assert-Registration $InstanceName $meta
    $dir=Join-Path $VvdRoot ($InstanceName+'.vvd')
    if((Test-Path -LiteralPath $dir) -or (Test-Path -LiteralPath (Join-Path $VvdRoot ($InstanceName+'.ini')))) { throw "实例已存在，拒绝覆盖：$InstanceName" }
    $skinInfo=Get-Skins | Where-Object Skin -eq $SelectedSkin
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $config=[ordered]@{
        AvdId=$InstanceName;'abi.type'='armeabi-v7a';'avd.ini.displayname'=$InstanceName;'avd.ini.encoding'='UTF-8'
        'fastboot.forceChosenSnapshotBoot'='no';'fastboot.forceColdBoot'='yes';'fastboot.forceFastBoot'='no'
        'hw.arc'='false';'hw.audioInput'='yes';'hw.battery'='yes';'hw.camera.back'='None';'hw.camera.front'='None'
        'hw.cpu.arch'='arm';'hw.cpu.ncore'='2';'hw.dPad'='no';'hw.gps'='yes';'hw.gpu.enabled'='no';'hw.gpu.mode'='host'
        'hw.initialOrientation'='Portrait';'hw.keyboard'='yes';'hw.lcd.width'=$skinInfo.Width;'hw.lcd.height'=$skinInfo.Height
        'hw.lcd.density'=$skinInfo.Density;'hw.mainKeys'='no';'hw.ramSize'='1024';'hw.sdCard'='no'
        'hw.sensors.orientation'='yes';'hw.trackBall'='no';'runtime.network.latency'='none';'runtime.network.speed'='full'
        showDeviceFrame='yes';'skin.dynamic'='yes';'skin.name'=$SelectedSkin;'skin.path'=(Join-Path $SkinRoot $SelectedSkin)
        'hw.accelerometer'='yes';'hw.gyroscope'='yes';'hw.sensors.proximity'='yes';'hw.sensors.magnetic_field'='yes'
        'hw.sensors.temperature'='yes';'hw.sensors.light'='yes';'hw.sensors.humidity'='yes';'hw.sensors.heart_rate'='yes'
        'hw.lcd.shape'=$skinInfo.Shape;'hw.device.flavor'=$skinInfo.Flavor;'ide.image.type'=$SelectedImage
        'product.marketname'=$SelectedSkin;'image.sysdir.1'=(Join-Path $ImageRoot $SelectedImage);'image.sysdir.2'=''
    }
    Write-Ini (Join-Path $dir 'config.ini') $config
    Write-Text (Join-Path $dir 'instance.json') ($meta | ConvertTo-Json)
    Repair-Instance $InstanceName
    Write-Host "已创建：$InstanceName（$SelectedSkin，$($skinInfo.Width)×$($skinInfo.Height)）。数据分区独立。"
}
function Start-Instance([string]$InstanceName,[int]$SelectedPort=$DebugPort) {
    if(!$InstanceName) { throw '请指定实例名，或运行 run.bat 从菜单中选择。' }
    Assert-Name $InstanceName
    $binary=Join-Path $SdkRoot 'emulator\windows-x86_64\emulator.exe'
    $adbBinary=Join-Path $SdkRoot 'tools\adb\win\adb.exe'
    if(!(Test-Path -LiteralPath $adbBinary -PathType Leaf)) { throw '包内 ADB 缺失，请检查 sdk/tools/adb/win/adb.exe。' }
    Repair-Instance $InstanceName
    $oldAvd=$env:ANDROID_AVD_HOME
    $oldSdk=$env:ANDROID_SDK_ROOT
    try {
        $env:ANDROID_AVD_HOME=$VvdRoot
        $env:ANDROID_SDK_ROOT=$SdkRoot
        $emuArgs=@('-vela','-avd',$InstanceName,'-adb-path',$adbBinary,'-network-user-mode-options',"hostfwd=tcp:127.0.0.1:${SelectedPort}-10.0.2.15:101")
        $emuArgs+=@('-qemu','-device','virtio-snd,bus=virtio-mmio-bus.2','-allow-host-audio','-semihosting','-smp','2')
        $argumentLine=($emuArgs | ForEach-Object { '"'+$_+'"' }) -join ' '
        # 独立启动原生模拟器，不经过后台脚本，不接管输出。
        $nativeProcess=Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory $Root -WindowStyle Hidden -PassThru
        try {
            if($nativeProcess.WaitForExit(2000) -and $nativeProcess.ExitCode -ne 0) { throw "模拟器启动失败，退出码：$($nativeProcess.ExitCode)" }
        } finally { $nativeProcess.Dispose() }
    } finally {
        $env:ANDROID_AVD_HOME=$oldAvd
        $env:ANDROID_SDK_ROOT=$oldSdk
    }
    Write-Host "已启动：$InstanceName。可继续选择其他实例，或退出菜单。" -ForegroundColor Green
}
function Read-MenuInput([string]$Prompt) {
    $answer=Read-Host $Prompt
    if($null -eq $answer) { throw [OperationCanceledException]::new('输入已结束。') }
    return $answer.Trim()
}
function Read-MenuChoice([string]$Prompt,[int]$Count) {
    while($true) {
        $answer=Read-MenuInput $Prompt
        if($answer -eq 'q') { return -1 }
        $number=0
        if([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $Count) { return $number-1 }
        Write-Host "请输入 1–$Count 之间的编号；例如：1。输入 Q 返回主菜单。" -ForegroundColor Yellow
    }
}
function Start-MenuInstance([string]$InstanceName) {
    $port=0
    foreach($candidate in 2512..2612) {
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$candidate)
        try { $listener.Start(); $port=$candidate; break } catch [Net.Sockets.SocketException] { } finally { $listener.Stop() }
    }
    if(!$port) { throw '没有可用调试端口，请关闭不再使用的模拟器后重试。' }
    Start-Instance -InstanceName $InstanceName -SelectedPort $port
}
function Show-CreateWizard {
    Write-Host "`n—— 新建实例向导（任一步输入 Q 返回）——" -ForegroundColor Cyan
    while($true) {
        $instanceName=Read-MenuInput '第 1 步 / 实例名称（示例：MyBand10；限字母、数字、_、-）'
        if($instanceName -eq 'q') { return }
        try {
            Assert-Name $instanceName
            if((Test-Path -LiteralPath (Join-Path $VvdRoot ($instanceName+'.vvd'))) -or (Test-Path -LiteralPath (Join-Path $VvdRoot ($instanceName+'.ini')))) { throw '该实例名已存在，请换一个名称。' }
            break
        } catch [OperationCanceledException] { throw }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
    $skins=@(Get-Skins)
    Write-Host "`n第 2 步 / 选择型号："
    for($i=0;$i -lt $skins.Count;$i++) {
        $item=$skins[$i]
        Write-Host ('  {0}. {1,-19} {2} × {3}' -f ($i+1),$item.Skin,$item.Width,$item.Height)
    }
    $skinIndex=Read-MenuChoice '请输入型号编号（示例：1 表示 redmi_watch）' $skins.Count
    if($skinIndex -lt 0) { return }
    $selectedSkin=$skins[$skinIndex]
    $images=@(Get-Images | Where-Object Ready)
    if(!$images.Count) { throw '未找到完整可用镜像，请先补齐 sdk/system-images 中的镜像文件。' }
    if($images.Count -eq 1) {
        $selectedImage=$images[0].Image
        Write-Host "`n第 3 步 / 镜像：$selectedImage（当前仅此一个可用镜像，自动选用）。"
    } else {
        Write-Host "`n第 3 步 / 选择镜像："
        for($i=0;$i -lt $images.Count;$i++) { Write-Host "  $($i+1). $($images[$i].Image)" }
        $imageIndex=Read-MenuChoice '请输入镜像编号（示例：1）' $images.Count
        if($imageIndex -lt 0) { return }
        $selectedImage=$images[$imageIndex].Image
    }
    Write-Host "`n将创建：$instanceName / $($selectedSkin.Skin) / $($selectedSkin.Width)×$($selectedSkin.Height) / $selectedImage"
    $confirm=Read-MenuInput '确认创建？[Y/n]（回车或 Y 创建；N 取消）'
    if($confirm -notin @('','y')) { Write-Host '已取消，未创建实例。'; return }
    Write-Host '正在复制独立数据分区，请稍候……'
    New-Instance -InstanceName $instanceName -SelectedSkin $selectedSkin.Skin -SelectedImage $selectedImage
    $launch=Read-MenuInput '是否立即启动？[y/N]（示例：Y 启动；回车返回主菜单）'
    if($launch -eq 'y') { Start-MenuInstance $instanceName }
}
function Show-Menu {
    :MenuLoop while($true) {
        try {
            Write-Host "`n========== Vela 模拟器 ==========" -ForegroundColor Cyan
            $names=@(Get-InstanceNames)
            if(!$names.Count) {
                Write-Host '尚无实例。输入 N，按向导创建第一个实例。'
            } else {
                Write-Host '输入实例编号即可启动：'
                for($i=0;$i -lt $names.Count;$i++) {
                    try {
                        $config=Read-Ini (Join-Path $VvdRoot ($names[$i]+'.vvd\config.ini'))
                        Write-Host ('  {0}. {1}  [{2}]' -f ($i+1),$names[$i],$config['skin.name'])
                    } catch { Write-Host ('  {0}. {1}  [配置不完整]' -f ($i+1),$names[$i]) -ForegroundColor Yellow }
                }
            }
            Write-Host "`n  N 新建实例    P 修正搬家路径    C 清理孤立索引    R 刷新列表    0 退出"
            $answer=Read-MenuInput '请选择（示例：N 新建、1 启动第一个实例、0 退出）'
            if($answer -in @('0','q')) { return }
            switch($answer.ToUpperInvariant()) {
                N { Show-CreateWizard; continue MenuLoop }
                C { Clear-OrphanedRegistrations; continue MenuLoop }
                P {
                    foreach($instanceName in $names) { Repair-Instance $instanceName }
                    if(!$names.Count) { Write-Host '暂无实例需要修正；新建时会自动配置路径。' }
                    continue MenuLoop
                }
                R { continue MenuLoop }
            }
            $number=0
            if([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $names.Count) {
                Start-MenuInstance $names[$number-1]
            } else { Write-Host '选项无效。请输入上方编号或字母；例如 N。' -ForegroundColor Yellow }
        } catch [OperationCanceledException] { return }
        catch { Write-Host "操作失败：$($_.Exception.Message)" -ForegroundColor Red }
    }
}
try {
    switch($Command) {
        menu { Show-Menu }
        help {
            @'
便携 Vela 模拟器工具（Windows 10 自带 PowerShell 即可）
  双击 run.bat                             打开菜单和创建向导
  .\emu.ps1 skins                          列出 builtin 型号及尺寸
  .\emu.ps1 images                         列出本地镜像
  .\emu.ps1 list                           列出实例
  .\emu.ps1 create MyBand -Skin xiaomi_band_10
  .\emu.ps1 repair                         搬家后修正全部实例
  .\emu.ps1 clean                          确认后清理孤立 .ini 索引
  .\emu.ps1 start MyBand                    自动修正后启动
  .\emu.ps1 start MyBand -DebugPort 2513     指定调试端口
同名外部实例拒绝覆盖，请另取名称。
'@ | Write-Host
        }
        skins { Get-Skins | Format-Table -AutoSize }
        images { Get-Images | Format-Table -AutoSize }
        list {
            foreach($instanceName in Get-InstanceNames) {
                $config=Read-Ini (Join-Path $VvdRoot ($instanceName+'.vvd\config.ini'))
                [pscustomobject]@{Name=$instanceName;Skin=$config['skin.name'];Image=$config['ide.image.type']}
            }
        }
        create { New-Instance $Name }
        repair {
            $names=if($Name) { @($Name) } else { @(Get-InstanceNames) }
            foreach($instanceName in $names) { Repair-Instance $instanceName }
        }
        start { Start-Instance $Name }
        clean { Clear-OrphanedRegistrations }
    }
} catch {

    Write-Error $_ -ErrorAction Continue
    exit 1
}
