# WinUtil — Fluent Aurora 设计系统

> 由 ui-ux-pro-max(打底)+ frontend-design(风格决策)+ impeccable(质量底线)流水线产出。
> 模式:**Operate**(桌面运维工具,可扫读性、一致性、原生预期 > 表现力)。
> 基准:WinUI 3 / Windows 11 设置应用观感,PowerShell + WPF + ModernWpf 技术栈。

## 品牌立场

WinUtil 的品牌是 Windows 本身。风格来自"把 WinUI 3 的层次做对":
- **不引入第三方字体**(Segoe UI Variable 是 Win11 原生)。
- **不做装饰性渐变/发光**;渐变仅存于主底色的 Mica 融合(功能:材质,非装饰)。
- **强调色统一为 WinUI 深色 hyperlink 系** #4CC2FF,替换混杂的 #63D6FF/#0078D4。

## 色彩 Token(themes.json「Modern」)

### 层次(自下而上,全部冷蓝灰相)
| Token | 值 | 用途 |
|---|---|---|
| MainBackgroundColor | `#C81B202E` | 窗底 L0(α78% 透 Mica) |
| SurfaceBackgroundColor | `#66202838` | 分组面板 L1 |
| AppInstallUnselectedColor | `#A61E2536` | 应用卡片 |
| AppInstallHighlightedColor | `#C2222B40` | 卡片 hover |
| AppInstallSelectedColor | `#D6242F4D` | 卡片选中 |

### 文本(三级)
| Token | 值 | 用途 |
|---|---|---|
| MainForegroundColor | `#EFF3FA` | 主文本(对比 L0 ≈ 12.8:1) |
| ComboBoxForegroundColor | `#D9E1EF` | 次级文本 |
| ButtonForegroundColor | `#DFE6F2` | 控件文本 |

### 强调与状态
| Token | 值 |
|---|---|
| LabelboxForegroundColor / BorderColor / LinkForegroundColor | `#4CC2FF` |
| LinkHoverForegroundColor | `#7FD4FF` |
| ProgressBarForegroundColor | `#4ADE80`(success)/ `#FF6B7A`(error)/ `#FFC15E`(warning) |

### Fluent 控件层(themes.json 每主题顶层键,主题引擎自动注入)
`FluentBtnBg #40283246` / `FluentBtnBgHover #592E3A54` / `FluentBtnBgPressed #33242938` /
`FluentBtnBorder #40384560` / `FluentBtnBorderHover #66465478` / `FluentAccentBrush #4CC2FF` /
`FluentCheckedBg #264CC2FF` / `FluentFieldBg #521C2434` / `FluentFieldBorderFocus #4CC2FF` /
`FluentPopupBg #F01C2434` 等——全部跟随主题相,四个旧主题各有等价映射。

## 字体
- 全局:`Segoe UI Variable Display, Segoe UI Variable, Segoe UI`(窗口 FontFamily + shared.FontFamily/ButtonFontFamily)。
- 等宽仅用于真实数据:日志 `Consolas, Monaco`(保留)。
- 字号阶梯:Hero 40(工作页 spinner)/ 标题 22 / 分区 16 / 正文 13.5 / 控件 13 / 辅助 12 / 弱化 11.5。

## 形状
- 卡片圆角 8、控件圆角 4、chips 药丸 12、弹窗 8(新键 `PopupCornerRadius 8`)。
- 标题栏高 40,品牌块 28×28。

## 动效(单一编排原则)
- 应用卡片 hover:叠加层 Opacity 0→1,180ms,ExitActions 回落 120ms(修复 0ms 切换反模式)。
- 图标按钮 hover:同机制 120ms。**契约:`HoverButtonStyle` 的 `ContentPresenter` 必须是 `HoverLayer` 的兄弟节点,绝不能是其子节点**——`HoverLayer` 静止态 `Opacity="0"`,内容若在其内部,图标/文字在 hover 前完全不可见(第七轮:标题栏主题/字体/设置三按钮消失的根因,放大镜与三键之间 ~150px 空白)。修复后 hover 动画只动 `HoverLayer` 背景,内容层常显。
- 工作页 spinner/进度脉冲:沿用现有(已达标)。
- 不新增散落效果;弹窗/菜单即时出现(系统惯例)。

