-- Run once in Supabase → SQL Editor (demo only: open read/write)
-- Client uses Publishable key (API Keys tab) or legacy anon — same RLS role `anon`
create table if not exists meshnews_demo (
  id text primary key,
  payload jsonb not null default '{}',
  updated_at timestamptz default now()
);

alter table meshnews_demo enable row level security;

create policy "meshnews_demo_select" on meshnews_demo
  for select using (true);
create policy "meshnews_demo_insert" on meshnews_demo
  for insert with check (true);
create policy "meshnews_demo_update" on meshnews_demo
  for update using (true);
