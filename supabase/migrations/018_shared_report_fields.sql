begin;

create or replace function omg_private.report_config_is_valid(p_config jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(
    jsonb_typeof(p_config)='object'
    and jsonb_typeof(p_config->'clock_in')='array'
    and jsonb_typeof(p_config->'clock_out')='array'
    and jsonb_typeof(p_config->'reminder_cards')='array'
    and jsonb_array_length(p_config->'clock_in')<=7
    and jsonb_array_length(p_config->'clock_out')<=7
    and jsonb_array_length(p_config->'reminder_cards')<=12
    and octet_length(p_config::text)<=6000000
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_in') item(value)
      where item.value<>all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','cleaned_rooms','inspected_rooms','reminder_cards']))
    and not exists(select 1 from jsonb_array_elements_text(p_config->'clock_out') item(value)
      where item.value<>all(array['clean_rooms','inspect_rooms','no_show','bedding_stain','cleaned_rooms','inspected_rooms','reminder_cards']))
    and not exists(select 1 from jsonb_array_elements(p_config->'reminder_cards') item(value)
      where jsonb_typeof(item.value)<>'object'
        or btrim(coalesce(item.value->>'id',''))='' or char_length(item.value->>'id')>50
        or btrim(coalesce(item.value->>'title',''))='' or char_length(item.value->>'title')>50
        or btrim(coalesce(item.value->>'text',''))='' or char_length(item.value->>'text')>1000
        or btrim(coalesce(item.value->>'image',''))='' or octet_length(item.value->>'image')>900000
        or jsonb_typeof(item.value->'weekdays')<>'array'
        or jsonb_array_length(item.value->'weekdays')>7
        or exists(select 1 from jsonb_array_elements_text(item.value->'weekdays') day(value)
          where day.value !~ '^[0-6]$')
    ),false
  );
$$;

commit;
