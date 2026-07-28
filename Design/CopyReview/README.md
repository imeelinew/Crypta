# Crypta 文案审核台

这是独立于 macOS App 的本地静态审核界面。它不访问保险库、不读取媒体标题，也不发送网络请求。

直接在浏览器中打开 `index.html`。审核状态保存在当前浏览器的 `localStorage` 中；“导出审核结果”会生成 `crypta-copy-review.json`，供后续人工确认后再应用到 App。

未经明确批准，审核台中的拟议文字不得写入 Crypta 的产品界面。