## 窗口外壳(无套娃契约)
- 窗口从创建起 `WindowStyle="None"` + `ResizeMode="CanResize"`;`WindowChrome` 显式 `GlassFrameThickness="0"`(默认值 `4,27,4,4` 会在顶部画 27px DWM 玻璃条,出现原生 `— □ ×` 与自绘三键套娃)。
- **禁止事后用 `SetWindowLong`/`SetWindowPos(SWP_FRAMECHANGED)` 剥离 `WS_CAPTION`**:WPF 的 `WindowChromeWorker` 会重新接管样式并回退到系统边框。标题栏三键、拖动、缩放全部由 `SystemCommands`/`DragMove`/`ResizeBorderThickness` 提供。
- **禁止 `DwmExtendFrameIntoClientArea(-1)`**(真正的套娃元凶):它把整窗变成 DWM "sheet of glass",DWM 会在顶部画 legacy caption 条(标题文字 + 原生 `— □ ×`),**完全不看 `WS_CAPTION` 位**,日志报 `WS_CAPTION absent: True` 也无效。这是 Win10 Acrylic 时代的技巧,Win11 22H2+ 的 Mica 只需 `DWMWA_SYSTEMBACKDROP_TYPE` + 半透明 WPF 底色,XAML 的 `GlassFrameThickness="0"` 必须保持不被运行时覆盖。
- 启动器 `dist/WinUtil.exe` 为 winexe 自提权:UAC 显示 "WinUtil" 而非 "Windows PowerShell";提权副本以 `CreateNoWindow` 拉起 GUI,全程零终端窗口。
- **双标题栏根因与正解(六轮终审)**:ModernWpf 合并词典(`ThemeResources`/`XamlControlsResources`)给 `Window` 注入隐式 `ControlTemplate`(5043 字符),其 client 区 `Grid.Row=0` 是 `<ui:TitleBarControl Title="{TemplateBinding Window.Title}"/>`,自带 min/max/close 并绑定 `Window.Title`——它画在 **client 区内**,所以 `topNonClient=0` / `WS_CAPTION absent` / `glass=0` 全成立却仍双栏。改 NC 层 / `WindowChrome` / DWM 均无效(前五轮全白费)。正解是 `<Window>` 根内联本地 `<Window.Template>`(仅 `Border`+`AdornerDecorator`+`ContentPresenter`,573 字符):**DP 优先级 本地值 > 隐式样式 setter**,压掉整条隐式模板后只剩自家 XAML 标题栏。验收判据:日志 `chrome diag: templateHasTitleBarControl=False; templateLen=573` + GUI 同进程 `RenderTargetBitmap` 自截图亲验单栏。
- **验收截图铁律**:以 GUI 同进程 `RenderTargetBitmap`(`%TEMP%\winutil-self-visual.png`)为准;外进程屏幕 DC `BitBlt` 会被 z-order/UIPI 遮挡而截到别的窗口(曾三次误读浏览器/微信为证据),仅作辅助、不得作结论依据。

## 导航窗格(主题/语言双契约)
- `mwc:NavigationView` 的 `MenuItems` 是 CLR `IList`,**既不在 `LogicalTreeHelper` 逻辑树、也不在可视树**(离线探针:`logical walk visited=545; NavigationViewItem reached=0`)。因此 `Set-WinUtilLanguage` 的通用树遍历**够不到** Install/Tweaks/Config 等六项,必须显式遍历 `NavView.MenuItems` 并用 `I18nNavOriginals` 快照做双向精确还原(en→zh→en 实测 `restore=True`);MenuItems 的 `Foreground` 也不能靠 `SetResourceReference`(无效,恒黑),须每次按解析后的主题画刷设本地值。
- NavigationView 模板内部窗格由 `PaneRoot #FF252525` / `LayoutRoot·按钮 #FF313131` 绘制,来源 `BaseValueSource=Style` 非表达式;**`ThemeManager=Light` 对它们完全无效**(离线探针:`changed=False`),刷 `Form.Resources` 通用键也不跟随。正解:窗口 `ContentRendered` 后按名字走可视树找到 9/9 个嵌套模板部件,对 `PaneRoot/LayoutRoot/RootGrid` 及各按钮 `SetResourceReference(Background,'MainBackgroundColor')` / `Foreground,'MainForegroundColor'`,一次性绑定后由主题函数刷新键即可自动跟随(浅 `#FFEFEBE4` ↔ 深 `#FF1B2029` 实测通过)。`Template.FindName` 找不到这些部件,必须用 `VisualTreeHelper` 遍历。

