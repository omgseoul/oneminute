-- Pending runs created before category settings must also respect current recipients.
do $migration$
declare def text;anchor text;begin
 def:=pg_get_functiondef('omg_private.briefing_release_deliveries()'::regprocedure);
 anchor:='case when d.categories is null then r.summary else omg_private.briefing_render';
 if strpos(def,anchor)=0 then raise exception 'Missing categorized delivery renderer';end if;
 def:=replace(def,anchor,'omg_private.briefing_render');
 def:=replace(def,'r.error) end as summary','r.error) as summary');
 def:=replace(def,'case when r.mode=''manual'' then r.settings->''categories'' else s.categories end','case when r.mode=''manual'' then coalesce(r.settings->''categories'',s.categories) else s.categories end');
 def:=replace(def,'unnest(d.categories)','unnest(coalesce(d.categories,omg_private.briefing_recipient_categories(r.property_id,s.categories,d.employee_id,d.owner_id)))');
 execute def;
end$migration$;
