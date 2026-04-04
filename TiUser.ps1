<#
.SYNOPSIS
    带 GUI 的权限执行器：支持 TrustedInstaller、SYSTEM、当前用户三种权限，在新窗口运行命令。
.DESCRIPTION
    - 提供窗口：输入命令/浏览文件，安装模块按钮（仅 TI 和 SYSTEM 需要），权限下拉框，运行按钮。
    - TrustedInstaller / SYSTEM 模式需要先安装 NtObjectManager 模块，并启用 SeDebugPrivilege。
    - 当前用户模式直接运行，无需模块。
    - 所有模式均在新窗口执行命令，不捕获输出。
.NOTES
    必须以管理员身份运行（当前用户模式除外，但为统一体验仍要求管理员）。
    警告：高权限可能损坏系统，请谨慎操作！
#>

#requires -RunAsAdministrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 全局变量 ----------
$global:ModuleInstalled = $false

# ---------- 辅助函数：检查模块是否已安装 ----------
function Test-NtObjectManagerInstalled {
    return [bool](Get-Module -ListAvailable -Name NtObjectManager)
}

# ---------- 辅助函数：安装模块 ----------
function Install-NtObjectManagerModule {
    Write-Host "[*] 正在安装 NtObjectManager 模块..." -ForegroundColor Cyan
    try {
        Install-Module -Name NtObjectManager -Force -Scope CurrentUser -AllowClobber
        Write-Host "[+] 模块安装成功" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[-] 模块安装失败: $_" -ForegroundColor Red
        return $false
    }
}

# ---------- 提权执行函数（新窗口模式）----------
function Invoke-AsHighIntegrity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CommandLine,
        [Parameter(Mandatory=$true)]
        [ValidateSet("TrustedInstaller", "SYSTEM", "CurrentUser")]
        [string]$Privilege
    )

    Write-Host "[*] 以 $Privilege 权限运行: $CommandLine" -ForegroundColor Cyan

    if ($Privilege -eq "CurrentUser") {
        # 直接启动新窗口
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $CommandLine" -WindowStyle Normal
            Write-Host "[+] 已在当前用户权限下启动新窗口。" -ForegroundColor Green
        }
        catch {
            Write-Host "[-] 启动失败: $_" -ForegroundColor Red
        }
        return
    }

    # TrustedInstaller 或 SYSTEM 模式需要 NtObjectManager 模块
    if (-not (Get-Module -Name NtObjectManager)) {
        try {
            Import-Module NtObjectManager -Force
        }
        catch {
            Write-Host "[-] 无法导入 NtObjectManager 模块，请先安装。" -ForegroundColor Red
            return
        }
    }

    try {
        Enable-NtTokenPrivilege SeDebugPrivilege | Out-Null

        # 获取父进程
        $parentProcess = $null
        if ($Privilege -eq "TrustedInstaller") {
            $svc = Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
            if ($svc.Status -ne 'Running') {
                Write-Host "[*] 启动 TrustedInstaller 服务..." -ForegroundColor Yellow
                Start-Service -Name TrustedInstaller
                Start-Sleep -Seconds 3
            }
            $parentProcess = Get-NtProcess -Name TrustedInstaller.exe -First 1
            if (-not $parentProcess) { throw "未找到 TrustedInstaller.exe 进程" }
        }
        elseif ($Privilege -eq "SYSTEM") {
            # 使用 winlogon.exe (通常以 SYSTEM 运行)
            $parentProcess = Get-NtProcess -Name winlogon.exe -First 1
            if (-not $parentProcess) { throw "未找到 winlogon.exe 进程，无法获取 SYSTEM 令牌" }
        }

        Write-Host "[+] 找到父进程 PID: $($parentProcess.ProcessId)" -ForegroundColor Green

        # 创建新进程（新控制台窗口）
        $proc = New-Win32Process -CommandLine "cmd.exe /c $CommandLine" -CreationFlags NewConsole -ParentProcess $parentProcess
        Write-Host "[+] 新窗口已启动，进程 PID: $($proc.ProcessId)" -ForegroundColor Green
    }
    catch {
        Write-Host "[-] 提权执行失败: $_" -ForegroundColor Red
    }
}

