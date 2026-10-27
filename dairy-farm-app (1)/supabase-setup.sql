-- Dairy farm app: Supabase setup. Run ONCE in Supabase > SQL Editor.
-- Everything is prefixed dairy_ . It creates only new objects and never changes or deletes your other apps' tables.
-- Before running, check Table Editor: no existing table or function should start with dairy_ .

create table if not exists dairy_profiles(
  id uuid primary key references auth.users on delete cascade,
  email text, full_name text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  is_admin boolean not null default false,
  created_at timestamptz not null default now());
create table if not exists dairy_farms(
  id uuid primary key default gen_random_uuid(),
  name text not null, code text unique not null,
  owner uuid references auth.users, created_at timestamptz not null default now());
create table if not exists dairy_members(
  farm_id uuid references dairy_farms on delete cascade,
  user_id uuid references auth.users on delete cascade,
  role text not null check (role in ('owner','worker')),
  status text not null default 'pending' check (status in ('pending','active','removed')),
  can_finance boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (farm_id,user_id));
create table if not exists dairy_docs(
  farm_id uuid references dairy_farms on delete cascade,
  kind text not null, id text not null, data jsonb not null default '{}', deleted boolean not null default false,
  updated_at timestamptz not null default now(), updated_by uuid,
  primary key (farm_id,kind,id));
create index if not exists dairy_docs_time on dairy_docs(farm_id,updated_at);

create or replace function dairy_is_admin() returns boolean language sql security definer set search_path=public stable as $$
  select exists(select 1 from dairy_profiles where id=auth.uid() and is_admin and status='approved') $$;
create or replace function dairy_can(p_farm uuid,p_kind text) returns boolean language sql security definer set search_path=public stable as $$
  select exists(select 1 from dairy_members m join dairy_profiles p on p.id=m.user_id
    where m.farm_id=p_farm and m.user_id=auth.uid() and m.status='active' and p.status='approved'
    and (m.role='owner' or m.can_finance or p_kind not in ('exp','sale'))) $$;
create or replace function dairy_touch() returns trigger language plpgsql as $$
  begin new.updated_at=now(); new.updated_by=auth.uid(); return new; end $$;
drop trigger if exists dairy_docs_touch on dairy_docs;
create trigger dairy_docs_touch before insert or update on dairy_docs for each row execute function dairy_touch();

create or replace function dairy_farm_code(n text) returns text language plpgsql security definer set search_path=public as $$
declare base text; c text; ab text:='ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int;
begin
  base:=rpad(upper(left(regexp_replace(coalesce(n,''),'[^A-Za-z]','','g'),3)),3,'X');
  loop
    c:=base||'-';
    for i in 1..4 loop c:=c||substr(ab,1+floor(random()*length(ab))::int,1); end loop;
    exit when not exists(select 1 from dairy_farms where code=c);
  end loop;
  return c;
end $$;

create or replace function dairy_register(p_name text,p_farm text default null,p_code text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); f dairy_farms; em text;
begin
  if u is null then raise exception 'Not logged in'; end if;
  select email into em from auth.users where id=u;
  insert into dairy_profiles(id,email,full_name) values(u,em,coalesce(nullif(trim(p_name),''),em)) on conflict (id) do nothing;
  if coalesce(trim(p_farm),'')<>'' then
    if exists(select 1 from dairy_farms where owner=u) then raise exception 'You already own a farm'; end if;
    insert into dairy_farms(name,code,owner) values(trim(p_farm),dairy_farm_code(p_farm),u) returning * into f;
    insert into dairy_members(farm_id,user_id,role,status,can_finance) values(f.id,u,'owner','active',true);
  elsif coalesce(trim(p_code),'')<>'' then
    select * into f from dairy_farms where code=upper(trim(p_code));
    if not found then raise exception 'Farm code not found'; end if;
    insert into dairy_members(farm_id,user_id,role) values(f.id,u,'worker') on conflict do nothing;
  end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function dairy_me() returns jsonb language sql security definer set search_path=public stable as $$
  select coalesce(
    (select jsonb_build_object('uid',p.id,'status',p.status,'is_admin',p.is_admin,'name',p.full_name,
       'memberships',coalesce((select jsonb_agg(jsonb_build_object('farm_id',f.id,'name',f.name,'code',f.code,'role',m.role,'status',m.status,'can_finance',m.can_finance))
         from dairy_members m join dairy_farms f on f.id=m.farm_id where m.user_id=p.id),'[]'::jsonb))
     from dairy_profiles p where p.id=auth.uid()),
    jsonb_build_object('uid',auth.uid(),'status','none','memberships','[]'::jsonb)) $$;

