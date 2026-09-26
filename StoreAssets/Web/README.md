# Sooogood Video Catch 公网页面模板

这里的静态页面可以部署到产品自己的 HTTPS 域名，作为 App Store Connect 的隐私政策和支持 URL。

发布前必须完成：

1. 将 `<LEGAL_ENTITY>`、`<SUPPORT_EMAIL>`、`<EFFECTIVE_DATE>` 和 `<SUPPORT_URL>` 替换为真实信息。
2. 由产品负责人/法律主体审核隐私政策内容，并确认它与应用内《隐私政策》、App Privacy 问卷和实际数据流一致。
3. 通过 HTTPS 部署 `privacy-policy.html` 和 `support.html`，确认无需登录即可访问，并把最终 URL 写入 `StoreAssets/AppStoreConnectChecklist.md` 的审核备注。
4. 部署后保存页面 URL、发布日期和页面 SHA-256；应用更新时同步检查政策与实际行为。

在上传前运行 `REQUIRE_PUBLIC_WEB=1 ./Scripts/validate_store_submission.sh "dist/Sooogood Video Catch.app"`；该模式会拒绝仍含法律主体、邮箱或生效日期占位符的 HTML。脚本不替代线上可达性检查，发布人仍需用 HTTPS 打开最终隐私政策和支持 URL。

模板不包含第三方分析、跟踪脚本或外部字体，便于在提交前做隐私和供应链审计。
