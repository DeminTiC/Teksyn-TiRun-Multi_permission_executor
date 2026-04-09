<#
.SYNOPSIS
    多权限执行器（GUI版）
.DESCRIPTION
    支持 TrustedInstaller、SYSTEM、当前用户三种身份启动新窗口运行命令。
    高权限模式需安装 NtObjectManager 模块。
.NOTES
    必须以管理员身份运行。
    请谨慎操作，后果自负。
#>

#requires -RunAsAdministrator

# DPI 适配与视觉样式（新加的，不知道效果在不同系统上是否通用）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# 全局变量
$script:ModuleReady = $false

# 检测 NtObjectManager 模块（这个不用多说）
function Test-NtObjectManagerInstalled {
    return [bool](Get-Module -ListAvailable -Name NtObjectManager)
}

# 安装模块部分
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

# 权限执行核心部分（这段我大概不会再修改了）
function Invoke-WithPrivilege {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [ValidateSet('TrustedInstaller','SYSTEM','CurrentUser')]
        [string]$Level
    )

    Write-Host "`n[*] 以 $Level 身份执行: $Command" -ForegroundColor Cyan

    if ($Level -eq 'CurrentUser') {
        try {
            Start-Process -FilePath cmd.exe -ArgumentList "/c $Command" -WindowStyle Normal
            Write-Host "[+] 已在新窗口启动（当前用户权限）" -ForegroundColor Green
        }
        catch {
            Write-Host "[-] 启动失败: $_" -ForegroundColor Red
        }
        return
    }

    # 高权限模式：加载模块，然后启用特权，再获取父进程令牌就行了
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

        $newProc = New-Win32Process -CommandLine "cmd.exe /c $Command" -CreationFlags NewConsole -ParentProcess $parentProc
        Write-Host "[+] 新窗口已启动，PID: $($newProc.ProcessId)" -ForegroundColor Green
    }
    catch {
        Write-Host "[-] 提权执行失败: $_" -ForegroundColor Red
    }
}

# 构建 GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Teksyn · 权限执行器'
$form.ClientSize = New-Object System.Drawing.Size(680, 320)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

# 控件
# 警告条
$lblWarning = New-Object System.Windows.Forms.Label
$lblWarning.Text = '权力越大，责任越大 - 请谨慎操作'
$lblWarning.Location = New-Object System.Drawing.Point(12, 12)
$lblWarning.Size = New-Object System.Drawing.Size(656, 28)
$lblWarning.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblWarning.ForeColor = [System.Drawing.Color]::Firebrick
$lblWarning.TextAlign = 'TopLeft'
$form.Controls.Add($lblWarning)

# 命令输入标签
$lblCmd = New-Object System.Windows.Forms.Label
$lblCmd.Text = '要执行的命令（支持参数）：'
$lblCmd.Location = New-Object System.Drawing.Point(12, 52)
$lblCmd.Size = New-Object System.Drawing.Size(300, 22)
$form.Controls.Add($lblCmd)

# 命令输入框
$txtCommand = New-Object System.Windows.Forms.TextBox
$txtCommand.Location = New-Object System.Drawing.Point(12, 78)
$txtCommand.Size = New-Object System.Drawing.Size(470, 28)
$txtCommand.Text = 'cmd'
$form.Controls.Add($txtCommand)

# 浏览按钮
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览...'
$btnBrowse.Location = New-Object System.Drawing.Point(492, 76)
$btnBrowse.Size = New-Object System.Drawing.Size(90, 30)
$btnBrowse.FlatStyle = 'System'
$btnBrowse.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = '选择程序或脚本'
    $ofd.Filter = '可执行文件 (*.exe;*.bat;*.cmd)|*.exe;*.bat;*.cmd|所有文件 (*.*)|*.*'
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtCommand.Text = $ofd.FileName
    }
})
$form.Controls.Add($btnBrowse)

