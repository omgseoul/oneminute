# Guest QR AI tests

Run `npm install --prefix tests/guest-ai`, `npx --prefix tests/guest-ai playwright install chromium`, then `NODE_PATH=tests/guest-ai/node_modules npm test --prefix tests/guest-ai`.

Database tests use an isolated PGlite database with representative existing guest tables and mocked Vault/cron. They never read production messages or send notifications. Edge tests inject mocked OpenAI and Supabase responses. UI tests run Chromium at mobile/tablet widths with no network access. Real model response quality and Android push/vibration require a connected provider key and device verification.

Manual activation:
1. 운영센터 → AI 자동답변 → API 연결 (encrypted server Vault; model access check only).
2. Assign a property's credits and monthly limit; zero prevents paid calls.
3. Property 설정 → QR 설정: enable guest chat.
4. Property 설정 → AI 자동답변: enter true property policies, select channel and schedule, save.
5. On a test guest QR room ask two questions in one message, ask an unsupported question, and explicitly test urgent staff notification with informed recipients.

The AI responds only to new guest messages while the selected condition holds. Staff takeover or guest human request pauses the room until a staff member resumes AI. Emergency/human buttons do not depend on API availability. Monthly quotas use Asia/Seoul; response schedules use property timezone. 1 credit = USD 0.001. Pricing is fixed to GPT-6 Luna standard rates verified 2026-10-25; review rates before changing models. Input/cache-write upper bounds reserve costs before a request. Ambiguous timeouts are conservatively settled at the reservation and marked estimated, never retried as another paid request; operators can reconcile using provider response IDs where available and credit adjustments. DATA/history stay bounded (200 rows/60KB, 12 messages) and tenant scoped.
