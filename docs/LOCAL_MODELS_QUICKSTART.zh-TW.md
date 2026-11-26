# 本機模型快速上手：Ollama 與 LM Studio

[English](LOCAL_MODELS_QUICKSTART.md) · [完整說明](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)

AgentBridge 內建 **Local** 供應商，可直接連到這台 Mac 上執行中的 Ollama 或 LM Studio。不需要經過 Codex 或 Claude，不需要 API key，也不會用到付費服務。AgentBridge 只連本機回送位址（`127.0.0.1`／`localhost`）。

這份文件說明怎麼接上這兩種服務。各項限制與細節請見[本機模型與可讀上下文壓縮](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)。

## Ollama

Ollama 最容易設定，AgentBridge 有引導流程。

### 在 App 中

1. 在供應商選 **Local**，打開 Local 模型設定。
2. 按最上方「Ollama 引導設定」中的「**檢查 Ollama 設定**」，再依結果操作：
   - **尚未安裝**：按「開啟 Ollama 下載頁面」，自行下載安裝。
   - **已安裝但未執行**：按「**啟動 Ollama**」。
   - **執行中**：AgentBridge 會依這台 Mac 的記憶體建議模型，也可以輸入其他模型名稱。按「**下載模型**」開始下載。

   | 實體記憶體 | 建議模型 | 下載量 |
   | --- | --- | --- |
   | 少於 12 GB | `qwen2.5-coder:3b` | 約 1.9 GB |
   | 12 GB 以上 | `qwen2.5-coder:7b` | 約 4.7 GB |
   | 24 GB 以上 | `qwen2.5-coder:14b` | 約 9 GB |
   | 48 GB 以上 | `qwen2.5-coder:32b` | 約 20 GB |

3. 下載完成後，Local 設定會改用 Ollama 後端與這個模型並儲存，然後做一次連線測試。
4. 按「**偵測上下文容量**」，再按「使用 N tokens」，最後按保存。

Ollama 每次要求都會使用 AgentBridge 送出的上下文長度。因此建議值是模型的最大上下文，再依記憶體壓低：少於 12 GB 為 8k、少於 24 GB 為 16k、少於 48 GB 為 32k，以上為 64k tokens。

Ollama 預設在閒置 5 分鐘後卸載模型。如果常隔一段時間才使用，可以設定「**保持模型載入**」（例如 1 小時），回應會比較快，但模型閒置時仍占用記憶體。CLI 是在 `agentbridge local configure` 加上 `--keep-alive MINUTES|forever|default`。

### 使用 CLI

```sh
agentbridge local setup-check
agentbridge local pull qwen2.5-coder:7b --confirm
agentbridge local context --apply
```

`local pull` 下載完成後會改用這個模型。如果你是用 Ollama 自己下載的模型，請用以下指令設定：

```sh
agentbridge local configure --backend ollama --endpoint http://127.0.0.1:11434 --model MODEL-ID
agentbridge local context --apply
```

## LM Studio

LM Studio 透過 OpenAI 相容介面連接。

1. 在 LM Studio 下載並載入模型，然後在 Developer 分頁啟動本機伺服器，預設位址是 `http://127.0.0.1:1234`。
   - **上下文長度（Context Length）要在 LM Studio 載入模型時設定。** LM Studio 會沿用載入時的長度，不理會 AgentBridge 要求中的設定。
2. 在 AgentBridge 選 **Local**，後端選「**相容 OpenAI API · LM Studio**」，位址填 `http://127.0.0.1:1234/v1`。按「更新模型清單」，再選取模型。
3. 按「**偵測上下文容量**」。建議值就是 LM Studio 載入模型時的長度。按「使用 N tokens」，再按保存。

使用 CLI：

```sh
agentbridge local configure --backend openai-compatible --endpoint http://127.0.0.1:1234/v1 --model MODEL-ID
agentbridge local context --apply
```

每次執行前，AgentBridge 會查詢 LM Studio 實際載入的上下文。如果 AgentBridge 設定的上下文視窗比它大，會在送出任何內容前拒絕執行，並列出兩個數字。這時請調低 AgentBridge 的設定，或在 LM Studio 以更長的上下文重新載入模型。

其他 OpenAI 相容服務也能用同樣方式連接，但不會回報上下文大小，請自行設定上下文視窗。

## 確認連線

```sh
agentbridge local models
agentbridge local test
```

`local models` 只列出服務上的模型。`local test` 檢查連線，不會產生模型回覆。

## 設定好之後能做什麼

- **討論與唯讀專案對話**：在 App 建立 Local 對話，或執行 `agentbridge chat new --provider local`。
- **隔離變更**：建立專案工作階段時選「隔離變更」。流程是：草擬計畫 → 檢視並核准 → 在 **Changes** 選取檔案 → 預覽 → 執行。模型會回傳完整檔案內容，AgentBridge 以 diff 顯示給你檢視。
  - 選取的檔案放不下時，預覽會建議分成幾組，每組都有「**選取這些檔案**」按鈕。每組執行前都要重新核准計畫。
- **本機模型輔助**：在 Codex 或 Claude 的工作中，用本機模型草擬提交／拉取要求文字、說明驗證失敗、撰寫交接摘要或摘要變更。預設關閉，請在 Local 模型設定中的「本機模型輔助」開啟。

## Local 做不到的事

本機模型沒有工具：不能自己讀檔、執行命令或搜尋專案，只看得到你選取的檔案。Local 也不支援原生 CLI 終端、Skills／MCP、自主工作流程角色或桌面控制。

Local 適合範圍明確、檔案數量少的工作。需要模型自己探索專案或執行測試時，請改用 Codex 或 Claude。

## 常見問題

- **模型清單是空的**：確認服務正在執行、模型已下載或已載入，而且位址是本機回送位址。
- **執行被拒絕，訊息說 LM Studio 載入的上下文比較小**：調低 AgentBridge 的上下文視窗，或在 LM Studio 以更長的上下文重新載入模型。
- **預覽說輸入或輸出超出預算**：選取較少或較小的檔案、依拆分建議分組執行，或在 Local 模型設定提高上下文視窗與輸出保留量（CLI 是 `agentbridge local configure` 加上 `--context-window` 與 `--max-output`，並一併提供 `--backend`、`--endpoint`、`--model`）。
- **回覆很慢或記憶體不足**：換較小的模型，或調低上下文視窗。