# 权限选择标签
$lblPriv = New-Object System.Windows.Forms.Label
$lblPriv.Text = '权限级别：'
$lblPriv.Location = New-Object System.Drawing.Point(12, 118)
$lblPriv.Size = New-Object System.Drawing.Size(80, 22)
$form.Controls.Add($lblPriv)

# 权限下拉框
$cboPriv = New-Object System.Windows.Forms.ComboBox
$cboPriv.Location = New-Object System.Drawing.Point(90, 116)
$cboPriv.Size = New-Object System.Drawing.Size(160, 28)
$cboPriv.DropDownStyle = 'DropDownList'
$cboPriv.Items.AddRange(@('TrustedInstaller', 'SYSTEM', 'CurrentUser'))
$cboPriv.SelectedIndex = 0
$form.Controls.Add($cboPriv)

# 安装模块按钮
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '安装模块'
$btnInstall.Location = New-Object System.Drawing.Point(262, 114)
$btnInstall.Size = New-Object System.Drawing.Size(140, 30)
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

# 运行按钮
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = '在新窗口中运行'
$btnRun.Location = New-Object System.Drawing.Point(414, 114)
$btnRun.Size = New-Object System.Drawing.Size(140, 30)
$btnRun.Enabled = $false
$btnRun.FlatStyle = 'System'
$btnRun.Add_Click({
    $cmd = $txtCommand.Text.Trim()
    if ([string]::IsNullOrEmpty($cmd)) {
        [System.Windows.Forms.MessageBox]::Show('请输入命令', '提示', 'OK', 'Warning')
        return
    }
    $level = $cboPriv.SelectedItem.ToString()
    Write-Host "`n========== 执行：$level 模式 ==========" -ForegroundColor Magenta
    Invoke-WithPrivilege -Command $cmd -Level $level
    Write-Host "========== 完成 ==========`n" -ForegroundColor Magenta
})
$form.Controls.Add($btnRun)

# 信息提示
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "· 所有模式均在新窗口运行，不捕获输出`n· TrustedInstaller / SYSTEM 需要先安装 NtObjectManager 模块`n· 当前用户模式无需模块，可直接运行"
$lblInfo.Location = New-Object System.Drawing.Point(12, 160)
$lblInfo.Size = New-Object System.Drawing.Size(656, 70)
$lblInfo.ForeColor = [System.Drawing.Color]::DarkSlateBlue
$form.Controls.Add($lblInfo)

# 底部按钮
$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = '关于'
$btnAbout.Size = New-Object System.Drawing.Size(90, 30)
$btnAbout.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 200), 245)
$btnAbout.FlatStyle = 'System'
$btnAbout.Add_Click({
    $about = @"
Teksyn 多权限执行器
版本 1.1 · 作者 ATRI-TOPiC

支持 TI / SYSTEM / 当前用户三种身份在新窗口执行命令。
高权限模式依赖 NtObjectManager 模块。

请勿滥用，后果自负。
"@
    [System.Windows.Forms.MessageBox]::Show($about, '关于', 'OK', 'Information')
})
$form.Controls.Add($btnAbout)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'
$btnExit.Size = New-Object System.Drawing.Size(90, 30)
$btnExit.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 100), 245)
$btnExit.FlatStyle = 'System'
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)
# 控件部分结束

# UI 状态更新（就是那个 安装模块 的按钮状态探测）
function UpdateUI {
    $priv = $cboPriv.SelectedItem.ToString()
    if ($priv -eq 'CurrentUser') {
        $btnRun.Enabled = $true
        $btnInstall.Enabled = $false
        $btnInstall.Text = '无需安装'
    }
    else {
        if ($script:ModuleReady) {
            $btnRun.Enabled = $true
            $btnInstall.Enabled = $false
            $btnInstall.Text = '已安装'
        }
        else {
            $btnRun.Enabled = $false
            $btnInstall.Enabled = $true
            $btnInstall.Text = '安装模块'
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