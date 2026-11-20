# 本機模型與可讀的上下文壓縮

[English](LOCAL_MODELS_AND_CONTEXT.md)

## 供應商邊界

AgentBridge 0.10 在 Codex、Claude 之外新增明確的 Local 供應商。選擇 Local 會直接連到這台 Mac 上已啟動的模型服務，不會變更預設雲端供應商、使用 CLI 訂閱、收集 API key 或退回付費服務。只有在 Ollama 引導設定中按「下載模型」，或執行 `agentbridge local pull MODEL --confirm` 時，才會下載模型。

支援 Ollama 原生聊天 API，以及包含 LM Studio 在內的 OpenAI 相容本機聊天介面。預設服務根位址分別為 `http://127.0.0.1:11434` 與 `http://127.0.0.1:1234/v1`。只有明確操作才查詢模型；服務沒有已安裝模型時，會如實顯示。

只接受本機回送位址，拒絕遠端主機、網址內的帳密、重新導向與隱含 HTTP 代理。Ollama 的雲端模型名稱及服務回報的遠端模型資訊也會被拒絕。AgentBridge 的網路邊界限於它與本機服務之間的連線；服務本身的轉送行為仍由其操作者負責。若要從服務層停用 Ollama 雲端功能，請依官方 FAQ 設定，AgentBridge 不會自行改動全域服務。

Local 支援專案前的討論、唯讀專案對話，以及經計畫核准的隔離變更。唯讀對話只取得已同意的 App 記憶；選取專案不會因此獲得檔案或命令工具。Local 變更工作階段只會把核准計畫、使用者需求、選取檔案的完整內容，以及明確列出的新路徑傳給本機回送模型。模型沒有工具，也不會執行命令。Local 仍不支援原生 CLI 終端、自主工作流程角色、實際 Skills／MCP 或桌面控制。

## 設定與使用

先自行啟動服務並準備模型。在 AgentBridge 選 **Local**，選擇後端、填入本機回送位址、更新模型清單並選取模型，再保存上下文容量與輸出上限。連線檢查只查詢模型，不會產生模型回覆。

Local 有獨立的帳戶／設定檔識別與共享同意。切換 Local、Codex、Claude 時，可以延續符合條件的 App 記憶；仍須符合來源帳戶當時及目前的同意，以及目標帳戶目前的同意。服務位址與模型是本機後端設定，不是訂閱方案或雲端憑證。

Local 執行次數與服務回報的 token 用量，會與 Codex／Claude 訂閱計數及 Claude API 費用分開。服務未回報 token 時即為未提供；依文字位元組估算的容量不會當成模型實際 token 用量。

首版 Local 的固定 App 上限為：每個設定檔滾動 24 小時最多 200 次已授權執行嘗試，每個討論／工作階段最多 50 次。畫面會一起顯示本機計數；這不是服務配額或帳單。服務有回報模型容量時，設定的上下文視窗不得超過它。

選好共用工作區資料資料夾後，CLI 會使用相同設定：

```sh
agentbridge local configure --backend ollama --endpoint http://127.0.0.1:11434 --model MODEL-ID --context-window 8192 --max-output 1024
agentbridge local models
agentbridge local test
agentbridge chat new --provider local
agentbridge local preview discussion CHAT-ID < prompt.txt
agentbridge chat send CHAT-ID < prompt.txt
```

相容服務使用 `--backend openai-compatible` 及其服務根位址，例如 `http://127.0.0.1:1234/v1`。`local preview project SESSION-ID` 可預覽唯讀專案組成的輸入。保存設定與預覽不會啟動推論；只有送出聊天或執行專案回合才會呼叫模型。

## Local 隔離變更

Local 隔離變更可在訂閱或 Claude API 用量模式下使用。建立專案工作階段時選擇「隔離變更」；Local 不提供原生互動終端。第一次「草擬計畫」只會傳送使用者需求與工作區候選路徑清單，不會傳送檔案內容。檢視並保存計畫後，還要明確核准才能執行。Local 變更執行不包含共享記憶。

在 **Changes** 選取既有候選檔案、加入新的相對路徑、輸入需求，並先檢視位元組數預覽。預覽會列出完整提示大小與輸入預算：設定的上下文視窗減去輸出保留量與 512 token 緩衝，以一 token 對一位元組估算，最高 2 MiB。變更需求與計畫草稿上限為 8 KiB；修復備註也相同。修復執行只會加入失敗驗證輸出的最後 12 KiB。超出預算的輸入會在連線模型前拒絕。模型必須傳回完整檔案內容，因此預覽也會估算輸出：所有選取檔案的完整內容，加上每個檔案項目（含新路徑）的路徑與 48 位元組，以及摘要與 JSON 外框的 512 位元組。這個估算會對照輸出保留量（`maxOutputTokens`，每 token 一位元組）；放不下的執行會在連線模型前拒絕，並記錄為 `local.change.rejected`、`reason=output_over_budget`。請選取較少或較小的檔案，或以 `agentbridge local configure --max-output N` 提高保留量。預覽與候選檔案清單只讀取工作區，不會占用工作階段的執行鎖，因此預覽不會阻擋執行；App 會在輸入停頓片刻後才更新預覽，工作階段執行期間則暫停預覽。

