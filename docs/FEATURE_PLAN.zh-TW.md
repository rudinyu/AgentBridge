# AgentBridge 功能計畫

- **狀態：** 提案
- **依據：** AgentBridge 0.10.0 工作樹、0.6.0 競品研究基準、[產品差距研究](PRODUCT_GAP_STUDY.zh-TW.md)及官方 CLI／API 文件
- **最後檢視：** 2026-11-02

[英文版](FEATURE_PLAN.md)

### 產品目標

把 AgentBridge 做成 Codex 與 Claude Code 共用的本機工作台：使用者能選擇實際登入的帳戶和方案、在隔離工作區完成工作、看懂 agent 做了什麼、審查每一項修改，並在明確授權下交付成果。產品沿用兩家的官方 CLI 和登入流程，不複製 provider 的憑證或重做其原生互動 TUI。

### 本次新增 — AgentBridge 0.10.0

新增明確連到本機回送位址的 Local 供應商，支援 Ollama 與相容服務，以及受管理對話共用的可讀上下文壓縮。首版聊天／唯讀範圍包含模型清單、上下文與輸出上限、取消、用量區分及上下文預覽。Local 的工具、隔離修改與自主角色尚未提供；受保護內容放不下時停止要求，不默默遺失。詳見[本機模型與上下文](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)。

### 前版新增 — AgentBridge 0.9.0

先開始可保存的聊天，再選擇 Git 專案。討論綁定供應商與帳戶，使用官方訂閱登入，切換供應商時依共享同意延續內容。經過檢視的交接可建立新本機 Git 專案，或連結既有 Repository；只有選取的完整回合會帶入獨立的專案記憶，原討論仍保留。詳見[先聊天，再建立 Git 專案](CHAT_FIRST_WORKFLOW.zh-TW.md)。

此版仍需要使用者選擇資料資料夾；聊天不需要 Repository、不會初始化 Git，也不使用 API credits。0.9.0 build 8 交付檔已通過簽章、Apple 公證、staple 與 Gatekeeper 檢查；0.10.0 須另行授權及驗證發佈。

### 前版新增 — AgentBridge 0.8.0

下一個功能版本加入只用訂閱的自主流程：產生並檢視相依任務圖、選擇角色帳戶、限制並行和修正輪數、審查完整 diff、執行已核准驗證，並保存狀態與支援取消。不會自動接受成果、commit、push 或 merge。每次供應商啟動仍受帳戶本機用量控制限制，角色間共享也遵守帳戶同意。

實際 Skills／MCP 與舊中繼資料登錄分開：核准的 Skill 指令快照會進入受管理提示；已安裝且核准的本機 stdio MCP 透過每次執行的工具過濾代理運作。匯入不執行；設定變更或撤銷會使授權失效。附帶腳本的 Skill、自動安裝與遠端 HTTP／OAuth MCP 不在首版執行器範圍。

Mac Control 以明確類型的預設整合提供：強制限制目標 App、預設觀察、另行同意控制、檢查權限就緒狀態並提供停止控制。截圖包含整個主螢幕且可能傳給所選供應商，不是目標視窗裁切。macOS 權限仍由使用者手動授予。架構、範圍與驗證邊界見[自主工作流程與擴充執行](AUTONOMY_AND_EXTENSIONS.zh-TW.md)。

0.8.0 build 7 交付檔已完成 Developer ID 簽章、Apple 公證、staple 與 Gatekeeper 驗證；這不代表 0.9.0 工作樹已通過發佈驗收。

### 歷史基準 — AgentBridge 0.6.0（2026-10-27）

AgentBridge 0.6.0 預設使用英文，並完整支援英文與繁體中文介面。使用者可在 App 標題列切換並保存語言；App 也已封裝兩種語言資源。

使用者選擇的工作區資料根目錄已實作。首次使用時，App 會請使用者選擇或建立資料夾；CLI 使用相同的已保存位置。隔離工作階段工作區與共用記憶放在該位置；私人設定、帳戶 profile、工作階段／稽核中繼資料、用量控制及預算帳本則留在 Application Support。變更根目錄時會複製既有工作區與記憶，不會刪除舊資料或覆寫衝突的目標資料。App 會拒絕選取 Git Repository 內的資料夾，包括 linked worktree。