## 导航点击契约(第九轮)
- `NavigationView.SelectionChanged` 事件参数是 `ModernWpf.Controls.NavigationViewSelectionChangedEventArgs`(有 `SelectedItem` / `SelectedItemContainer`),程序赋值 `SelectedItem` 时同步触发且 Tag 正常(probe14/15 实证);但 **`item.IsSelected=$true` 不触发事件**,真实鼠标点击走 ModernWpf 模板内部路径,与程序赋值不等价,不能只靠离线赋值外推。
- 两个独立失效口:① `NavSyncing` guard 可能在"程序切到已选中项"时残留,吞掉后续第一次真实点击;② 内部点击路径可能给出无 Tag 的 `SelectedItem`。契约:guard 必须带时间戳并 >2 秒自动过期;Tag 解析需多源(`e.SelectedItem` → `e.SelectedItemContainer` → `sender.SelectedItem`);**每个 `NavigationViewItem` 直接挂 `PreviewMouseLeftButtonUp` 作为点击级兜底**(probe16:`RaiseEvent` 准确拿到 WPFTab2/3/4),点击窗口内忽略随后同步触发的 SelectionChanged,避免单次点击重复切换。
- 点击类修复必须真机模拟点击验证:GUI 进程内用 flag 文件门控 `RaiseEvent(PreviewMouseLeftButtonUpEvent)`,记录 `currentTab` 前后值并二次 `RenderTargetBitmap` 截图;跨进程 UIA 对提权窗口不可用,日志宣称/启动期截图都不能证明联动。

## 中文行高/按钮裁切契约(第十轮)
- Tweaks「个性化偏好」Toggle 行由 `Invoke-WPFUIElements.ps1` 动态生成(DockPanel + Label + `ColorfulToggleSwitchStyle` 40x20 开关),无固定高度;中文 12px 字默认贴行无呼吸空间,相邻行视觉拥挤/裁切。契约:**Toggle DockPanel `MinHeight=30` + `Margin=0,3,0,3`**,CheckBox/Label 均 `VerticalAlignment=Center`;通用隐式 CheckBox `MinHeight=26`。XAML `ColorfulToggleSwitchStyle` 只管开关视觉,不承载行高。
- 底部「应用优化/撤销所选优化」及预设按钮均 `Height={DynamicResource ButtonHeight}`;隐式 Button 样式 `Padding=12,5` + `BorderThickness=1` → 原 `ButtonHeight=25` 只剩 13px 内容区,中文 12px 行高 ~17px 被硬裁。契约:**`shared.ButtonHeight=32`(WinUI 3 标准按钮高度)、`shared.ButtonFontSize=13`**,与 `Padding=12,5` 配合内容区 20px,且不破坏 FontScaling 按 `shared` 基准缩放。
- 验收:离线同路径探针(真实 XAML + 真实生成代码 + `Set-WinUtilLanguage zh-CN`,不 Show、对 panel 自身 Measure/Arrange + RenderTargetBitmap)量得 `row h=30 minHeight=30` / `button h=32 fontSize=13`,中文截图两处红框文字完整;真机 e2e 以 GUI 同进程 `winutil-self-visual-afterclick.png` + `tweaks layout probe` 数值互证。第十轮 e2e 不再发 OS 级点击:第九轮 nav 点击已由 operator 确认修复,误点 Tweaks 内容区会实际触发注册表写操作。

