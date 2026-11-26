begin;
CREATE OR REPLACE FUNCTION omg_private.guard_room_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_limit integer;v_old integer:=0;v_new integer;
BEGIN
 -- Internal properties marked exempt by the operations center do not use plan quotas.
 IF NEW.billing_exempt IS TRUE THEN RETURN NEW; END IF;
 v_new:=jsonb_array_length(coalesce(NEW.rooms,'[]'));
 IF TG_OP='UPDATE' THEN v_old:=jsonb_array_length(coalesce(OLD.rooms,'[]')); END IF;
 IF v_new<=v_old THEN RETURN NEW; END IF;
 SELECT room_limit INTO v_limit FROM omg_private.service_plans WHERE code=NEW.service_plan;
 IF v_new>coalesce(v_limit,10) THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='요금제의 객실 수 한도('||coalesce(v_limit,10)||'개)를 초과했습니다.'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION omg_private.guard_room_limit() FROM PUBLIC,anon,authenticated;
commit;
