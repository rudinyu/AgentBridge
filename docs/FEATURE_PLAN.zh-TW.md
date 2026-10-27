# AgentBridge 功能計畫

- **狀態：** 提案
- **依據：** [產品差距研究](PRODUCT_GAP_STUDY.zh-TW.md)，AgentBridge 0.2.0 基線
- **最後檢視：** 2026-10-26

[英文版](FEATURE_PLAN.md)

### 產品目標

把 AgentBridge 做成 Codex 與 Claude Code 共用的本機工作台：使用者能選擇實際登入的帳戶和方案、在隔離工作區完成工作、看懂 agent 做了什麼、審查每一項修改，並在明確授權下交付成果。產品沿用兩家的官方 CLI 和登入流程，不複製 provider 的憑證或重做其原生互動 TUI。

### 實作狀態 — 2026-10-26

目前工作目錄已部分實作 MUST-10：

- App 依帳戶顯示 AgentBridge 管理的近 5 小時、24 小時、7 天及所選工作階段執行次數，並提供近 7 天圖表。可設定訂閱模式本機執行次數上限，並在管理執行啟動前檢查。
- Claude API 活動與訂閱活動分開。App 與 CLI 共用帳戶範圍的月、日、工作階段及單次控制，包括內建 Claude 帳戶 US$140 月上限、新 Claude 帳戶必須自行設定的月上限、保守預留、最多一筆未結算呼叫，以及啟動前阻擋。
- 達到 50%、75%、90% 和 100% 時只提醒一次；提醒會顯示在 App，也可選擇 macOS 通知。上限變更與門檻事件保存在有筆數上限的本機稽核歷程。未知費用會繼續保留，直到使用者依 provider 帳單在 App 或 CLI 手動結算。
- 本 App 使用的官方介面沒有提供受支援、可機器讀取的訂閱額度百分比與重置資料。儀表板會明確說明並提供官方 `/usage` 指令。原生 TUI 回合不會被記錄或限制。

MUST-10 尚未完成使用者自訂提醒門檻，以及選擇高用量門檻後、下次管理執行前要求確認的功能。這份計畫仍為「提案」，直到上述項目與其他首版驗收門檻都完成。

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
| **MUST-08** | **跨供應商共享記憶與交接** | App/CLI 與 Codex/Claude 依同一來源 Repository canonical path + pinned commit 共用記憶；新增帳戶預設允許共享，帳戶可明確退出。每次執行前可查看哪些記憶會送入哪個 provider；工作階段需標示記憶來源與所屬帳戶。原生 TUI 不擷取 transcript；使用者可儲存有目標、決策、完成／未完成項、檔案、commit 和驗證結果的交接摘要。 |
| **MUST-09** | **Claude API 授權與支出帳本** | 預設使用訂閱登入；訂閱額度用盡絕不可自動改用付費 API。只有明確選擇 Claude API 才顯示 API 控制；Codex 不得出現相關選項。每次呼叫都須提供當次 key、確認費用並設定單次上限；key 只提供給該次程序。App 與 CLI 共用依 Claude 帳戶 profile 分開的帳本，不可只憑顯示名稱合併帳戶。使用者目前的 Team 帳戶已知每月額度為 US$140，作為該帳戶的預設本機上限；新增的 Claude 帳戶必須另行設定自己的上限，不可沿用其他帳戶額度。啟動前保留並行呼叫的預算，超過剩餘額度就拒絕執行；費用未知時不能當成零。說明本機帳本看不到 AgentBridge 外的用量，也不是 Anthropic 端的硬上限。 |
| **MUST-10** | **額度檢視、通知與使用量控制** | 將 provider 回報的訂閱額度與 AgentBridge 計算的 API 支出分開。依所選帳戶和方案，分別顯示 provider 回報的每個用量週期，例如 5 小時／工作階段與每週額度，並列出用量／剩餘額度、重置時間、資料來源及最後更新時間。各 provider 和方案的額度週期不同；只顯示 provider 確認提供的週期，不假設每個方案都有兩種週期。只使用官方文件支援的 CLI 狀態／用量介面，不得擷取私人帳戶端點或原生 TUI transcript。沒有受支援的數字資料時標示「無法取得」，並提供官方狀態／用量指令供手動檢查。AgentBridge 自行追蹤的執行次數／回合數須另標為本機用量；provider 額度可能與其他官方 App 共用，因此不得宣稱本機用量代表整個帳戶。對每個可量測的額度週期，預設在 50%、75%、90% 各發一次可調整的 App 內與 macOS 通知；若僅能取得額度用盡／重置訊號，則依該訊號通知。各額度週期的重置時間可取得時分開顯示。達到 90% 等門檻時，可設定在下一次 AgentBridge 管理的工作前要求確認；確認額度用盡時暫停／阻擋新的 AgentBridge 管理工作，直到額度重置或使用者明確選擇下一步。絕不可自動切換付費 API 或其他帳戶。每個 Claude API 計費帳戶／預算池顯示本機月上限、已用、保留中、剩餘 AgentBridge 預算及重置日期／時間；不得把本機剩餘預算標成 provider 的實際 credit 餘額。API 預設在 50%、75%、90% 發出每期一次提醒；到達上限時提醒並硬性阻擋新呼叫。每帳戶可設定月、日、單一工作階段及單次呼叫上限；新增計費帳戶必須明確設定預算。付費呼叫預設最多同時一個，App 與 CLI 共用預留額度後才啟動。可為 AgentBridge 管理的訂閱工作階段設定每日／每工作階段的執行次數或回合上限。原生互動 TUI 的用量無法由 AgentBridge 完整計量或限制，啟動前須說明。使用者可調整提醒門檻並停用後續 Claude API 呼叫。關閉 macOS 通知不得解除用量限制或硬性阻擋。超限工作須在啟動前拒絕。上限變更、預留、結算、提醒和拒絕事件都須可稽核且不記錄祕密。取消進行中的呼叫不能撤銷已產生的費用，介面須提醒。 |
| **MUST-11** | **分語言文件與可交付 App** | README、Architecture、Feature Plan、How to Use 分別維護獨立的繁體中文版與英文版；功能變更需同步更新操作步驟和安全限制。正式對外散佈前，以 Developer ID 簽署 App 並完成 Apple 公證／staple 與 Gatekeeper 驗證；不得把未簽署開發包描述成已可安全安裝的正式版。 |

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
- 訂閱額度提醒只能使用官方文件支援的狀態／用量資料。沒有受支援的數字來源時標示「無法取得」，並提供官方 CLI 手動檢查方式；AgentBridge 本機執行次數／回合數須分開標示為估算，不得稱為帳戶整體用量。
- 預設在每個可量測額度週期的 50%、75%、90% 各通知一次。確認額度用盡後提醒並阻擋新的 AgentBridge 管理工作；可取得時分別顯示各週期的重置時間。不得自動改用 API 或切換帳戶。
- 使用者可設定在 90% 等門檻後，下一次 AgentBridge 管理工作開始前先要求確認。關閉 macOS 通知不會隱藏 App 內額度狀態或解除限制。
- API 月支出與上限維持獨立面板；達到 API 上限時通知並硬性阻擋新的付費呼叫。超出可用預算的呼叫須在啟動前拒絕。
- 每帳戶日／月、單一工作階段及單次呼叫上限須由 App 與 CLI 共用並確實執行；付費呼叫預設最多同時一個，且不得因並行競爭超出預留額度。使用者可降低上限、調整提醒門檻、停用後續 Claude API 呼叫。
- AgentBridge 管理的訂閱工作階段不得超過已設定的每日／每工作階段執行次數或回合數。原生互動 TUI 無法由 AgentBridge 完整計量或限制，啟動前必須明確告知。
- 上限變更、預留、結算、提醒和拒絕事件都可稽核且不含祕密。取消進行中的呼叫時，盡可能停止工作，並記錄供應商可能已開始計費。
- 使用相同 Repository/commit 的 Codex 與 Claude 能取得允許共享的記憶；新帳戶預設共享；退出後不再自動讀寫；來源和注入項目可查。
- 有失敗／取消／CLI 格式變更時，畫面顯示實際錯誤，不偽裝成功或把未知費用記為零。
- 發佈候選版完成簽署、公證、staple 及 Gatekeeper 安裝驗證；雙語文件與 UI 操作相符。

