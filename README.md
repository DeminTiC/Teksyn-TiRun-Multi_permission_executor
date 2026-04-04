# Teksyn-Multi_permission_executor

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

一款带图形界面的 Windows 权限提升工具，支持以 **TrustedInstaller**、**SYSTEM** 或 **当前用户** 权限在新窗口中运行任意命令或程序。

>  **警告**：高权限可能损坏系统或带来安全风险，请在理解权限作用后谨慎使用。建议仅在测试环境或系统维护场景下使用。

##  界面预览

```
+--------------------------------------------------------+
|  Teksyn - 多权限执行器                                 |
|  权力越大，责任越大，请谨慎操作！                       |
|                                                        |
|  要执行的命令（支持参数）：                             |
|  [ cmd.exe                          ] [浏览...]       |
|                                                        |
|  权限级别：[ TrustedInstaller ▼ ]                      |
|  [安装 NtObjectManager 模块]  [在新窗口中运行命令]      |
|                                                        |
|  提示：所有模式均在新窗口运行命令，不捕获输出。          |
|  TrustedInstaller / SYSTEM 模式需要先安装模块。        |
|  当前用户模式直接运行，无需模块。                       |
|                                                        |
|                          [关于]  [退出]                |
+--------------------------------------------------------+
```

##  功能特性

-  **三种权限级别**  
  - **TrustedInstaller** – 最高系统权限，可修改受保护的系统文件  
  - **SYSTEM** – 系统账户权限，与 Windows 内核级服务同级  
  - **当前用户** – 标准用户权限，无需额外依赖  

-  **图形化界面**  
  无需记忆命令行参数，输入命令或通过“浏览”选择可执行文件即可运行。

-  **一键安装依赖**  
  TrustedInstaller / SYSTEM 模式依赖 [`NtObjectManager`](https://www.powershellgallery.com/packages/NtObjectManager) PowerShell 模块，界面内置安装按钮。

-  **独立新窗口运行**  
  所有命令均在新控制台窗口中启动，不干扰主界面，输出直接显示在目标窗口中。

-  **安全提示**  
  界面醒目提醒权限风险，默认禁用需要模块的操作直到模块安装成功。

##  使用前提

- **操作系统**：Windows 7 / 8 / 10 / 11，Windows Server 2012+  
- **PowerShell**：5.1 或更高版本  
- **权限要求**：**必须以管理员身份运行**（当前用户模式虽可独立运行，但为统一体验建议始终以管理员启动）  
- **.NET Framework**：4.5 或更高（通常 Windows 已自带）

##  快速开始

### 1️⃣ 下载脚本

### 2️⃣ 以管理员身份运行Starter

### 3️⃣ 使用步骤

| 步骤 | 操作 |
|------|------|
| 1 | 在文本框中输入要执行的命令（例如 `notepad.exe`、`cmd /k whoami`）或点击“浏览”选择文件。 |
| 2 | 从下拉框选择需要的权限级别：`TrustedInstaller`、`SYSTEM` 或 `CurrentUser`。 |
| 3 | 若选择 `TrustedInstaller` 或 `SYSTEM` 且未安装模块，点击“安装 NtObjectManager 模块”。 |
| 4 | 点击“在新窗口中运行命令”，目标程序将以所选权限在新控制台窗口中启动。 |

##  工作原理

- **TrustedInstaller / SYSTEM 模式**  
  使用 `NtObjectManager` 模块获取 TrustedInstaller.exe 或 winlogon.exe 的进程令牌，通过 `New-Win32Process` 创建继承该令牌的新进程（带 `NewConsole` 标志）。

- **当前用户模式**  
  直接调用 `Start-Process` 以当前会话权限启动新窗口。

- **GUI 框架**  
  基于 `System.Windows.Forms` 原生实现，无需额外安装任何 UI 库。

##  依赖项（自动处理）

| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| [`NtObjectManager`](https://www.powershellgallery.com/packages/NtObjectManager) | 获取 TrustedInstaller / SYSTEM 令牌并创建进程 | 脚本内一键安装（需联网） |
| `SeDebugPrivilege` | 调试特权，用于打开高权限进程 | 脚本执行 `Enable-NtTokenPrivilege` 自动启用 |

> 若网络受限，可手动安装模块：  
> `Install-Module -Name NtObjectManager -Force -Scope CurrentUser`

##  常见问题

### 问：为什么 TrustedInstaller 模式需要启动服务？
答：TrustedInstaller 服务默认是手动启动，脚本会自动启动它并等待几秒，确保进程存在后再获取令牌。

### 问：SYSTEM 模式为何选用 winlogon.exe？
答：`winlogon.exe` 是 Windows 登录进程，始终以 SYSTEM 身份运行，且相比 `lsass.exe` 更稳定安全。

### 问：运行后没有任何窗口弹出？
答：请检查：
- 是否以管理员身份运行脚本
- 防火墙/杀毒软件是否拦截了 `NtObjectManager` 的行为
- 命令本身是否正确（例如路径包含空格时需加引号）

### 问：能否捕获命令的输出？
答：本工具专注于“在新窗口运行”，不捕获输出。如需捕获输出，建议直接使用 `Start-Process -RedirectStandardOutput` 自行编写脚本。

##  安全声明

- 本工具**不包含任何后门、木马或遥测代码**，所有操作均在本地完成。
- 使用 TrustedInstaller 权限可绕过大部分系统保护，**请勿用于恶意目的**。
- 建议仅在你完全理解命令后果的情况下使用，作者不对误操作导致的系统损坏负责。

##  许可证

本项目采用 [MIT 许可证](LICENSE)，你可以自由使用、修改和分发，但需保留版权声明。

##  致谢

- [NtObjectManager](https://github.com/google/gears) 提供了强大的 Windows NT 对象管理能力。
- 灵感来源于系统维护中对 TrustedInstaller 权限的实际需求。

##  联系与反馈

- 提交 [Issue](https://github.com/your-repo/Teksyn/issues) 报告 Bug 或建议
- 欢迎 Pull Request 改进代码或文档

---

**⭐ 如果这个工具帮助到了你，请给一个 Star 支持作者！**