# ---------- 创建 GUI 窗口 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Teksyn - 多权限执行器"
$form.Size = New-Object System.Drawing.Size(660, 320)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# 警告标签
$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Text = "权力越大，责任越大，请谨慎操作！"
$warningLabel.Location = New-Object System.Drawing.Point(10, 10)
$warningLabel.Size = New-Object System.Drawing.Size(620, 30)
$warningLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei", 10, [System.Drawing.FontStyle]::Bold)
$warningLabel.ForeColor = [System.Drawing.Color]::DarkRed
$warningLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($warningLabel)

# 命令标签
$labelCmd = New-Object System.Windows.Forms.Label
$labelCmd.Text = "要执行的命令（支持参数）："
$labelCmd.Location = New-Object System.Drawing.Point(10, 50)
$labelCmd.Size = New-Object System.Drawing.Size(400, 25)
$form.Controls.Add($labelCmd)

# 命令文本框
$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Location = New-Object System.Drawing.Point(10, 80)
$textBox.Size = New-Object System.Drawing.Size(450, 25)
$textBox.Text = "cmd"
$form.Controls.Add($textBox)

# 浏览按钮
$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = "浏览..."
$browseBtn.Location = New-Object System.Drawing.Point(470, 78)
$browseBtn.Size = New-Object System.Drawing.Size(120, 30)
$browseBtn.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "选择程序或脚本"
    $ofd.Filter = "可执行文件 (*.exe;*.bat;*.cmd)|*.exe;*.bat;*.cmd|所有文件 (*.*)|*.*"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBox.Text = $ofd.FileName
    }
})
$form.Controls.Add($browseBtn)

# 权限选择标签和下拉框
$labelPriv = New-Object System.Windows.Forms.Label
$labelPriv.Text = "权限级别："
$labelPriv.Location = New-Object System.Drawing.Point(10, 120)
$labelPriv.Size = New-Object System.Drawing.Size(80, 25)
$form.Controls.Add($labelPriv)

$comboPriv = New-Object System.Windows.Forms.ComboBox
$comboPriv.Location = New-Object System.Drawing.Point(90, 118)
$comboPriv.Size = New-Object System.Drawing.Size(150, 25)
$comboPriv.DropDownStyle = 'DropDownList'
$comboPriv.Items.AddRange(@("TrustedInstaller", "SYSTEM", "CurrentUser"))
$comboPriv.SelectedIndex = 0
$form.Controls.Add($comboPriv)

# 安装模块按钮
$installBtn = New-Object System.Windows.Forms.Button
$installBtn.Text = "安装 NtObjectManager 模块"
$installBtn.Location = New-Object System.Drawing.Point(260, 116)
$installBtn.Size = New-Object System.Drawing.Size(200, 30)
$installBtn.BackColor = [System.Drawing.Color]::LightGray
$installBtn.Add_Click({
    $installBtn.Enabled = $false
    $installBtn.Text = "安装中，请稍候..."
    $success = Install-NtObjectManagerModule
    if ($success) {
        $global:ModuleInstalled = $true
        $runBtn.Enabled = $true
        $installBtn.Text = "模块已安装"
        $installBtn.BackColor = [System.Drawing.Color]::LightGreen
        Write-Host "[+] 模块已就绪，现在可以执行命令了。" -ForegroundColor Green
    } else {
        $installBtn.Text = "安装失败，重试"
        $installBtn.Enabled = $true
        $installBtn.BackColor = [System.Drawing.Color]::LightCoral
        $runBtn.Enabled = $false
    }
})
$form.Controls.Add($installBtn)

