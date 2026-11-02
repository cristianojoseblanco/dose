-- DOSE · estrutura do banco (rodar uma vez no SQL Editor)
create extension if not exists pgcrypto;

-- casa compartilhada e quem faz parte dela
create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Casa',
  invite_code text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create or replace function public.is_member(hid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.household_members
                where household_id = hid and user_id = auth.uid());
$$;

-- dados do app
create table public.meds (
  id text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table public.dose_log (
  id text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  med_id text not null references public.meds(id) on delete cascade,
  sched timestamp not null,
  taken timestamp,
  status text not null check (status in ('ok','late','miss')),
  site text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index dose_log_casa_sched on public.dose_log (household_id, sched desc);

create table public.appts (
  id text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

create table public.settings (
  household_id uuid primary key references public.households(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- updated_at automático
create or replace function public.touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger meds_touch before update on public.meds for each row execute function public.touch();
create trigger appts_touch before update on public.appts for each row execute function public.touch();
create trigger settings_touch before update on public.settings for each row execute function public.touch();

-- segurança: só quem é da casa lê e escreve
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.meds enable row level security;
alter table public.dose_log enable row level security;
alter table public.appts enable row level security;
alter table public.settings enable row level security;

create policy "casa: ver" on public.households for select using (public.is_member(id));
create policy "membros: ver" on public.household_members for select using (public.is_member(household_id));

do $$ declare t text; begin
  foreach t in array array['meds','dose_log','appts','settings'] loop
    execute format('create policy "casa: ler" on public.%I for select using (public.is_member(household_id))', t);
    execute format('create policy "casa: inserir" on public.%I for insert with check (public.is_member(household_id))', t);
    execute format('create policy "casa: alterar" on public.%I for update using (public.is_member(household_id)) with check (public.is_member(household_id))', t);
    execute format('create policy "casa: apagar" on public.%I for delete using (public.is_member(household_id))', t);
  end loop;
end $$;

-- criar a casa e entrar com código de convite
create or replace function public.create_household(p_name text default 'Casa')
returns public.households language plpgsql security definer set search_path = public as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  insert into public.households(name, created_by)
    values (coalesce(nullif(trim(p_name),''),'Casa'), auth.uid()) returning * into h;
  insert into public.household_members(household_id, user_id, role) values (h.id, auth.uid(), 'owner');
  insert into public.settings(household_id) values (h.id);
  return h;
end $$;

create or replace function public.join_household(p_code text)
returns public.households language plpgsql security definer set search_path = public as $$
declare h public.households;
begin
  if auth.uid() is null then raise exception 'precisa estar logado'; end if;
  select * into h from public.households where invite_code = upper(trim(p_code));
  if h.id is null then raise exception 'código inválido'; end if;
  insert into public.household_members(household_id, user_id) values (h.id, auth.uid())
    on conflict do nothing;
  return h;
end $$;

revoke all on function public.create_household(text) from public, anon;
revoke all on function public.join_household(text) from public, anon;
grant execute on function public.create_household(text) to authenticated;
grant execute on function public.join_household(text) to authenticated;

-- acesso pela API (só usuários logados)
grant usage on schema public to authenticated;
grant select on public.households, public.household_members to authenticated;
grant select, insert, update, delete on public.meds, public.dose_log, public.appts, public.settings to authenticated;

-- atualização em tempo real nos dois celulares
alter publication supabase_realtime add table public.meds, public.dose_log, public.appts, public.settings;
