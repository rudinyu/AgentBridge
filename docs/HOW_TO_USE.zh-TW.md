# AgentBridge 使用指南

[英文版](HOW_TO_USE.md)

這份指南說明如何安裝、登入、開始對話、切換 provider 與帳戶、使用共用記憶，以及在需要時啟用 Claude API。App 與 CLI 共用本機設定、工作階段、記憶和 API 預算帳本。

> App 目前的控制項以繁體中文顯示；本指南直接使用畫面上的繁體中文按鈕與欄位名稱。

### 1. 準備環境與啟動 App

需要 macOS 14 或更新版本、Swift 6 與 Xcode toolchain。先安裝你要使用的官方 CLI，並在該 CLI 完成訂閱登入：

- Codex CLI：[官方安裝與登入文件](https://developers.openai.com/codex/cli)
- Claude Code：[官方安裝文件](https://code.claude.com/docs/en/quickstart)

在 AgentBridge Repository 執行：

`Assets/AppIcon-1024.png` 是 App icon 原始圖；封裝時會產生 macOS `.icns` 並加入 App。

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh
open build/AgentBridge.app
```

CI 腳本會建置 CLI、App 並執行核心測試；封裝腳本會建立未簽署的本機 App。上述步驟不登入 provider、不呼叫模型，也不產生 Claude API 費用。若已建置，只要重新開啟 `build/AgentBridge.app` 即可。若要交付給其他 Mac，請完成本文最後的 Developer ID 簽署與 Apple 公證流程。

### 2. 檢查 CLI 登入與方案

App 開啟後，從左側的「助理」選 Codex 或 Claude，然後按右上方「檢查登入與方案」。App 只顯示官方 CLI 確認的帳戶與方案欄位；如果 Codex CLI 沒有回報方案名稱，AgentBridge 不會猜測。

CLI 也可檢查環境與登入狀態：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" profiles list
```

如果找不到 CLI，可在 App 左側「CLI 執行檔」填入執行檔路徑，或使用 `agentbridge settings binary codex|claude /absolute/path/to/cli` 設定。官方 CLI 管理其登入資料；AgentBridge 不複製現有憑證。

### 3. 開始一段唯讀 App 對話

1. 在左側「助理」選 Codex 或 Claude。Codex 只提供官方 CLI 訂閱登入。
2. 在「官方 CLI 帳戶」確認目前帳戶。若需要其他帳戶，先依下節新增並登入。
3. 在「專案」輸入 Git Repository 路徑，或按「選擇儲存庫…」。
4. 保持「互動終端工作階段」關閉，按「建立同一專案的新工作階段」。這會建立唯讀聊天工作階段。
5. 在右側輸入提示並按「傳送」。成功完成的回合會保存到此 Repository 與固定提交版本的共用記憶。

每個工作階段固定建立時的來源 `HEAD`，並在 AgentBridge 自己的隔離複本中執行。未提交和未追蹤的檔案不會複製。來源提交後續改變時，既有工作階段仍使用原來的固定版本；建立新工作階段會以新的來源提交建立新的記憶範圍。AgentBridge 不會自動合併或推送工作區變更。

### 4. 新增帳戶、登入與切換方案

新增帳戶不會重新登入或改動目前本機帳戶：

1. 在「官方 CLI 帳戶」填入名稱。「建立後允許共用專案記憶」預設已勾選；若這個帳戶不應讀取或保存專案記憶，請先取消勾選，再按「新增並切換帳戶」。
2. 在新增帳戶下按「在 App 內登入此帳戶」，並在內嵌終端完成 provider 官方登入流程。
3. 登入完成後按「檢查登入與方案」。App 顯示官方 CLI 回報的帳戶和方案資訊。
4. 新工作階段會綁定建立時選定的帳戶。要換另一帳戶，先在帳戶選單選擇它，再建立或切換到綁定該帳戶的工作階段。

App 內建的「目前本機登入」帳戶直接使用現有官方 CLI 登入。新建的獨立帳戶各自使用不同的 CLI 設定資料夾，必須分別完成登入。改選帳戶不會讓既有工作階段改用另一個帳戶；原工作階段需切回原帳戶才能繼續。

CLI 帳戶操作：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" profiles create --provider claude --name work
"$CLI" profiles list claude
# 使用輸出中的 PROFILE_ID，在互動終端完成登入：
"$CLI" profile-login PROFILE_ID
"$CLI" profiles select --provider claude PROFILE_ID
```

新帳戶預設允許使用共享記憶。若要停止某帳戶共享，可在 App 取消勾選「允許此帳戶載入與保存專案共用記憶」，或執行 `agentbridge profiles memory PROFILE_ID off`。關閉會停止該帳戶自動載入或保存回合，但不會刪除既有記憶；既有帳戶的設定不會被更新改動。

### 5. 切換 Codex 與 Claude，共用記憶

共用記憶以「來源 Repository 路徑 + 固定提交」作為範圍。App 與 CLI 的唯讀聊天成功完成後，會在帳戶允許共享時加入記憶。從 Codex 切到 Claude，或從 Claude 切到 Codex，當兩個工作階段使用相同來源路徑和提交版本時，可共用同一份 App/CLI 對話和手動備註。新帳戶預設共享；可在帳戶設定中逐一關閉。

「專案共用記憶」區塊可查看聊天回合，並在「記憶備註與終端機交接」中儲存要交給另一位助理的內容。成功完成的 App 或 CLI 唯讀聊天會自動加入記憶；原生 Codex/Claude TUI 的輸入和輸出不會被擷取。請自行把需要交接的重點記入備註。清除記憶會刪除該來源與固定提交的聊天記憶及備註，不會刪除 provider 自己的 session 資料。

### 6. 使用原生互動終端

要直接使用 Codex 或 Claude 的原生互動介面：

1. 確認目前選的是訂閱登入；Claude API 模式不支援互動終端。
2. 勾選「互動終端工作階段」並建立工作階段。
3. 按「開啟內嵌終端機」，在 provider TUI 中自行輸入並控制下一步。

這與 App 右側的唯讀聊天不同。Codex 互動工作階段維持唯讀 sandbox；Claude 使用原生 Manual 權限流程，使用者核准的操作可能修改隔離複本、讀取工作區外的檔案或連接網路。終端逐字稿只留在目前畫面，不寫入 AgentBridge 記憶或稽核記錄。

右上方「本機終端機」會在 Repository 複本位置開啟 shell，但仍以目前 macOS 使用者權限執行；它可能存取複本外的檔案或網路。Git 隔離複本不是作業系統層級的 sandbox。

### 7. 用量儀表板與本機執行上限

用量區依目前選取的 provider 與帳戶分開顯示。訂閱模式會以圖表呈現 AgentBridge 記錄的本機管理執行嘗試，範圍為滾動近 5 小時、24 小時及 7 天。這些是本機估計，不是 provider 額度或帳戶總用量；provider 限制和共享方式會因方案而異，其他 provider App 的活動也不會計入。互動 TUI 內的回合不會被記錄。

AgentBridge 無法讀取官方訂閱額度百分比。要手動查看，請在 provider 官方互動 CLI 開啟後輸入 `/usage`：Codex CLI 會顯示每日、每週及累積活動；Claude CLI 會顯示本次工作階段費用、方案用量限制及活動統計。AgentBridge 不會解析終端輸出或存取 provider 私有端點。

可選擇設定訂閱模式的本機執行次數上限，範圍包括近 5 小時、24 小時、7 天及目前 AgentBridge 工作階段。Claude API 有選用的 UTC 每日及工作階段 USD 上限、24 小時及工作階段執行次數上限，也可停用所選帳戶未來的 API 執行。單次 USD 預算、每日/工作階段 USD 上限、月度 USD 帳本和執行次數上限是不同控制。每次 API 執行會在啟動前以單次預算的兩倍預留金額。App 和 CLI 同一時間最多允許一筆尚未確認費用的付費呼叫。

如果已完成或中斷的 API 呼叫沒有可確認的費用，該帳戶會維持封鎖。請先將特定 Claude API 工作階段與 Anthropic 帳單核對，再於 App 手動結算區選擇該工作階段綁定的帳戶與工作階段、輸入帳單實際 USD 費用並確認。CLI 也可使用 `agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm`。結算不會連線呼叫 provider，會追加不含機密的稽核事件。結算前會先取得該工作階段的執行鎖：作用中的程序會被拒絕；若仍顯示「執行中」但其實是中斷後殘留的狀態，會標記為失敗後才結算。如果其中一本本機帳本先完成，使用相同金額重試即可。除非帳單明確顯示零費用，否則不要輸入 0。與先前結算金額衝突時會拒絕更新。無法歸屬到帳戶的舊預留會保持封鎖，不會被分配到錯誤帳戶。

達到上限時，AgentBridge 會在呼叫 provider 模型前阻擋新的管理執行。達到 50%、75%、90%、100% 時，App 會顯示提醒；100% 代表已達設定的本機上限，並會阻擋新的管理執行。提醒會依帳戶與期間保存去重狀態；本機上限與通知設定變更，以及門檻達成紀錄，會保存在有筆數上限的本機稽核歷程。macOS 通知為選用功能，且需要允許通知權限。本機滾動期間不是 provider 的額度期間。

### 8. 選用 Claude API 與預算控制

預設使用訂閱登入，不需 API key。只有選擇 Claude 後才會顯示 Claude API 模式。每次 API 執行都必須輸入 API key、單次 USD 預算並勾選付費確認；取消執行無法撤回已產生的 Anthropic 費用。Codex 不提供 API 模式。App 不保存 API key；切換 provider 或模式會清除本次授權欄位。API 模式只適用唯讀聊天，不適用原生互動終端。

內建 Claude 帳戶沿用既有每 UTC 月 US$140 的本機帳本，App 與 CLI 共用。舊帳本沒有帳戶欄位，因此無法可靠拆分歷史支出屬於哪個帳戶。每個新 Claude 帳戶都有獨立帳本，且必須先在 App 設定本機月度 USD 上限，才會允許 API 執行；帳本建立後月上限固定，避免變更上限造成既有支出被重算。每次呼叫先保留所輸入單次預算的兩倍，以處理並行呼叫和未知費用；預留金額不足時呼叫會被拒絕。Claude CLI 的 `--max-budget-usd` 依成本估算，不保證實際費用不超過輸入值。本機帳本不計算 AgentBridge 以外的 Anthropic 用量，也不能取代 Anthropic 帳單或 provider-side spending limit。

CLI 使用 API 時，先以安全方式讓環境變數 `ANTHROPIC_API_KEY` 可供目前 CLI 程序使用；不要把 key 寫在命令列參數、文件或版本控制檔案中。接著明確切換模式、建立 Claude 工作階段，並在每次呼叫中附上預算及確認旗標：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" settings usage api
"$CLI" session create --provider claude --repo "$HOME/Projects/example"
# 把上一個命令輸出的 session ID 設定在這裡：
SESSION_ID="paste-session-id-here"
printf '%s' 'Summarize the repository architecture.' | \
  "$CLI" run "$SESSION_ID" --api-budget 1.00 \
  --confirm-api-spend --api-key-env ANTHROPIC_API_KEY
"$CLI" budget
```

回到訂閱模式時執行 `"$CLI" settings usage subscription`，再建立或切回訂閱工作階段。API 模式不能續用已有 provider session 的訂閱工作階段。帳本只計算 AgentBridge API 呼叫；供應商實際費用及 Anthropic Console 的限制為準。

### 9. CLI 常用操作

建置後的 CLI 位於 `build/swiftpm/debug/agentbridge`。提示由標準輸入提供，不會放在程序參數中：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" session create --provider codex --repo "$HOME/Projects/example"
"$CLI" sessions
# 將新工作階段輸出中的 ID 貼到此處：
SESSION_ID="paste-session-id-here"
printf '%s' 'Summarize the repository architecture.' | "$CLI" run "$SESSION_ID"
"$CLI" events "$SESSION_ID"
"$CLI" memory show "$SESSION_ID"
printf '%s' 'Key decisions and next steps.' | "$CLI" memory notes "$SESSION_ID"
```

CLI 亦支援 `agentbridge cancel SESSION_ID` 取消執行、`agentbridge budget` 檢視 API 帳本，以及 `agentbridge help` 查看完整命令。清除共用記憶需加上明確確認：`agentbridge memory clear SESSION_ID --confirm`。

### 10. 常見狀況

- **找不到 provider CLI：** 在 App 的「CLI 執行檔」指定路徑，或先把官方 CLI 加入登入環境可找到的路徑，再按「檢查登入與方案」。
- **顯示未登入或未確認方案：** 在 provider 官方 CLI 完成訂閱登入；對新帳戶，使用 AgentBridge 的登入終端，再重新檢查。
- **切換帳戶後舊工作階段不能執行：** session 綁定建立時的帳戶。切回該帳戶，或用目前帳戶建立新工作階段。
- **新提交看不到舊記憶：** 記憶依固定提交隔離。確認兩邊 session 使用相同 Repository 路徑和 commit。
- **API 呼叫被拒絕或保留金額未退回：** 檢查 `agentbridge budget` 或 App 顯示的 UTC 月帳本。費用未知、失敗或取消時，保留額不會被當作零費用退回。
- **工作區與來源 Repository 不一致：** 這是刻意的快照邊界；建立工作階段後的來源變更不會自動複製進來。

### 11. 簽署、公證與驗證 App

`scripts/package-app.sh` 會重建未簽署的開發 App。準備好發行版本並通過 `.codex/ci.sh` 後，使用共用 `macos-notarization-release` helper 進行正式簽署與公證。helper 從使用者層級設定讀取 Apple 公證認證（Keychain profile 或 App Store Connect API key），與 Claude API key 分開；不要把簽署憑證或 Apple `.p8` 私鑰放進 Repository。App 簽署身份必須是 Developer ID Application。App 內的 `agentbridge` helper 要先簽署，再簽外層 App。

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
TOOL="$HOME/.codex/skills/macos-notarization-release/scripts/macos_notarization.py"
APP="$PWD/build/AgentBridge.app"
# 替換成 Keychain 中 Developer ID Application 憑證顯示的完整身份名稱。
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
AUTH_KIND="$(python3 "$TOOL" resolve-auth --project-root "$PWD")"

python3 "$TOOL" sign "$APP/Contents/Helpers/agentbridge" \
  --identity "$SIGNING_IDENTITY" --authorized
python3 "$TOOL" sign "$APP" --identity "$SIGNING_IDENTITY" --authorized
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "$PWD/build/AgentBridge-notarization-upload.zip"
python3 "$TOOL" submit "$PWD/build/AgentBridge-notarization-upload.zip" \
  --authorized --wait --timeout 30m --auth "$AUTH_KIND" --project-root "$PWD"
python3 "$TOOL" staple "$APP"
python3 "$TOOL" verify "$APP"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "$PWD/build/AgentBridge-notarized.zip"
```

上傳用 ZIP 是送交 Apple 的載體；Apple 接受後，ticket 會 staple 到 `.app`，再以已 staple 的 App 建立交付 ZIP。驗證包含簽章、Gatekeeper 與 ticket。若 helper 回報逾時或結果未知，不要自動重送同一 artifact；先依 Apple 回傳的 submission ID 查明該次狀態。`doctor` 只檢查本機設定，不代表 Apple 已接受公證。重跑 `package-app.sh` 會覆寫 App 並移除既有簽章，之後需重新簽署、公證。

---
