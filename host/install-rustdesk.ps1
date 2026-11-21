#Requires -Version 5.1
<#
.SYNOPSIS
  Vega 安装包内的 RustDesk 一键安装 / 配置 / 回滚脚本。

.DESCRIPTION
  由 Vega-Setup.exe 的 NSIS 钩子在提权上下文里调用（perMachine，只提权这一次），
  也可以在被控端管理员 PowerShell 里手动运行。

  安装：
    - 读取随包的 vega-defaults.json（idServer / relayServer / key）；
    - 已装 RustDesk 就跳过安装，只写中继配置。已有安装的识别不只看默认
      Program Files 路径，还显式读 Registry64/Registry32 的 Uninstall 项
      InstallLocation / DisplayIcon 与 RustDesk 服务 ImagePath（t3-fix4）；
    - 未装时从官方 GitHub Release 下载固定版本（AGPL：不内嵌二进制），
      校验 SHA256 后以 --silent-install 静默安装，等待 RustDesk 服务出现；
    - 复用 Vega.Common 里 T2 的 RustDesk2.toml 写入逻辑（ACL 校验、原子写入）：
      NSIS 钩子把交互用户的 SID / Roaming AppData 以 ASCII Base64 传进来
      （-InteractiveUserContextB64），脚本解码并校验路径存在后只写该用户自己的
      用户级配置 + LocalService 服务级配置；取不到或解码失败时退回只写服务级，
      并在退出码/结果里标记降级。绝不写提权账户的 %APPDATA%；
    - 若这次是 Vega 装的，把安装记录写进 host-state.json，卸载时据此回滚。

  回滚（-Uninstall）：
    - 只按 state.json / host-state.json 里的记录恢复受管键；
    - 只卸载本次由 Vega 安装、且 state.json 记录了安装路径的 RustDesk；
      -KeepRustDesk 可保留，卸载失败时保留记录作为重试入口。

  脚本失败不会让 Vega 安装失败：NSIS 钩子只提示用户到 Vega 里手动安装。

  退出码（安装模式）：
    0 = 用户级 + 服务级都写入成功；
    2 = 成功但降级（只写了服务级配置，或用户级写入失败）；
    1 = 失败。

.PARAMETER DefaultsFile
  默认中继配置。默认取脚本同级目录的上一级（安装包里的 resources\vega-defaults.json）。

.PARAMETER LogFile
  日志路径，默认 %ProgramData%\Vega\logs\setup.log。写日志失败不影响安装。

.PARAMETER NoFileLog
  t3-fix4：不写文件日志（NSIS 钩子在 icacls 收紧 ACL 失败时传它）。
  脚本内部与 NSIS 的追加日志两层同时跳过文件写入。

.PARAMETER Uninstall
  回滚模式：恢复 RustDesk 配置，并按记录决定是否卸载 RustDesk。

.PARAMETER KeepRustDesk
  回滚模式下不卸载 RustDesk，只恢复配置。

.PARAMETER StatePath
  被控端清单路径，默认 %ProgramData%\Vega\host-state.json。

.PARAMETER ServiceStatePath
  服务模式清单路径，默认 %ProgramData%\Vega\state.json。

.PARAMETER InteractiveUserSid
  明文 SID（兼容/调试用）。安装包改用 -InteractiveUserContextB64。

.PARAMETER InteractiveUserAppData
  明文 Roaming AppData（兼容/调试用）。安装包改用 -InteractiveUserContextB64。

.PARAMETER InteractiveUserContextB64
  t3-fix4：NSIS 钩子一次解析后传来的 ASCII Base64(UTF-8("SID\nAppData"))。
  脚本解码后校验 SID 格式与 AppData 目录存在；校验失败按“取不到交互用户”处理，
  只写服务级配置并返回降级退出码 2。该参数优先于明文参数。

.EXAMPLE
  .\install-rustdesk.ps1 -DefaultsFile .\resources\vega-defaults.json

.EXAMPLE
  .\install-rustdesk.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DefaultsFile = '',
    [string]$LogFile = '',
    [switch]$NoFileLog,
    [switch]$Uninstall,
    [switch]$KeepRustDesk,
    [string]$StatePath = '',
    [string]$ServiceStatePath = '',
    [string]$InteractiveUserSid = '',
    [string]$InteractiveUserAppData = '',
    [string]$InteractiveUserContextB64 = ''
)

$ErrorActionPreference = 'Stop'