跨 provider 的 App/CLI 記憶已支援相同 canonical 來源 Repository 和固定提交版本；是否共享仍依各帳戶 profile 的設定。原生 provider TUI transcript 不會匯入。使用者可明確選取 App 保存的回合與／或備註，將記憶延續到同一 canonical Repository 的不同提交版本；符合目標提交的交接會以有界、標示為不可信的 JSON 形式，連同來源／目標提交 provenance 傳入目標工作階段下一次提示。

以下四項競品研究優先功能均已在 0.6.0 實作：隔離且經核准計畫的修改、使用者啟動的驗證與活動紀錄、明確記憶交接，以及含惰性擴充權限中繼資料的任務看板。任務看板只記錄已啟動的操作；App 最多同時執行三個不同工作階段，CLI 操作會共用每工作階段執行鎖，但不受 App 的三工作階段上限限制。Descriptor 匯入與授權不會啟用 provider extension，也不會執行腳本。發佈仍維持「提案」狀態，直到簽署、公證、Gatekeeper 等驗收門檻完成。

目前工作目錄已部分實作 MUST-10：

- App 依帳戶顯示 AgentBridge 管理的近 5 小時、24 小時、7 天及所選工作階段執行次數，並提供近 7 天圖表。可設定訂閱模式本機執行次數上限，並在管理執行啟動前檢查。
- Claude API 活動與訂閱活動分開。App 與 CLI 共用帳戶範圍的月、日、工作階段及單次控制，包括內建 Claude 帳戶 US$140 月上限、新 Claude 帳戶必須自行設定的月上限、保守預留、最多一筆未結算呼叫，以及啟動前阻擋。
- 達到 50%、75%、90% 和 100% 時只提醒一次；提醒會顯示在 App，也可選擇 macOS 通知。上限變更與門檻事件保存在有筆數上限的本機稽核歷程。未知費用會繼續保留，直到使用者依 provider 帳單在 App 或 CLI 手動結算。
- 本 App 使用的官方介面沒有提供受支援、可機器讀取的訂閱額度百分比與重置資料。使用者明確在官方 CLI 啟動 `/usage` 後，儀表板會從有限長度的可見畫面文字盡力解析可辨識欄位並填入統一資料卡；未知欄位維持未提供。這不是結構化額度 API，官方 TUI 畫面仍是依據。原生 TUI 回合不會被記錄或限制。

MUST-10 尚未完成使用者自訂提醒門檻，以及選擇高用量門檻後、下次管理執行前要求確認的功能。MUST-11 的介面多語化已實作；Developer ID 簽章、公證、staple 與 Gatekeeper 驗證仍是發佈門檻。這份計畫仍為「提案」，直到上述項目與其他首版驗收門檻都完成。

### 競品研究的四項優先功能 — 0.6.0 已實作

以下優先順序參考 Codex、Claude Code、Cursor 和 Google Antigravity 的官方文件。摘要列出本機優先實作狀態；雲端執行與啟用 provider extension 不在此版本範圍。

