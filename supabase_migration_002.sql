-- DOSE · atualização 002: status de dose "auto" (contada sozinha) e "skip" (dia pulado)
alter table public.dose_log drop constraint if exists dose_log_status_check;
alter table public.dose_log add constraint dose_log_status_check check (status in ('ok','late','miss','auto','skip'));
