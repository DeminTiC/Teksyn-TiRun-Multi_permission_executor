<#
.SYNOPSIS
    多权限执行器（GUI V1.3 + CLI 扩展 = V2.0 Alpha）
    支持 TrustedInstaller、SYSTEM、当前用户三种身份运行命令。
    新增：交互式控制台模式、命令行调用模式。
.DESCRIPTION
    支持三种使用方式：
    1. 无参数：启动图形界面。
    2. -Interactive：进入交互式控制台，反复执行命令。
    3. -Command <命令> [-Level <权限>] [其他开关]：执行单条命令后退出。
.PARAMETER Command
    要执行的命令（如 "cmd /c whoami" 或 "powershell Get-Process"）。
.PARAMETER Level
    执行权限：TrustedInstaller / SYSTEM / CurrentUser（默认 CurrentUser）。
.PARAMETER Interactive
    启用交互式控制台模式。
.PARAMETER HideWindow
    隐藏新窗口（仅对 cmd 类命令有效）。
.PARAMETER EnableAllPrivileges
    尝试为新进程启用所有可用特权（高权限模式有效）。
.PARAMETER InteractiveDesktop
    在交互式桌面启动（默认启用）。
.PARAMETER PauseBeforeStart
    启动前暂停 3 秒。
.PARAMETER WorkingDirectory
    工作目录路径。
.NOTES
    必须管理员身份运行。高权限模式需安装 NtObjectManager 模块。
#>

#requires -RunAsAdministrator

