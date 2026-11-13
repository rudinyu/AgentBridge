# 先聊天，再建立 Git 專案

[English](CHAT_FIRST_WORKFLOW.md)

## 使用流程

先按 **New Chat**，與 Codex、Claude 或已設定的 Local 模型討論想法、需求及取捨，不必先選儲存庫。方向明確後，再選 **Create Git Project** 或 **Link Existing Project**，檢視完整脈絡與目的位置，確認後延續為一般專案對話。

第一次使用仍須選擇資料存放資料夾，供聊天資料與專案記憶使用；這個資料夾不是 Git 專案，也不必包含儲存庫。建立聊天或傳送訊息都不會初始化 Git 或複製儲存庫。

## 討論身分與帳戶

每段討論有獨立 UUID、版本、逐字稿及供應商／帳戶設定，不使用虛構的儲存庫路徑或提交。雲端訊息使用明確綁定帳戶的官方 CLI 訂閱登入，Local 使用設定好的本機回送服務。討論不使用既有專案的 Claude API 模式，也不會自動使用 API 額度。

切換供應商與帳戶只改變該段討論，不改寫全域帳戶選擇。每次執行不續用原生供應商 session ID，而是將符合資格的先前回合，以有界、遮蔽的 App 脈絡提供給下一次呼叫。

執行使用全新、空白、私有的暫存目錄。Codex 採官方非 Git 執行選項與唯讀限制，關閉 shell、代理、目標與網頁搜尋工具，使用暫時工作階段並忽略使用者設定。Claude 採受限列印模式，不啟用工具，使用嚴格空白 MCP 設定並停用提示歷史。討論不會取得專案 Skill、MCP、桌面控制、Git 修改或自主代理權限。

## 逐字稿與共享脈絡

逐字稿存於使用者選擇的資料根目錄下 discussions 資料夾。當次提示一定會送給所選供應商，成功回應會顯示在同一段討論；保存前先限制大小並遮蔽敏感資訊。

預設允許分享，仍受帳戶同意限制。只有已完成、可分享、保存時來源帳戶允許共享，而且來源與目標帳戶目前都同意的回合，才會進入後續提示或專案交接。關閉分享會保留本機可見逐字稿，同時將該回合排除於後續脈絡與移轉之外；仍可正常傳送當次訊息。

變更資料根目錄時會在衝突檢查後複製討論，保留原始資料；正在傳送或交接專案時會拒絕變更。討論也受既有本機帳戶用量限制與取消控制；本機計數不是供應商的實際訂閱額度。

## 建立或連結專案

1. 選擇新的絕對資料夾路徑，或既有 Git 儲存庫。
2. 指定目標供應商／帳戶及要延續的已完成、可分享回合。
3. 預覽完整內容、來源版本、目的位置、模式與摘要；既有儲存庫也綁定目前 HEAD。
4. 確認這份預覽。討論內容、同意、目的位置或 HEAD 變更時，須重新預覽。
5. 開啟建立的一般專案工作階段；原始討論仍保留。

新專案只建立本機儲存庫及空白初始提交，讓既有工作區流程能固定真實提交。不提交逐字稿、不新增遠端、不發佈或推送。新目的位置不可已存在、經過符號連結，或位於另一個儲存庫內。

連結既有專案只讀取已提交狀態並建立原有的隔離工作區，不修改來源儲存庫的檔案、設定或歷史。

核准回合另行複製到 AgentBridge 專案記憶，依 canonical 儲存庫與固定提交區分，不放入原始碼檔案或 Git 提交。之後的修改、驗證及套用仍沿用既有核准邊界。

## 容量限制

最多保存 64 個討論，每個討論保存 256 個回合，每則文字上限 64 KiB，編碼後每份紀錄上限 4 MiB。新寫入超限會被拒絕，不默默縮短較早原文；舊版本截短標記仍保留。每次專案交接最多選取 40 個回合，同一討論版本最多保存四份有效預覽；完成交接或繼續討論後可淘汰過期預覽。可讀上下文壓縮另有模型輸入預算，詳見[本機模型與上下文](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)。

## CLI

先設定一次資料根目錄，再使用下列命令；提示從有界標準輸入讀取。

```sh
agentbridge workspace set /absolute/path/to/data
agentbridge chat new --provider codex
agentbridge chat send CHAT-ID < prompt.txt
agentbridge chat send CHAT-ID --no-share < private-prompt.txt
agentbridge chat target CHAT-ID --provider claude --profile PROFILE-ID
agentbridge chat project preview CHAT-ID --mode new --path /absolute/path/to/new-project --provider codex --profile PROFILE-ID
agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm
```

使用 existing 模式可連結既有儲存庫。CLI 預設為唯讀；changes 會建立隔離變更工作階段，interactive 會建立原生互動終端工作階段（僅限訂閱登入模式）。在 App 中，交接預設為原生互動終端；本機模型或 API 模式則為唯讀。不指定回合時選取已完成、符合共享條件的回合；重複使用 --turn TURN-ID 可選擇明確子集；--no-context 則明確不帶入任何回合，允許私人聊天轉入不共享內容的專案。套用前請完整檢視輸出內容。

## 驗證與狀態

可重現測試使用假 CLI、本機 HTTP 回覆與測試儲存庫；真實模型、GUI 操作、簽章及公證是分開的驗證層。最新的 0.9.0 簽章發佈版與 0.10.0 開發版分開保存。

完整結果與畫面驗收缺口見 [0.9.0 驗證紀錄](CHAT_FIRST_VALIDATION.zh-TW.md)。

非 Git 執行方式已核對本機 Codex 0.166.0 與 [Codex 官方非互動文件](https://learn.chatgpt.com/docs/non-interactive-mode)，控制項參見[官方設定文件](https://developers.openai.com/codex/config-reference)。Claude 的列印模式與設定參數已核對本機 Claude Code 2.1.309 及[官方 CLI 文件](https://code.claude.com/docs/en/cli-reference)。此查核僅使用說明、版本輸出與文件，未呼叫真實模型。
