#!/usr/bin/env python3
"""Run in the owner's Google Cloud Shell. Never prints private credentials.

Creates a send-only FCM identity, installs Supabase secrets, then validates
without notifying a device. App/Telegram routing is deliberately unchanged.
"""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PROJECT = 'guesthouse-manager-ajh'
REF = 'rfcozgyvupvachhhblzn'
ACCOUNT = 'omg-supabase-push'
EMAIL = ACCOUNT + '@' + PROJECT + '.iam.gserviceaccount.com'
ROLE_ID = 'omgFcmSendOnly'
ROLE = 'projects/' + PROJECT + '/roles/' + ROLE_ID
PERMISSION = 'cloudmessaging.messages.create'
CLI = ['npx', '--yes', 'supabase@2.118.0']


def run(args, capture=False, check=True):
    return subprocess.run(args, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def google(*args, capture=False, check=True):
    return run(['gcloud', *args, '--project=' + PROJECT, '--quiet'], capture, check)


def validation(secret):
    req = urllib.request.Request(
        'https://' + REF + '.supabase.co/functions/v1/dispatch-notification/validate',
        data=b'{}', method='POST',
        headers={'Content-Type': 'application/json', 'x-webhook-secret': secret})
    with urllib.request.urlopen(req, timeout=40) as response:
        result = json.load(response)
        return result.get('ok') is True and result.get('validated') is True


def main():
    os.umask(0o077)
    for executable in ('gcloud', 'npx'):
        if not shutil.which(executable):
            raise RuntimeError('Google Cloud Shell에서 실행해주세요: ' + executable + ' 필요')
    print('1/5 Google 프로젝트와 Supabase 연결 확인', flush=True)
    google('projects', 'describe', PROJECT, capture=True)
    if run(CLI + ['secrets', 'list', '--project-ref', REF], True, False).returncode:
        print('Supabase 로그인이 필요합니다. 표시되는 링크를 열어 인증해주세요.', flush=True)
        run(CLI + ['login', '--no-browser'])
    run(CLI + ['secrets', 'list', '--project-ref', REF], True)
    # Read existing webhook secret only after both project access checks succeed.
    telegram = google('secrets', 'versions', 'access', 'latest',
                      '--secret=TELEGRAM_URGENT_SECRET', capture=True).stdout.strip()
    if not telegram or any(c in telegram for c in "'\r\n"):
        raise RuntimeError('기존 텔레그램 인증값 확인 필요. 변경하지 않았습니다.')

    print('2/5 알림 발송만 가능한 전용 계정 생성', flush=True)
    existing = google('iam', 'roles', 'describe', ROLE_ID, '--format=json', capture=True, check=False)
    if existing.returncode == 0:
        role = json.loads(existing.stdout)
        if set(role.get('includedPermissions', [])) != {PERMISSION} or role.get('deleted'):
            raise RuntimeError('동일 이름의 역할 권한이 다릅니다. 수동 검토 필요.')
    else:
        google('iam', 'roles', 'create', ROLE_ID, '--title=OMG FCM send only',
               '--permissions=' + PERMISSION, '--stage=GA', capture=True)
    if google('iam', 'service-accounts', 'describe', EMAIL, capture=True, check=False).returncode:
        google('iam', 'service-accounts', 'create', ACCOUNT,
               '--display-name=OMG Supabase push transport', capture=True)
    google('projects', 'add-iam-policy-binding', PROJECT,
           '--member=serviceAccount:' + EMAIL, '--role=' + ROLE,
           '--condition=None', capture=True)

    # Retain a private local copy on failure so rerunning does not create more keys.
    state = Path.home() / '.config' / 'omgworks-push'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    key_file = state / 'fcm-service-account.json'
    receipt = state / 'connection-verified.json'
    if receipt.exists() and not key_file.exists():
        print('이미 연결 완료 기록이 있습니다. 키를 추가 생성하지 않았습니다.')
        print('FCM_ALREADY_CONFIGURED')
        return
    if not key_file.exists():
        google('iam', 'service-accounts', 'keys', 'create', str(key_file),
               '--iam-account=' + EMAIL, capture=True)
    key_file.chmod(0o600)
    key = json.loads(key_file.read_text())
    if key.get('project_id') != PROJECT or key.get('client_email') != EMAIL:
        raise RuntimeError('발송 인증키의 프로젝트/계정이 일치하지 않습니다.')
    admin_secret = secrets.token_hex(32)

    print('3/5 Supabase에 인증값 연결 (내용은 화면에 출력하지 않음)', flush=True)
    with tempfile.TemporaryDirectory(prefix='omg-fcm-') as temp:
        envfile = Path(temp) / 'push.env'
        values = {'FCM_SERVICE_ACCOUNT': json.dumps(key, separators=(',', ':')),
                  'TELEGRAM_URGENT_SECRET': telegram, 'PUSH_ADMIN_SECRET': admin_secret}
        # Single-quoted dotenv preserves the JSON PEM's literal backslash escapes.
        if any("'" in value or '\n' in value or '\r' in value for value in values.values()):
            raise RuntimeError('인증값 형식 확인 필요. 화면에 공유하지 마세요.')
        envfile.write_text(''.join(name + "='" + value + "'\n" for name, value in values.items()))
        run(CLI + ['secrets', 'set', '--env-file', str(envfile), '--project-ref', REF], True)

    print('4/5 FCM 검증 (실제 직원 알림은 보내지 않음)', flush=True)
    verified = False
    # Newly created Google IAM permissions / Edge secrets can take time to propagate.
    for attempt in range(12):
        try:
            verified = validation(admin_secret)
        except (urllib.error.URLError, TimeoutError, ValueError):
            verified = False
        if verified:
            break
        if attempt < 11:
            print('권한 반영 대기 후 재검증 중...', flush=True)
            time.sleep(10)
    if not verified:
        raise RuntimeError('FCM 검증 실패. 기존 알림 경로는 유지됩니다. 잠시 후 같은 명령을 다시 실행해주세요.')
    print('5/5 검증된 Supabase 발송 기능 활성화', flush=True)
    run(CLI + ['secrets', 'set', 'PUSH_DELIVERY_ENABLED=true', '--project-ref', REF], True)
    receipt.write_text(json.dumps({'project': PROJECT, 'supabase_ref': REF,
                                  'private_key_id': key.get('private_key_id'),
                                  'validated_at': int(time.time())}))
    key_file.unlink()  # Remote key remains active in Supabase; remove only local copy.
    print('FCM_CONNECTION_VERIFIED')
    print('키 연결/검증 완료. 앱과 텔레그램 경로 전환은 다음 단계입니다.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError:
        print('설정 명령을 완료하지 못했습니다. 계정 권한/로그인을 확인해주세요. 비밀값은 공유하지 마세요.', file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
