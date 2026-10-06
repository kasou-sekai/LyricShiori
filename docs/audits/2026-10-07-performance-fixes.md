# 保持动画效果的 CPU 优化

日期：2026-10-07。源码基线：`a3845ed`。

## 运行证据

当前 `/Applications/LyricShiori.app` 的二进制 SHA256 与修改前的本地 Release 构建一致：
`991fa65402fe41dbc1279af855995114a79c5ea527823b2002ac098b8cb60d76`。
因此，本次调查针对已经包含上一轮 CPU 修复的运行版本。

两轮进程采样分别覆盖绘制不活跃和竖排动画活跃的时间段。动画活跃时，调用栈包含字形绘制、阴影及 `vImageConvolveWithBias_Planar8`；绘制不活跃时，也能看到周期性 Spotify 查询中的 AppleScript 编译。采样不能直接推导各热点的精确 CPU 百分比。

## 本次改动

- 对比实际的逐字进度和滚动位置。播放时间变化但画面未变化时，不再请求重绘。
- 列的位置不变时，仅使发生变化的字及其阴影周围区域失效。利用 AppKit 保留其余区域的像素，并重画与失效区域相交的邻近字，避免重叠阴影产生残影。
- 失效范围向外取整，并保留足够的字形、阴影、缩放和上浮边距。屏幕外且与绘制区域不相交的单元不再提交绘制。
- 整列滚动、文本、词时间、字体、活动状态、颜色、对齐、尺寸或系统外观变化时，仍执行完整重绘。保留原有 60 Hz 动画、变色方式、缩放/上浮曲线、阴影和滚动速度，没有引入位图缩放替代文字矢量绘制。
- Spotify 状态查询使用可复用的已编译 AppleScript。脚本对象只在专用串行队列内创建和执行，避免轮询与播放通知并发使用同一个对象。查询频率、输出解析及 Automation 错误映射保持原样；采集时间由实际执行区间计算，排队时间不计入区间。

## 验证

- 全部 43 项 XCTest 通过，0 失败。
- 48 组原有完整画面像素对照继续通过，包含 24/42 字号、当前/非当前行、三种对齐和混合文字。
- 新增 762 次连续帧或活动状态切换的 Retina 像素对照：保留上一帧的位图，只清除并刷新失效区域，与原版每次完整重绘的结果逐字节一致。覆盖 60 Hz 时间步、播放跳转、滚动、三种对齐及活动状态变化。
- 真实 layer-backed NSView 测试通过：同一测试列完整重绘绘制 17 个单元，逐字动画局部更新绘制 6 个单元，画面未变化时绘制 0 个单元。这是绘制工作量验证，不能当作整机或应用 CPU 下降百分比。
- 脚本状态在 12 个并发请求及后续请求中保持连续，验证实例复用和串行执行；Automation 拒绝错误映射保持一致。
- 当前 Xcode 下的 Release 构建成功，`codesign --verify --deep --strict` 通过。新二进制 SHA256：`7126b8651aeb514ccc632d504993c39fe33a077116d649fc9ec2dd26a7225770`。

构建产物：`dist/LyricShiori.app`。随后按用户要求，退出旧进程 PID 861，将新构建替换到 `/Applications/LyricShiori.app` 并重启为 PID 24143；安装后二进制 SHA256 与新构建一致，签名完整性验证通过。此次部署验证时尚未发布 GitHub Release。后续本地发布打包使用版本 0.3.1（build 19）。实际 CPU 降幅仍需用同一歌曲和相同设置复测；整列滚动期间仍完整重绘。

复现命令：

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --build-system native --scratch-path .build/sdk27
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-app.sh
codesign --verify --deep --strict dist/LyricShiori.app
```