param(
    [string]$Command,
    [string]$Level = 'CurrentUser',
    [switch]$Interactive,
    [switch]$HideWindow,
    [switch]$EnableAllPrivileges,
    [switch]$InteractiveDesktop = $true,
    [switch]$PauseBeforeStart,
    [string]$WorkingDirectory
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# 全局变量（GUI 专用）
$script:ModuleReady = $false

# 辅助函数
function Test-NtObjectManagerInstalled {
    return [bool](Get-Module -ListAvailable -Name NtObjectManager)
}

function Install-NtObjectManagerModule {
    Write-Host "[*] 正在安装 NtObjectManager 模块..." -ForegroundColor Cyan
    try {
        Install-Module -Name NtObjectManager -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        Write-Host "[+] 模块安装完成" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[-] 安装失败: $_" -ForegroundColor Red
        return $false
    }
}

# 核心提权执行函数（与 V1.3 的原代码一致，只修正了重复定义的小问题）
function Invoke-WithPrivilege {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [ValidateSet('TrustedInstaller','SYSTEM','CurrentUser')]
        [string]$Level,
        [string]$WorkingDirectory,
        [switch]$HideWindow,
        [switch]$EnableAllPrivileges,
        [switch]$InteractiveDesktop,
        [switch]$PauseBeforeStart
    )

    Write-Host "`n[*] 以 $Level 身份执行: $Command" -ForegroundColor Cyan
    if ($PauseBeforeStart) {
        Write-Host "[!] 启动前暂停 3 秒，可按 Ctrl+C 取消..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }

    # 处理命令引号
    $wrappedCommand = $Command
    if ($Command -match '\s' -and $Command -notmatch '^".*"$') {
        $wrappedCommand = '"' + $Command + '"'
    }
    $cmdSwitch = if ($HideWindow) { '/c' } else { '/k' }

    # 当前用户模式
    if ($Level -eq 'CurrentUser') {
        $startArgs = @{
            FilePath = 'cmd.exe'
            ArgumentList = "$cmdSwitch $wrappedCommand"
            WindowStyle = if ($HideWindow) { 'Hidden' } else { 'Normal' }
        }
        if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }
        try {
            Start-Process @startArgs
            Write-Host "[+] 已在新窗口启动（当前用户权限）" -ForegroundColor Green
        }
        catch {
            Write-Host "[-] 启动失败: $_" -ForegroundColor Red
        }
        return
    }

    # 高权限模式：需要 NtObjectManager（不用多讲）
    if (-not (Get-Module -Name NtObjectManager)) {
        try { Import-Module NtObjectManager -Force }
        catch {
            Write-Host "[-] 无法加载 NtObjectManager，请先安装模块" -ForegroundColor Red
            return
        }
    }

    try {
        Enable-NtTokenPrivilege SeDebugPrivilege | Out-Null

        $parentProc = $null
        if ($Level -eq 'TrustedInstaller') {
            $svc = Get-Service TrustedInstaller -ErrorAction SilentlyContinue
            if ($svc.Status -ne 'Running') {
                Write-Host "[*] 启动 TrustedInstaller 服务..." -ForegroundColor Yellow
                Start-Service TrustedInstaller
                Start-Sleep -Seconds 3
            }
            $parentProc = Get-NtProcess -Name TrustedInstaller.exe | Select-Object -First 1
            if (-not $parentProc) { throw "找不到 TrustedInstaller.exe 进程" }
        }
        else {
            $parentProc = Get-NtProcess -Name winlogon.exe | Select-Object -First 1
            if (-not $parentProc) { throw "找不到 winlogon.exe 进程（无法获取 SYSTEM 令牌）" }
        }

        Write-Host "[+] 父进程 PID: $($parentProc.ProcessId)" -ForegroundColor Green

        $flags = if ($HideWindow) { 0x08000000 } else { 0x00000010 }  # CREATE_NO_WINDOW / CREATE_NEW_CONSOLE
        $newProcParams = @{
            CommandLine = "cmd.exe $cmdSwitch $wrappedCommand"
            ParentProcess = $parentProc
            CreationFlags = $flags
        }
        if ($WorkingDirectory) { $newProcParams.CurrentDirectory = $WorkingDirectory }
        if ($InteractiveDesktop) { $newProcParams.Desktop = "WinSta0\Default" }

        $newProc = New-Win32Process @newProcParams

        # 获取 PID（多种策略）
        $procId = $null
        if ($null -ne $newProc -and $null -ne $newProc.Pid) { $procId = $newProc.Pid }
        if (-not $procId -and $null -ne $newProc.ProcessId) { $procId = $newProc.ProcessId }
        if (-not $procId) { $procId = $newProc | Select-Object -ExpandProperty Pid -ErrorAction SilentlyContinue }
        if (-not $procId) {
            $objStr = $newProc | Out-String
            if ($objStr -match 'Pid\s*:\s*(\d+)') { $procId = [int]$Matches[1] }
        }

        if ($procId) {
            Write-Host "[+] 新窗口已启动，PID: $procId" -ForegroundColor Green
            if ($EnableAllPrivileges) {
                Write-Host "[*] 尝试启用所有可用特权..." -ForegroundColor Cyan
                try {
                    $token = Get-NtToken -ProcessId $procId -Access MaximumAllowed
                    $allPrivs = $token.Privileges | Select-Object -ExpandProperty Name
                    $enabledCount = 0
                    foreach ($privName in $allPrivs) {
                        try {
                            Enable-NtTokenPrivilege -Token $token -Privilege $privName -ErrorAction Stop
                            $enabledCount++
                        }
                        catch { Write-Host "  警告: 无法启用特权 $privName" -ForegroundColor DarkYellow }
                    }
                    Write-Host "[+] 已启用 $enabledCount 项特权（共 $($allPrivs.Count) 项可用）" -ForegroundColor Green
                }
                catch { Write-Host "[-] 启用全部特权时出错: $_" -ForegroundColor Red }
            }
        }
        else {
            Write-Host "[-] 无法获取进程 ID" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[-] 提权执行失败: $_" -ForegroundColor Red
    }
}

# 交互式控制台（新加的）
function Start-InteractiveConsole {
    Clear-Host
    Write-Host @"
║  TiRun 多权限执行器 - 交互式控制台模式
║  输入命令后按回车，然后选择要使用的权限。
║  输入 "exit" 退出，输入 "help" 查看帮助。
"@ -ForegroundColor Cyan

    $defaultLevel = 'SYSTEM'
    $lastCommand = $null

    while ($true) {
        Write-Host "`n[TiRun]" -ForegroundColor Green -NoNewline
        $inputLine = Read-Host "> "
        $inputLine = $inputLine.Trim()
        if ($inputLine -eq '') { continue }

        # 处理清屏命令
        if ($inputLine -eq 'clear' -or $inputLine -eq 'cls') {
            Clear-Host
            # 可选：重新显示 banner
            Write-Host @"
║  TiRun 多权限执行器 - 交互式控制台模式
║  输入命令后按回车，然后选择要使用的权限。
║  输入 "exit" 退出，输入 "help" 查看帮助。
"@ -ForegroundColor Cyan
            continue
        }

        if ($inputLine -eq 'exit') {
            Write-Host "再见！" -ForegroundColor Magenta
            break
        }
        if ($inputLine -eq 'help') {
            Write-Host @"
可用命令:
  直接输入要执行的命令，例如: whoami
  特殊命令:
    setlevel <TI|SYSTEM|CurrentUser>   - 设置默认权限（当前默认: $defaultLevel）
    last                                 - 重复上一次执行的命令
    clear / cls                          - 清屏
    help                                 - 显示此帮助
    exit                                 - 退出控制台
"@ -ForegroundColor Yellow
            continue
        }
        if ($inputLine -eq 'last') {
            if ($lastCommand) {
                $inputLine = $lastCommand
            }
            else {
                Write-Host "没有上次执行的命令" -ForegroundColor Red
                continue
            }
        }
        if ($inputLine -match '^setlevel\s+(.+)$') {
            $newLevel = $matches[1].Trim()
            if ($newLevel -in 'TI','TrustedInstaller','SYSTEM','CurrentUser') {
                if ($newLevel -eq 'TI') { $newLevel = 'TrustedInstaller' }
                $defaultLevel = $newLevel
                Write-Host "[*] 默认权限已设置为: $defaultLevel" -ForegroundColor Green
            }
            else {
                Write-Host "无效权限，可选值: TI, SYSTEM, CurrentUser" -ForegroundColor Red
            }
            continue
        }

        # 记录命令
        $lastCommand = $inputLine

        # 询问权限（直接回车即使用默认）
        Write-Host "请选择执行权限 (1=TI, 2=SYSTEM, 3=CurrentUser, 默认=$defaultLevel): " -NoNewline
        $choice = Read-Host
        $level = switch ($choice.Trim()) {
            '1' { 'TrustedInstaller' }
            '2' { 'SYSTEM' }
            '3' { 'CurrentUser' }
            default { $defaultLevel }
        }

        # 询问附加选项
        $hide = $false
        $yn = Read-Host "是否隐藏窗口？(y/N)"
        if ($yn -eq 'y' -or $yn -eq 'Y') { $hide = $true }

        # 执行
        Invoke-WithPrivilege -Command $inputLine -Level $level -HideWindow:$hide -InteractiveDesktop
        Write-Host "`n[完成] 按 Enter 继续..." -ForegroundColor DarkGray
        Read-Host
    }
}

# 图形界面（原 GUI）
function Start-GUI {
    # 原有 GUI 代码（保持不变，仅将窗体和控件创建移到函数内）
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Teksyn · 多权限执行器'
    $form.ClientSize = New-Object System.Drawing.Size(750, 320)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

    # 左侧说明面板
    $lblHelpTitle = New-Object System.Windows.Forms.Label
    $lblHelpTitle.Text = '使用说明'
    $lblHelpTitle.Location = New-Object System.Drawing.Point(12, 12)
    $lblHelpTitle.Size = New-Object System.Drawing.Size(150, 18)
    $lblHelpTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblHelpTitle)

    $txtHelp = New-Object System.Windows.Forms.RichTextBox
    $txtHelp.Location = New-Object System.Drawing.Point(12, 32)
    $txtHelp.Size = New-Object System.Drawing.Size(170, 245)
    $txtHelp.ReadOnly = $true
    $txtHelp.BackColor = [System.Drawing.Color]::WhiteSmoke
    $txtHelp.BorderStyle = 'FixedSingle'
    $txtHelp.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $txtHelp.Text = @"
【功能】
以 TrustedInstaller、
SYSTEM 或当前用户
身份运行任意命令。

【权限说明】
· TrustedInstaller：
  Windows 最高特权，
  可修改系统核心文件。
· SYSTEM：
  系统账户权限，
  高于管理员。
· 当前用户：
  当前登录用户权限。

【依赖模块】
高权限模式需安装
NtObjectManager 模块，
可通过右侧按钮安装。

【控制台模式】
运行本脚本时加 -Interactive
参数可进入命令行交互。
"@
    $form.Controls.Add($txtHelp)

    $line = New-Object System.Windows.Forms.Label
    $line.Location = New-Object System.Drawing.Point(195, 12)
    $line.Size = New-Object System.Drawing.Size(2, 265)
    $line.BorderStyle = 'Fixed3D'
    $form.Controls.Add($line)

    [int]$rightX = 210

    $lblCmd = New-Object System.Windows.Forms.Label
    $lblCmd.Text = '命令(&C):'
    $lblCmd.Location = New-Object System.Drawing.Point($rightX, 15)
    $lblCmd.Size = New-Object System.Drawing.Size(45, 23)
    $form.Controls.Add($lblCmd)

    $txtCommand = New-Object System.Windows.Forms.TextBox
    $txtCommand.Location = New-Object System.Drawing.Point(($rightX + 48), 12)
    $txtCommand.Size = New-Object System.Drawing.Size(385, 23)
    $txtCommand.Text = 'cmd'
    $form.Controls.Add($txtCommand)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(($rightX + 438), 10)
    $btnBrowse.Size = New-Object System.Drawing.Size(75, 25)
    $btnBrowse.FlatStyle = 'System'
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = '选择可执行文件'
        $ofd.Filter = '可执行文件 (*.exe;*.bat;*.cmd;*.ps1)|*.exe;*.bat;*.cmd;*.ps1|所有文件 (*.*)|*.*'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtCommand.Text = $ofd.FileName
        }
    })
    $form.Controls.Add($btnBrowse)

    $lblWorkDir = New-Object System.Windows.Forms.Label
    $lblWorkDir.Text = '目录(&D):'
    $lblWorkDir.Location = New-Object System.Drawing.Point($rightX, 45)
    $lblWorkDir.Size = New-Object System.Drawing.Size(45, 23)
    $form.Controls.Add($lblWorkDir)

    $txtWorkDir = New-Object System.Windows.Forms.TextBox
    $txtWorkDir.Location = New-Object System.Drawing.Point(($rightX + 48), 42)
    $txtWorkDir.Size = New-Object System.Drawing.Size(385, 23)
    $txtWorkDir.Text = [Environment]::GetFolderPath('Desktop')
    $form.Controls.Add($txtWorkDir)

    $btnWorkDir = New-Object System.Windows.Forms.Button
    $btnWorkDir.Text = '...'
    $btnWorkDir.Location = New-Object System.Drawing.Point(($rightX + 438), 40)
    $btnWorkDir.Size = New-Object System.Drawing.Size(30, 25)
    $btnWorkDir.FlatStyle = 'System'
    $btnWorkDir.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = '选择工作目录'
        $fbd.SelectedPath = $txtWorkDir.Text
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtWorkDir.Text = $fbd.SelectedPath
        }
    })
    $form.Controls.Add($btnWorkDir)

    $lblPriv = New-Object System.Windows.Forms.Label
    $lblPriv.Text = '权限(&P):'
    $lblPriv.Location = New-Object System.Drawing.Point($rightX, 80)
    $lblPriv.Size = New-Object System.Drawing.Size(45, 23)
    $form.Controls.Add($lblPriv)

    $cboPriv = New-Object System.Windows.Forms.ComboBox
    $cboPriv.Location = New-Object System.Drawing.Point(($rightX + 48), 78)
    $cboPriv.Size = New-Object System.Drawing.Size(130, 23)
    $cboPriv.DropDownStyle = 'DropDownList'
    $cboPriv.Items.AddRange(@('TrustedInstaller', 'SYSTEM', 'CurrentUser'))
    $cboPriv.SelectedIndex = 0
    $form.Controls.Add($cboPriv)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = '运行'
    $btnRun.Location = New-Object System.Drawing.Point(($rightX + 188), 76)
    $btnRun.Size = New-Object System.Drawing.Size(90, 28)
    $btnRun.Enabled = $false
    $btnRun.FlatStyle = 'System'
    $btnRun.Add_Click({
        $cmd = $txtCommand.Text.Trim()
        if ([string]::IsNullOrEmpty($cmd)) {
            [System.Windows.Forms.MessageBox]::Show('请输入命令', '提示', 'OK', 'Warning')
            return
        }
        $level = $cboPriv.SelectedItem.ToString()
        $workDir = $txtWorkDir.Text.Trim()
        if (-not (Test-Path $workDir)) {
            [System.Windows.Forms.MessageBox]::Show('工作目录不存在，将使用默认目录', '警告', 'OK', 'Warning')
            $workDir = $null
        }

        $params = @{
            Command = $cmd
            Level = $level
            WorkingDirectory = $workDir
            HideWindow = $chkHideWindow.Checked
            EnableAllPrivileges = $chkAllPrivileges.Checked
            InteractiveDesktop = $chkInteractiveDesktop.Checked
            PauseBeforeStart = $chkPauseBefore.Checked
        }
        Write-Host "`n=> 执行：$level 模式 " -ForegroundColor Magenta
        Invoke-WithPrivilege @params
        Write-Host "=> 完成 `n" -ForegroundColor Magenta
    })
    $form.Controls.Add($btnRun)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = '安装模块'
    $btnInstall.Location = New-Object System.Drawing.Point(($rightX + 288), 76)
    $btnInstall.Size = New-Object System.Drawing.Size(100, 28)
    $btnInstall.FlatStyle = 'System'
    $btnInstall.Add_Click({
        $btnInstall.Enabled = $false
        $btnInstall.Text = '安装中...'
        if (Install-NtObjectManagerModule) {
            $script:ModuleReady = $true
            $btnRun.Enabled = $true
            $btnInstall.Text = '已安装'
            Write-Host '[+] 模块就绪，可以执行命令了' -ForegroundColor Green
        }
        else {
            $btnInstall.Text = '重试安装'
            $btnInstall.Enabled = $true
            $btnRun.Enabled = $false
        }
    })
    $form.Controls.Add($btnInstall)

    $grpOptions = New-Object System.Windows.Forms.GroupBox
    $grpOptions.Text = '选项'
    $grpOptions.Location = New-Object System.Drawing.Point($rightX, 115)
    $grpOptions.Size = New-Object System.Drawing.Size(520, 80)
    $form.Controls.Add($grpOptions)

    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 5000
    $tooltip.InitialDelay = 500

    $chkHideWindow = New-Object System.Windows.Forms.CheckBox
    $chkHideWindow.Text = '隐藏窗口(&H)'
    $chkHideWindow.Location = New-Object System.Drawing.Point(12, 20)
    $chkHideWindow.Size = New-Object System.Drawing.Size(110, 24)
    $chkHideWindow.Checked = $false
    $tooltip.SetToolTip($chkHideWindow, '以隐藏窗口方式启动（对 SYSTEM/TI 有效），即 “/c” 与 “/k” 运行参数切换')
    $grpOptions.Controls.Add($chkHideWindow)

    $chkAllPrivileges = New-Object System.Windows.Forms.CheckBox
    $chkAllPrivileges.Text = '启用全部特权(&A)'
    $chkAllPrivileges.Location = New-Object System.Drawing.Point(130, 20)
    $chkAllPrivileges.Size = New-Object System.Drawing.Size(140, 24)
    $chkAllPrivileges.Checked = $false
    $tooltip.SetToolTip($chkAllPrivileges, '尝试为进程启用所有可用特权（需高权限）')
    $grpOptions.Controls.Add($chkAllPrivileges)

    $chkInteractiveDesktop = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveDesktop.Text = '交互式桌面(&I)'
    $chkInteractiveDesktop.Location = New-Object System.Drawing.Point(280, 20)
    $chkInteractiveDesktop.Size = New-Object System.Drawing.Size(120, 24)
    $chkInteractiveDesktop.Checked = $true
    $tooltip.SetToolTip($chkInteractiveDesktop, '在 WinSta0\Default 桌面启动（正常情况不要取消勾选）')
    $grpOptions.Controls.Add($chkInteractiveDesktop)

    $chkPauseBefore = New-Object System.Windows.Forms.CheckBox
    $chkPauseBefore.Text = '启动前暂停(&P)'
    $chkPauseBefore.Location = New-Object System.Drawing.Point(12, 45)
    $chkPauseBefore.Size = New-Object System.Drawing.Size(130, 24)
    $chkPauseBefore.Checked = $false
    $tooltip.SetToolTip($chkPauseBefore, '创建进程前暂停 3 秒，便于附加调试器或取消')
    $grpOptions.Controls.Add($chkPauseBefore)

    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.Text = '关于(&A)'
    $btnAbout.Size = New-Object System.Drawing.Size(80, 26)
    $btnAbout.Location = New-Object System.Drawing.Point(($rightX + 350), 250)
    $btnAbout.FlatStyle = 'System'
    $btnAbout.Add_Click({
        $about = @"
Teksyn 多权限执行器
版本 1.4 · 作者 ATRI-TOPiC

支持 TI / SYSTEM / 当前用户身份执行命令
依赖 NtObjectManager 模块

新增：交互式控制台模式（-Interactive）
      命令行调用模式（-Command）

权力越大，责任越大，请合理使用
"@
        [System.Windows.Forms.MessageBox]::Show($about, '关于', 'OK', 'Information')
    })
    $form.Controls.Add($btnAbout)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出(&X)'
    $btnExit.Size = New-Object System.Drawing.Size(80, 26)
    $btnExit.Location = New-Object System.Drawing.Point(($rightX + 438), 250)
    $btnExit.FlatStyle = 'System'
    $btnExit.Add_Click({ $form.Close() })
    $form.Controls.Add($btnExit)

    $statusBar = New-Object System.Windows.Forms.StatusBar
    $statusBar.Text = '就绪'
    $statusBar.SizingGrip = $false
    $form.Controls.Add($statusBar)

    function UpdateUI {
        $priv = $cboPriv.SelectedItem.ToString()
        if ($priv -eq 'CurrentUser') {
            $btnRun.Enabled = $true
            $btnInstall.Enabled = $false
            $btnInstall.Text = '无需安装'
            $statusBar.Text = '当前用户模式 - 无需额外模块'
        }
        else {
            if ($script:ModuleReady) {
                $btnRun.Enabled = $true
                $btnInstall.Enabled = $false
                $btnInstall.Text = '已安装'
                $statusBar.Text = "模块已就绪，可执行 $priv 命令"
            }
            else {
                $btnRun.Enabled = $false
                $btnInstall.Enabled = $true
                $btnInstall.Text = '安装模块'
                $statusBar.Text = "需要安装 NtObjectManager 模块才能使用 $priv 权限"
            }
        }
    }

    $cboPriv.Add_SelectedIndexChanged({ UpdateUI })

    if (Test-NtObjectManagerInstalled) { $script:ModuleReady = $true }
    UpdateUI

    [void]$form.ShowDialog()
}

# 启动判断
if ($Interactive) {
    Start-InteractiveConsole
}
elseif ($Command) {
    # 一次性调用模式
    if ($Level -notin 'TrustedInstaller','SYSTEM','CurrentUser') {
        Write-Host "无效的权限级别，使用默认 CurrentUser" -ForegroundColor Yellow
        $Level = 'CurrentUser'
    }
    Invoke-WithPrivilege -Command $Command -Level $Level -HideWindow:$HideWindow -EnableAllPrivileges:$EnableAllPrivileges -InteractiveDesktop:$InteractiveDesktop -PauseBeforeStart:$PauseBeforeStart -WorkingDirectory $WorkingDirectory
}
else {
    Start-GUI
}