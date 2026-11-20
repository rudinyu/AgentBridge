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
cd /path/to/AgentBridge
./.codex/ci.sh
./scripts/package-app.sh --app-name AgentBridge-0.18.0-dev.app
open build/AgentBridge-0.18.0-dev.app
```

CI 腳本會建置 CLI、App 並執行核心測試；封裝腳本會建立未簽署的本機 App。上述步驟不登入 provider、不呼叫模型，也不產生 Claude API 費用。若已建置此開發版，只要重新開啟 `build/AgentBridge-0.18.0-dev.app` 即可。若要交付給其他 Mac，請完成本文最後的 Developer ID 簽署與 Apple 公證流程。

第一次開啟 App 時，請選擇或建立存放工作區資料的資料夾。AgentBridge 必須先有這項設定才會建立工作階段，不會暗中把資料夾放在 Application Support。App 和 CLI 共用已保存的位置。自選資料夾會包含隔離的工作階段工作區與共用記憶：

```text
<你選擇的資料夾>/
  workspaces/<工作階段 ID>/   # 每個工作階段各自的隔離 Git 複本
  shared-memory/              # App/CLI 共用對話記憶
  handoffs/<repo-key>/<commit>.md # 同提交版本接續交接歷史，內容會遮蔽敏感資料
```

私有 App 資料仍保存在 `~/Library/Application Support/AgentBridge`，包含 App 設定、帳戶設定資料、各 provider CLI 專用的 profile 資料夾（CLI 會在其中保存該 profile 的登入資料）、工作階段和稽核記錄，以及用量／預算帳本。內建帳戶仍使用 provider CLI 原有的登入資料夾。日後若要在 App 變更資料夾，請在「專案」面板的「資料根目錄」旁按「變更…」。若要從 CLI 設定或變更位置，執行 `agentbridge workspace set /absolute/path/to/folder`；執行 `agentbridge workspace show` 可查看已保存的位置。尚未選擇資料夾時，CLI 會顯示這項可直接執行的設定命令。

變更資料夾時，AgentBridge 會把既有工作區、共用記憶與交接歷史複製到新位置，再更新既有工作階段記錄以使用新副本。原本的資料夾和檔案會完整保留；新工作階段則使用新資料夾。若目的地已有不同內容的工作區、記憶或交接檔，AgentBridge 會停止並回報衝突，不會覆寫任一副本。變更資料夾不會改變共用記憶的識別方式：記憶仍以來源 Repository 的 canonical 路徑及工作階段固定的提交版本作為範圍。

App 沒有可用的工作區資料夾時會自動開啟設定精靈。精靈會依序引導語言和供應商、必要的資料資料夾、選用的 CLI 尋找或路徑選擇、登入檢查、帳戶記憶同意設定，以及本機用量設定。只有工作區資料夾是必填項目；CLI 尚未安裝或登入尚未確認時仍可略過，最後的檢查頁會清楚列出未完成項目。精靈不會安裝軟體、執行 provider 工作、傳送模型請求或設定 API 金鑰。儲存帳戶或預設設定時可能會準備本機工作階段。只有你明確按下登入或狀態檢查按鈕時，才會啟動官方 CLI。設定預設使用訂閱登入；若尚未完成就結束 App，下次啟動會接續設定。有可用資料夾的既有安裝不會自動跳出精靈；按標題列的「設定精靈」即可重新開啟。除非你明確儲存變更，重新開啟不會改動已儲存的供應商設定或既有記憶同意設定。

### 2. 檢查 CLI 登入與方案

本機模型使用 Local 後端及模型設定，不需要 CLI 登入。先啟動既有服務、設定本機回送位址，再更新模型清單並選取模型。上下文與輸出上限會決定保守輸入預算；「上下文預覽」可查看確切歷史內容與拒絕原因。如果還沒設定 Ollama，可用 Local 模型設定最上方的「Ollama 引導設定」：它會檢查是否已安裝與執行，在你點按時開啟下載頁面或啟動 App，依這台 Mac 的記憶體建議程式碼模型，且只有按「下載模型」時才下載。支援範圍見[本機模型與上下文](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)。

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
4. 在「新工作階段存取模式」選「唯讀」（預設是「原生互動終端」），按「建立同一專案的新工作階段」。這會建立唯讀聊天工作階段。
5. 在右側輸入提示並按「傳送」。成功完成的回合會保存到此 Repository 與固定提交版本的共用記憶。

模型與推理強度：建立按鈕上方的「模型」與「推理強度」決定新的 Codex 或 Claude 工作階段使用什麼。模型可自由輸入，清單按鈕提供幾個建議名稱；CLI 接受的名稱都能輸入。推理強度第一個選項是「CLI 預設」，後面是 CLI 接受的等級（Codex：low、medium、high、xhigh、max、ultra；Claude：low、medium、high、xhigh、max）。兩者都留空就使用 CLI 自己的預設值，AgentBridge 不會猜測那是哪個模型。這個選擇和帳戶一樣綁定在工作階段上：套用於唯讀執行、修改執行與原生終端，之後無法更改，並在工作階段的供應商與帳戶旁顯示，例如「gpt-x · high」或「CLI 預設」。若 CLI 拒絕該模型，執行會失敗並顯示 CLI 的訊息；AgentBridge 不會改用其他模型重試。用量終端永遠不設定模型，本機模型仍使用自己的模型設定。新工作階段與新對話的預設值在「助理」>「新工作階段的預設模型」。新對話也有相同的兩個欄位；對話切換到其他供應商時會回到 CLI 預設。CLI 用法：`session create … --model NAME --effort LEVEL`、`chat new … --model NAME --effort LEVEL`，以及 `settings model codex|claude [--model NAME] [--effort LEVEL]`。

每個工作階段固定建立時的來源 `HEAD`，並在 `<你選擇的資料夾>/workspaces/<工作階段 ID>/` 中的專屬隔離複本執行。未提交和未追蹤的檔案不會複製。來源提交後續改變時，既有工作階段仍使用原來的固定版本；建立新工作階段會以新的來源提交建立新的記憶範圍。AgentBridge 不會自動合併或推送工作區變更；只有透過第 9 節經你確認的拉取要求動作才會提交與推送。

以此建立新工作階段：若想用其他模型、推理強度或帳戶處理同一個任務，在任一工作階段清單的工作階段上按右鍵，選擇「以此建立新工作階段…」。Codex 或 Claude 執行因 CLI 錯誤而失敗時，錯誤提示會提供「改用其他模型…」，失敗的工作階段標題旁也會顯示同一個按鈕。表單會預先帶入來源工作階段的模型、推理強度與帳戶（只列出同一供應商的帳戶），並沿用其供應商、Repository 與存取模式（唯讀、隔離變更或互動式終端機）。選擇「相同提交」會固定在來源工作階段的提交版本；選擇「來源儲存庫目前的 HEAD」則固定在 Repository 現在的版本。核准、驗證結果、變更與已啟用的擴充功能不會複製。隔離變更工作階段的變更計畫（標題、摘要、步驟及是否包含共享記憶）會以未核准狀態儲存在新工作階段，必須重新檢視並核准；若無法儲存，例如所選帳戶不允許共享記憶，新工作階段仍會建立，錯誤訊息會說明計畫未複製。唯讀對話中，你在這次 App 啟動期間於來源工作階段最後送出的提示詞會放進新工作階段的輸入框，但絕不會自動送出。來源工作階段可以是已失敗、已取消或已移除的工作階段。CLI 用法：`session create --like SESSION-ID [--model NAME] [--effort LEVEL] [--latest-commit] [--profile PROFILE-ID]`；`--provider`、`--repo`、`--changes` 與 `--interactive` 不能和 `--like` 一起使用，未指定 `--model` 或 `--effort` 時沿用來源工作階段的值。

專案指示：Codex 會自行讀取 Repository 的 `AGENTS.md`。對 Claude（唯讀、修改、API 與原生終端工作階段）和本機模型，AgentBridge 會傳入工作階段工作區根目錄、位於工作階段固定提交版本的 `AGENTS.md`，讓三者遵循相同的指示。只使用根目錄的檔案，上限 32 KiB；不讀取 CLAUDE.md、上層資料夾或子資料夾。若本機模型的上下文視窗放不下，檔案會被縮短或略過。由於工作階段固定在某個提交版本，修改 `AGENTS.md` 後必須先提交，並建立新的工作階段才會生效。活動紀錄會記錄檔案是否納入、大小與 SHA-256，或略過的原因。

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

「專案共用記憶」區塊可查看聊天回合；「記憶備註」仍用於一般共用備註。若要同提交版本切換供應商，請在「專案對話」使用「快速切換並接續到其他供應商」。成功完成的 App 或 CLI 唯讀聊天會在帳戶同意共用時自動加入記憶；原生 Codex/Claude TUI 的輸入和輸出不會被擷取。「清除此提交的記憶」會刪除該 canonical Repository 與固定提交版本的聊天回合、一般備註及同提交版本交接 Markdown；不同提交版本的明確交接記錄和 provider 自己的 session 資料不會變更。

若要不呼叫來源模型或 API、快速接續到其他供應商，請先關閉作用中的 App 供應商終端機，再展開「快速切換並接續到其他供應商」。選擇目標供應商與帳戶；若尚未同意，請啟用「允許此目標帳戶載入與儲存專案共用記憶」，未同意前無法切換。「選填交接內容」可填入已完成事項、下一步與建議提示詞，也可以全部留白；AgentBridge 會在本機產生保守備援文字，要求下一位助理檢查共用記憶、Repository 檔案、目標工作階段工作樹與 Git 狀態、不要重複已完成事項，並在無法推斷原始意圖時先詢問你。產生備援文字不會呼叫模型。目標供應商使用自己的工作階段工作區；切換不會複製來源工作區的未提交檔案。若工作依賴這些檔案，下一位助理會先詢問你是否提供 diff 或手動轉移。App 會將已遮蔽敏感內容的 Markdown 交接另存於 `<你選擇的資料夾>/handoffs/<repository-key>/<固定提交版本>.md`，保留先前交接歷史，既有記憶備註則維持獨立。檔案會記錄來源／目標供應商、帳戶、Repository 與提交版本脈絡，再將目標設為預設供應商，並以「新工作階段存取模式」選定的模式選取或建立相同提交版本的工作階段（本機模型或 API 模式則為唯讀）。唯讀 App 對話只會在輸入框空白時填入建議提示詞，供你檢查與修改；不會自動送出。重新開啟相同儲存庫與提交版本的對話時，可在 Finder 顯示或複製既有交接，但不會自動填入輸入框。「複製已儲存的建議提示詞」會從最新交接複製已遮蔽敏感資料的提示詞；「複製完整交接至終端機」會複製最新一筆（最多 16 KiB），包含已完成摘要、下一步、建議提示詞及來源／目標供應商、帳戶、Repository 與提交版本脈絡，供手動貼上及檢查。受管理的 AgentBridge App 與 CLI 聊天只會在工作階段綁定帳戶允許共用記憶時，載入最新已保存交接作為不可信歷史脈絡。原生 Codex/Claude TUI 不會自動收到交接，輸入與輸出也不會被擷取；需要時請使用複製功能，再手動貼入終端機。若儲存後建立或切換工作階段失敗，Markdown 檔仍保留供此儲存庫與提交版本使用。

### 6. 使用原生互動終端

要直接使用 Codex 或 Claude 的原生互動介面：

1. 確認目前選的是訂閱登入；Claude API 模式不支援互動終端。
2. 「新工作階段存取模式」保持「原生互動終端（預設）」，並建立工作階段。
3. 按「開啟內嵌終端機」，在 provider TUI 中自行輸入並控制下一步。像 `/status` 這類指令會由官方 CLI 原生處理。按「在視窗中開啟」可在獨立視窗調整終端機大小；按「返回對話」會把同一個工作階段移回對話畫面。正常結束 CLI（例如輸入 `/quit` 或 `/exit`）後，面板不會關閉，而是在同一個隔離工作區開啟 shell，上方仍保留 CLI 最後的畫面，可以接著執行 `git` 或測試；輸入 `exit` 即可關閉。CLI 執行失敗或被取消時，面板會照舊結束，並保留錯誤訊息。在「專案對話」中也可隱藏側邊欄，讓工作區更寬敞。

這與 App 右側的唯讀聊天不同。Codex 互動工作階段維持唯讀 sandbox；Claude 使用原生 Manual 權限流程，使用者核准的操作可能修改隔離複本、讀取工作區外的檔案或連接網路。終端逐字稿只留在目前畫面，不寫入 AgentBridge 記憶或稽核記錄。

右上方「本機終端機」會在 Repository 複本位置開啟 shell（標題顯示「本機終端機 · 專案名稱 的隔離副本」，因為它不是來源 Repository），但仍以目前 macOS 使用者權限執行；它可能存取複本外的檔案或網路。Git 隔離複本不是作業系統層級的 sandbox。

### 7. 用量儀表板與本機執行上限

用量區依目前選取的 provider 與帳戶分開顯示。訂閱模式會以圖表呈現 AgentBridge 記錄的本機管理執行嘗試，範圍為滾動近 5 小時、24 小時及 7 天。這些是本機估計，不是 provider 額度或帳戶總用量；provider 限制和共享方式會因方案而異，其他 provider App 的活動也不會計入。互動 TUI 內的回合不會被記錄。

AgentBridge 無法透過受支援的機器可讀來源取得官方訂閱額度百分比。要查看額度，請開啟 provider 官方互動 CLI，再按固定的 **送出 /usage** 操作：Codex CLI 會顯示每日、每週及累積活動；Claude CLI 會顯示本次工作階段費用、方案用量限制及活動統計。使用者明確執行此操作後，AgentBridge 會將有限長度的可見畫面文字暫存在記憶體，盡力解析可辨識欄位並填入統一資料卡；未知欄位顯示「未提供」。官方 TUI 畫面仍是依據；這種畫面文字解析不是穩定的額度 API。AgentBridge 不會讀取其他終端輸出或存取 provider 私有端點。

可選擇設定訂閱模式的本機執行次數上限，範圍包括近 5 小時、24 小時、7 天及目前 AgentBridge 工作階段。Claude API 有選用的 UTC 每日及工作階段 USD 上限、24 小時及工作階段執行次數上限，也可停用所選帳戶未來的 API 執行。單次 USD 預算、每日/工作階段 USD 上限、月度 USD 帳本和執行次數上限是不同控制。每次 API 執行會在啟動前以單次預算的兩倍預留金額，App 與 CLI 會在呼叫前顯示此金額。同一工作階段可進行多次付費呼叫，工作階段 USD 上限會計入全部呼叫。App 和 CLI 同一時間最多允許一筆尚未確認費用的付費呼叫。

如果已完成或中斷的 API 呼叫沒有可確認的費用，該帳戶會維持封鎖。請先將特定 Claude API 工作階段與 Anthropic 帳單核對，再於 App 手動結算區選擇該工作階段綁定的帳戶與工作階段、輸入帳單實際 USD 費用並確認。CLI 也可使用 `agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm`。若帳單尚未顯示這筆費用，可在 App 按「使用預留金額」，或在 CLI 以 `--settle-at-reserved` 取代 `--actual-usd USD`，用完整預留金額保守結算並恢復 API 執行。此結算之後不能更改，本機帳本可能高估這次費用。結算不會連線呼叫 provider，會追加不含機密的稽核事件。結算前會先取得該工作階段的執行鎖：作用中的程序會被拒絕；若仍顯示「執行中」但其實是中斷後殘留的狀態，會標記為失敗後才結算。使用相同金額重試是安全的。除非帳單明確顯示零費用，否則不要輸入 0。與先前結算金額衝突時會拒絕更新。無法歸屬到帳戶的舊預留會保持封鎖，不會被分配到錯誤帳戶。

達到上限時，AgentBridge 會在呼叫 provider 模型前阻擋新的管理執行。達到 50%、75%、90%、100% 時，App 會顯示提醒；100% 代表已達設定的本機上限，並會阻擋新的管理執行。提醒會依帳戶與期間保存去重狀態；本機上限與通知設定變更，以及門檻達成紀錄，會保存在有筆數上限的本機稽核歷程。macOS 通知為選用功能，且需要允許通知權限。本機滾動期間不是 provider 的額度期間。

同一區的「工作完成時通知」是另一個設定：App 啟動的變更執行、驗證或自主工作流程在 AgentBridge 位於背景時結束，就會發出 macOS 通知。這個設定預設關閉，套用到整個 App 而非單一帳戶，開啟時會要求通知權限；權限被拒時會維持關閉。AgentBridge 視窗在最前面、你自行取消變更執行或驗證，或工作是從 CLI 啟動時，都不會通知。通知可能顯示在鎖定畫面，因此只說明發生了什麼，以及儲存庫資料夾名稱與 provider，不含提示內容、輸出、路徑或錯誤訊息。點選通知會把 AgentBridge 帶到最前面，並開啟該工作階段或工作流程執行（若仍存在）。

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

#### 尋找工作階段

兩個工作階段列表上方都有搜尋欄位與篩選條件。搜尋不分大小寫，會比對來源儲存庫的資料夾名稱、模型與推理強度、固定 commit 的開頭，以及工作階段變更計畫的標題。「供應商」、「狀態」與「存取模式」可以再縮小範圍；工作階段必須符合所有已設定的條件。按「清除篩選」會再次顯示所有工作階段。兩個列表共用同一組篩選條件，且不會儲存：每次啟動都從未篩選開始。

在 CLI 中，`"$CLI" sessions` 會列出所有工作階段；加上 `--provider codex|claude|local`、`--status created|running|completed|failed|cancelled`、`--mode read-only|changes|interactive` 與 `--repo PATH`，只會顯示符合所有指定選項的工作階段。`--repo` 會在解析符號連結後比較來源儲存庫路徑。

#### 移除工作階段

不再需要的工作階段，可在任一個工作階段列表上按右鍵，選「移除工作階段…」。AgentBridge 會先檢查該工作階段的隔離工作區，列出移除後會刪掉的內容：與來源儲存庫不同的檔案；被忽略、Git 不會保存的檔案與資料夾（例如 `.env`）；以及只存在這個工作區、來源儲存庫沒有其 commit 的分支、tag、notes 或 stash。若無法完成檢查，會直接說明，而不會當成工作區沒有內容。移除會刪除工作區且無法復原；工作階段的稽核事件與用量紀錄會保留，用量統計仍會計入它的執行。正在執行的工作階段、工作區內開著終端機的工作階段，以及有尚未對帳 API 呼叫的 Claude 工作階段，都不能移除。檢視之後工作區若有變動，不會刪除任何東西，並請你重新檢視。

要一次移除多個工作階段，按任一列表上方的「選取」，勾選工作階段，或按「全選顯示中的項目」選取篩選後顯示的所有工作階段，再按「移除 N 個工作階段…」。AgentBridge 會逐一檢查選取的工作階段，並以一個確認畫面分成三組顯示：可安全移除的工作階段；可能遺失工作的工作階段，逐一列出會遺失的檔案與參照；以及目前無法移除的工作階段與原因，這些會保留不動。確認後會逐一移除其餘工作階段，每個都依它自己的檢查結果，其中一個失敗也會繼續；完成後會回報移除了幾個，以及未移除的原因。只有篩選後仍顯示的已選取工作階段會被移除。自動化工作流程或其他移除正在進行時，無法使用批次移除。CLI 一次只移除一個工作階段。

在 CLI 中，`"$CLI" session remove SESSION-ID` 只顯示同樣的檢查結果、不會移除；`"$CLI" session remove SESSION-ID --confirm` 會再檢查一次並移除工作階段。若檢查發現會遺失的內容，或無法完成檢查，只加 `--confirm` 不會移除任何東西；要刪除這些內容需再加上 `--discard-unsaved-work`。

#### 移除聊天

要移除聊天，請在「聊天」列表上按右鍵，選「移除聊天…」，再確認。這會刪除聊天和其對話紀錄，無法復原。由這個聊天建立的專案工作階段會保留，已複製到其共用記憶的回合也會保留。正在執行的聊天不能移除。在 CLI 中，`"$CLI" chat remove CHAT-ID` 只顯示移除會刪除什麼，`"$CLI" chat remove CHAT-ID --confirm` 才會移除。

### 9. 安全修改、活動紀錄、記憶交接與擴充權限

Local 是下方訂閱模式限制的例外：Local 工作階段可在訂閱或 Claude API 用量模式下選擇「隔離變更」。Local 不提供原生互動終端。

預設的存取模式是原生互動終端。若要隔離修改，請在「新工作階段存取模式」選「隔離變更」，並在訂閱模式建立新工作階段。它會依來源 Repository 已提交的 `HEAD` 建立新工作區；來源未提交檔案不會複製。原生互動 TUI 是獨立模式。

在 **Changes** 填入計畫標題、摘要和步驟，保存後先完整檢視。若想從草稿開始，可在 **要變更什麼？** 描述變更並按 **草擬計畫**：AgentBridge 會向此工作階段的供應商送出一次實際的唯讀請求，供應商可讀取工作區但不能修改，並以回覆填入標題、摘要和步驟。若這些欄位已有內容，取代前會先詢問；草擬期間可取消。草稿不會被儲存、核准或執行，也不會開啟共享記憶；編輯後照常儲存即可。這次請求與其他執行一樣計入。CLI 可用 `changes draft SESSION-ID < request.txt` 印出草稿（`--json` 輸出 JSON）而不儲存；再把要保留的內容交給 `changes plan`。除非勾選 **在變更執行中包含共享記憶**（或對 `changes plan` 加上 `--with-memory`），變更執行不會看到共享記憶；核准涵蓋當下的記憶，記憶變更後請重新核准。可先調整計畫，確認符合預期後再按 **Approve reviewed plan**；只有核准後 **Run approved changes** 才能執行。Provider 只會在隔離工作階段工作區寫檔。Codex 變更使用非互動 `codex exec`：AgentBridge 不會啟用自動核准，也無法在執行途中顯示核准提示。需要超出 sandbox 權限的命令會失敗停止；請將工作限制在已核准計畫和隔離工作區內。CLI 流程如下：

```sh
CLI=build/swiftpm/debug/agentbridge
"$CLI" session create --provider codex --repo "$HOME/Projects/example" --changes
# 複製上方輸出的工作階段 ID。
SESSION_ID="在此貼上工作階段 ID"
# 可選：請模型草擬計畫。只會印出計畫，不會儲存。
printf '%s' '讓 parser 支援新的記錄格式。' | "$CLI" changes draft "$SESSION_ID"
"$CLI" changes plan "$SESSION_ID" --title "更新 parser" \
  --summary "支援新的記錄格式。" --step "更新解碼方式" --step "調整重點驗證"
