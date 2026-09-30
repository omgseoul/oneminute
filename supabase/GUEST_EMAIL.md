# 게스트 답변 이메일 + 원래 채팅방 링크

## 현재 방식

Resend와 이메일 답장 수신 연동을 제거했습니다. 숙소에서 게스트 채팅에 보낸 새 메시지를
일반 SMTP 계정으로 이메일 발송하고 본문 아래 **답변하기 · Reply in chat** 버튼을 표시합니다.
게스트는 버튼을 누르면 원래 대화방에서 답변합니다. 이메일 자체에 회신한 내용은 채팅에 등록되지 않습니다.
이 안내도 이메일에 함께 표시합니다.

표시 이름은 숙소명이며 실제 발신 주소는 SMTP에서 허용한 `GUEST_EMAIL_FROM`입니다.
`reply-...@reply.omgworks24.com` 주소를 더 이상 사용하지 않으며 수신 MX/webhook도 필요하지 않습니다.
Resend 가입 또는 키는 필요 없습니다. 그러나 실제 메일 발송에는 SMTP 발송 계정이 필요합니다.
단순히 Supabase Pro로 올린다고 업무용 이메일 발송 계정이 생기지는 않습니다.

## 링크와 대화 보호

- 대화방별로 추측하기 어려운 링크를 생성하고 링크 해시로 해당 대화만 조회합니다.
- 링크를 다른 브라우저/기기에서 열어도 원래 대화방에 연결됩니다. 새 대화방은 만들지 않습니다.
- 링크는 최대 14일 또는 기존 대화 이용 만료 시점 중 빠른 날짜까지 유효합니다.
- 종료/만료/채팅 중지된 대화와 삭제된 메시지의 링크는 열 수 없습니다.
- 링크는 URL fragment(`#reply=...`)에 넣고 POST로만 교환합니다. 성공 후 주소창에서 제거합니다.
- 각 브라우저에 별도 게스트 세션을 발급하여 원래 QR로 입장한 브라우저의 세션도 유지합니다.
- 링크를 가진 사람은 해당 대화에 접근할 수 있으므로 이메일 전달은 접근권한 전달과 같습니다.
- 원래 웹채팅과 사진 첨부는 그대로 사용합니다. 이메일에 사진은 4MB 이하 JPG/PNG/WEBP로 첨부합니다.

## 운영 적용 상태 및 순서

소스 구현과 자동 테스트까지 완료. SMTP 계정 설정과 서버 배포 전에는 실제 이메일이 전송되지 않습니다.
기본 활성화 값은 false이며, 과거 메시지는 일괄 발송하지 않습니다.

1. `migrations/049_guest_email_relay.sql`이 미적용이면 먼저 적용하고,
   이어서 `migrations/050_guest_email_reply_link.sql`을 적용합니다.
   050은 이전 이메일 수신 함수의 서비스 실행 권한을 제거하고 이전 발송 대기 건을 취소합니다.
   기존에 049를 적용했어도 050만 이어서 적용하면 됩니다.
2. 운영자가 사용할 SMTP 발송 계정을 결정하고 서버 비밀값을 설정합니다.
   - `SMTP_HOST`, `SMTP_PORT` (465 기본, 587 또는 2525도 TLS 필수)
   - `SMTP_USER`, `SMTP_PASSWORD` (해당 제공업체가 허용한 SMTP 자격증명/앱 비밀번호)
   - `GUEST_EMAIL_FROM` (SMTP에서 발신을 허용한 실제 이메일 주소)
   - `GUEST_EMAIL_WORKER_SECRET` (무작위 서버 비밀값)
   개인 Outlook 등 OAuth가 필요한 계정은 일반 비밀번호로 연결할 수 없습니다.
   해당 계정을 선택하면 OAuth 연결을 별도로 구성해야 합니다. 일반 계정 비밀번호를 소스에 저장하지 않습니다.
3. 저장소 루트에서 인증된 Supabase CLI로 배포합니다.
   `supabase functions deploy guest-email --project-ref rfcozgyvupvachhhblzn --no-verify-jwt`
4. Supabase Vault의 `omg_guest_email_worker_secret`에 위 worker secret과 같은 값을 저장하고
   `setup/049_guest_email_scheduler.sql`을 적용합니다. 매분 최대 5건을 처리합니다.
5. SMTP 제공업체 발신주소 인증 및 필요한 DNS를 완료한 다음 활성화합니다.
   `update public.guest_email_config set enabled=true where singleton;`
6. 운영자 소유 테스트 이메일로 새 QR 대화를 만듭니다. 직원의 답변 이메일을 받고,
   다른 브라우저에서 **답변하기**를 눌러 동일한 room_id와 기존 대화가 보이는지 확인합니다.
   원래 QR 브라우저에서도 계속 채팅이 되는지 확인합니다. 실제 게스트에게 무단 테스트하지 않습니다.

## 실패 처리

채팅 저장은 SMTP 응답을 기다리지 않습니다. 저장과 동시에 DB 큐에 등록하고 서버 스케줄이 발송합니다.
첨부 다운로드 등 SMTP 전 단계의 실패만 자동 재시도합니다. SMTP 전송 결과가 불명확하거나
전송 중 실행이 끊긴 경우에는 중복 발송을 피하기 위해 failed로 남겨 관리자 확인을 기다립니다.
고정 Message-ID를 사용하지만 SMTP 자체는 정확히 한 번 전달을 보장하지 않습니다.
`sent`는 SMTP 접수 성공이며 실제 수신함 도착 보장은 아닙니다. 제공업체 로그에서 반송/배달을 확인합니다.

```sql
select status,count(*),min(created_at) as oldest from public.guest_email_outbox group by status;
select message_id,status,attempts,last_error from public.guest_email_outbox where status='failed';
-- 중단 (기존 QR 웹채팅은 유지):
update public.guest_email_config set enabled=false where singleton;
```

## 자동 테스트

```sh
cd supabase/tests/email
npm ci
npm test
cd ../../..
node --test supabase/tests/guest-support-handler.test.mjs
```

049 테스트는 이전 마이그레이션 자체의 회귀 검증용입니다. 운영에서는 050이 이전 수신 권한을 제거합니다.
새 테스트는 SMTP 이메일 내용/답변 링크/수신 endpoint 제거, PostgreSQL의 대화별 세션 권한과
원래 QR 세션 유지, 다른 브라우저 진입 및 링크 만료를 확인합니다. 실제 이메일은 발송하지 않습니다.
