# 本機模型與可讀的上下文壓縮

[English](LOCAL_MODELS_AND_CONTEXT.md)

## 供應商邊界

AgentBridge 0.10 在 Codex、Claude 之外新增明確的 Local 供應商。選擇 Local 會直接連到這台 Mac 上已啟動的模型服務，不會變更預設雲端供應商、使用 CLI 訂閱、收集 API key、下載模型或退回付費服務。

支援 Ollama 原生聊天 API，以及包含 LM Studio 在內的 OpenAI 相容本機聊天介面。預設服務根位址分別為 `http://127.0.0.1:11434` 與 `http://127.0.0.1:1234/v1`。只有明確操作才查詢模型；服務沒有已安裝模型時，會如實顯示。

只接受本機回送位址，拒絕遠端主機、網址內的帳密、重新導向與隱含 HTTP 代理。Ollama 的雲端模型名稱及服務回報的遠端模型資訊也會被拒絕。AgentBridge 的網路邊界限於它與本機服務之間的連線；服務本身的轉送行為仍由其操作者負責。若要從服務層停用 Ollama 雲端功能，請依官方 FAQ 設定，AgentBridge 不會自行改動全域服務。

Local 目前支援專案前的討論，以及唯讀專案對話。選取專案只會讓對話取得已同意的 App 記憶，不會因此獲得檔案或命令工具。本版的 Local 不提供隔離修改、原生 CLI 終端、自主工作流程角色、實際 Skills／MCP 或桌面控制；這些能力需要另接工具執行器。

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