## ComboBox 主题配色契约(第十一轮)
- 根因:XAML Fluent compat 词典里 `ComboBoxBackground/Foreground/ItemForeground/ItemBackgroundPointerOver` 等一整组键是**硬编码深色**(`#313131`/`#E6FFFFFF`/`#383838`),而主题引擎写的是 `ComboBoxBackgroundColor/ForegroundColor`(带 `Color` 后缀,不同 key),DynamicResource 永远命中不到主题值。浅色主题下 ComboBox 本体黑底白字;弹层用随主题变白的 `FluentPopupBg` 却配白色 item 文字 → **展开后白底白字,只剩 hover 黑条可见**。
- 契约:ComboBox / ComboBoxItem 隐式样式**只引用主题引擎每次切换都刷新的 Fluent 语义键**:本体 `FluentFieldBg` + `SystemControlForegroundBaseHighBrush` + `FluentFieldBorder`;hover `FluentFieldBgHover`/`FluentBtnBorderHover`;展开态 `FluentBtnBgPressed` + `FluentFieldBorderFocus`;下拉 Glyph 用 `SystemControlForegroundBaseHighBrush`;item 背景透明、文字 `SystemControlForegroundBaseHighBrush`;item hover `FluentListHover`、选中 `FluentCheckedBg`。5 套主题(Modern/Light/Dark/Cyberpunk/ClassicLight)均显式定义上述键,不依赖 XAML 暗色 fallback。旧的 `ComboBox*` 深色键保留作 compat 死键,不再被样式引用。
- 验收:离线同路径探针(真实 XAML + ClassicLight + zh-CN)量得 `FluentFieldBg=#FFFFFFFF`、`SystemControlForegroundBaseHighBrush=#FF3A3A3A`、`FluentPopupBg=#FFFFFFFF`,ComboBox `bg=白 fg=深灰 border=浅灰`,展开项 `fg=深灰 bg=透明`,渲染图闭合/展开均白底深灰字;真机 e2e 以 `combobox theme probe` 数值 + 同进程 `winutil-self-visual-afterclick.png` 互证。

## Toggle 异步执行契约(第十二轮)
- 根因:Toggle 的 `Add_Checked`/`Add_Unchecked` 在 UI 线程同步跑 `Invoke-WinUtilTweaks`——`Get-Service`/`Set-Service` + 多个 `Set-ItemProperty` + `Invoke-Command` 内联脚本全部阻塞 Dispatcher,开关点击后界面卡顿感来自这里。Tab 切换已被证伪不是瓶颈(预热后 select 33ms + content 0ms);按钮路径(应用优化/撤销所选/预设)本来就走 `Start-WinUtilJob` 后台 runspace。
- 契约:Toggle 两个 handler 在 UI 线程只做两件事——① `Invoke-WPFSelectedCheckboxesUpdate` 更新选中列表(轻量);② `Start-WinUtilJob -Name "Toggle" -QueueIfBusy` 把 tweak 本体提交给 worker runspace(worker 有 `$sync` + 全部函数,`New-WinUtilSessionState` 保证)。`ImportInProgress` 守卫保留。"Toggle" 不在 Start-WinUtilJob 的 working-area 映射里,无 spinner,只有任务栏/日志反馈,这是有意的(单击开关不该闪 busy 视图)。
- **去重签名陷阱**:`-QueueIfBusy` 用参数 JSON 做签名,apply 和 undo 必须把动作并入参数(`UndoAction=$true/$false`),否则同一开关"勾选→取消"时 undo 会因签名相同被当重复任务丢弃。
- 验收:离线探针 probe19(真实 XAML + ClassicLight + zh-CN + stub 掉 Start-WinUtilJob)量得 flip 28ms / unchecked 8ms,Dispatcher 40ms 内恢复 Background 优先级,`jobs submitted: 1`、`undo` 值正确。注意探针目标必须取 `config type='Toggle'` 且带 registry/service 的条目并从 `$sync` 拿实例(tweaks.json 里大量 `WPFTweaks*` 条目 type 为空,走的是无 handler 的普通 checkbox 分支)。
- 若用户实测仍感延迟,下一嫌疑:按钮路径 job 提交后的 busy spinner 观感、主题切换耗时(apply theme ~560ms)。

## 禁止清单(本项目的 impeccable 底线)
- 卡片套卡片;**标题栏套标题栏**;Emoji 代图标;装饰性发光渐变;0ms 状态切换;
- 修改业务逻辑/事件处理器 Name;发布物手改(XAML 改动必须经 Compile.ps1)。
