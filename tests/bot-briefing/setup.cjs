const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs'),assert=require('node:assert/strict');
const id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
async function setup(){
 const db=new PGlite();await db.exec(fs.readFileSync('tests/holiday-requests/schema.sql','utf8'));
 await db.exec(`create role service_role;create schema extensions;create function extensions.gen_random_bytes(int) returns bytea language sql as $$select decode(repeat('ab',$1),'hex')$$;create function extensions.digest(bytea,text) returns bytea language sql as $$select decode(md5($1),'hex')$$;
 create schema vault;create table vault.secrets(id uuid primary key default gen_random_uuid(),name text unique,decrypted_secret text);create view vault.decrypted_secrets as select * from vault.secrets;
 create function vault.create_secret(secret text,name text,description text)returns uuid language plpgsql as $$declare i uuid;begin insert into vault.secrets(name,decrypted_secret)values(name,secret)returning id into i;return i;end$$;
 create function vault.update_secret(i uuid,s text) returns void language sql as $$update vault.secrets set decrypted_secret=s where id=i$$;
 create schema cron;create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
 create table public.platform_administrators(user_id uuid primary key);
 `);
 let foundation=fs.readFileSync('supabase/migrations/034_guest_support.sql','utf8').split('-- All actions go through')[0].replace('begin;','');await db.exec(foundation);
 await db.exec(`alter table guest_chat_rooms add email text,add room_unknown boolean default false;alter table guest_chat_alert_preferences add schedules jsonb default '[]';create table guest_email_sessions(token_hash text,room_id uuid,expires_at timestamptz);`);
 await db.exec(fs.readFileSync('supabase/migrations/20261025070201_guest_ai_autoreply.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/20261025094411_guest_ai_continue_after_handoff.sql','utf8'));
 await db.exec(`create function public.list_notification_bot_messages(uuid,timestamptz,uuid)returns jsonb language sql as $$select jsonb_build_object('ok',true)$$;`);
 await db.exec(fs.readFileSync('supabase/setup/guest_ai_support_handoff.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/guest_ai_alert_settings.sql','utf8'));

 const shared=fs.readFileSync('supabase/migrations/20261005090000_shared_settings_reminders.sql','utf8');await db.exec(shared.slice(shared.indexOf('CREATE OR REPLACE FUNCTION omg_private.can_manage_shared_property('),shared.indexOf('CREATE OR REPLACE FUNCTION public.shared_get_work_app_config')));
 await db.exec(fs.readFileSync('supabase/setup/beds24_online.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/beds24_sync_cache.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/setup/beds24_inbox_workflow.sql','utf8'));

 await db.exec(`alter table work_sessions add column unconfirmed_ended_at timestamptz;`);
 await db.exec(fs.readFileSync('supabase/setup/bot_briefing.sql','utf8'));
 return db;
}
module.exports={setup,id};
