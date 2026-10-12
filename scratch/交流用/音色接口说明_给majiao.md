# 音色相关接口说明（给 majiao 做调试界面用）

> 日期：2026-10-09
> 背景：`timbre_map` 已接入 `voice_alloc`，**Program Change 现在真正生效了**
> （此前 `timbre_slot` 取的是 `note[2:0]`，所以换音色完全没反应 —— 上板实测发现）
> 相关文档：`硬件实现.md` §三.五「音色映射」、`技术文档.md` §四（音色映射表）

---

## 一、已经能用的

### 1. Program Change 切音色（新接入）

| 项 | 值 |
|---|---|
| 消息 | `0xCn pp`（n = 通道 0~15，pp = 音色号 0~127） |
| 当前映射 | **恒等**：`timbre_slot = program[2:0]` |
| 生效时机 | **新音起效**（GM2 要求）——只影响之后按下的音符，正在响的保持原音色 |
| 音色槽数 | **8**（`timbre_slot` 3 位） |

**⚠️ 恒等映射的含义**：只取低 3 位，所以

```
program 0 → 槽 0      program 8  → 槽 0
program 1 → 槽 1      program 9  → 槽 1
...                   ...
program 7 → 槽 7      program 127 → 槽 7
```

**调试界面上如果做音色下拉，建议只列 0~7**（8 个）。列 128 个会让用户以为有 128 种音色，
实际每 8 个就循环一次。

### 2. Bank Select（暂不生效，但已被正确缓存）

- `CC0`（Bank MSB）→ 写通道表 `bank_msb`
- `CC32`（Bank LSB）→ 写通道表 `bank_lsb`
- **单独发送不生效**，要等下一个 Program Change 一起用
- **本期 `bank_msb` 未参与映射**（`timbre_map` 的 `map_fn` 里没用它，接口保留）

### 3. 「新音起效」的观察方式

调试界面如果想直观展示这一点：

1. 按住一个音（发 Note On，不发 Note Off）
2. 发 Program Change 换音色
3. **这个音的音色不变**（正确行为）
4. 松开发新的音 → 新音色

## 二、还不能用的（重要！避免调试界面误导）

### ⚠️ 1. 音色参数表尚未实现

`voice_mono` 需要的这些音色参数，**目前全是 `full_system.v` 里的参数常量**：

```
wave_sel / f_coeff / q_coeff / filter_type / adsr_curve
attack_step / decay_step / sustain_level / release_step
```

**后果**：**滤波器截止频率、共振、包络的 ADSR 四段参数，对所有音色槽都是同一个值。**
调试界面即使暴露了这些旋钮，**改了也不会有任何反应**。

换成真表后的接法（接口已经预留，不用改端口）：
把 `full_system` 里的 `DEF_*` 常量换成"按 `timbre_slot` 查音色参数表"即可。

### ⚠️ 2. Pitch Bend 未接

`voice_fetch.note2inc()` 里没有乘 `bend_ratio`（声部表里也没有这个字段）。
**发 `0xEn ll mm` 不会有任何效果。**

### ⚠️ 3. 8 个波表槽的内容取决于 `wave_table.hex`

当前 `wave_table/out/wave_table.hex` 是 8 槽 × 2048 点。
**如果某些槽是空的/重复的，对应的音色听起来就会没区别或静音** ——
这不是 bug，是波表数据的问题，调试时可以用它区分"映射没生效"和"槽里没内容"。

## 三、接口/信号速查（如果调试界面要显示内部状态）

| 信号 | 位宽 | 含义 |
|---|---|---|
| `ev_pc` / `ev_pc_ch` / `ev_pc_prog` | 1 / 4 / 7 | `midi_filter` 输出的 Program Change 事件 |
| 通道表 `rd_program` / `rd_bank_msb` / `rd_bank_lsb` | 7 / 7 / 7 | 每通道的待用音色号与库号 |
| `timbre_map.timbre_slot` / `.vld` | 3 / 1 | 映射结果（`req` 后下一拍有效） |
| 声部表 `V_TIMBRE` 字段 | 3 | 该声部**分配时锁定**的音色槽 |
| `voice_fetch.pf_timbre` | `P*3` | 预取给单声部层的音色槽（每个泳道 3 位） |

## 四、调试界面建议

**可以直接做的**：

- **音色下拉只列 0~7**（8 个槽），标注"当前为恒等映射，8 槽循环"
- **显示每通道的 `program` / `bank_msb` / `bank_lsb` 待用值**
- **显示每声部锁定的 `timbre_slot`**（能直观看到"新音起效"）
- **音色切换测试按钮**：发 `CC0 → CC32 → PC` 顺序序列

**建议先不做（或标注"未实现"）**：

- 滤波器截止/共振旋钮
- ADSR 四段参数控制
- 弯音轮（Pitch Bend）
- 128 个音色的完整列表

---

## 五、一句话总结

**Program Change 已经能切音色了（8 槽、恒等映射、新音起效）；但音色"内部参数"（滤波/包络）还是常量，改了没反应 —— 这是下一步要接的音色参数表。**
