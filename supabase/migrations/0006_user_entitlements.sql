-- ============================================================
-- Nutzer-Berechtigungen (aktuell nur `is_paid_user`, Default false für
-- alle) – reine Datenstruktur-Vorbereitung, wie von Simon gewünscht.
--
-- WICHTIG: Es gibt aktuell KEINE echte Bezahlfunktion. Weder App Store
-- In-App-Purchase noch irgendein anderer Zahlungsweg ist angebunden (dafür
-- bräuchte es ein kostenpflichtiges Apple-Developer-Konto + App-Store-/
-- TestFlight-Vertrieb statt des aktuellen unsignierten Sideloadly-Wegs,
-- siehe CLAUDE.md). `is_paid_user` bleibt also für jeden Account auf
-- `false`, bis diese Infrastruktur existiert. Der Client liest diese Spalte
-- aktuell noch nicht mal – siehe `AuthManager.isPaidUser` (hartcodiert
-- `false`, mit Verweis genau hierher).
--
-- Genutzt vom PDF-Import (`PDFImportView`): freie Accounts dürfen maximal
-- 2 PDFs à 50MB gleichzeitig hochladen; das Feld ist der vorbereitete
-- Anknüpfungspunkt, um das später pro Account zu erhöhen.
-- ============================================================

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  is_paid_user boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Users manage own profile" on public.profiles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Legt beim Signup automatisch eine Profil-Zeile an (statt dass der Client
-- das selbst tun/prüfen muss) – analog zum üblichen Supabase-Muster.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