1. **P0 — 安全修改與交付流程（MUST-03 至 MUST-05、MUST-07）。已實作。** 唯讀為預設。隔離變更工作階段只支援訂閱模式，且寫檔前必須明確核准可審查計畫；可檢視完整逐檔 diff、還原檔案、匯出 patch，或只在目前 diff 通過驗證後接受／套用。套用前檢查來源 base commit，並在具名本機 branch 建立未提交工作樹；不會自動 commit、push 或 merge。
2. **P0 — 活動與驗證（MUST-01、MUST-06、MUST-07）。已實作。** App 顯示排序後、已遮蔽的稽核事件及已啟動的任務記錄。驗證只在使用者啟動後執行，預設使用 `.codex/ci.sh`；自訂 executable 與獨立 argv 必須先明確核准。可呈現 provider CLI 實際回報的事件與驗證 executable、argv、工作目錄、退出狀態、耗時及可取得的遮蔽輸出；AgentBridge 不會宣稱 CLI 未提供的遙測資訊。
3. **P1 — 專案記憶與明確交接（MUST-08）。已實作。** 同一 Repository 不同 commit 間的記憶延續，必須明確選取 App 記憶回合／備註，且目標綁定帳戶允許共享記憶。只有符合目標 commit 的交接會放入目標工作階段下一次 provider 提示，作為有界、標示不可信且包含來源／目標 provenance 的歷史 JSON。原生 TUI transcript 不會匯入。
4. **P1 — 平行工作與受控擴充。以本機任務紀錄及惰性政策中繼資料實作。** 任務看板記錄實際啟動的操作、逐工作階段進度、核准狀態、取消及 diff／驗證參照。App 最多同時執行三個不同工作階段；CLI 也使用程序層級執行鎖，避免同一工作階段重複執行。Skills/MCP descriptor 只以惰性中繼資料匯入；明確的每專案授權只保存狹窄權限資料，不會啟用 extension、連接 MCP server 或執行安裝腳本。[Codex App](https://openai.com/index/introducing-the-codex-app/) · [Claude Code subagents／擴充功能](https://code.claude.com/docs/en/features-overview) · [Cursor Projects](https://cursor.com/docs/agent/projects) · [Antigravity 功能](https://antigravity.google/docs/features)

### 發佈前一定要完成

以下項目都是第一個可交付版本的必要條件；任何一項未通過驗收，都不應把「可安全修改程式碼」宣稱為完成。

| ID | 必做功能 | 必要行為與驗收條件 |
| --- | --- | --- |
| **MUST-01** | **專案與工作階段工作台** | 以 Project → Sessions/Tasks 導覽工作；工作區清楚提供 Chat、Changes、Terminal、Activity。每個工作階段可辨認標題、狀態和所屬專案。至少能找回目前及最近工作；搜尋、封存和進階篩選可在首版後補。 |
| **MUST-02** | **真實帳戶／方案切換** | Codex 與 Claude 各自顯示已登入的實際 profile、CLI 驗證狀態及 CLI 確認提供的方案資料；工作階段固定綁定建立時選定的帳戶。切換帳戶必須改變實際 CLI profile，不能只換 UI 標籤。新工作階段建立前可確認 provider、帳戶、方案回報、Repository 和 base commit。 |
| **MUST-03** | **清楚的執行模式與權限** | 提供唯讀分析、隔離修改、原生互動 CLI 三種清楚模式，預設唯讀。每次執行期間持續顯示 provider、帳戶、工作目錄、base commit、可寫範圍、網路／工具權限、memory 狀態和取消方式。原生互動模式保持 Codex/Claude 官方 TUI；不可假裝其逐字稿會被 AgentBridge 稽核。 |
| **MUST-04** | **隔離修改與可審查計畫** | 修改工作只能在 AgentBridge 管理的隔離 clone/worktree 與獨立 branch 進行，記錄 base commit；不得先改使用者來源工作樹。非微小修改先呈現可審查計畫，允許使用者調整、留言、核准或取消，再開始寫檔。取消或失敗須清理子程序，並保留清楚的工作區狀態。 |
| **MUST-05** | **Changes diff、接受與復原** | 顯示變更檔案清單及逐檔 diff；可拒絕單檔或整份結果、復原隔離工作區，或在確認後輸出 patch／套用到明確指定的本機 branch。套用前比對來源 Repository/base commit，來源已變動時停止並要求重新檢查。不得自動 commit、push 或 merge。 |
| **MUST-06** | **活動與核准時間軸** | 將計畫、工具／命令、核准要求、檔案變更、驗證結果、重試、錯誤、等待和取消狀態分段呈現；可展開安全遮蔽後的命令輸出。畫面能回答「現在在做什麼、動了哪些檔、是否需要我核准、是否完成」。取消必須能終止 AgentBridge 啟動的程序群組，且 UI 不可把仍在執行的程序標成已停止。 |
| **MUST-07** | **可核對的驗證結果** | 接受程式修改前，可在隔離工作區執行專案既有 `.codex/ci.sh` 或使用者選定的測試命令。執行前顯示命令與目標目錄；自訂命令須先核准，以 executable + argv 啟動，不得拼接 shell 命令；網路或較高權限操作須另行核准。日誌需遮蔽敏感資訊。逐項呈現輸出、退出碼、耗時和未執行原因。失敗不得顯示為成功。 |
| **MUST-08** | **跨供應商共享記憶與交接** | App/CLI 與 Codex/Claude 依同一來源 Repository canonical path + pinned commit 共用記憶；新增帳戶預設允許共享，帳戶可明確退出。每次執行前可查看哪些記憶會送入哪個 provider；工作階段需標示記憶來源與所屬帳戶。原生 TUI 不擷取 transcript；使用者可儲存有目標、決策、完成／未完成項、檔案、commit 和驗證結果的交接摘要。要把選取記憶延續到較新提交版本，必須由使用者明確審查和確認；不得自動混合 branch 或專案。 |
| **MUST-09** | **Claude API 授權與支出帳本** | 預設使用訂閱登入；訂閱額度用盡絕不可自動改用付費 API。只有明確選擇 Claude API 才顯示 API 控制；Codex 不得出現相關選項。每次呼叫都須提供當次 key、確認費用並設定單次上限；key 只提供給該次程序。App 與 CLI 共用依 Claude 帳戶 profile 分開的帳本，不可只憑顯示名稱合併帳戶。使用者目前的 Team 帳戶已知每月額度為 US$140，作為該帳戶的預設本機上限；新增的 Claude 帳戶必須另行設定自己的上限，不可沿用其他帳戶額度。啟動前保留並行呼叫的預算，超過剩餘額度就拒絕執行；費用未知時不能當成零。說明本機帳本看不到 AgentBridge 外的用量，也不是 Anthropic 端的硬上限。 |
| **MUST-10** | **額度檢視、通知與使用量控制** | 將 provider 回報的訂閱額度與 AgentBridge 計算的 API 支出分開。依所選帳戶和方案，分別顯示 provider 回報的每個用量週期，例如 5 小時／工作階段與每週額度，並列出用量／剩餘額度、重置時間、資料來源及最後更新時間。各 provider 和方案的額度週期不同；只顯示 provider 確認提供的週期，不假設每個方案都有兩種週期。只使用官方文件支援的 CLI 狀態／用量介面，不得擷取私人帳戶端點或原生 TUI transcript。沒有受支援的數字資料時標示「無法取得」，並提供官方狀態／用量指令供手動檢查。AgentBridge 自行追蹤的執行次數／回合數須另標為本機用量；provider 額度可能與其他官方 App 共用，因此不得宣稱本機用量代表整個帳戶。對每個可量測的額度週期，預設在 50%、75%、90% 各發一次可調整的 App 內與 macOS 通知；若僅能取得額度用盡／重置訊號，則依該訊號通知。各額度週期的重置時間可取得時分開顯示。達到 90% 等門檻時，可設定在下一次 AgentBridge 管理的工作前要求確認；確認額度用盡時暫停／阻擋新的 AgentBridge 管理工作，直到額度重置或使用者明確選擇下一步。絕不可自動切換付費 API 或其他帳戶。每個 Claude API 計費帳戶／預算池顯示本機月上限、已用、保留中、剩餘 AgentBridge 預算及重置日期／時間；不得把本機剩餘預算標成 provider 的實際 credit 餘額。API 預設在 50%、75%、90% 發出每期一次提醒；到達上限時提醒並硬性阻擋新呼叫。每帳戶可設定月、日、單一工作階段及單次呼叫上限；新增計費帳戶必須明確設定預算。付費呼叫預設最多同時一個，App 與 CLI 共用預留額度後才啟動。可為 AgentBridge 管理的訂閱工作階段設定每日／每工作階段的執行次數或回合上限。原生互動 TUI 的用量無法由 AgentBridge 完整計量或限制，啟動前須說明。使用者可調整提醒門檻並停用後續 Claude API 呼叫。關閉 macOS 通知不得解除用量限制或硬性阻擋。超限工作須在啟動前拒絕。上限變更、預留、結算、提醒和拒絕事件都須可稽核且不記錄祕密。取消進行中的呼叫不能撤銷已產生的費用，介面須提醒。 |
| **MUST-11** | **多語介面、分語言文件與可交付 App** | App 預設使用英文，並內建英文和繁體中文介面及可保存選擇的語言選單。README、Architecture、Feature Plan、How to Use 分別維護獨立的繁體中文版與英文版；功能變更需同步更新操作步驟和安全限制。正式對外散佈前，以 Developer ID 簽署 App 並完成 Apple 公證／staple 與 Gatekeeper 驗證；不得把未簽署開發包描述成已可安全安裝的正式版。 |

### 必要的工作流程

1. **開始：**選 Project/Repository → 選 provider → 選真實帳戶／方案 → 選唯讀、隔離修改或原生互動 → 檢視權限、base commit、memory 和任何 Claude API 預算。
2. **執行：**如需修改，先核准計畫；在隔離工作區執行。Activity 顯示 agent 進度、工具、核准、檔案與驗證狀態；使用者可取消。
3. **審查：**在 Changes 看完整 diff 和測試結果；逐檔拒絕或接受。套用成果前檢查來源版本沒有衝突，確認後輸出 patch 或套用到明確指定 branch。
4. **交接：**在相同 Repository/commit 切換 Codex/Claude；可檢視共享記憶來源並傳遞明確的交接摘要。不讀取或匯入 provider 私有 transcript。

### 首版驗收門檻

- 來源 Repository 在使用者接受成果前保持不變；取消、失敗與拒絕 diff 都不留下來源修改或孤兒程序。
- 任一修改工作階段可呈現 provider/account、base commit、權限、計畫、完整 diff、驗證結果和最後狀態。
- 切換 Codex/Claude profile 後，實際 CLI 使用對應帳戶；工作階段不會因全域帳戶切換而換帳戶。
- Codex UI 完全不顯示 Claude API；訂閱與付費 API 不會互相自動 fallback。每次 Claude API 呼叫都須明確授權並記入所選帳戶自己的帳本；目前 Team 帳戶預設為已知的 US$140 月上限，其他帳戶須另外設定上限。
- 額度面板分開呈現 provider 回報的訂閱額度和 API 支出；對 provider 實際回報的各個方案週期（包含適用時的 5 小時／工作階段及每週週期）分別顯示用量、剩餘額度、重置時間、資料來源與最後更新時間，不假設所有方案的週期相同。
- 訂閱額度提醒只能使用官方文件支援的機器可讀狀態／用量資料。沒有此類數字來源時標示「無法取得」，並提供由使用者明確啟動的官方 CLI `/usage` 畫面；啟動後可盡力解析有限長度的可見文字，未知欄位標示「未提供」。不得讀取任意終端逐字稿或私有端點；AgentBridge 本機執行次數／回合數須分開標示為估算，不得稱為帳戶整體用量。
- 預設在每個可量測額度週期的 50%、75%、90% 各通知一次。確認額度用盡後提醒並阻擋新的 AgentBridge 管理工作；可取得時分別顯示各週期的重置時間。不得自動改用 API 或切換帳戶。
- 使用者可設定在 90% 等門檻後，下一次 AgentBridge 管理工作開始前先要求確認。關閉 macOS 通知不會隱藏 App 內額度狀態或解除限制。
- API 月支出與上限維持獨立面板；達到 API 上限時通知並硬性阻擋新的付費呼叫。超出可用預算的呼叫須在啟動前拒絕。
- 每帳戶日／月、單一工作階段及單次呼叫上限須由 App 與 CLI 共用並確實執行；付費呼叫預設最多同時一個，且不得因並行競爭超出預留額度。使用者可降低上限、調整提醒門檻、停用後續 Claude API 呼叫。
- AgentBridge 管理的訂閱工作階段不得超過已設定的每日／每工作階段執行次數或回合數。原生互動 TUI 無法由 AgentBridge 完整計量或限制，啟動前必須明確告知。
- 上限變更、預留、結算、提醒和拒絕事件都可稽核且不含祕密。取消進行中的呼叫時，盡可能停止工作，並記錄供應商可能已開始計費。
- 使用相同 Repository/commit 的 Codex 與 Claude 能取得允許共享的記憶；新帳戶預設共享；退出後不再自動讀寫；來源和注入項目可查。將選取脈絡延續到不同提交版本時，必須由使用者明確審查，並顯示來源與目標提交；不得自動合併不同 branch 或專案。
- 有失敗／取消／CLI 格式變更時，畫面顯示實際錯誤，不偽裝成功或把未知費用記為零。
- 發佈候選版完成簽署、公證、staple 及 Gatekeeper 安裝驗證；雙語文件與 UI 操作相符。

### 後續工作，不阻擋首版

- 超出本次有限自主流程的定時／背景排程，以及手機與遠端監控。
- 目標受限的 Mac Control 之外，瀏覽器專用自動化、網頁預覽與錄影成果。計畫、diff、命令輸出與測試報告仍是主要持久化成果。
- 遠端 HTTP／OAuth MCP、Skill 腳本、hooks、自動安裝、GitHub issue／PR 與 Linear／Slack 整合。本機 stdio MCP 與 Skill 指令啟用由上方本次新增範圍涵蓋；舊中繼資料授權仍不執行。
- 附件、圖片、拖放、進階搜尋、重命名／封存批次操作、歷史用量分析／匯出、可收合欄位，以及英文與繁體中文以外的語言。
- 新增第三家模型供應商。先把 Codex/Claude 的安全修改、審查、交接和費用控制做完整。

### 明確不做

- 不複製 Antigravity、Codex 或 Claude 的完整 IDE/TUI；AgentBridge 負責跨 provider 的專案、權限、記憶、審查和預算控制。
- 不自動 commit、push、merge、升權、切換至 API 付費模式或在未經使用者明確同意時擴大 memory 分享範圍。
- 不從官方 CLI 複製 OAuth token，不解析 provider 私有 transcript，不將本機 Git clone/worktree 宣稱為 macOS OS sandbox。
- 不把 AgentBridge 的 US$140 本機帳本宣稱為 Anthropic 帳戶整體硬上限。

### 參考

- 產品差距研究：[PRODUCT_GAP_STUDY.zh-TW.md](PRODUCT_GAP_STUDY.zh-TW.md)
- 操作指南：[HOW_TO_USE.zh-TW.md](HOW_TO_USE.zh-TW.md)
- Google Antigravity：[Projects / Features](https://antigravity.google/docs/features) · [Artifacts](https://antigravity.google/docs/artifacts) · [Plans](https://antigravity.google/docs/implementation-plan) · [Changelog](https://antigravity.google/docs/changelog)
- Google Gemini Code Assist：[Agent mode](https://docs.cloud.google.com/gemini/docs/codeassist/use-agentic-chat-pair-programmer)
- OpenAI Codex：[Codex CLI](https://developers.openai.com/codex/cli) · [Codex App](https://openai.com/index/introducing-the-codex-app/)
- OpenAI Codex：[Codex 方案額度與重置方式](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex) · [使用 ChatGPT 方案中的 Codex](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)
- Anthropic Claude Code：[CLI overview](https://code.claude.com/docs/en/overview) · [Desktop](https://code.claude.com/docs/en/desktop) · [擴充功能](https://code.claude.com/docs/en/features-overview) · [Costs](https://code.claude.com/docs/en/costs)
- Anthropic Claude Code：[Pro／Max 方案用量](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan) · [Team／Enterprise 方案用量](https://support.claude.com/en/articles/11845131-use-claude-code-with-your-team-or-enterprise-plan) · [Slash commands](https://code.claude.com/docs/en/commands)
- Cursor：[Agent overview](https://cursor.com/docs/agent/overview) · [Projects](https://cursor.com/docs/agent/projects) · [Cloud Agents](https://cursor.com/docs/cloud-agent)
- Google Antigravity：[功能](https://antigravity.google/docs/features) · [Implementation plans](https://antigravity.google/docs/plan/)
