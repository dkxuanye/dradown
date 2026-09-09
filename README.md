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
| 7.1.2 → 8.4.1 直刷 | ✅ dradown.sh |
| 8.4.1 → 5.1.1 | ✅ dradown.sh |

目标版本范围：**iOS 5.0 – 9.3.6 任意官方版本**（DRA exploit 分区对 6.x 目标提供免签引导；7.x/8.x/9.x 走苹果签名链开机）。

## 硬件/环境要求

- iPhone 4S（iPhone4,1, n94ap），需通过 iOS 6.1.3 兼容测试（能刷入并开机 6.1.3）
- **checkm8-a5 pwn 硬件**：Arduino + USB Host Shield 或 Raspberry Pi Pico（见 LIK wiki: checkm8-a5）——每次刷机前 pwn 一次
- macOS x86_64（工具二进制来自 Legacy-iOS-Kit macOS 构建）
- 数据线（建议直插 Mac，不用 Hub）

## 快速开始

    ./dradown.sh setup              # 下载全部工具与资源
    ./dradown.sh ipsw 8.4.1         # 构建目标固件（自动下载固件+密钥+打包+修复）
    # 设备进 DFU → Arduino pwn →
    ./dradown.sh restore            # 自动检测新鲜 pwn 并刷入（等 10 分钟窗口）

或一键（构建缺则自动 + 全自动确认）：

    ./dradown.sh auto 7.1.2         # 构建缺则自动 + 等待你的 pwn + 自动刷入

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
- 刷 6.1.6/6.1.6 以下版本后如不开机：Clear NVRAM（见 LIK wiki / 本工具后续版本）
- 激活：需要 SIM 卡 + 网络；无基带服务时部分功能受限
- NVRAM 中的 exploit 引导变量**不要随意清除**（清除后需重走 DRA 刷机流程）

## 已知限制

- 仅支持 iPhone 4S（DRA v6 另支持 iPad2,1 / iPod touch 4，本脚本未封装）
- 目标版本下限 iOS 5.0（更早版本未经测试）
- JB 越狱组件路径（8.x/9.x 的 aquila/freeze）未默认启用——如需越狱版固件请使用 Legacy-iOS-Kit

## 免责声明

仅供学习研究老设备的历史与技术。刷机有风险，数据丢失概不负责。
Apple、iPhone 为 Apple Inc. 商标。本工具不包含任何 Apple 版权固件文件，固件由用户自行从苹果官方服务器下载。

## 许可证

GPL-3.0（继承 Legacy-iOS-Kit 与 powdersn0w_pub 的许可）
