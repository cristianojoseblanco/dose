-- DOSE · migração 003: lembretes no celular
-- Rodar uma vez no SQL Editor do Supabase.

-- 1) onde mandar os avisos (um registro por celular)
create table if not exists public.push_subs (
  endpoint text primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid default auth.uid() references auth.users(id) on delete cascade,
  sub jsonb not null,
  ua text,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "push: ler" on public.push_subs;
drop policy if exists "push: inserir" on public.push_subs;
drop policy if exists "push: alterar" on public.push_subs;
drop policy if exists "push: apagar" on public.push_subs;
create policy "push: ler" on public.push_subs for select using (public.is_member(household_id));
create policy "push: inserir" on public.push_subs for insert with check (public.is_member(household_id));
create policy "push: alterar" on public.push_subs for update using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy "push: apagar" on public.push_subs for delete using (public.is_member(household_id));

-- 2) avisos já mandados (para não repetir). Só a função do servidor mexe aqui.
create table if not exists public.push_sent (
  key text primary key,
  at timestamptz not null default now()
);
alter table public.push_sent enable row level security;

-- 3) relógio que chama a função a cada 5 minutos
create extension if not exists pg_cron;
create extension if not exists pg_net;