# 运行按钮
$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Text = "在新窗口中运行命令"
$runBtn.Location = New-Object System.Drawing.Point(480, 116)
$runBtn.Size = New-Object System.Drawing.Size(150, 30)
$runBtn.Enabled = $false
$runBtn.BackColor = [System.Drawing.Color]::LightGreen
$runBtn.Add_Click({
    $command = $textBox.Text.Trim()
    if ([string]::IsNullOrEmpty($command)) {
        [System.Windows.Forms.MessageBox]::Show("请输入命令", "提示", "OK", "Warning")
        return
    }
    $priv = $comboPriv.SelectedItem.ToString()
    Write-Host "`n========== 开始执行（$priv 模式） ==========" -ForegroundColor Magenta
    Write-Host "[*] 用户命令: $command" -ForegroundColor Cyan
    Invoke-AsHighIntegrity -CommandLine $command -Privilege $priv
    Write-Host "========== 执行结束 ==========`n" -ForegroundColor Magenta
})
$form.Controls.Add($runBtn)

# 提示标签
$infoLabel = New-Object System.Windows.Forms.Label
$infoLabel.Text = "提示：所有模式均在新窗口运行命令，不捕获输出。`nTrustedInstaller / SYSTEM 模式需要先安装 NtObjectManager 模块。`n当前用户模式直接运行，无需模块。"
$infoLabel.Location = New-Object System.Drawing.Point(10, 160)
$infoLabel.Size = New-Object System.Drawing.Size(620, 60)
$infoLabel.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($infoLabel)

# ---------- 底部按钮：关于和退出 ----------
$formWidth = $form.ClientSize.Width

$aboutBtn = New-Object System.Windows.Forms.Button
$aboutBtn.Text = "关于"
$aboutBtn.Size = New-Object System.Drawing.Size(90, 28)
$aboutBtn.BackColor = [System.Drawing.Color]::LightGray
$aboutBtn.Location = New-Object System.Drawing.Point(($formWidth - 10 - 90 - 10 - 90), 240)
$aboutBtn.Add_Click({
    $aboutText = @"
作者：ATRI-TOPiC
版本：1.0 (支持 TI / SYSTEM / 当前用户)
功能：以不同权限级别在新窗口中运行命令
依赖：TrustedInstaller 和 SYSTEM 模式需要 NtObjectManager 模块
声明：本工具仅供学习和系统维护使用，滥用可能导致系统不稳定或安全风险。
      使用前请确保您了解不同权限级别的影响。
"@
    [System.Windows.Forms.MessageBox]::Show($aboutText, "关于多权限执行器", "OK", "Information")
})
$form.Controls.Add($aboutBtn)

$cancelBtn = New-Object System.Windows.Forms.Button
$cancelBtn.Text = "退出"
$cancelBtn.Size = New-Object System.Drawing.Size(90, 28)
$cancelBtn.BackColor = [System.Drawing.Color]::LightCoral
$cancelBtn.Location = New-Object System.Drawing.Point(($formWidth - 10 - 90), 240)
$cancelBtn.Add_Click({
    $form.Close()
})
$form.Controls.Add($cancelBtn)

# ---------- 窗口启动检查模块（仅当默认权限为 TI 或 SYSTEM 时需要）----------
function UpdateUIForPrivilege {
    $selected = $comboPriv.SelectedItem.ToString()
    if ($selected -eq "CurrentUser") {
        # 当前用户模式不需要模块，运行按钮始终启用，安装按钮禁用
        $runBtn.Enabled = $true
        $installBtn.Enabled = $false
        $installBtn.Text = "当前用户无需模块"
        $installBtn.BackColor = [System.Drawing.Color]::LightGray
    }
    else {
        # 需要模块
        if ($global:ModuleInstalled) {
            $runBtn.Enabled = $true
            $installBtn.Enabled = $false
            $installBtn.Text = "模块已安装"
            $installBtn.BackColor = [System.Drawing.Color]::LightGreen
        }
        else {
            $runBtn.Enabled = $false
            $installBtn.Enabled = $true
            $installBtn.Text = "安装 NtObjectManager 模块"
            $installBtn.BackColor = [System.Drawing.Color]::LightGray
        }
    }
}

# 监听权限下拉框变化
$comboPriv.Add_SelectedIndexChanged({
    UpdateUIForPrivilege
})

# 初始检查
if (Test-NtObjectManagerInstalled) {
    $global:ModuleInstalled = $true
}
UpdateUIForPrivilege

# 显示窗口
$form.ShowDialog() | Out-Null