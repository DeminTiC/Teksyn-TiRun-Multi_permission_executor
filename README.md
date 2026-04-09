# Teksyn - 多权限执行器

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

一个带窗口界面的权限提升小工具，可以用 **TrustedInstaller**、**SYSTEM** 或 **当前用户** 身份在新窗口里跑命令或程序
可以试试用选定的权限启动一个 CMD 窗口，然后输入 whoami /groups 看看权限池多大

> 用 TrustedInstaller 权限的时候悠着点，乱删文件或改系统配置可能会把系统搞崩，后果自己担

## 界面长这样（差不多吧）

```
+--------------------------------------------------------+
|  Teksyn · 权限执行器                                   
|  权力越大，责任越大                    
|                                                        
|  要执行的命令（支持参数）：                             
|  [ cmd.exe                          ] [浏览...]       
|                                                        
|  权限级别：[ TrustedInstaller ▼ ]                      
|  [安装模块]  [在新窗口中运行]                          
|                                                        
|  · 所有模式均在新窗口运行，不捕获输出                  
|  · TrustedInstaller / SYSTEM 需要先装 NtObjectManager  
|  · 当前用户模式不用模块，直接跑                        
|                                                        
|                          [关于]  [退出]                
+--------------------------------------------------------+
```

## 这脚本能干啥

- **三种权限切换**  
  - **TrustedInstaller**：系统里最高的权限，能改那些受保护的系统文件  
  - **SYSTEM**：和 Windows 后台服务一个级别  
  - **当前用户**：就是你当前登录账户的权限，不用装额外东西  

- **图形界面操作**  
  不用记命令行，输入命令或者点“浏览”选程序就行，自由度也更高

- **点一下装模块**  
  TrustedInstaller 和 SYSTEM 模式需要 `NtObjectManager` 这个 PowerShell 模块，界面里有个按钮点一下就自动装了（需要联网）

- **单独弹窗口跑命令**  
  所有命令都在新控制台窗口里跑，主界面不卡，输出就在新窗口里看

- **提示和禁用逻辑**  
  需要装模块的时候运行按钮是灰的，装完才能点。选当前用户模式就直接能用

## 运行条件

- **系统**：Windows 7 到 11，Server 2012 及以上都行  
- **PowerShell**：5.1 或更高（Win10/11 自带就是）  
- **权限**：**得用管理员身份运行**（就算只用当前用户模式也建议右键管理员启动，省得出奇怪问题）  
- **.NET**：4.5 以上（系统一般都有）

## 怎么用

1. 从 Release 中下载 **TiRun** 的压缩包，然后解压
2. 右键 Stater.bat 选“以管理员身份运行”，等待启动
3. 输入你要跑的命令，或者点“浏览”找个 exe/bat
4. 下拉选权限：TrustedInstaller / SYSTEM / 当前用户
5. 如果选了高权限模式且没装过模块，点“安装模块”，等它装完
6. 点“在新窗口中运行”，目标程序就会以你选的权限弹新窗口了

## 原理简单说

- **高权限模式**：通过 `NtObjectManager` 模块拿到 TrustedInstaller.exe 或 winlogon.exe 的令牌，再用 `New-Win32Process` 以这个令牌起个新进程，同时指定 `NewConsole` 让它有独立窗口
- **当前用户模式**：直接用 `Start-Process` 起新窗口，权限跟你当前一样
- **界面**：纯 `System.Windows.Forms` 手搓的，没依赖外部 UI 库

## 依赖（点按钮自动装）

| 依赖 | 干嘛的 | 怎么装 |
|------|--------|--------|
| `NtObjectManager` | 获取高权限令牌并创建进程 | 点界面按钮自动装（需要联网） |
| `SeDebugPrivilege` | 调试特权，用来打开高权限进程 | 脚本里 `Enable-NtTokenPrivilege` 自动启用 |

如果网络不行，也可以手动装：  
`Install-Module -Name NtObjectManager -Force -Scope CurrentUser`

## 常见问题（如果真有什么神秘问题的话，直接联系我吧，下面列的应该够全了）

**Q：为何要单独写一个 Starter.bat 来启动脚本？**  
A：直接用 Bypass 策略启动更省事点，这样就不用自己跑去改 Powershell 脚本启动策略了

**Q：为什么 TrustedInstaller 模式有时候会卡一会儿？**  
A：TrustedInstaller 服务默认手动启动，脚本会去拉它起来，得等几秒让进程稳定

**Q：SYSTEM 模式干嘛用 winlogon.exe？**  
A：winlogon 是登录进程，始终 SYSTEM 身份跑，比 lsass 稳，也不会被杀软盯上

**Q：点了运行没反应？**  
- 看看是不是没以管理员身份跑脚本  
- 杀软可能拦了 `NtObjectManager` 的行为，暂时关了试试  
- 命令路径有空格的话记得在界面上加引号，比如 `"C:\Program Files\xxx\xxx.exe"`

**Q：能不能把输出抓回来显示在界面上？**  
A：这工具设计就是弹新窗口看输出，没做输出捕获。想要日志的话自己在命令里加重定向，比如 `cmd /c my.exe > log.txt`

## 安全相关

- 没后门、没联网上报、没多余动作，代码全公开
- TrustedInstaller 权限能干很多底层操作，**别瞎搞**，尤其是删系统文件或者改注册表
- 作者不对你自己误操作导致的系统挂掉负责

## 许可证

就是MIT，随便用，改也行，保留个作者名就行

## 参考/致谢

- [NtObjectManager](https://github.com/googleprojectzero/sandbox-attacksurface-analysis-tools)（其实是 google 的 project zero 那套，不过模块在 PSGallery 里）  
- 写这个主要是提权的时候老要手动敲代码，还要搞什么获取所有权（还有几率失败），干脆整个带GUI界面的脚本多省事
- **Nsudo** 也给这个项目带来了很大的启发（Nsudo提权真的很快，比我这个脚本快多了其实，但是脚本的兼容性会更好一点，跨平台啥的会更方便）（不是要对标Nsudo，Nsudo可以以调用方式运行，这个脚本暂时还没做这个，各位按需选择吧）

## 反馈

有问题或建议直接提 [Issue] 吧

---

**觉得好用就给个 Star，谢了。**
