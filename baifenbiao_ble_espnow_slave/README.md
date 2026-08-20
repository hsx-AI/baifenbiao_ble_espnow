# 五表 BLE 采集从站

一个合宙 ESP32-C3 最多配置 5 块百分表。连接依据是严格的 MAC 白名单；每条白名单同时保存全局 `meter_id`，因此 20 块表同时开机也只有所属从站会连接它。

## 串口命令

```text
map show
map set <槽位1-5> <全局表号1-20> <MAC>
map clear <槽位1-5>
node set <节点号1-255>
discover on
discover off
keepalive show
keepalive set <mode 0-3> <秒数30-600>
keepalive send
reboot
```

示例：

```text
node set 1
map set 1 1 C4:AD:BF:FE:96:AF
map set 2 2 AA:BB:CC:DD:EE:02
map show
reboot
```

映射保存在 NVS。普通重新烧录不会清除映射；只有擦除 Flash/NVS 后才会恢复 `include/config.h` 中的首次启动默认值。

## 百分表防关机实验

从站会取得 NUS RX 写入特征 `6E400002...`，可按节点定时向已连接的5块表写入测试字节。策略同样保存在 NVS：

| mode | 写入字节 | 用途 |
|---:|---|---|
| 0 | 不写入 | 对照组 |
| 1 | `0D 0A` | 空行/CRLF |
| 2 | `3F 0D 0A` | `?` 查询行 |
| 3 | `00` | NUL 字节 |

推荐4节点分别设置为0、1、2、3，间隔90秒。定时写入不会在刚连接时立即触发，而是等待一个完整间隔。串口输出示例：

```text
[KEEPALIVE] meter=6 mode=1 payload=0D 0A write=ok response=yes trigger=timer
```

`write=ok` 只代表 BLE GATT 写入成功，不代表百分表一定将该字节识别为保活。实验期间应记录每组实际关机时间，并观察是否出现清零、单位切换等副作用。执行 `keepalive set 0 90` 可立即停止定时写入。

## 推荐：使用 JSON 批量配置

编辑 `tools/maps/slave1.json` 至 `slave4.json`，填入 20 块表的 MAC。先检查是否有重复：

```powershell
python tools\validate_maps.py
```

然后逐台连接从站并写入配置：

```powershell
python tools\configure_slave.py --port COM34 --config tools\maps\slave1.json
```

查找百分表 MAC：

```powershell
python tools\configure_slave.py --port COM34 --discover 20
```

本项目实测百分表广播名称为数字序列号，且扫描输出带 `NUS` 标记。

## 连接数量

固件使用 NimBLE-Arduino，编译配置为 5 个并发连接。连接间隔设为 50–100 ms，以给五路 BLE 和 ESP-NOW 共存留出射频调度空间。部署时应逐节点做五表同时运动、持续至少数小时的压力测试；如果现场 2.4 GHz 干扰很强，5 节点×4表会比4节点×5表留有更大裕量。
