# Store 截图采集清单

这份清单用于每次 Store profile 发布前重新采集真实应用截图。截图必须来自同一个已签名的 Store release bundle，不能用 Local profile、设计稿或封面图代替。

## 采集前

- 在解锁的 macOS 上运行最终 Store 包，窗口至少为 960×680；建议先在 1440×900 窗口完成验收。
- 使用固定预览夹具或演示数据，不登录真实 Spotify 账号，不显示真实 Client ID、Cookie、文件路径或受版权保护的音频字节。
- Store 版可从“音乐”未连接页点击“查看演示”载入合成元数据；该路径不需要 Spotify 登录，适合截图和初次审核。
- 确认当前构建使用 `Info-Store.plist`、音乐分类和 Store 文案；视频入口应显示“商店版未启用第三方站点音视频下载”。
- 分别检查默认深色模式、Reduce Motion 和 Reduce Transparency；状态必须同时有文字与 SF Symbol。
- Apple 审核规则 2.3.3 要求截图展示应用正在使用的真实界面，不能只放标题艺术、登录页或启动画面；五张截图都必须保留可操作的业务状态。

## 五张主截图

1. **首页**：音乐桥接与本地素材工作台；显示音乐入口、可追溯入口和商店版能力状态。
2. **音乐已载入**：使用固定的歌单/专辑元数据，保留原始方形封面比例，显示 Spotify 来源标识和曲目摘要。
3. **匹配审核**：同时展示已匹配、待确认和未匹配，突出版本冲突与人工确认权。
4. **素材包完成**：展示音频数量、`playlist.m3u8`、`manifest.json` 和 SHA-256 校验状态；不展示真实音频内容。
5. **设置与隐私**：显示 PKCE 连接说明、凭据存储边界、应用内隐私政策入口和断开凭据操作。

## 输出与验收

- 按 App Store Connect 当前 storefront 要求导出截图尺寸；不要把 1440×900 封面当作应用截图上传。
- 截图必须为不含 alpha/transparency 通道的 PNG/JPEG；脚本会拒绝 `hasAlpha: yes` 的文件。
- 文件名固定为：`store-01-home.png`、`store-02-loaded.png`、`store-03-review.png`、`store-04-complete.png`、`store-05-settings.png`；目录说明见 `StoreAssets/Screenshots/README.md`。
- 逐张检查长标题、多语言字符、1000 首曲目的虚拟化列表、空歌单、超长路径和键盘焦点顺序。
- 检查截图没有第三方平台 Logo、绕过 DRM/破解文案、真实账号、Cookie、个人路径或音频字节。
- 采集完成后运行 `Scripts/validate_store_screenshots.sh StoreAssets/Screenshots`；脚本会检查五张 PNG、允许的 Mac 16:10 尺寸并输出 SHA-256。再将构建版本、Store bundle hash 和采集日期写入交付记录。

Store 封面与品牌说明见 [AppStoreListing.md](AppStoreListing.md)；封面本身为无 alpha 的 1440×900 RGB PNG，但仍不得把封面当作 App Store 截图；本地完整版的 `Sooogood-Media-Catch-local-cover-1440x900.png` 不得混入 Store 截图。