create or replace function dairy_admin_list() returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not dairy_is_admin() then raise exception 'Administrators only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'email',p.email,'name',p.full_name,'status',p.status,'created',p.created_at,
    'farms',coalesce((select jsonb_agg(jsonb_build_object('name',f.name,'code',f.code,'role',m.role,'mstatus',m.status))
      from dairy_members m join dairy_farms f on f.id=m.farm_id where m.user_id=p.id),'[]'::jsonb)) order by p.created_at desc)
    from dairy_profiles p),'[]'::jsonb);
end $$;
create or replace function dairy_admin_set(p_user uuid,p_status text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not dairy_is_admin() then raise exception 'Administrators only'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'Bad status'; end if;
  update dairy_profiles set status=p_status where id=p_user;
end $$;
create or replace function dairy_team(p_farm uuid) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from dairy_members where farm_id=p_farm and user_id=auth.uid() and role='owner' and status='active') then raise exception 'Owners only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',p.full_name,'email',p.email,'role',m.role,'status',m.status,'can_finance',m.can_finance,'account',p.status) order by m.joined_at)
    from dairy_members m join dairy_profiles p on p.id=m.user_id where m.farm_id=p_farm and m.status<>'removed'),'[]'::jsonb);
end $$;
create or replace function dairy_member_set(p_farm uuid,p_user uuid,p_status text,p_fin boolean) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from dairy_members where farm_id=p_farm and user_id=auth.uid() and role='owner' and status='active') then raise exception 'Owners only'; end if;
  if p_status not in ('active','removed') then raise exception 'Bad status'; end if;
  update dairy_members set status=p_status,can_finance=coalesce(p_fin,false) where farm_id=p_farm and user_id=p_user and role='worker';
end $$;

alter table dairy_profiles enable row level security;
alter table dairy_farms enable row level security;
alter table dairy_members enable row level security;
alter table dairy_docs enable row level security;
drop policy if exists dairy_profiles_sel on dairy_profiles;
create policy dairy_profiles_sel on dairy_profiles for select to authenticated using (id=auth.uid() or dairy_is_admin());
drop policy if exists dairy_farms_sel on dairy_farms;
create policy dairy_farms_sel on dairy_farms for select to authenticated using (dairy_is_admin() or exists(select 1 from dairy_members m where m.farm_id=id and m.user_id=auth.uid()));
drop policy if exists dairy_members_sel on dairy_members;
create policy dairy_members_sel on dairy_members for select to authenticated using (user_id=auth.uid() or dairy_is_admin());
drop policy if exists dairy_docs_sel on dairy_docs;
create policy dairy_docs_sel on dairy_docs for select to authenticated using (dairy_can(farm_id,kind));
drop policy if exists dairy_docs_ins on dairy_docs;
create policy dairy_docs_ins on dairy_docs for insert to authenticated with check (dairy_can(farm_id,kind));
drop policy if exists dairy_docs_upd on dairy_docs;
create policy dairy_docs_upd on dairy_docs for update to authenticated using (dairy_can(farm_id,kind)) with check (dairy_can(farm_id,kind));

revoke all on dairy_profiles,dairy_farms,dairy_members,dairy_docs from anon;
revoke execute on function dairy_is_admin(),dairy_can(uuid,text),dairy_farm_code(text),dairy_register(text,text,text),dairy_me(),dairy_admin_list(),dairy_admin_set(uuid,text),dairy_team(uuid),dairy_member_set(uuid,uuid,text,boolean) from public,anon;
grant execute on function dairy_is_admin(),dairy_can(uuid,text),dairy_register(text,text,text),dairy_me(),dairy_admin_list(),dairy_admin_set(uuid,text),dairy_team(uuid),dairy_member_set(uuid,uuid,text,boolean) to authenticated;

-- STEP 2: after you create your login in Supabase, run make-admin.sql to become the administrator.
