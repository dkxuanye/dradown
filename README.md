# dradown — iPhone 4S 免 SHSH 全版本降级/刷写工具

基于 **De Rebus Antiquis v6** (synackuk) 的 iBoot 漏洞 + **checkm8-a5** pwned DFU（Arduino/Pi Pico），
实现 iPhone 4S 在 **iOS 5.0 – 9.3.6 任意版本间自由刷写**，全程无需 SHSH 票据、无需苹果服务器签名。

> 致谢与出处：
> - 漏洞与 exploit：[synackuk/De-Rebus-Antiquis-v6](https://github.com/synackuk/De-Rebus-Antiquis-v6)（另见 [xerub 研究](https://github.com/xerub)）
> - 工具二进制与流程参考：[LukeZGD/Legacy-iOS-Kit](https://github.com/LukeZGD/Legacy-iOS-Kit)（GPL-3.0）
> - checkm8-a5 硬件 pwn：[LukeZGD checkm8-a5](https://github.com/LukeZGD/checkm8-a5)（Arduino+USB Host Shield / Pi Pico）

## 已实测验证的刷机路径

| 路径 | 状态 |
|---|---|
| 9.3.6/9.3.5 → 6.1.3 | ✅（Arduino pwnDFU 工具链） |
| 6.1.3 → 8.4.1（DRA v6） | ✅ dradown.sh |
| 9.3.5 → 7.1.2 直刷（不经 6.1.3） | ✅ dradown.sh |
| 8.4.1 → 7.1.2 直刷（不经 6.1.3） | ✅ dradown.sh |
| 7.1.2 → 8.4.1 直刷 | ✅ dradown.sh |
| 8.4.1 → 5.1.1 | ✅ dradown.sh |

目标版本范围：**iOS 5.0 – 9.3.6 任意官方版本**（DRA exploit 分区对 6.x 目标提供免签引导；7.x/8.x/9.x 走苹果签名链开机）。

## 开始前请准备

- iPhone 4S（iPhone4,1 / n94ap）
- **Arduino + USB Host Shield 或 Raspberry Pi Pico**，用于每次刷机前进入 pwned DFU
- 一条数据线，建议直接连接 Mac，不使用 Hub
- macOS **10.13 (High Sierra) 或更高**（工具最低要求 10.11/10.12；脚本兼容系统自带 bash 3.2）
- **Apple Silicon (M 系列) Mac 需安装 Rosetta 2**：`softwareupdate --install-rosetta --agree-to-license`
  （附带工具链为 x86_64 二进制，Intel Mac 无需此步）
- 重要数据备份：刷机将清除设备全部内容

> iOS 5 目标还可能导致蜂窝/基带不可用。确定要刷 iOS 5 时，向导会再次提示。

## 快速开始（新手向导）

这是 **Terminal 终端向导**，不是图形窗口。双击 **`双击运行.command`** 后，只需按编号操作：

    [1] 开始刷机（推荐）
    [2] 只构建固件
    [3] 查看设备状态
    [4] 工具检查与修复
    [H] 使用帮助 / 已知风险

推荐流程：

1. 选择“开始刷机”，输入要安装的**目标版本**（刷完后设备运行的版本）。
2. 确认已备份数据，并确认清除设备内容。
3. 按提示让设备进入 DFU，用 Arduino/Pico checkm8-a5 完成 pwn。
4. 保持数据线连接，向导会自动完成刷入并提示结果。

**基础版本 iOS 6.1.3 只用于准备刷机引导链，由工具自动处理，不是最终系统。**
首次从网络下载的 `.command` 文件若被 macOS 拦截，请右键点它 → **打开**（只需一次）。

### 高级命令

    ./dradown.sh setup              # 检查/下载工具与资源
    ./dradown.sh info               # 查看设备状态
    ./dradown.sh ipsw 8.4.1         # 只构建目标版本固件
    ./dradown.sh restore <固件路径>  # 刷入明确指定的固件
    ./dradown.sh auto 7.1.2         # 构建缺则自动构建，再进入刷入流程
    ./dradown.sh keys <build号>     # 单独下载指定 build 的固件密钥
    ./dradown.sh clean              # 清理工作缓存

无参数运行 `./dradown.sh`（或双击 `.command`）进入新手向导。

## 工作机制

1. **pwned DFU**：checkm8-a5 破坏 ROM 堆 → 接受补丁版引导链（绕过刷机期签名验证）
2. **custom IPSW**：base(6.1.3) 引导链 + 目标版本 rootfs/内核，powdersn0w 打包，
   ramdisk 注入 DRA exploit 镜像 + partition 钩子脚本
3. **刷入完成时**：钩子脚本缩小 Data 分区、写入 exploit 分区、设置 NVRAM boot-partition=2
4. **每次开机**：iBoot 挂载 exploit 镜像触发 DRA 漏洞 → 补掉签名校验 → 引导目标 iOS
   （7.x/8.x/9.x 目标因组件均为苹果签名，exploit 为惰性保险，正常签名引导）

## 注意事项

- **刷机会抹掉全部数据**
- **刷 iOS 5 会损坏基带**（蜂窝失效；WiFi/系统正常）。恢复方法：刷回 7.1.2/8.4.1/9.3.x
- 后期生产批次的 4S 可能无法刷 iOS 5/6（白屏/"Waiting for NAND" 卡死，硬件限制无法修复）
- 刷 6.x 版本后如不开机：先强制重启一次；仍无法开机时，使用 LIK 的 Clear NVRAM 工具清除引导变量
- 激活：需要 SIM 卡 + 网络；无基带服务时部分功能受限
- NVRAM 中的 exploit 引导变量**不要随意清除**（清除后需重走 DRA 刷机流程）

## 已知限制

- 仅支持 iPhone 4S（DRA v6 另支持 iPad2,1 / iPod touch 4，本脚本未封装）
- 目标版本下限 iOS 5.0（更早版本未经测试）
- 本向导默认只负责刷入系统，不额外安装越狱软件；如需越狱版系统，请使用 Legacy-iOS-Kit

## 免责声明

仅供学习研究老设备的历史与技术。刷机有风险，数据丢失概不负责。
Apple、iPhone 为 Apple Inc. 商标。本工具不包含任何 Apple 版权固件文件，固件由用户自行从苹果官方服务器下载。

## 许可证

GPL-3.0（继承 Legacy-iOS-Kit 与 powdersn0w_pub 的许可）
