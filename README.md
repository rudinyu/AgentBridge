# AgentBridge

AgentBridge 是 macOS 14+ 原生 Swift 應用程式，提供 Codex CLI 與 Claude CLI 的聊天介面、命令列工具，以及內嵌 VT100 終端機。App 聊天以「來源儲存庫的固定提交版本」作為記憶範圍；已同意共用記憶的 Codex、Claude 帳戶可讀取同一份成功完成的 App 對話與手動備註。

## 功能

- 以同一份 Swift 核心處理 App 與 `agentbridge` CLI 的登入檢查、工作階段、事件、Git 隔離、取消與預算帳本。
- 每個 App 聊天工作階段使用來源 `HEAD` 的獨立複本；未提交和未追蹤檔案不會複製，不會自動合併或推送。
- Codex 訂閱模式使用 Codex CLI 唯讀 sandbox。Claude 訂閱模式使用唯讀檔案工具；Codex 與 Claude 的 `-p`/`exec` 聊天使用各自 CLI，不透過 shell 字串啟動。
- App 聊天以來源路徑和固定提交識別共用記憶。從 Codex 切換至 Claude（或反向切換）會沿用同一份 App 對話；新帳戶預設不傳送記憶，需明確開啟該帳戶的共用同意。
- 帳戶設定可新增多個獨立 CLI 登入。新帳戶只建立專屬 provider 設定目錄；使用者在內嵌終端自行完成官方 CLI 登入，不會複製或讀取登入憑證。既有本機登入不會被重新登入。
- 「檢查登入與方案」只顯示官方 CLI 回報的資料。若 Codex CLI 未提供訂閱方案名稱，App 會如實顯示登入狀態，不會推測方案。
- 內嵌終端以 SwiftTerm 處理 ANSI/VT100、鍵盤輸入與視窗尺寸；可執行 Codex/Claude 原生互動 CLI、獨立帳戶登入，或用「本機終端機」檢查 PTY。獲帳戶同意的共用記憶會作為背景指示載入，不會變成啟動提示；終端會等待使用者輸入後才開始模型回合。終端 TUI 不會被解析或匯入聊天記憶；重要交接請寫在共用記憶備註。
- Claude API 是獨立的明確付費路徑：每次執行必須輸入 API key、單次預算並確認。Codex API 不支援；Codex 選取時不會顯示 Claude API 選項或金鑰欄位。
- App 與 CLI 共用私有 JSONL 稽核記錄和 UTC 月度 API 預算帳本；輸出在儲存前遮罩常見 token 格式及本次 API key。

## 建置與執行

需求：macOS 14 或更新版本、Swift 6 與 Xcode toolchain。CLI、核心與 App 使用 SwiftPM；App 內嵌終端依賴釘選版本的 [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0)（MIT 授權，見 [`LICENSES/SwiftTerm-LICENSE.txt`](LICENSES/SwiftTerm-LICENSE.txt)）。不需要在開發檢查期間登入 provider，也不會呼叫模型或產生 API 費用。

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh
open build/AgentBridge.app
```

兩個腳本都使用專案 `build/` 內的 SwiftPM 暫存、套件快取和 module cache，依 `Package.resolved` 停用自動解析，並使用 SwiftPM native build backend。SwiftTerm 的 Metal shader 會作為執行期資源打包；這個後端可在 Xcode 尚未安裝獨立 Metal Toolchain 元件時完成建置。若新版 SwiftPM 移除此已標示 deprecated 的 backend 選項，建置需改用可編譯 Metal shader 的工具鏈。CI 建置 CLI/App 並執行測試。封裝腳本建立未簽署的本機 `build/AgentBridge.app`，包含 CLI helper、SwiftTerm 資源與授權檔；這不是 Developer ID 發行或 notarization。

## App 使用方式

1. 選擇 Codex 或 Claude；若使用 Claude，可選官方 CLI 訂閱或 Claude API。
2. 檢查目前帳戶的登入狀態與 CLI 有提供的方案資訊。建立其他帳戶時輸入名稱，並自行選擇是否允許該帳戶共用專案記憶。
3. 選擇 Git 儲存庫，建立唯讀聊天工作階段。AgentBridge 固定來源 `HEAD` 並建立自己的隔離複本。
4. 在聊天輸入提示。成功完成的 App 聊天回合會加入此專案與提交版本的記憶；切換 provider 或獲同意的帳戶時，App 會把記憶上下文加到下一次提示。
5. 需要帳戶登入或原生 TUI 時，在左側建立互動工作階段或新增獨立帳戶，然後在 App 內嵌終端完成操作。

內嵌終端的 provider 原生 TUI 會自己管理互動內容，AgentBridge 不保存其逐字稿。若要讓另一個助理接續終端工作，請把重點寫入「記憶備註與終端機交接」。刪除或清除共用記憶不會刪除 provider 自己的工作階段資料。

## 命令列

建置後的命令列工具位於 `build/swiftpm/debug/agentbridge`：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" profiles list
"$CLI" session create --provider codex --repo "$HOME/Projects/example"
"$CLI" sessions
printf '%s' 'Summarize the repository architecture.' | "$CLI" run SESSION-ID
"$CLI" events SESSION-ID
```