模型沒有工具，不能執行命令。既有輸入必須是隔離工作區內未被 Git 忽略、無符號連結且為 UTF-8 的一般檔案，每個最多 256 KiB。模型最多可回傳 200 個檔案操作；每個路徑都必須已選取或明確列為新檔；每個輸出檔最多 256 KiB，所有輸出內容合計最多 1 MiB，完整 JSON 回應最多 2 MiB。路徑必須為相對路徑；拒絕絕對路徑、空元件、. 與 .. 元件、控制字元及 .git 元件。全部操作會先驗證再寫入。寫檔使用暫存檔，若任一寫入失敗就回復。

模型回覆必須完全符合以下 JSON 物件，不可包含說明文字、Markdown 圍欄或 diff：

~~~json
{"summary":"變更摘要","files":[{"path":"相對路徑","action":"modify|create|delete","content":"完整的新檔案內容"}]}
~~~

每個檔案項目只能包含 path、action、content。modify 與 create 必須提供完整 UTF-8 檔案內容；delete 可省略 content 或使用 null。App 會把結果顯示為 diff 供檢視。驗證失敗後會顯示「以 Local 模型修復」及選填備註；按鈕本身不會執行驗證。修復只會加入檔案清單規則下可選取的已變更檔案；其他檔案（二進位、超過 256 KiB、被 Git 忽略或未列出）會列為未納入，該輪無法修改，而你明確選取的檔案仍必須可選取。每次修復都會消耗目前計畫核准，下次執行前必須重新核准檢視過的計畫。只有在執行實際寫入工作區時才會重設驗證與接受狀態；沒有寫入的執行會保留它們，因此修復失敗後可重新核准並再試一次。

CLI 使用相同流程：

~~~sh
agentbridge session create --provider local --repo /path/to/repo --changes
printf '%s' '支援新的檔案格式。' | agentbridge changes draft SESSION-ID
agentbridge changes plan SESSION-ID --title '更新 parser' --summary '支援新格式。' --step '更新解碼'
printf '%s\n' 'APPROVE REVIEW_DIGEST' | agentbridge changes approve SESSION-ID PLAN-ID REVIEW_DIGEST
printf '%s' '依核准計畫完成修改。' | agentbridge changes run SESSION-ID PLAN-ID REVIEW_DIGEST --file Sources/Parser.swift --new-file Sources/NewFormat.swift --preview
~~~

正式執行時重複最後一個命令並移除 --preview。修復時將失敗驗證輸出透過標準輸入提供給 agentbridge changes fix SESSION-ID；可用 --file 和 --new-file 選取額外輸入、用 --note 提供有限長度備註，並以 --command／--exit-code 標示失敗檢查。模型寫檔前仍須完成預覽與計畫核准；Local 輸出不會傳給 Codex 或 Claude。

## Ollama 引導設定

Local 模型設定最上方的「Ollama 引導設定」，適合還沒設定 Ollama 時使用。「檢查 Ollama 設定」會在 PATH、`/opt/homebrew/bin`、`/usr/local/bin` 與 `/Applications/Ollama.app` 內尋找 `ollama` 指令，並向 Ollama 端點查詢模型清單：後端是 Ollama 時用設定的端點，否則用 `http://127.0.0.1:11434`。除此之外，沒有你的點按就不會做任何事：

- **尚未安裝：**「開啟 Ollama 下載頁面」會在瀏覽器開啟 <https://ollama.com/download>，由你自行安裝。
- **已安裝但未執行：**「啟動 Ollama」會對 Ollama 應用程式執行 `open -a`，讓它像你自己開啟的 App 一樣獨立執行，不是 AgentBridge 底下的隱藏子程序。沒有 App 套件時，會顯示 `ollama serve` 讓你在「終端機」執行。
- **執行中：**依這台 Mac 的實體記憶體建議程式碼模型，也可以輸入其他任何名稱。「下載模型」會對 Ollama 端點執行 `ollama pull NAME`（以參數傳遞，絕不經過 shell），顯示進度且可取消。完成後，Local 設定會改用 Ollama 後端與這個模型並儲存，然後執行連線測試。

| 實體記憶體 | 建議模型 | 下載量 |
| --- | --- | --- |
| 少於 12 GB | `qwen2.5-coder:3b` | 約 1.9 GB |
| 12 GB 以上 | `qwen2.5-coder:7b` | 約 4.7 GB |
| 24 GB 以上 | `qwen2.5-coder:14b` | 約 9 GB |
| 48 GB 以上 | `qwen2.5-coder:32b` | 約 20 GB |

