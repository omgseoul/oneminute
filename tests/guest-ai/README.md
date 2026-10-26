# Guest QR AI tests

Run `npm install --prefix tests/guest-ai`, `npx --prefix tests/guest-ai playwright install chromium`, then `NODE_PATH=tests/guest-ai/node_modules npm test --prefix tests/guest-ai`.

Database tests use an isolated PGlite database with representative existing guest tables and mocked Vault/cron. They never read production messages or send notifications. Edge tests inject mocked OpenAI and Supabase responses. UI tests run Chromium at mobile/tablet widths with no network access. Real model response quality and Android push/vibration require a connected provider key and device verification. The Excel/chat browser test covers XLSX download and compressed/shared-string imports, preview/apply/cancel, invalid-file preservation, original attendance export compatibility, removed guest controls and AI-only badges.

Manual activation:
1. 운영센터 → AI 자동답변 → API 연결 (encrypted server Vault; model access check only).
2. Assign a property's credits and monthly limit; zero prevents paid calls.
3. Property 설정 → QR 설정: enable guest chat.
4. Property 설정 → AI 자동답변: enter true property policies, select channel and schedule, save.
5. On a test guest QR room ask two questions in one message, ask an unsupported question, and explicitly test urgent staff notification with informed recipients.

The AI responds only to new guest messages while the selected condition holds. Staff takeover or guest human request pauses the room until a staff member resumes AI. The guest header stays compact with no staff/urgent buttons. AI messages display a small AI badge; model-classified urgent or human handoff still routes to staff. Monthly quotas use Asia/Seoul; response schedules use property timezone. 1 credit = USD 0.001. Pricing is fixed to GPT-6 Luna standard rates verified 2026-10-25; review rates before changing models. Input/cache-write upper bounds reserve costs before a request. Ambiguous timeouts are conservatively settled at the reservation and marked estimated, never retried as another paid request; operators can reconcile using provider response IDs where available and credit adjustments. DATA/history stay bounded (200 rows/60KB, 12 messages) and tenant scoped.

AI DATA supports `.xlsx` export and import of 제목 / 답변 내용 columns. Imports are parsed in a local worker with file/expansion/time limits, validated before editor replacement, previewed, and only persisted by 설정 저장. Formulas and invalid layouts are rejected; strings starting with formula characters remain literal text. The parser is pinned and vendored (see vendor/xlsx.README.md).

Prompt caching uses an explicit boundary after the unchanged property preferences and DATA (kept in user-level content), with a 30-minute write lifetime. Conversation and attachment state follow that boundary without cache writes. The model, rules, output schema and answer validation remain unchanged. Saving a different prompt, editing/deleting DATA or selecting another property's data changes the prefix automatically; no manually cleared cache or stored answer is used. Existing cached-token accounting settles the reduced cost into the wallet. Tests cover prefix stability/invalidation and cached-read/write settlement. Live cache savings must be measured from provider usage; simulated hit-rate savings are not production measurements.
