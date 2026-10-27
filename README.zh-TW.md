# AgentBridge

[英文版](README.md)

![AgentBridge macOS app icon](Assets/AppIcon-1024.png)

AgentBridge 0.3.0 是一個 macOS 14+ Swift 專案，提供共用核心、命令列工具 `agentbridge`，以及原生 SwiftUI App。它透過本機官方 Codex CLI 與 Claude Code CLI 工作；App 與 CLI 的唯讀聊天可依專案與固定提交版本共用記憶。

AgentBridge 預設沿用官方 CLI 的訂閱登入。Codex 固定使用訂閱登入；Claude API 是可選的付費模式，必須逐次輸入 API key、單次預算並明確確認。每月 US$140 是 AgentBridge 本機帳本上限，不是 Anthropic 帳單的硬性限制。

## 文件

- [架構與設計](ARCHITECTURE.zh-TW.md)
- [使用指南](docs/HOW_TO_USE.zh-TW.md)
- [產品差距研究](docs/PRODUCT_GAP_STUDY.zh-TW.md)
- [功能計畫](docs/FEATURE_PLAN.zh-TW.md)

## 快速開始

需求：macOS 14 或更新版本、Swift 6 與 Xcode toolchain。請先安裝並登入想使用的官方 provider CLI；登入由各 CLI 管理。SwiftTerm 1.20.0 以固定版本作為 App 內嵌終端的依賴，授權見 [LICENSES/SwiftTerm-LICENSE.txt](LICENSES/SwiftTerm-LICENSE.txt)。

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh
open build/AgentBridge.app
```

`.codex/ci.sh` 建置 CLI/App 並執行核心測試；`scripts/package-app.sh` 將設計好的 icon 打入未簽署的本機 `build/AgentBridge.app`。發行時需使用 Developer ID 簽署、送交 Apple 公證、staple ticket 並驗證；步驟見[使用指南](docs/HOW_TO_USE.zh-TW.md)。建置與檢查不需要登入 provider、不會呼叫模型，也不會產生 Claude API 費用。CLI 位於 `build/swiftpm/debug/agentbridge`。

### 預設安全邊界

- App 聊天建立來源 Git `HEAD` 的獨立工作區；未提交及未追蹤檔案不會複製，也不會自動合併或推送。
- 非互動聊天以唯讀權限執行。互動 provider 終端保留各 CLI 的操作流程；Claude 核准的指令可能存取工作區外資料或網路。
- Codex/Claude 可共用 AgentBridge 的 App/CLI 唯讀聊天記憶，但不會匯入原生 TUI transcript。新帳戶預設開啟記憶共享，仍可逐帳戶關閉。
- 本機終端使用目前 macOS 使用者權限；Git 隔離工作區不是作業系統層級的 sandbox。

## 查看官方訂閱用量

在訂閱活動面板開啟目前所選 Codex 或 Claude 帳戶的官方 CLI 用量終端。請等待該帳戶的 CLI 就緒並完成登入，再按終端中的固定「送出 /usage」按鈕。按鈕只會送出 /usage 和 Enter，不接受自行輸入的命令。Claude API 模式不提供此操作。

AgentBridge 會在全新且私有的空白暫存資料夾中啟動官方互動 TUI，套用唯讀限制，並使用所選帳戶既有或專屬的 CLI 設定資料夾。按下固定的 /usage 按鈕後，App 只會將有限長度的可見畫面文字暫存在記憶體，以 provider 專用的盡力辨識器填入統一資料卡；辨識到用量值或 15 秒後即停止取樣，再按固定按鈕可重新啟動。未知欄位會顯示「Not provided / 未提供」。原始 TUI 仍會留在畫面供核對。此辨識依賴 provider 畫面文字，並非穩定 API；AgentBridge 不會保存或記錄擷取文字，也不會傳給模型。CLI 結束後會刪除暫存資料夾；Claude 此用量專用啟動也會停用 prompt 歷史與 session transcript 寫入。

## 官方 CLI 參考

- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive) · [authentication](https://developers.openai.com/codex/auth) · [configuration](https://developers.openai.com/codex/config-reference)
- [Codex CLI](https://developers.openai.com/codex/cli)
- [Claude Code headless mode](https://code.claude.com/docs/en/headless) · [CLI reference](https://code.claude.com/docs/en/cli-reference) · [authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code slash commands](https://code.claude.com/docs/en/commands)
- [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)
