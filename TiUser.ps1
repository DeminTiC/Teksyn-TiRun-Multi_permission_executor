<#
.SYNOPSIS
    多权限执行器（GUI V1.3版）
    V1.2我尝试修改了GUI界面，并且尝试添加了一些新功能，比如启用所有特权、交互式桌面、启动前暂停等等，可能不太稳定或者无效
V1.3依旧GUI更新，功能不变
    如果真不行的话我再改吧
.DESCRIPTION
    支持 TrustedInstaller、SYSTEM、当前用户三种身份启动新窗口运行命令
    高权限模式需安装 NtObjectManager 模块（无需多言）
.NOTES
    你知道这必须以管理员身份运行
    请谨慎操作，后果自负，真搞坏什么东西了就无了
#>

#requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# 全局变量
$script:ModuleReady = $false

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

# 提权部分（讲真这个地方是真难写，为了搞一个启用所有特权又是赋值错误，又是无法获取进程PID，我以后是坚决不会再去乱改这个地方了 :( ）
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

    # 当前用户模式
    $wrappedCommand = $Command # 依旧自动识别
	if ($Command -match '\s' -and $Command -notmatch '^".*"$') {
		$wrappedCommand = '"' + $Command + '"'
	}
	
    if ($Level -eq 'CurrentUser') {
        # 当前用户模式
		if ($HideWindow) {
			# 隐藏时用 /c
			$startArgs = @{
				FilePath = 'cmd.exe'
				ArgumentList = "/c $wrappedCommand"
				WindowStyle = 'Hidden'
			}
		}
		else {
			$startArgs = @{
				FilePath = 'cmd.exe'
				ArgumentList = "/k $wrappedCommand"
				WindowStyle = 'Normal'
			}
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

    # 高权限模式：加载模块然后提权（无需多言）
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

        $CREATE_NEW_CONSOLE = 0x00000010
		$CREATE_NO_WINDOW   = 0x08000000

		if ($HideWindow) {
			$flags = $CREATE_NO_WINDOW
			$cmdSwitch = '/c'
		} else {
			$flags = $CREATE_NEW_CONSOLE
			$cmdSwitch = '/k'
		}

		$newProcParams = @{
			CommandLine = "cmd.exe $cmdSwitch $wrapped"
			ParentProcess = $parentProc
			CreationFlags = $flags
		}
		
		# 这里是以弹出新窗口的方式运行其他脚本的关键，“/c”参数会直接隐藏窗口启动，这里我换成了“/k”
		# 此外如果脚本本身还带有空格等特殊字符的话，还要添加引号，我试着写了下自动识别调整，但愿能用（你别说还有点希望）
        $wrappedCommand = $Command
		if ($Command -match '\s' -and $Command -notmatch '^".*"$') {
			$wrappedCommand = '"' + $Command + '"'
		}
		
		#切换器形式的参数修改，要不然太难写了
		$cmdSwitch = if ($HideWindow) { '/c' } else { '/k' }

		$newProcParams = @{
			CommandLine = "cmd.exe $cmdSwitch $wrappedCommand"
			ParentProcess = $parentProc
			CreationFlags = $flags
		}

        if ($WorkingDirectory) {
            $newProcParams.CurrentDirectory = $WorkingDirectory
        }

        if ($InteractiveDesktop) {
            $newProcParams.Desktop = "WinSta0\Default"
        }

        $newProc = New-Win32Process @newProcParams

        # 获取进程 ID（5个策略，都不行的话就真完了）
        $procId = $null

        # 策略1：检查 Pid 属性（NtCoreLib.Win32.Process.Win32Process 类型）
        if ($null -ne $newProc -and $null -ne $newProc.Pid) {
            $procId = $newProc.Pid
            Write-Host "[*] 通过属性 Pid 获取 PID: $procId" -ForegroundColor Gray
        }

        # 策略2：直接访问 ProcessId 属性
        if (-not $procId -and $null -ne $newProc.ProcessId) {
            $procId = $newProc.ProcessId
            Write-Host "[*] 通过属性 ProcessId 获取 PID: $procId" -ForegroundColor Gray
        }

        # 策略3：尝试强制转换
        if (-not $procId) {
            try {
                $procId = [int]$newProc.Pid
                Write-Host "[*] 通过强制转换 Pid 获取 PID: $procId" -ForegroundColor Gray
            }
            catch { }
        }

        # 策略4：通过 Select-Object
        if (-not $procId) {
            $procId = $newProc | Select-Object -ExpandProperty Pid -ErrorAction SilentlyContinue
            if (-not $procId) {
                $procId = $newProc | Select-Object -ExpandProperty ProcessId -ErrorAction SilentlyContinue
            }
            if ($procId) {
                Write-Host "[*] 通过 Select-Object 获取 PID: $procId" -ForegroundColor Gray
            }
        }

        # 策略5：字符串解析（穷途末路）
        if (-not $procId) {
            $objStr = $newProc | Out-String
            if ($objStr -match 'Pid\s*:\s*(\d+)') {
                $procId = [int]$Matches[1]
                Write-Host "[*] 通过字符串解析获取 PID: $procId" -ForegroundColor Gray
            }
        }

        if (-not $procId) {
            Write-Host "[-] 无法获取进程 ID。New-Win32Process 返回的对象类型: $($newProc.GetType().FullName)" -ForegroundColor Yellow
            Write-Host "    对象内容: $($newProc | Out-String)" -ForegroundColor Yellow
        }
        else {
            Write-Host "[+] 新窗口已启动，PID: $procId" -ForegroundColor Green
        }

        # 处理“启用全部特权”选项（最难写的地方，没有之一）
        if ($EnableAllPrivileges) {
            if ($procId) {
                Write-Host "[*] 正在尝试为新进程启用所有可用特权..." -ForegroundColor Cyan
                try {
                    $token = Get-NtToken -ProcessId $procId -Access MaximumAllowed
                    $allPrivs = $token.Privileges | Select-Object -ExpandProperty Name
                    $enabledCount = 0
                    foreach ($privName in $allPrivs) {
                        try {
                            Enable-NtTokenPrivilege -Token $token -Privilege $privName -ErrorAction Stop
                            $enabledCount++
                        }
                        catch {
                            Write-Host "  警告: 无法启用特权 $privName" -ForegroundColor DarkYellow
                        }
                    }
                    Write-Host "[+] 已启用 $enabledCount 项特权（共 $($allPrivs.Count) 项可用）" -ForegroundColor Green
                }
                catch {
                    Write-Host "[-] 启用全部特权时出错: $_" -ForegroundColor Red
                }
            }
            else {
                Write-Host "[-] 无法获取进程 ID，跳过启用全部特权" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "[*] 未启用“启用全部特权”选项" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "[-] 提权执行失败: $_" -ForegroundColor Red
    }
}

# 构建 GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Teksyn · 多权限执行器'
$form.ClientSize = New-Object System.Drawing.Size(750, 320)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

# 左侧说明面板（新加的）
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

【注意事项】
- 必须管理员身份运行
- 操作不可逆，请谨慎
- 隐藏窗口选项仅对
  cmd 类脚本有效
"@
$form.Controls.Add($txtHelp)

# 垂直分隔线
$line = New-Object System.Windows.Forms.Label
$line.Location = New-Object System.Drawing.Point(195, 12)
$line.Size = New-Object System.Drawing.Size(2, 265)
$line.BorderStyle = 'Fixed3D'
$form.Controls.Add($line)

# 右侧主操作区起始 X 坐标（显式声明为 int）
[int]$rightX = 210

# 命令输入行
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

# 工作目录行
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

# 权限选择行
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

# 运行按钮
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

# 模块安装按钮
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

# 附加选项分组框
$grpOptions = New-Object System.Windows.Forms.GroupBox
$grpOptions.Text = '选项'
$grpOptions.Location = New-Object System.Drawing.Point($rightX, 115)
$grpOptions.Size = New-Object System.Drawing.Size(520, 80)
$form.Controls.Add($grpOptions)

# ToolTip
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

# 底部按钮
$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = '关于(&A)'
$btnAbout.Size = New-Object System.Drawing.Size(80, 26)
$btnAbout.Location = New-Object System.Drawing.Point(($rightX + 350), 250)
$btnAbout.FlatStyle = 'System'
$btnAbout.Add_Click({
    $about = @"
Teksyn 多权限执行器
版本 1.3 · 作者 ATRI-TOPiC

支持 TI / SYSTEM / 当前用户身份执行命令
依赖 NtObjectManager 模块

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

# 状态条
$statusBar = New-Object System.Windows.Forms.StatusBar
$statusBar.Text = '就绪'
$statusBar.SizingGrip = $false
$form.Controls.Add($statusBar)

# UI 状态更新函数
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

# 初始化模块检测
if (Test-NtObjectManagerInstalled) {
    $script:ModuleReady = $true
}
UpdateUI

# 显示窗口
[void]$form.ShowDialog()