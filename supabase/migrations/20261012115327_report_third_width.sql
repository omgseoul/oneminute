CREATE OR REPLACE FUNCTION omg_private.custom_report_fields_are_valid(p_fields jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
begin
 if p_fields is null or jsonb_typeof(p_fields)<>'array' then return false;end if;
 return jsonb_array_length(p_fields)<=20 and octet_length(p_fields::text)<=7500
 and not exists(select 1 from jsonb_array_elements(p_fields) item(value)
 where jsonb_typeof(item.value)<>'object' or coalesce(item.value->>'key','')!~'^custom_[a-z0-9_-]{1,50}$'
 or char_length(btrim(coalesce(item.value->>'label',''))) not between 1 and 40
 or (item.value ? 'kind' and (jsonb_typeof(item.value->'kind')<>'string' or item.value->>'kind' not in('text','numeric','counter','rooms','photo')))
 or (item.value ? 'size' and (jsonb_typeof(item.value->'size')<>'string' or item.value->>'size' not in('full','half','third')))
 or (item.value ? 'required' and jsonb_typeof(item.value->'required')<>'boolean'))
 and (select count(*)=count(distinct item.value->>'key') from jsonb_array_elements(p_fields)item(value));
end;$function$
;
revoke all on function omg_private.custom_report_fields_are_valid(jsonb) from public,anon,authenticated;
