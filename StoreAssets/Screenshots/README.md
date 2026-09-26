# Store 截图目录

此目录只接受来自最终签名 Store bundle 的真实应用截图，不提交设计稿、封面图或 Local profile 截图。

每个 release 需要以下五个文件：

- `store-01-home.png`
- `store-02-loaded.png`
- `store-03-review.png`
- `store-04-complete.png`
- `store-05-settings.png`

截图必须来自解锁的 macOS，使用 Store profile 的固定演示夹具，不显示真实账号、Client ID、Cookie、个人路径或受版权保护的音频字节。Apple 当前要求 Mac 截图使用 16:10 规格之一，并且不能包含 alpha/transparency 通道。
截图还必须展示应用正在使用的真实界面；不要用标题艺术、登录页或启动画面替代业务状态。

采集完成后运行：

```bash
./Scripts/validate_store_screenshots.sh StoreAssets/Screenshots
```

不要把 `MediaFetch-store-cover-1440x900.png` 或 `MediaFetch-local-cover-1440x900.png` 放进本目录；它们是品牌封面，不是应用截图。