這張表是 Core 中的單一常數（`OllamaSetup.recommendations`），每次發布前都會對照 [Ollama 模型庫](https://ollama.com/library) 檢查名稱。CLI 也有相同步驟：

```sh
agentbridge local setup-check
agentbridge local pull qwen2.5-coder:7b --confirm
```

## 本機模型輔助

本機模型輔助讓設定好的 Local 模型，在 Codex 與 Claude 工作中為小型工作撰寫文字草稿。它不是供應商，也絕不呼叫 Codex 或 Claude。它使用與 Local 相同的端點、模型、上下文視窗與輸出保留量，也使用相同的上限：每次輔助要求都算一次已授權嘗試，計入 Local 設定檔滾動 24 小時 200 次的上限，以及所協助工作階段每個 50 次的上限。服務回報的 token 數會記在 Local 設定檔下，與 Codex、Claude 分開。

Local 模型設定中的「本機模型輔助」是總開關，下方每項工作各有一個開關，預設全部關閉。開啟總開關時，會用已儲存的 Local 設定執行連線測試；服務沒有列出設定的模型時就維持關閉。CLI 是 `agentbridge local helper show|on|off [--commit-text] [--explain-failure] [--handoff] [--change-summary]`；`on`、`off` 加上工作旗標時切換那些工作，不加時切換總開關。

| 工作 | 位置 | 送出的內容 | 回答 |
| --- | --- | --- | --- |
| 提交與拉取要求文字 | 「提交、推送並開啟 PR…」視窗中的「用本機模型改寫」；`changes pr SESSION-ID --draft-text-with-local` | 計畫的標題、摘要與步驟；變更檔案及其新增、刪除行數；AgentBridge 記錄的驗證指令與結果；套用工作樹中已驗證的差異 | 一個剛好含 `commitSubject`、`commitBody`、`prTitle`、`prBody` 的 JSON 物件 |
| 說明失敗的驗證 | 「變更」中失敗驗證下方的「說明這次失敗」；`changes explain SESSION-ID` | 驗證指令、結束代碼、輸出的最後部分（最多 12 KiB）與變更檔案清單，不含差異 | 純文字：出了什麼問題、要檢查哪些檔案 |
| 交接摘要 | 「快速切換並接續到其他供應商 → 選填交接內容」中的「用本機模型草擬」 | 這段對話最近已儲存的回合（最多 8 個，每邊最多 4 KiB）與儲存庫資料夾名稱 | 一個剛好含 `done`、`next`、`prompt` 的 JSON 物件 |
| 摘要變更 | 「完整檔案差異」面板中的「用本機模型摘要」；`changes summarize SESSION-ID` | 變更檔案及行數，以及差異 | 純文字：摘要與需要檢查的事項 |

### 同意

開啟輔助與某項工作的開關，就是同意該工作送出要求。與 Local 對話不同，輔助要求**不**需要來源帳戶或 Local 設定檔的共享記憶同意。這是刻意的例外：要求只會送到這台 Mac 的迴路端點，而且輔助要求送出或收到的任何內容，都不會寫入共享記憶、專案記憶、交接檔案或供應商歷史。稽核紀錄會記下 `local_helper.started`、`local_helper.finished`、`local_helper.failed`，內容只有工作種類、位元組數與輸入是否被截短，絕不包含提示或回答。

### 送出什麼、如何放進上下文

所有送出的內容都會像其他輸出一樣先遮蔽敏感資訊。差異預設完整送出。為了放進 Local 上下文視窗，AgentBridge 使用與 Local 上下文預覽相同的位元組預算：上下文視窗減去輸出保留量與 512 token 安全邊際，以一個位元組對一個 token 估算。指示、計畫、驗證紀錄與完整檔案清單一定會送出；接著依序放入各檔案的差異，直到放不下為止。有檔案沒送出時，提示會寫「已截短：只送出前 N 個檔案（共 M 個）。」連第一個都放不下時，會送出它的開頭並在行尾截斷。差異太長而無法顯示的檔案不會送出，它之後的檔案也不會。失敗說明只送出放得下的輸出最後部分；交接摘要則送出放得下的最新回合。

每個入口都有「將送出的內容」，可在不送出任何東西的情況下，查看檔案及其位元組數、其他部分、截短提示與確切文字。CLI 的 `changes explain` 與 `changes summarize` 可加 `--preview`，`changes pr --draft-text-with-local --preview` 則對提交與拉取要求文字做同樣的事。

### 只是草稿

每個回答都是草稿。輔助不會套用、儲存、送出或提交任何東西。提交與拉取要求文字會填入視窗欄位：欄位仍是 AgentBridge 提議的文字時直接取代；你編輯過時會先詢問。提交主旨必須是一行、最多 200 個位元組，超過 72 個字元時視窗會提示。若說明沒有寫出 AgentBridge 記錄的驗證，會補上那一行，因此說明不會宣稱比實際更多的測試。CLI 絕不把草稿和 `--confirm` 一起使用：請把想用的文字存成檔案，再用 `--message-file`、`--body-file` 與 `--title` 確認。

失敗說明會顯示在驗證結果下方，並附「用作變更要求」：它會把說明複製到「草擬計畫」使用的「要變更什麼？」欄位（欄位已有文字時先詢問），不會送出任何內容。交接草稿會填入「已完成哪些工作？」、「接下來要做什麼？」與「建議下一個提示詞」，任一欄已有文字時先詢問。變更摘要會標示為模型的意見，不能取代驗證。這些內容都不會儲存。

要填入欄位的回答會嚴格讀取：必須剛好是一個 JSON 物件、剛好包含列出的鍵、值都是文字，前後不能有說明文字或程式碼框，也不做修補。純文字回答最多 32 KiB。

### 沒有草稿時

輔助或該工作已關閉、無法連到服務、要求逾時、達到上限，或回答格式不符時，AgentBridge 會保留現有文字（拉取要求則保留提議的提交訊息、標題與說明），並以簡短提示說明原因，而不是跳出錯誤對話框。每個要求都可以取消。

## 壓縮後仍可理解的內容

壓縮只改變送給模型的上下文，不會拿生成的摘要覆蓋已保存逐字稿。壓縮器在 AgentBridge 內執行，不另呼叫模型或付費摘要服務；它從已同意的歷史內容擷取原文，並標示為不可信的歷史資料。

組成的提示會區分：

1. 受保護的較早內容，附來源回合識別及時間順序。
2. 預算容許時保留原文的近期完整使用者／助理回合。
3. 與歷史資料分開的完整當前要求。

目標、決策、限制、否定語句、修正、數字、路徑及程式識別名稱會優先保護。文字維持一般語言，保留完整段落／程式碼邊界；不會改成 ZIP、base64、難懂縮寫或模型必須另行解碼的私有格式。較早的助理陳述仍是有來源的歷史說法，不會變成新驗證過的事實；較新的指示與修正優先於舊內容。

一般安全壓縮會自動執行。預覽可查看組成文字、來源識別、位元組數、保留／省略數量及拒絕原因，不會每則訊息都額外要求核准。若完整當前要求、固定備註或受保護段落仍超出容量，就停止送出並提示整理方式；按確認不能略過這項拒絕。

模型上下文設定會預留輸出與提示本身的空間。不同模型的分詞不同，因此輸入使用保守的位元組預算；這可降低溢出風險，但不是精確分詞結果，也不能保證模型遵守每個指示。保留測試會核對指定限制在壓縮後仍存在；實際理解能力仍取決於所選模型，需另行驗收。

舊版本已截短的紀錄無法重建，原有遺失標記會保留。儲存容量與模型上下文容量是兩件事：不能為了讓提示放得下，就默默破壞較早的來源文字。

專案共享記憶最多保存 256 個回合、編碼後 2 MiB，每組使用者／助理文字上限 128 KiB，備註上限 64 KiB。討論紀錄最多 256 個回合、4 MiB，每則文字上限 64 KiB。超限的新寫入會失敗並保留原本內容；專案交接仍最多明確選取 40 個回合。

## 執行與驗證

HTTP 執行有串流、容量限制、取消及逾時。缺少完成標記、回覆格式錯誤、服務錯誤及輸出超限都會視為失敗，不把部分回覆當成功。稽核紀錄會遮蔽敏感文字，並區分上下文壓縮及供應商回報的用量。

專案仍以 `.codex/ci.sh` 為正式建置／測試入口。傳輸測試使用本機假服務；壓縮測試包含中英文限制、數值修正、否定語句、歷史順序、程式碼邊界及容量不足拒絕。真實模型理解、可見畫面驗收、Developer ID 簽章與 Apple 公證是分開的檢查。

## 官方參考資料

已完成的檢查與待驗收項目，請參閱 [0.10.0 驗證紀錄](LOCAL_MODELS_VALIDATION.zh-TW.md)。

- [Ollama 聊天](https://docs.ollama.com/api/chat)、[模型清單](https://docs.ollama.com/api/tags)及[串流](https://docs.ollama.com/api/streaming)。
- [Ollama FAQ](https://docs.ollama.com/faq)及含遠端模型欄位的[官方 API 型別](https://github.com/ollama/ollama/blob/main/api/types.go)。
- [LM Studio 聊天介面](https://lmstudio.ai/docs/developer/openai-compat/chat-completions)及[模型清單](https://lmstudio.ai/docs/developer/openai-compat/models)。