if ($NoFileLog) {
    # 不解析默认路径：没有可写日志目录时连目录创建都不做。
    $LogFile = ''
}
elseif ([string]::IsNullOrWhiteSpace($LogFile)) {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) { $programData = $env:TEMP }
    $LogFile = Join-Path (Join-Path (Join-Path $programData 'Vega') 'logs') 'setup.log'
}

if ([string]::IsNullOrWhiteSpace($DefaultsFile)) {
    $DefaultsFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'vega-defaults.json'
}

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "缺少共享模块：$modulePath" -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force

function Write-VegaLog {
    param([AllowEmptyString()][string]$Message = '')

    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
    Write-VegaSetupLog -Path $LogFile -Message $Message
}

Write-VegaLog ("开始：Uninstall={0} DefaultsFile={1}" -f [bool]$Uninstall, $DefaultsFile)

if (-not (Test-VegaProcessElevated)) {
    # 安装包调用时一定是提权的；手动运行时给出可执行的原因，而不是等到写配置才报错。
    Write-Host '需要管理员权限：请右键以管理员身份运行，或由 Vega-Setup.exe 调用。' -ForegroundColor Red
    Write-VegaLog 'FAIL 当前进程未提权'
    exit 1
}

# t3-fix4：解码 NSIS 传的 Base64 上下文，并校验路径真实存在。
# 校验失败不硬失败：清空交互用户参数，后面只写服务级配置，最终以退出码 2 标记降级。
$contextDecodeError = ''
if (-not [string]::IsNullOrWhiteSpace($InteractiveUserContextB64)) {
    $decodedContext = ConvertFrom-VegaInteractiveUserContextPayload -Payload $InteractiveUserContextB64
    if ($decodedContext.Valid) {
        $InteractiveUserSid = [string]$decodedContext.Sid
        $InteractiveUserAppData = [string]$decodedContext.AppDataPath
        Write-VegaLog ("交互用户上下文已解码：SID {0}" -f $InteractiveUserSid)
    }
    else {
        $contextDecodeError = [string]$decodedContext.Error
        $InteractiveUserSid = ''
        $InteractiveUserAppData = ''
        Write-VegaLog ("WARN 交互用户上下文无效（{0}），只写服务级配置。" -f $contextDecodeError)
        Write-Host ("未取到可用的交互用户（{0}），只写服务级中继配置。" -f $contextDecodeError) -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Get-VegaHostStatePath }
if ([string]::IsNullOrWhiteSpace($ServiceStatePath)) { $ServiceStatePath = Get-VegaRustDeskServiceStatePath }

try {
    if ($Uninstall) {
        $rollback = Invoke-VegaRustDeskRollback -HostStatePath $StatePath -ServiceStatePath $ServiceStatePath `
            -InteractiveUserAppData $InteractiveUserAppData -KeepRustDesk:$KeepRustDesk -Confirm:$false

        foreach ($message in @($rollback.Messages)) {
            Write-Host $message
            Write-VegaLog $message
        }
        foreach ($failure in @($rollback.Failures)) {
            Write-Host $failure -ForegroundColor Yellow
            Write-VegaLog "FAIL $failure"
        }
        exit $rollback.ExitCode
    }

    $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $DefaultsFile -HostStatePath $StatePath `
        -ServiceStatePath $ServiceStatePath -InteractiveUserSid $InteractiveUserSid `
        -InteractiveUserAppData $InteractiveUserAppData -LogFile $LogFile -Confirm:$false

    foreach ($message in @($result.Messages)) {
        Write-Host $message
        Write-VegaLog $message
    }

    if (-not $result.Success) {
        Write-Host $result.Error -ForegroundColor Yellow
        Write-Host '也可以打开 https://rustdesk.com/download 手动下载安装，装完回到 Vega 设置页查看配置。'
        Write-VegaLog "FAIL $($result.Error)"
        exit 1
    }

    if ($result.Degraded) {
        Write-Host 'RustDesk 已写入服务级自建中继配置；用户级配置未写入（已降级），请在完成页按提示手动处理。' -ForegroundColor Yellow
        Write-VegaLog '完成（降级：用户级配置未写入）'
        exit 2
    }

    Write-Host 'RustDesk 已安装并写入自建中继配置。' -ForegroundColor Green
    Write-VegaLog '完成'
    exit 0
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-VegaLog "FAIL 未捕获异常：$($_.Exception.Message)"
    exit 1
}
