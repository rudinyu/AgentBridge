# 本機模型驗證紀錄 — 0.10.0 build 9

[English](LOCAL_MODELS_VALIDATION.md) · [使用說明](LOCAL_MODELS_AND_CONTEXT.zh-TW.md)

2026 年 11 月 2 日於本機 macOS／Xcode 驗證。本紀錄涵蓋開發版；0.10.0 尚未以 Developer ID 簽章、公證或正式發布。

## 建置與自動測試

- `./.codex/ci.sh`：**219 項測試通過，0 失敗**。紀錄：`build/local-model-ci-final.log`。
- 最後加入 Local 自主編排拒絕檢查及 App 草稿／完成處理後，11 項相關回歸測試通過，並重新編譯完整 App。紀錄：`build/local-model-final-guard.log`。11 月 3 日在 MIT 封裝更新後另重跑完整測試，219 項全部通過。紀錄：`build/mit-license-ci.log`。
- `./scripts/package-app.sh --app-name AgentBridge-0.10.0-dev.app`：Release CLI 與 App 建置成功，Info.plist 驗證通過。紀錄：`build/local-model-package.log`。
- 包裝的執行檔與 Release 輸出一致，版本為 0.10.0、build 9。ATS 允許本機網路，未全面允許任意載入。
- 11 月 3 日 MIT 補充驗證：重新封裝通過；App 內專案授權與根目錄 `LICENSE` 一致、SwiftTerm 宣告保留，`NSHumanReadableCopyright` 含專案版權與 MIT 資訊。紀錄：`build/mit-license-package.log`。
- 變更空白檢查、Shell／Python 語法、多國語言檔語法及鍵值一致性通過；英文及繁體中文各有 1,322 個鍵值。

建置紀錄仍保留 SwiftPM 原生建置系統棄用與 Sendable 函式轉換的非致命警告。

首次受限環境中的 SwiftPM 執行停在 `sandbox_apply: Operation not permitted`。隨後使用相同驗證命令，在允許的主機環境執行，明確選用 Xcode，並使用專案內建置／快取路徑。沒有修改全域快取、登入或服務設定。

## CLI 與 HTTP 實際驗證

使用隔離資料與本機假服務，移除 provider key／base URL 環境變數。回覆來自固定測試資料，不是真實推論。

| 項目 | 結果 |
| --- | --- |
| 相容協定模型清單與聊天串流 | 通過 |
| Ollama 原生模型清單與 NDJSON 聊天 | 通過 |
| 尚無 Git 專案時建立討論 | 通過 |
| 後續對話／切換帳戶保留符合分享同意的事實 | 通過 |
| 上下文不足 | 在 POST 與對話資料變更之前拒絕 |
| 長歷史壓縮 | 14,599 → 6,420 UTF-8 位元組；保留目前要求、「Maple Lantern」、US$140 及禁止雲端限制 |
| 審閱七輪交接後執行 Local 專案對話 | 通過；原討論保留，新 Git 工作樹為空且乾淨 |
| 從另一個 CLI 取消執行 | 通過；取消回覆未存為完成，先前完成輪次保留 |

測試服務已關閉，使用者原本的 Ollama 服務未變更。實際連線／清單檢查成功，但**沒有已安裝模型**。未下載模型、未執行真實推論，也沒有付費／雲端呼叫。保留測試與 HTTP 輸入檢查不能證明任意模型的理解品質。

## UI、審查與發布範圍

GUI 前置檢查回報 `screen_locked=true`，前景為 `loginwindow`。未啟動 UI 測試或開發版 App。[UI 前置檢查技能](/Users/rudin_yu/.codex/skills/macos-ui-test-preflight/SKILL.md) 明確要求：「Do not start or retry the UI tests.」實際畫面操作仍未驗證。

Codex 已在目前任務中，以唯讀方式審查完整變更與相關呼叫點，包含最後的草稿／完成處理及 Local 自主編排拒絕檢查。未發現尚未處理的 P0／P1／P2 問題。沒有啟動巢狀 Codex 或另一套獨立審查流程。

原有 0.9.0 build 8 App 的嚴格簽章檢查仍通過。已公證 ZIP 的 SHA-256 仍為 `f6a2e6576f82e01972a61a0bba5d7b63b3020461dce94fbff30855fcc95bba7c`，未被開發版取代。

待驗收：用已安裝模型測試重要事實與修正要求的理解；在解鎖 App 中操作設定、串流、取消與切換；收到另行指示後再簽章與公證。原始碼提交及 GitHub 推送與正式發布分開處理。