### 之後再做，不阻擋首版

- 多工作階段背景任務中心、平行寫入 agent、排程、手機／遠端監控。
- 瀏覽器自動化、網頁預覽、截圖／錄影 artifacts；首版先完整支援計畫、diff、命令輸出和測試報告等文字 artifacts。
- Skills/MCP/hooks 目錄、GitHub issue/PR、Linear/Slack 等服務整合。
- 附件、圖片、拖放、進階搜尋、重命名／封存批次操作、歷史用量分析／匯出、可收合欄位與完整英文 UI。
- 新增第三家模型供應商。先把 Codex/Claude 的安全修改、審查、交接和費用控制做完整。

### 明確不做

- 不複製 Antigravity、Codex 或 Claude 的完整 IDE/TUI；AgentBridge 負責跨 provider 的專案、權限、記憶、審查和預算控制。
- 不自動 commit、push、merge、升權、切換至 API 付費模式或擴大 memory 分享範圍。
- 不從官方 CLI 複製 OAuth token，不解析 provider 私有 transcript，不將本機 Git clone/worktree 宣稱為 macOS OS sandbox。
- 不把 AgentBridge 的 US$140 本機帳本宣稱為 Anthropic 帳戶整體硬上限。

### 參考

- 產品差距研究：[PRODUCT_GAP_STUDY.zh-TW.md](PRODUCT_GAP_STUDY.zh-TW.md)
- 操作指南：[HOW_TO_USE.zh-TW.md](HOW_TO_USE.zh-TW.md)
- Google Antigravity：[Projects / Features](https://antigravity.google/docs/features) · [Artifacts](https://antigravity.google/docs/artifacts) · [Plans](https://antigravity.google/docs/implementation-plan) · [Changelog](https://antigravity.google/docs/changelog)
- Google Gemini Code Assist：[Agent mode](https://docs.cloud.google.com/gemini/docs/codeassist/use-agentic-chat-pair-programmer)
- OpenAI Codex：[Codex CLI](https://developers.openai.com/codex/cli)
- OpenAI Codex：[Codex 方案額度與重置方式](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex) · [使用 ChatGPT 方案中的 Codex](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)
- Anthropic Claude Code：[CLI overview](https://code.claude.com/docs/en/overview) · [Costs](https://code.claude.com/docs/en/costs)
- Anthropic Claude Code：[Pro／Max 方案用量](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan) · [Team／Enterprise 方案用量](https://support.claude.com/en/articles/11845131-use-claude-code-with-your-team-or-enterprise-plan) · [Slash commands](https://code.claude.com/docs/en/commands)