# 複製輸出的 PLAN_ID 與 REVIEW_DIGEST。核准時會顯示完整計畫，並要求
# 從標準輸入提供完整的 `APPROVE REVIEW_DIGEST` 確認文字。
printf '%s\n' 'APPROVE REVIEW_DIGEST' | "$CLI" changes approve "$SESSION_ID" PLAN_ID REVIEW_DIGEST
printf '%s' '依核准計畫完成修改。' | \
  "$CLI" changes run "$SESSION_ID" PLAN_ID REVIEW_DIGEST
```

在 **Changes** 檢視完整檔案清單與 diff。拒絕某個變更時還原該檔，或將全部檔案還原到基準快照，也可匯出 patch。差異超過 1 MiB 的檔案不會顯示，非 UTF-8 文字會以替代字元顯示；兩者在 patch 中都完整保留，請匯出以檢視。接受與套用需要針對該差異另行確認：App 使用核取方塊，CLI 使用 `--confirm-partial DIFF-DIGEST`，摘要由 `changes diff` 印出。檢視畫面也會列出工作區中被 Git 忽略的路徑；驗證看不到它們，它們也不在 patch 內，不會進入你的分支。**Verify** 在由基準提交加上 patch 建立的拋棄式副本中執行，並位於 macOS 沙箱內：家目錄遭封鎖，但可使用網路，因此建置不含快取，而會自行啟動沙箱的指令碼須在設定 `AGENTBRIDGE_VERIFICATION_SANDBOX` 時關閉該功能。只有按下後才會執行 `.codex/ci.sh`，且會拒絕與固定提交版本不同的指令碼；請還原它，或以已核准的自訂驗證執行。自訂驗證需先明確核准，並以 executable 和分開的 argv 傳入；AgentBridge 不會組合 shell 命令。結果顯示 executable、參數、工作目錄、退出代碼、耗時及遮蔽後的 stdout/stderr。接受與套用只適用於已成功驗證的目前完整 diff。套用時須輸入本機 branch 名稱；AgentBridge 先檢查來源 Repository 仍有此工作階段的 base commit，再從該提交建立未提交 worktree；即使來源之後已前進也可以套用。AgentBridge 不會自行 commit、push 或 merge；唯一會 commit 與 push 的方式是下方經確認的拉取要求動作，且絕不 merge。

**Activity** 時間軸呈現排序後、已遮蔽的稽核事件，包括可取得的進度、計畫核准、取消、錯誤、diff 變化與驗證結果。只有官方 CLI 實際回報的 provider 輸出才會顯示。**Parallel task board** 列出所有工作階段實際啟動的操作、狀態、核准、進度、取消及 diff／驗證參照。App、CLI 與自主流程合計最多同時進行三個供應商執行（唯讀、變更與驗證執行），第四個會被拒絕，直到有一個結束；檢視差異、核准計畫、接受變更等操作不受此上限阻擋；共用的程序鎖也會阻止同一工作階段重複執行。請在對應任務按 **Cancel this session**。

若要將記憶延續到另一個 commit，請選擇相同 canonical Repository、不同提交版本的來源和目標工作階段。目標工作階段綁定的帳戶必須允許共用記憶。選取來源回合與／或備註，檢查來源／目標 commit，再建立交接。目標工作階段下一次允許的提示只會收到所選內容，並以有界（16 KiB）、標明不可信的歷史 JSON envelope 傳入且保留 provenance。交接存於所選工作區資料根目錄下的 `shared-memory/project-handoffs/`。原生 provider TUI transcript 永不匯入。

舊版擴充描述資料只是惰性中繼資料，其授權不會執行任何內容。App 已不再顯示舊的描述資料面板；請改用下方的 `extensions import`、`extensions grant` 與 `extensions revoke` CLI 命令管理。先前匯入的描述資料會保留。若要真正載入 Skill 指令或連接已安裝的 MCP，請依第 11 節使用 **Skills & MCP**。

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

#### 提交、推送並開啟拉取要求

套用之後，**Changes** 會顯示 branch 與 worktree，以及「提交、推送並開啟 PR…」按鈕。按下後會開啟一個視窗，讓你檢視並可修改：遠端（每個都附上網址；有 `origin` 時預設選它）、基準 branch（遠端預設 branch，取自 `refs/remotes/REMOTE/HEAD`，否則用 `gh repo view` 取得 GitHub 預設 branch，再否則用已存在的 `main` 或 `master`；都沒有時請自行輸入）、提交訊息、拉取要求標題與說明，以及「草稿拉取要求」（預設開啟）。訊息與說明由計畫的標題、摘要、步驟及驗證結果組成；不含提示詞或模型輸出；除非你按「用本機模型改寫」（見下方本機模型輔助），否則不會呼叫任何模型。在你確認之前不會執行任何動作；確認後會在套用 worktree 中提交、將 branch 推送到遠端，並在 GitHub 開啟拉取要求。你的程式碼會離開這台 Mac。不會合併任何內容。

- **提交：** 只有在 worktree 仍完全等於已驗證的 diff 時才會進行；驗證後若有修改或新增檔案就會停止。只會暫存並提交已驗證的檔案，使用 Repository 或你的 Git 設定中的身分。因為檔案來自模型，hook 一律不執行。
- **推送：** `git push -u REMOTE BRANCH:BRANCH`，絕不使用 force；branch 是基準 branch 或遠端預設 branch 時會拒絕。
- **拉取要求：** 以 `gh pr create` 搭配 `--base`、`--head`、標題、說明，除非你關閉，否則加上 `--draft`。若該 branch 已有開啟中的拉取要求，會記錄它而不再開新的。

必須安裝 GitHub CLI（`gh`，會在 PATH、`/opt/homebrew/bin` 與 `/usr/local/bin` 中尋找）並已登入。AgentBridge 只看 `gh auth status` 的結束代碼，絕不替你登入；若尚未登入，請在終端機執行 `gh auth login` 後再試一次。每個步驟成功時都會記錄在工作階段上。若某一步失敗，視窗會顯示是哪一步，「重試」會從該步繼續，不會產生第二個提交或拉取要求。重新套用到新 branch 會從頭開始。活動時間軸會記錄 `change.pr.committed`、`change.pr.pushed`、`change.pr.opened` 與 `change.pr.failed`，錯誤內容會先遮蔽。

AgentBridge 其他的 Git 指令使用私人 home 資料夾且不讀全域 Git 設定；這些指令則不同，會以你的 home 資料夾、PATH（另加 Homebrew 資料夾）、SSH agent（`SSH_AUTH_SOCK`）、gh 設定與 token 變數、GnuPG home 及 proxy 設定執行你自己的 Git 與 `gh`，讓身分、credential helper、SSH 金鑰、提交簽章與 gh 登入和在終端機中一樣運作。提示輸入已關閉，因此需要輸入的憑證會直接失敗而不會等待。不會傳入其他環境變數，provider 執行仍使用各自經過清理的環境。

```sh
"$CLI" changes pr "$SESSION_ID"            # 只列出將會執行的內容，不做任何變更
"$CLI" changes pr "$SESSION_ID" --base main --message-file msg.txt --body-file body.md --confirm
```

選項：`--remote NAME`、`--base BRANCH`、`--title TEXT`、`--body-file PATH`、`--message-file PATH`、`--no-draft`。沒有 `--confirm` 時只會列出預覽。失敗後再執行一次即可繼續。

#### 本機模型輔助

本機模型輔助讓你設定好的 Local 模型在 Codex 與 Claude 工作中撰寫文字草稿，不會呼叫 Codex 或 Claude。請在 Local 模型設定中開啟「本機模型輔助」（會先執行連線測試），再開啟需要的工作開關；預設全部關閉，開啟某項工作就是同意它送出要求。每個入口只在對應工作開啟時出現：

- 「提交、推送並開啟 PR…」視窗中的「用本機模型改寫」，會依計畫、檔案清單、驗證紀錄與已驗證的差異，草擬提交訊息與拉取要求標題、說明。
- 「變更」中失敗驗證結果下方的「說明這次失敗」，會用淺白文字說明原因並列出要檢查的檔案。「用作變更要求」會把說明複製到「草擬計畫」使用的「要變更什麼？」，不會送出。
- 「快速切換並接續到其他供應商 → 選填交接內容」中的「用本機模型草擬」，會依這段對話最近已儲存的回合，填入「已完成哪些工作？」、「接下來要做什麼？」與「建議下一個提示詞」。
- 「完整檔案差異」上方的「用本機模型摘要」，會顯示差異摘要與需要檢查的事項，並標示為模型的意見。

每個按鈕下方的「將送出的內容」可查看檔案、位元組數、為了放進上下文視窗而省略的部分與確切文字，且不會送出任何東西。每個回答都是草稿：你編輯過的文字只有在你同意後才會被取代，也不會套用、儲存或送出任何內容。沒有草稿時（輔助已關閉、服務沒有回應、逾時、達到 Local 上限或回答格式不符），會保留現有文字並以簡短提示說明原因。要求會計入 Local 上限，活動紀錄只記錄要求本身而不含內容；因為不會寫入共享記憶、專案記憶或交接檔案，所以不需要共享記憶同意。

```sh
"$CLI" local helper on                        # 會先執行連線測試
"$CLI" local helper on --commit-text --explain-failure --change-summary
"$CLI" changes pr "$SESSION_ID" --draft-text-with-local     # 印出草稿；不變更任何東西
"$CLI" changes verify "$SESSION_ID" 2>&1 | "$CLI" changes explain "$SESSION_ID" --exit-code 1
"$CLI" changes summarize "$SESSION_ID" --preview            # 將送出的內容；不送出
```

各工作送出的內容與截短方式，請見[本機模型與上下文](LOCAL_MODELS_AND_CONTEXT.zh-TW.md#本機模型輔助)。

#### Local 隔離變更

建立 Local 專案工作階段時選擇「隔離變更」。在 **Changes** 建立或草擬計畫，保存、檢視並明確核准。Local 計畫草稿只會傳送需求及工作區候選路徑清單，不會傳送檔案內容或共享記憶。

搜尋候選清單並選取要完整傳送的既有檔案。每行加入一個新檔相對路徑，輸入需求，並檢視輸入位元組數預覽，再選 **Generate changes with Local model** 執行。模型沒有工具，不能執行命令。回應必須是根層只有 summary 與 files 的單一 JSON 物件。每個檔案項目只能有 path、action、content；modify/create 的 content 是完整新 UTF-8 檔案內容，delete 可省略 content 或設為 null。AgentBridge 會先驗證完整回應再寫入，並顯示結果 diff 供檢視。

既有輸入必須是隔離工作區內未被 Git 忽略、無符號連結且為 UTF-8 的一般檔案，每個不超過 256 KiB。每個新檔路徑都要明確列出。回應上限為 200 個檔案操作、每個輸出檔 256 KiB、輸出內容合計 1 MiB、JSON 回應 2 MiB。輸入預算是上下文視窗減去輸出保留量和 512 token 緩衝，以每位元組一個 token 估算，最高 2 MiB。變更需求與計畫草稿上限為 8 KiB；超出預算會在連線模型前拒絕。由於模型會完整傳回每個變更的檔案，預覽也會顯示可能需要的輸出：所有選取檔案的完整內容，加上每個檔案項目（含新路徑）的路徑與 48 位元組，以及摘要與 JSON 外框的 512 位元組，並以每 token 一位元組對照輸出保留量。放不下時，執行會在連線模型前被拒絕；請選取較少或較小的檔案，或提高輸出保留量，例如 `agentbridge local configure --max-output N`。

驗證失敗後，**Fix with Local model** 可使用驗證輸出的最後 12 KiB 與最多 8 KiB 選填備註；按鈕不會執行驗證。修正也會傳送工作區中已變更的檔案，但只限檔案清單允許選取的檔案；二進位、大於 256 KiB、被 Git 忽略或其他無法選取的已變更檔案會列為未納入，模型在該輪無法變更它們。每次 Local 執行都會消耗計畫核准，下次執行前要重新檢視並核准計畫。沒有寫入任何內容的執行（回應無效、路徑被拒、逾時或取消）會保留先前的驗證結果，因此修正失敗後可重新核准計畫再修正一次。

CLI 使用相同流程：

~~~sh
"$CLI" session create --provider local --repo "$HOME/Projects/example" --changes
printf '%s' '支援新的檔案格式。' | "$CLI" changes draft SESSION_ID
"$CLI" changes plan SESSION_ID --title "更新 parser" --summary "支援新格式。" --step "更新解碼"
printf '%s\n' 'APPROVE REVIEW_DIGEST' | "$CLI" changes approve SESSION_ID PLAN_ID REVIEW_DIGEST
printf '%s' '依核准計畫完成修改。' | "$CLI" changes run SESSION_ID PLAN_ID REVIEW_DIGEST --file Sources/Parser.swift --new-file Sources/NewFormat.swift --preview
~~~

正式執行時移除 --preview。每個既有輸入加上 --file PATH，每個允許的新檔加上 --new-file PATH。修復時將失敗驗證輸出導入 changes fix SESSION_ID；--note、--command 與 --exit-code 可提供選填備註和失敗標籤。

### 10. 自主工作流程

開啟 **Autonomous Workflow**。畫面頂端顯示三個步驟：**1 目標**、**2 檢視計畫**、**3 執行**。目前步驟依所選執行紀錄的狀態而定；按 **New workflow** 回到步驟 1，標題列的 **Runs** 選單可開啟先前的執行紀錄或更新清單。

**1 目標。** 選擇來源 Repository 並填入具體目標。目標下方以三行摘要目前的角色、驗證與上限。按 **Check subscription sign-in** 確認每個角色的帳戶；呼叫只使用訂閱登入。在 **Generate plan** 上方開啟 **Share the exact implementation diff with the reviewer**：它預設關閉但為必要項目，且實作者與審查者的帳戶都必須已允許共享記憶。其餘設定都在預設收合的 **Advanced settings** 中：

- 規劃、調查、實作與審查角色的供應商與帳戶、各角色的模型與推理強度（預先帶入已儲存的預設值），以及各執行角色可使用的已啟用 Skills／MCP。有設定時，計畫摘要值會涵蓋各角色的模型與推理強度，因此核准後若要更改，就需要新的計畫。CLI 使用 `--planner-model`、`--planner-effort`，以及 `researcher`、`implementer`、`reviewer` 的同名選項；未指定的角色使用 CLI 預設。
- 並行數、審查修正輪數、時間與供應商呼叫上限；並行數和審查輪數最多三個／三輪。
- 驗證：專案 CI、不驗證，或已檢視的自訂執行檔。只有選擇自訂時才會出現路徑與參數欄位。
- 其他共享選擇。將任務輸出傳給相依角色預設關閉。保存最終摘要到專案記憶開啟時，才會要求選擇目標帳戶。
- 桌面控制聲明，只在實作者選了 Control 模式的 Mac Control 預設設定時出現。

**Generate plan** 無法使用時，原因會列在按鈕下方；若需要修改的設定在 Advanced settings 中，會附上開啟它的連結。**Generate plan** 會發出一次真正的唯讀規劃請求，不會核准或開始任何工作。

**2 檢視計畫。** 頁首先摘要變更範圍、任務數、上限、驗證與共享選擇，接著是任務圖（每個任務的提示各自收在展開區塊中）。帳戶、Skills／MCP 權限、驗證細節與來源指紋收在展開區塊；計畫包含桌面控制範圍時會直接顯示。若計畫包含凍結的專案記憶，請展開 **Inspect exact frozen project memory** 並勾選其確認；允許共享的角色會跨供應商與帳戶取得同一快照。勾選檢視確認後按 **Approve and start**：它會核准畫面上的摘要，且只有核准成功時才會開始流程。若執行紀錄已在其他地方核准（例如 CLI），或核准後開始失敗，則改顯示 **Start approved workflow**。**Cancel plan** 會取消計畫。綁定變更後必須產生新計畫並重新核准。

**3 執行。** 查看任務進度與審查／驗證結果。**Cancel all agents** 會停止派送並要求終止程序，中斷工作不自動重跑。完成後按 **Open final diff in Change Review**，在 **Project Conversations** 開啟實作者的隔離變更，沿用 diff、驗證、接受與套用控制。已核准的計畫保留在 **Approved plan details**，執行事件也有各自的展開區塊。不會自動 commit、push 或 merge。CLI 的 `autonomous` 提供相同規劃、核准、執行、狀態與取消操作；完整參數和 JSON 狀態輸出請查看 `agentbridge help`。

### 11. Skills、MCP 實際執行與 Mac Control

開啟 **Skills & MCP**。頂端一行顯示畫面要啟用的範圍：**套用於**所選專案工作階段的 Repository、供應商與帳戶設定檔。按 **Change…** 可改選其他 Repository、供應商、設定檔或範圍工作階段，或建立唯讀範圍工作階段（不會呼叫模型）。

用 **Add** 匯入：

- **Skill from SKILL.md…**：選擇檔案後確認 Skill ID、名稱與摘要。這些欄位會依檔案的 front matter 或所在資料夾名稱預先填入，可以修改。只保存指令文字，永不執行腳本或 hooks。
- **MCP server from JSON…**：已安裝本機 stdio MCP 的執行設定檔。
- **Mac Control preset…**：見下方說明。

匯入不執行任何內容。每個匯入項目是一列，顯示狀態（例如 **尚未測試**、**已測試 · 未啟用** 或 **已啟用 · 3 個工具**）和一個主要按鈕。MCP 伺服器會先顯示 **Test connection**：測試會啟動該本機程式進行初始化與工具查詢，因此會先要求確認。接著按 **Review and enable** 開啟檢視表單，內含執行檔、argv、允許與實際查得的工具、摘要、範圍與信任提醒（Skill 則顯示完整指令）。勾選同意後按 **Enable**；勾選同意即為確認。已啟用的項目提供 **Disable**，執行前會先確認。每列的選單有 **Show details** 和 **Test connection again**。舊中繼資料授權不足以啟用。設定變更和撤銷會使綁定失效，若要求請建立新工作階段。首版不支援遠端 HTTP／OAuth MCP。

**Mac Control**：選擇 **Add > Mac Control preset…**，選擇目標 App 或輸入 bundle ID，先使用 **Observe**，並自行開啟目標 App。按 **Check installed helper**，可再按 **Test permission readiness**（只讀取就緒狀態，不授予 macOS 權限；若需要，請手動授予輔助使用及螢幕錄製），然後匯入。預設設定會成為一列：先測試連線，再檢視並啟用。檢視表單對執行工具與傳送整個螢幕截圖分別要求同意，**Control** 另須同意輸入。受保護的系統、憑證、終端及 AgentBridge 目標會遭拒絕。截圖包含整個主螢幕且可能傳給所選供應商；目標限制的是輸入，不是圖片範圍，請先關閉私人視窗。已啟用的 Control 預設設定會顯示 **Stop Control**，撤銷範圍並要求取消，但無法撤回已送出的操作；列選單也可停止其他範圍的 Control。一般桌面同意不包含憑證、系統驗證、安全設定或重大交易。

產生流程計畫前，在 **Advanced settings** 為角色選擇已啟用擴充的 ID；核准會綁定其範圍與上限。Repository 唯讀不會使另外核准的外部工具變成唯讀。詳見[設計與驗證邊界](AUTONOMY_AND_EXTENSIONS.zh-TW.md)。

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
- **「先前的終端機程序仍在執行，因此重新顯示」：** App 內終端機的程序在面板關閉後仍未結束。在顯示出來的終端機裡結束它（先退出 CLI，再輸入 `exit`），然後關閉面板。為了找出原因，AgentBridge 會記錄每個終端機的啟動、關閉、取消、交接給 shell 與結束，以及該終端機上的程序編號、程序群組與執行檔名稱（前 16 個字元）。關掉訊息前，先把最近一小時的記錄存下來附在回報裡：

  ```bash
  /usr/bin/log show --last 1h --style compact --predicate 'subsystem BEGINSWITH "org.agentbridge"' > ~/Desktop/agentbridge-terminal.log
  ```

  記錄不含命令參數、路徑、環境變數、標題或終端機文字。

### 14. 簽署、公證與驗證 App

`scripts/package-app.sh` 會重建未簽署的 Universal（Apple Silicon 與 Intel）開發 App。準備好發行版本並通過 `.codex/ci.sh` 後，使用共用 `macos-notarization-release` helper 進行正式簽署與公證。helper 從使用者層級設定讀取 Apple 公證認證（Keychain profile 或 App Store Connect API key），與 Claude API key 分開；不要把簽署憑證或 Apple `.p8` 私鑰放進 Repository。App 簽署身份必須是 Developer ID Application。App 內的 `agentbridge` helper 要先簽署，再簽外層 App。

```sh
cd /path/to/AgentBridge
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
./scripts/verify-app-launch.sh "$APP"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP" "$PWD/build/AgentBridge-notarized.zip"
```

上傳用 ZIP 是送交 Apple 的載體；Apple 接受後，ticket 會 staple 到 `.app`，再以已 staple 的 App 建立交付 ZIP。驗證包含簽章、Gatekeeper 與 ticket。接著的啟動檢查會確認執行檔是 Universal、App 內有翻譯字串表，再移開本機建置輸出，實際以 arm64 和 Rosetta 下的 x86_64 啟動 App，只能在這台 Mac 上執行的版本會在產生交付 ZIP 前失敗。檢查時 App 視窗會以你保存的設定開啟幾秒。若 helper 回報逾時或結果未知，不要自動重送同一 artifact；先依 Apple 回傳的 submission ID 查明該次狀態。`doctor` 只檢查本機設定，不代表 Apple 已接受公證。重跑 `package-app.sh` 會覆寫 App 並移除既有簽章，之後需重新簽署、公證。

---
