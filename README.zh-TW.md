# AgentBridge

[英文版](README.md)

![AgentBridge macOS app icon](Assets/AppIcon-1024.png)

AgentBridge 0.6.0 是一個 macOS 14+ Swift 專案，提供共用核心、命令列工具 `agentbridge`，以及原生 SwiftUI App。它透過本機官方 Codex CLI 與 Claude Code CLI 工作；App 與 CLI 的唯讀聊天可依專案與固定提交版本共用記憶，也可由使用者明確選取記憶延續到另一個提交版本。首次使用時，請在 App 選擇工作區資料根目錄；CLI 會使用相同的已保存路徑。App 預設使用英文，也支援繁體中文；可在 App 標題列切換語言。

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

- 唯讀仍是預設。隔離變更工作階段使用固定提交的獨立工作區，寫入前必須先檢視並明確核准工作計畫，provider 編輯只會留在該工作階段工作區。
- 可檢視完整逐檔 diff、還原個別檔案或匯出 patch。接受／套用成果前，必須先成功驗證目前完全相同的 diff。套用會先檢查來源 base commit，再於指定本機 branch 建立未提交工作樹；AgentBridge 不會自動 commit、push 或 merge。
- 只有使用者明確啟動後才會驗證。預設使用 Repository 的 `.codex/ci.sh`；自訂 executable 與獨立 argv 必須先明確核准。驗證在隔離工作區執行，並顯示命令、退出代碼、耗時及遮蔽後輸出。
- 活動時間軸與任務看板顯示排序後的遮蔽事件，以及各工作階段實際啟動的任務記錄。最多可同時執行三個不同工作階段；取消只針對指定工作階段。
- Codex/Claude 可共用相同 Repository/commit 的 AgentBridge App/CLI 記憶。延續到不同提交版本時，必須明確選取 App 保存的回合與／或備註，並由允許記憶共享的綁定帳戶執行。原生 TUI transcript 不會匯入。
- Skills/MCP descriptor 以停用的中繼資料匯入。每專案授權只記錄狹窄權限；匯入或授權都不會啟用 extension 或執行腳本。
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
