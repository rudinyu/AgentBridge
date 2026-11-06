# AgentBridge 使用指南

[英文版](HOW_TO_USE.md)

這份指南說明如何安裝、登入、開始對話、切換 provider 與帳戶、使用共用記憶，以及在需要時啟用 Claude API。App 與 CLI 共用已保存的使用者自選工作區資料夾；私有設定、帳戶資料、工作階段／稽核中繼資料及用量／預算帳本則留在 Application Support。

> App 全新安裝時預設使用英文。可隨時從標題列的語言選單選擇「English」或「繁體中文」；選擇會立即套用並自動保存。以下使用繁體中文介面名稱說明操作。

### 1. 準備環境與啟動 App

需要 macOS 14 或更新版本、Swift 6 與 Xcode toolchain。若要完整使用 provider 功能，請先安裝官方 CLI，並在該 CLI 完成訂閱登入：

- Codex CLI：[官方安裝與登入文件](https://developers.openai.com/codex/cli)
- Claude Code：[官方安裝文件](https://code.claude.com/docs/en/quickstart)

在 AgentBridge Repository 執行：

`Assets/AppIcon-1024.png` 是 App icon 原始圖；封裝時會產生 macOS `.icns` 並加入 App。

```sh
cd /Users/rudin_yu/codexworkspace/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh --app-name AgentBridge-0.11.2-dev.app
open build/AgentBridge-0.11.2-dev.app
```

CI 腳本會建置 CLI、App 並執行核心測試；封裝腳本會建立未簽署的本機 App。上述步驟不登入 provider、不呼叫模型，也不產生 Claude API 費用。若已建置此開發版，只要重新開啟 `build/AgentBridge-0.11.2-dev.app` 即可。若要交付給其他 Mac，請完成本文最後的 Developer ID 簽署與 Apple 公證流程。

第一次開啟 App 時，請選擇或建立存放工作區資料的資料夾。AgentBridge 必須先有這項設定才會建立工作階段，不會暗中把資料夾放在 Application Support。App 和 CLI 共用已保存的位置。自選資料夾會包含隔離的工作階段工作區與共用記憶：

```text
<你選擇的資料夾>/
  workspaces/<工作階段 ID>/   # 每個工作階段各自的隔離 Git 複本
  shared-memory/              # App/CLI 共用對話記憶
```

私有 App 資料仍保存在 `~/Library/Application Support/AgentBridge`，包含 App 設定、帳戶設定資料、各 provider CLI 專用的 profile 資料夾（CLI 會在其中保存該 profile 的登入資料）、工作階段和稽核記錄，以及用量／預算帳本。內建帳戶仍使用 provider CLI 原有的登入資料夾。日後若要在 App 變更資料夾，請在「專案」面板的「資料根目錄」旁按「變更…」。若要從 CLI 設定或變更位置，執行 `agentbridge workspace set /absolute/path/to/folder`；執行 `agentbridge workspace show` 可查看已保存的位置。尚未選擇資料夾時，CLI 會顯示這項可直接執行的設定命令。

變更資料夾時，AgentBridge 會把既有工作區和共用記憶複製到新位置，再更新既有工作階段記錄以使用新副本。原本的資料夾和檔案會完整保留；新工作階段則使用新資料夾。若目的地已有不同內容的工作區或記憶檔，AgentBridge 會停止並回報衝突，不會覆寫任一副本。變更資料夾不會改變共用記憶的識別方式：記憶仍以來源 Repository 的 canonical 路徑及工作階段固定的提交版本作為範圍。

App 沒有可用的工作區資料夾時會自動開啟設定精靈。精靈會依序引導語言和供應商、必要的資料資料夾、選用的 CLI 尋找或路徑選擇、登入檢查、帳戶記憶同意設定，以及本機用量設定。只有工作區資料夾是必填項目；CLI 尚未安裝或登入尚未確認時仍可略過，最後的檢查頁會清楚列出未完成項目。精靈不會安裝軟體、執行 provider 工作、傳送模型請求或設定 API 金鑰。儲存帳戶或預設設定時可能會準備本機工作階段。只有你明確按下登入或狀態檢查按鈕時，才會啟動官方 CLI。設定預設使用訂閱登入；若尚未完成就結束 App，下次啟動會接續設定。有可用資料夾的既有安裝不會自動跳出精靈；按標題列的「設定精靈」即可重新開啟。除非你明確儲存變更，重新開啟不會改動已儲存的供應商設定或既有記憶同意設定。

### 2. 檢查 CLI 登入與方案

本機模型使用 Local 後端及模型設定，不需要 CLI 登入。先啟動既有服務、設定本機回送位址，再更新模型清單並選取模型。上下文與輸出上限會決定保守輸入預算；「上下文預覽」可查看確切歷史內容與拒絕原因。支援範圍見[本機模型與上下文](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)。

全新安裝預設使用英文。可在設定精靈或 App 標題列選擇「English」或「繁體中文」；選擇會立即套用並保存。若要主動檢查登入，請從左側「助理」選 Codex 或 Claude，再按右上方「檢查登入與方案」。App 只顯示官方 CLI 確認的帳戶與方案欄位；如果 Codex CLI 沒有回報方案名稱，AgentBridge 不會猜測。

CLI 也可檢查環境與登入狀態：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" doctor
"$CLI" profiles list
```

如果找不到 CLI，可在 App 左側「CLI 執行檔」填入執行檔路徑，或使用 `agentbridge settings binary codex|claude /absolute/path/to/cli` 設定。官方 CLI 管理其登入資料；AgentBridge 不複製現有憑證。

### 3. 先討論，再建立專案

開啟 **Chats**，按 **New Chat**，選擇供應商／帳戶即可傳送訊息，不必先有儲存庫。討論固定使用訂閱登入，保存獨立有界逐字稿，後續脈絡受帳戶共享同意限制。方向明確後選擇 **Create Git Project** 或 **Link Existing Project**，明確選取要移轉的已完成回合（也可完全不移轉），檢視目的位置與摘要後再確認。新本機儲存庫只有空白初始提交；核准內容另存於 AgentBridge 記憶，原始聊天保留。詳見[先聊天流程](CHAT_FIRST_WORKFLOW.zh-TW.md)。

### 3a. 開始一段唯讀 App 對話

1. 在左側「助理」選 Codex 或 Claude。Codex 只提供官方 CLI 訂閱登入。
2. 在「官方 CLI 帳戶」確認目前帳戶。若需要其他帳戶，先依下節新增並登入。
3. 在「專案」輸入 Git Repository 路徑，或按「選擇儲存庫…」。
4. 保持「互動終端工作階段」關閉，按「建立同一專案的新工作階段」。這會建立唯讀聊天工作階段。
5. 在右側輸入提示並按「傳送」。成功完成的回合會保存到此 Repository 與固定提交版本的共用記憶。

每個工作階段固定建立時的來源 `HEAD`，並在 `<你選擇的資料夾>/workspaces/<工作階段 ID>/` 中的專屬隔離複本執行。未提交和未追蹤的檔案不會複製。來源提交後續改變時，既有工作階段仍使用原來的固定版本；建立新工作階段會以新的來源提交建立新的記憶範圍。AgentBridge 不會自動合併或推送工作區變更。

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

共用記憶存放在 `<你選擇的資料夾>/shared-memory/`，並以來源 Repository 的 canonical 路徑及固定提交作為範圍。記憶範圍不受隔離工作區複本存放位置影響。App 與 CLI 的唯讀聊天成功完成後，會在帳戶允許共享時加入記憶。從 Codex 切到 Claude，或從 Claude 切到 Codex，當兩個工作階段使用相同來源路徑和提交版本時，可共用同一份 App/CLI 對話和手動備註。新帳戶預設共享；可在帳戶設定中逐一關閉。

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

AgentBridge 無法透過受支援的機器可讀來源取得官方訂閱額度百分比。要查看額度，請開啟 provider 官方互動 CLI，再按固定的 **送出 /usage** 操作：Codex CLI 會顯示每日、每週及累積活動；Claude CLI 會顯示本次工作階段費用、方案用量限制及活動統計。使用者明確執行此操作後，AgentBridge 會將有限長度的可見畫面文字暫存在記憶體，盡力解析可辨識欄位並填入統一資料卡；未知欄位顯示「未提供」。官方 TUI 畫面仍是依據；這種畫面文字解析不是穩定的額度 API。AgentBridge 不會讀取其他終端輸出或存取 provider 私有端點。

可選擇設定訂閱模式的本機執行次數上限，範圍包括近 5 小時、24 小時、7 天及目前 AgentBridge 工作階段。Claude API 有選用的 UTC 每日及工作階段 USD 上限、24 小時及工作階段執行次數上限，也可停用所選帳戶未來的 API 執行。單次 USD 預算、每日/工作階段 USD 上限、月度 USD 帳本和執行次數上限是不同控制。每次 API 執行會在啟動前以單次預算的兩倍預留金額，App 與 CLI 會在呼叫前顯示此金額。同一工作階段可進行多次付費呼叫，工作階段 USD 上限會計入全部呼叫。App 和 CLI 同一時間最多允許一筆尚未確認費用的付費呼叫。

如果已完成或中斷的 API 呼叫沒有可確認的費用，該帳戶會維持封鎖。請先將特定 Claude API 工作階段與 Anthropic 帳單核對，再於 App 手動結算區選擇該工作階段綁定的帳戶與工作階段、輸入帳單實際 USD 費用並確認。CLI 也可使用 `agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm`。若帳單尚未顯示這筆費用，可在 App 按「使用預留金額」，或在 CLI 以 `--settle-at-reserved` 取代 `--actual-usd USD`，用完整預留金額保守結算並恢復 API 執行。此結算之後不能更改，本機帳本可能高估這次費用。結算不會連線呼叫 provider，會追加不含機密的稽核事件。結算前會先取得該工作階段的執行鎖：作用中的程序會被拒絕；若仍顯示「執行中」但其實是中斷後殘留的狀態，會標記為失敗後才結算。使用相同金額重試是安全的。除非帳單明確顯示零費用，否則不要輸入 0。與先前結算金額衝突時會拒絕更新。無法歸屬到帳戶的舊預留會保持封鎖，不會被分配到錯誤帳戶。

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

### 9. 安全修改、活動紀錄、記憶交接與擴充權限

唯讀仍是預設。若要隔離修改，請在 **Access mode** 選取 **Isolated Changes**，並在訂閱模式建立新工作階段。它會依來源 Repository 已提交的 `HEAD` 建立新工作區；來源未提交檔案不會複製。原生互動 TUI 是獨立模式。

在 **Changes** 填入計畫標題、摘要和步驟，保存後先完整檢視。可先調整計畫，確認符合預期後再按 **Approve reviewed plan**；只有核准後 **Run approved changes** 才能執行。Provider 只會在隔離工作階段工作區寫檔。Codex 變更使用非互動 `codex exec`：AgentBridge 不會啟用自動核准，也無法在執行途中顯示核准提示。需要超出 sandbox 權限的命令會失敗停止；請將工作限制在已核准計畫和隔離工作區內。CLI 流程如下：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" session create --provider codex --repo "$HOME/Projects/example" --changes
# 複製上方輸出的工作階段 ID。
SESSION_ID="在此貼上工作階段 ID"
"$CLI" changes plan "$SESSION_ID" --title "更新 parser" \
  --summary "支援新的記錄格式。" --step "更新解碼方式" --step "調整重點驗證"
# 複製輸出的 PLAN_ID 與 REVIEW_DIGEST。核准時會顯示完整計畫，並要求
# 從標準輸入提供完整的 `APPROVE REVIEW_DIGEST` 確認文字。
printf '%s\n' 'APPROVE REVIEW_DIGEST' | "$CLI" changes approve "$SESSION_ID" PLAN_ID REVIEW_DIGEST
printf '%s' '依核准計畫完成修改。' | \
  "$CLI" changes run "$SESSION_ID" PLAN_ID REVIEW_DIGEST
```

在 **Changes** 檢視完整檔案清單與 diff。拒絕某個變更時還原該檔，或將全部檔案還原到基準快照，也可匯出 patch。差異超過 1 MiB 的檔案不會顯示，非 UTF-8 文字會以替代字元顯示；兩者在 patch 中都完整保留，請匯出以檢視。**Verify** 只有按下後才會執行 `.codex/ci.sh`，且會拒絕與固定提交版本不同的指令碼；請還原它，或以已核准的自訂驗證執行。自訂驗證需先明確核准，並以 executable 和分開的 argv 傳入；AgentBridge 不會組合 shell 命令。結果顯示 executable、參數、工作目錄、退出代碼、耗時及遮蔽後的 stdout/stderr。接受與套用只適用於已成功驗證的目前完整 diff。套用時須輸入本機 branch 名稱；AgentBridge 先檢查來源 base commit 未改變，再建立未提交 worktree。AgentBridge 不會 commit、push 或 merge。

**Activity** 時間軸呈現排序後、已遮蔽的稽核事件，包括可取得的進度、計畫核准、取消、錯誤、diff 變化與驗證結果。只有官方 CLI 實際回報的 provider 輸出才會顯示。**Parallel task board** 列出所有工作階段實際啟動的操作、狀態、核准、進度、取消及 diff／驗證參照。App、CLI 與自主流程合計最多同時進行三個供應商執行（唯讀、變更與驗證執行），第四個會被拒絕，直到有一個結束；檢視差異、核准計畫、接受變更等操作不受此上限阻擋；共用的程序鎖也會阻止同一工作階段重複執行。請在對應任務按 **Cancel this session**。

若要將記憶延續到另一個 commit，請選擇相同 canonical Repository、不同提交版本的來源和目標工作階段。目標工作階段綁定的帳戶必須允許共用記憶。選取來源回合與／或備註，檢查來源／目標 commit，再建立交接。目標工作階段下一次允許的提示只會收到所選內容，並以有界（16 KiB）、標明不可信的歷史 JSON envelope 傳入且保留 provenance。交接存於所選工作區資料根目錄下的 `shared-memory/project-handoffs/`。原生 provider TUI transcript 永不匯入。

**Skills & MCP** 中的舊政策面板可匯入描述資料 JSON，仍只保存惰性中繼資料，授權不會執行任何內容。若要真正載入 Skill 指令或連接已安裝的 MCP，請使用下方說明的獨立擴充執行控制。

CLI 也提供對應操作：

```sh
"$CLI" changes diff "$SESSION_ID"
"$CLI" changes restore "$SESSION_ID" Sources/example.swift
"$CLI" changes export "$SESSION_ID" "$HOME/Desktop/example.patch"
"$CLI" changes verify "$SESSION_ID" # 只有明確執行此命令才會啟動 .codex/ci.sh
"$CLI" changes verify "$SESSION_ID" --custom /absolute/path/to/check --approve-custom --arg "--fast"
"$CLI" changes accept "$SESSION_ID" --confirm
"$CLI" changes apply "$SESSION_ID" reviewed-local-branch
"$CLI" tasks
"$CLI" memory handoffs "$SESSION_ID"
"$CLI" memory carry-forward SOURCE_SESSION TARGET_SESSION --turn TURN_UUID --notes
"$CLI" extensions import /absolute/path/to/descriptor.json
"$CLI" extensions grant "$SESSION_ID" extension-id --permission readSelectedFiles --path Sources --confirm
"$CLI" extensions revoke "$SESSION_ID" extension-id --confirm
```

`changes apply` 會回傳未提交的本機 worktree。自訂 `changes verify` 會直接將 argv 傳給 executable。CLI 同樣受訂閱模式、計畫核准、驗證、來源 commit 和帳戶共享記憶同意檢查，不會繞過這些限制。

### 10. 自主工作流程

開啟 **Autonomous Workflow**，選擇來源 Repository 並填入具體目標，再選擇規劃、調查、實作與審查角色的實際供應商／帳戶。呼叫使用訂閱登入；允許相依任務或完整實作 diff 傳給其他角色前，先確認帳戶的共享同意。

設定並行、審查修正輪數、時間與呼叫上限，並行數和審查輪數最多三個／三輪。選擇不驗證、專案 CI，或已檢視的自訂執行檔與獨立參數。**Generate plan** 會發出真正的規劃請求，但不會核准工作。檢視每個任務、相依、提示、來源 commit、帳戶、記憶選擇、擴充、驗證與限制；確認已檢視，核准畫面摘要後再啟動。綁定變更後必須重新核准。

核准前請檢視完整凍結的專案記憶；允許共享的角色會跨供應商與帳戶取得同一快照。選擇保存最終摘要及允許共享的目標帳戶，才會把一次流程結果追加到共用記憶。相依任務輸出分享是另一項獨立選擇。

查看任務進度與審查／驗證結果；取消會停止派送並要求終止程序，中斷工作不自動重跑。完成後在 **Project Conversations** 開啟實作者的隔離變更，沿用 diff、驗證、接受與套用控制，不自動 commit、push 或 merge。CLI 的 `autonomous` 提供相同規劃、核准、執行、狀態與取消操作；完整參數和 JSON 狀態輸出請查看 `agentbridge help`。

### 11. Skills、MCP 實際執行與 Mac Control

選好專案工作階段後開啟 **Skills & MCP**，匯入真正 SKILL.md 快照或已安裝本機 stdio MCP 的設定。匯入不執行；先檢視 MCP 執行檔、獨立參數與精確工具清單，再明確啟動連線測試。測試會執行該程式，進行初始化與工具查詢。預覽啟用、檢視摘要、指令／工具與信任提醒，再明確同意並為指定專案／供應商／帳戶啟用；舊中繼資料授權不足以啟用。設定變更和撤銷會使綁定失效，若要求請建立新工作階段。首版不支援 Skill 腳本／hooks 或遠端 HTTP／OAuth MCP。

**Mac Control** 選擇已安裝 helper 的預設整合並指定目標 bundle ID，先自行開啟目標 App，再使用 **Observe**；匯入預設整合後，先按 **Test Connection** 檢查工具清單，再預覽與啟用。權限測試只讀取就緒狀態，不授予 macOS 權限；若需要，請手動授予輔助使用及螢幕錄製。檢視畫面存取同意後才能啟用；**Control** 另須同意輸入。受保護的系統、憑證、終端及 AgentBridge 目標會遭拒絕。截圖包含整個主螢幕且可能傳給所選供應商；目標限制的是輸入，不是圖片範圍，請先關閉私人視窗。**Stop Control** 撤銷範圍並要求取消，無法撤回已送出操作。一般桌面同意不包含憑證、系統驗證、安全設定或重大交易。

產生流程計畫前，為角色選擇已啟用擴充的 ID；核准會綁定其範圍與上限。Repository 唯讀不會使另外核准的外部工具變成唯讀。詳見[設計與驗證邊界](AUTONOMY_AND_EXTENSIONS.zh-TW.md)。

### 12. CLI 常用操作

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

如果你搬動或改名了儲存庫，共用記憶仍留在舊路徑，新的工作階段會從空白開始。`agentbridge memory relink-candidates SESSION_ID` 會列出「同一個 commit、但舊路徑已不存在」的記憶；`agentbridge memory relink SESSION_ID KEY --confirm` 會把它複製進這個工作階段。原記憶不會被修改，而且只有在這個工作階段自己的記憶是空的時候才能使用。舊資料夾仍存在的第二份 clone 不會被列出。

`agentbridge doctor` 也會顯示各 provider CLI 的版本，並和 AgentBridge 上次驗證的版本對照；若 CLI 說明裡找不到 AgentBridge 依賴的旗標會發出警告，但不會阻擋執行。

### 13. 常見狀況

- **找不到 provider CLI：** 在 App 的「CLI 執行檔」指定路徑，或先把官方 CLI 加入登入環境可找到的路徑，再按「檢查登入與方案」。
- **顯示未登入或未確認方案：** 在 provider 官方 CLI 完成訂閱登入；對新帳戶，使用 AgentBridge 的登入終端，再重新檢查。
- **切換帳戶後舊工作階段不能執行：** session 綁定建立時的帳戶。切回該帳戶，或用目前帳戶建立新工作階段。
- **新提交看不到舊記憶：** 記憶依固定提交隔離。確認兩邊 session 使用相同 Repository 路徑和 commit。
- **API 呼叫被拒絕或保留金額未退回：** 檢查 `agentbridge budget` 或 App 顯示的 UTC 月帳本。費用未知、失敗或取消時，保留額不會被當作零費用退回。
- **工作區與來源 Repository 不一致：** 這是刻意的快照邊界；建立工作階段後的來源變更不會自動複製進來。

### 14. 簽署、公證與驗證 App

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
