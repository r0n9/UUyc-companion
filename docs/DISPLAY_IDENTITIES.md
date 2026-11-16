# 虚拟屏身份与 ColorSync 维护

## 身份与回收规则

主应用使用两组固定的 `vendorID/productID/serialNum`：`0x5555/0x0001/0x55550001` 与 `0x5555/0x0001/0x55550002`。
首次使用前写入 `~/Library/Application Support/UUDisplay/display-identities.json`；重启或文件丢失时仍使用同一组序列号。文件损坏、版本不兼容或保存失败会停止建屏并记录原因。

虚拟屏统一显示为“UUyc companion”，尺寸与 HiDPI 仍按设备配置设置。正常重连优先复用第一个空闲槽位；更换尺寸时允许新旧两块屏短暂重叠。执行器先等新屏上线、设为主屏并安全回收旧屏，再处理最新的配置变化。创建、应用模式或设主屏失败时保留健康的旧屏，新对象经过存活期保护后回收。

释放对象后，槽位继续保留，直到在线列表确认对应显示器已离线。其他进程占用的槽位不能借用；槽位不足时等待，显示器查询失败时也停止建屏。手动恢复物理屏优先处理，不会被槽位等待挡住。

该机制约束主应用生成的序列号数量；ColorSync/WindowServer 的持久记录行为仍需在目标 macOS 上实测。历史随机身份不会因为升级自动消失。

## 回归测试与实际验证

运行 `scripts/test-connection.sh`。除连接检测外，还覆盖 1000 轮身份分配、30 轮显示执行器重连/快速改尺寸、构造/模式/配置事务失败、未上线超时、延迟撤销、外部槽位占用及手动恢复。私有 API 使用模拟模块，测试不会改变真实屏幕。缓存维护使用临时文件测试备份、选择规则、冲突拒绝与回退。

轻量实机验证需要先完全退出主应用与探测工具，保存工作，再显式运行：

```sh
zsh scripts/test-display-identities.sh --real-displays
```

该脚本保持物理屏在线，不执行主屏或布局配置事务，创建两个槽位并各复用一次，对比不同尺寸/HiDPI 下的 UUID，检查安全撤销与原主屏。2026-11-16 在本机 macOS 27、Swift 6.4 上四次创建验证通过；这项检查与完整应用的反复切屏压测范围不同。

在目标机器验证时先保存工作，关闭“远程时只保留虚拟屏”以保留物理屏，再进行少量实际连接、重连和尺寸变更。每次上线执行：

```sh
swift scripts/display-snapshot.swift
```

确认主应用在线序列号只来自上述两组，同一槽位的 UUID 可复用，断开完成后虚拟屏离线。分别在测试前、测试后和再次重连后执行缓存审计，核对 UUID 记录数量没有持续增长，并检查颜色服务响应：

```sh
sudo python3 scripts/colorsync-maintenance.py audit
python3 scripts/colorsync-maintenance.py healthcheck --timeout 10
```

`healthcheck` 在独立子进程查询 ColorSync，超时会终止子进程并报告失败，避免把同步等待放进应用主线程。它包括 Swift 脚本启动时间，不能单独用于精确性能基准。

## 旧版本记录迁移

维护工具只识别标准缓存 `/Library/Caches/ColorSync/com.apple.colorsync.devices` 中的显示器记录。所有本地化名称必须属于“UUyc companion”或旧名称“UUDisplay”，ICC 路径必须对应同名、同 UUID 的显示器文件，记录必须离线，且所有引用文件均缺失。现存文件、权限不明、未知结构、自定义路径和其他显示器记录均保留。

先断开远程并完全退出应用、探测工具，再生成预览。输出目录必须尚不存在：

```sh
sudo python3 scripts/colorsync-maintenance.py prepare --output /private/tmp/uuyc-colorsync-plan
```

目录包含原始 `backup.plist`、候选 `cleaned.plist` 和列明删除项及校验和的 `manifest.json`。此命令只生成文件，系统缓存保持原样。

核对预览后，停止当前用户的颜色代理并明确应用：

```sh
killall colorsync.useragent
sudo python3 scripts/colorsync-maintenance.py apply --plan /private/tmp/uuyc-colorsync-plan
```

工具再次检查在线显示器、代理进程、ICC 文件和原缓存；缓存变化或代理已重启会拒绝写入。采用原所有者和权限原子替换，只删除预览列出的记录，不更改 WindowServer 配置，也不自动重启服务或应用。应用后重新打开活动监视器，并运行审计和 `healthcheck`。

需要回退时，同样先退出应用并停止颜色代理：

```sh
sudo python3 scripts/colorsync-maintenance.py rollback --plan /private/tmp/uuyc-colorsync-plan
```

仅当当前缓存与清理后文件仍完全一致时才恢复原始备份；出现新系统记录会拒绝覆盖。备份须保留到验证结束。维护涉及系统私有缓存格式；目标系统结构变化时应重新分析，不能扩大删除范围绕过检查。