`run` 從標準輸入讀取最多 256 KiB UTF-8 提示，不把提示放在程序參數或稽核事件。遮罩後的模型回覆會保存以供聊天記錄查看；如果回覆重述提示中的敏感內容，該內容也可能出現在回覆記錄。

建立獨立帳戶並在內嵌終端登入：

```sh
"$CLI" profiles create --provider claude --name work
"$CLI" profiles list claude
# 在 App 內按「在 App 內登入此帳戶」，或在可互動的終端執行：
"$CLI" profile-login PROFILE-ID
```

登入命令不使用 `claude auth login --console`，也不會建立 API key。Codex 和 Claude 的 profile 各自使用 provider CLI 支援的獨立設定資料夾；現有本機帳戶維持不變。

Codex 與 Claude 都能建立原生互動工作階段，並在終端機或 App 內執行：

```sh
"$CLI" session create --provider codex --repo "$HOME/Projects/example" --interactive
"$CLI" interactive SESSION-ID --profile PROFILE-ID
```

Codex 與 Claude 的互動模式都使用隔離複本。Claude 的檔案或命令編輯依 Claude 原生 Manual 權限模式執行；Codex 互動模式維持唯讀 sandbox，且不會要求提升權限。「本機終端機」shell 仍以目前使用者權限執行，可能存取複本以外的檔案或網路；Git 複本不是作業系統層級的 sandbox。

查看、編輯或清除 App 共用記憶：

```sh
"$CLI" memory show SESSION-ID
cat handoff-notes.txt | "$CLI" memory notes SESSION-ID
"$CLI" memory clear SESSION-ID --confirm
```

## Claude API 預算

API 路徑只適用於 Claude。App 每次要求使用者輸入金鑰、單次預算並明確確認；CLI 則必須明確指定 `ANTHROPIC_API_KEY` 環境變數來源、美元預算與付費確認：

```sh
"$CLI" settings usage api
printf '%s' 'Summarize this repository.' | \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" "$CLI" run SESSION-ID \
  --api-budget 1.00 --confirm-api-spend --api-key-env ANTHROPIC_API_KEY
```

預算帳本以 UTC 月曆月、US$140 本機上限計算，App 與 CLI 共用。每次執行預留單次預算兩倍；未取得供應商實際費用時不退回預留額。此上限只代表 AgentBridge 本機帳本，非 Anthropic 帳單或 Team credit 餘額。Claude CLI 的 `--max-budget-usd` 是估算限制，不能保證實際費用一定不超過輸入值；請在 Anthropic Console 為專用 workspace/key 另設 provider-side spending limit。錯誤、取消及未回報費用不會假裝成成功或退回預算。API 工作階段不可續用訂閱工作階段，須建立新的 API 工作階段。

開發 CI 和 App 打包不讀取 API key、不執行登入、不呼叫模型。互動模式僅支援官方 CLI 登入，不接受 API key。

## 資料、安全與限制

- AgentBridge 私有資料位於 `~/Library/Application Support/AgentBridge`；session、事件、帳戶標籤、共享記憶與帳本在 App/CLI 間共用，使用 owner-only 權限與檔案鎖。
- 預設工作區保存來源 `HEAD` 的 detached clone，不包含未提交/未追蹤變更；clone 不保留 `origin`，並停用 Git hooks、fsmonitor 與 LFS smudge。
- 訂閱模式僅傳遞必要 provider 認證設定；自訂帳戶不複製既有憑證。CLI 帳戶和實際方案仍由官方工具管理。
- AgentBridge 不保存原始 provider stderr 或提示；App 共用記憶只存明確傳入的提示、成功回覆及使用者備註。已遮罩輸出仍可能包含未識別的敏感格式。
- provider CLI 本身仍依自己的政策保存登入、工作階段或快取資料。App 共用記憶不會把 Codex/Claude 的原生 session ID 假裝成可互通，也不會讀取原生 TUI transcript。
- 本機月度預算帳本無法監控 App 外或其他工具的 provider 使用量；供應商實際費用與帳單為準。

## 專案結構

```text
AgentBridge/
├── Package.swift / Package.resolved
├── ARCHITECTURE.md
├── Sources/
│   ├── AgentBridgeCore/        # 執行、帳戶、記憶、Git、記錄、預算與遮罩
│   ├── AgentBridgeCLI/         # agentbridge 命令列與 PTY helper
│   └── AgentBridgeApp/         # SwiftUI App 與 SwiftTerm 內嵌終端
├── Tests/AgentBridgeCoreTests/
├── LICENSES/SwiftTerm-LICENSE.txt
├── scripts/package-app.sh
└── .codex/ci.sh
```

## 官方文件

- Codex non-interactive mode: <https://developers.openai.com/codex/noninteractive>
- Codex authentication: <https://developers.openai.com/codex/auth>
- Codex configuration reference: <https://developers.openai.com/codex/config-reference>
- Claude headless mode: <https://code.claude.com/docs/en/headless>
- Claude CLI reference: <https://code.claude.com/docs/en/cli-reference>
- Claude authentication: <https://code.claude.com/docs/en/authentication>
- SwiftTerm 1.20.0: <https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0>
