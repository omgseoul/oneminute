# 게스트 이메일 ↔ 웹채팅

## 현재 상태

소스 구현 완료. 049 마이그레이션과 guest-email Edge Function 배포, Resend 및 DNS 연결,
스케줄러 설치 전에는 실제 이메일을 보내거나 받지 않습니다. DB 활성화 기본값은 false입니다.
기존 guest-support 및 웹채팅 동작을 바꾸지 않으며, 과거 메시지를 일괄 발송하지 않습니다.

## 동작

- 직원/사장이 게스트 채팅에 보낸 **새 메시지**를 같은 트랜잭션의 발송 큐에 추가합니다.
- 매분 실행되는 서버 작업이 Resend로 전송합니다. 한 번에 5건 처리하며, 지연된 큐는 다음 실행에서 이어갑니다.
- 표시 이름은 숙소명. From과 Reply-To는 모두 `reply-<32자리 난수>@reply.omgworks24.com`입니다.
- 같은 대화에서는 주소가 유지되고 다른 대화/숙소에는 다른 주소를 사용합니다.
- 답장은 공급자 서명, 공급자의 SPF/DKIM/DMARC 판정, 대화 주소, 등록 게스트 이메일을 확인합니다.
  DMARC fail은 차단하고 DMARC 또는 정렬된 DKIM pass가 있어야 허용합니다.
- 답장은 guest_chat_messages/event에 등록되어 기존 알림 및 안읽음 카운터가 사용됩니다.
- 재전송은 원 메시지 ID를 Resend Idempotency-Key로 사용합니다. 23시간 또는 10회 후 실패로 남습니다.
- 답장 수신은 Resend email_id로 중복 방지합니다. 메시지를 수동 삭제해도 수신 이력은 유지합니다.
- 종료/만료된 대화, 다른 이메일에서 온 답장, 자동응답에는 대화 등록 및 자동메일 회신을 하지 않습니다.
- 사진은 JPG/PNG/WEBP, 개당 4MB 이하, 수신 메일당 최대 5개입니다. 지원하지 않는 첨부는 채팅에 안내를 남깁니다.
- HTML 메일은 텍스트로 변환하고, 알려진 원문 인용 구분자만 제거합니다. 임의 HTML/원격 이미지를 렌더링하지 않습니다.
- 웹채팅 버튼은 기존 QR 사용 브라우저에서 기존 대화로 연결됩니다. 다른 브라우저에서는 숙소 안내/입력 화면이 나옵니다.

## 연결 순서 (운영자)

1. [Resend](https://resend.com/domains)에 로그인하고 **reply.omgworks24.com**을 등록합니다.
   Sending과 Receiving 모두 켜고, Resend가 표시하는 정확한 DNS 레코드를 도메인 DNS 관리에 등록합니다.
   이 서브도메인의 DKIM/SPF/수신 MX를 인증합니다. 기존 omgworks24.com 루트 MX는 변경하지 않습니다.
2. Resend에서 발송과 수신 API 접근이 가능한 키를 만듭니다. 발송 전용 키만으로는 수신 본문 조회가 안 됩니다.
3. [Supabase SQL Editor](https://supabase.com/dashboard/project/rfcozgyvupvachhhblzn/sql/new)에서
   `migrations/049_guest_email_relay.sql`을 한 번 적용합니다.
4. Supabase 프로젝트에 아래 Edge Function secrets를 설정합니다. 비밀값을 GitHub/채팅/브라우저 코드에 넣지 않습니다.
   - `RESEND_API_KEY`
   - `RESEND_WEBHOOK_SECRET` (6번에서 받은 서명 비밀값)
   - `GUEST_EMAIL_WORKER_SECRET` (충분히 긴 무작위 비밀값)
   - `PUSH_ADMIN_SECRET` (기존 dispatch-notification과 동일, 이미 설정되어 있으면 유지)
   SUPABASE_URL과 SUPABASE_SERVICE_ROLE_KEY는 플랫폼이 기본 제공하는 값을 사용합니다.
5. 저장소 루트에서 인증된 Supabase CLI로 실행합니다.
   `supabase functions deploy guest-email --project-ref rfcozgyvupvachhhblzn --no-verify-jwt`
6. [Resend Webhooks](https://resend.com/webhooks)에 `email.received` 구독을 추가합니다.
   URL: `https://rfcozgyvupvachhhblzn.supabase.co/functions/v1/guest-email/webhook`
   서명 비밀값을 4번의 RESEND_WEBHOOK_SECRET에 저장합니다.
7. Supabase Vault에 `omg_guest_email_worker_secret` 이름으로 4번의 GUEST_EMAIL_WORKER_SECRET과 같은 값을 저장합니다.
   `setup/049_guest_email_scheduler.sql`을 적용합니다. 스케줄 등록만으로 발송이 켜지지 않습니다.
8. Resend 도메인 Sending/Receiving Verified와 webhook/worker 설정 완료를 확인한 다음 활성화합니다.
   `update public.guest_email_config set enabled=true where singleton;`
9. 운영자 소유 테스트 이메일로 **새 QR 대화**를 만들고 직원 메시지 1건 → 이메일 수신 → 메일 답장 → 같은 채팅/카운터를 확인합니다.
   실제 게스트에게 무단 테스트를 보내지 않습니다. 도메인 인증 없는 Resend 테스트 발신 주소로 전환하지 않습니다.

## 운영 확인

```sql
select status,count(*),min(created_at) as oldest from public.guest_email_outbox group by status;
select message_id,status,attempts,last_error from public.guest_email_outbox where status='failed';
select jobname,active from cron.job where jobname='omg-guest-email-dispatch';
```

`sent`는 Resend 접수 성공을 뜻하며 수신함 도달 보장은 아닙니다. 반송/스팸/실제 배달 상태는 Resend Emails에서 확인합니다.
서명 오류/인증 실패는 Webhook 응답의 reason과 Resend 이벤트 기록을 확인합니다.
인증 결과가 없는 메일은 허용하지 않습니다. 수신 API 일시 실패는 503으로 공급자 재시도를 유도합니다.
자동응답/불명확한 수신주소는 의도적으로 무시합니다. 트래픽이 늘어 큐가 밀리면 공급자 요금제/요청 제한에 맞춰 처리량을 조정합니다.

중단: `update public.guest_email_config set enabled=false where singleton;`
기존 웹채팅은 그대로 유지됩니다. 서비스 재개는 발송 큐의 오래된 건을 확인한 뒤 진행합니다.

## 검증

```sh
cd supabase/tests/email
npm ci
npm test
cd ../../..
node --test supabase/tests/guest-support-handler.test.mjs
```

DB 테스트는 실제 PostgreSQL 엔진(PGlite)에서 트리거, 권한, 발송 임대, 중복 수신 방지,
테넌트/발신자 제한, 기능 비활성 상태를 검증합니다. 외부 게스트에게 메일은 발송하지 않습니다.
