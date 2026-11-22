-- Bunny's Flying Submarine: leaderboard database
-- Paste all of this into the Supabase SQL Editor and press Run. It is safe to run more than once.
--
-- What it stores: a made-up bunny nickname, a year group, and round scores. No real names,
-- emails or passwords. Children's devices remember them with a secret token, and only a scrambled
-- copy of that token is stored here.
--
-- Nobody can read or change the tables directly from the website. The website can only call the
-- four functions at the bottom, which check everything they are given.

-------------------------------------------------------------------------------
-- Tables
-------------------------------------------------------------------------------
create table if not exists public.players (
  id          uuid primary key default gen_random_uuid(),
  nickname    text not null unique,
  year_group  smallint not null check (year_group between 0 and 6),   -- 0 = Reception
  token_hash  text not null,
  hidden      boolean not null default false,   -- set to true to take a nickname off the leaderboard
  created_at  timestamptz not null default now()
);

create table if not exists public.rounds (
  id         bigserial primary key,
  player_id  uuid not null references public.players(id) on delete cascade,
  level      smallint not null check (level between 1 and 8),
  points     integer  not null check (points >= 0),
  score      integer  not null check (score >= 0),      -- leaderboard score = points x level
  caught     smallint not null,
  perfect    smallint not null,
  total      smallint not null,
  played_at  timestamptz not null default now()
);
create index if not exists rounds_played_at_idx on public.rounds (played_at);
create index if not exists rounds_player_idx    on public.rounds (player_id, played_at);

-- Lock the tables: row level security on, and no policies, so the website cannot touch them directly.
alter table public.players enable row level security;
alter table public.rounds  enable row level security;
revoke all on public.players from anon, authenticated;
revoke all on public.rounds  from anon, authenticated;
revoke all on sequence public.rounds_id_seq from anon, authenticated;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
-- The words children build their nickname from. Keep this in step with the lists in index.html.
create or replace function public.bs_first_words() returns text[]
language sql immutable as $$
  select array['Captain','Pilot','Admiral','Commander','Skipper','Navigator','Explorer','Professor',
               'Chief','Agent','Ranger','Major','Champion','Inventor','Wizard','Ace',
               'Super','Turbo','Mighty','Cosmic','Speedy','Brave','Zippy','Jolly',
               'Sparkly','Bouncy','Clever','Lucky','Sunny','Rocket','Golden','Little']
$$;

create or replace function public.bs_second_words() returns text[]
language sql immutable as $$
  select array['Big Ears','Floppy Ears','Fluffy','Fluffytail','Cottontail','Bobtail','Whiskers','Nibbles',
               'Hoppy','Hopscotch','Bounce','Snowball','Velvet','Buttons','Clover','Dandelion',
               'Thistle','Daisy','Biscuit','Toffee','Crumpet','Muffin','Cocoa','Pepper',
               'Pom Pom','Puffball','Fuzzball','Snuffles','Sniffles','Wiggles','Pipkin','Burrow',
               'Lettuce','Radish','Pickle','Jellybean','Marshmallow','Twitchy Nose','Puddle','Sprout']
$$;

-- Monday 00:00 London time of the current week: the leaderboard starts afresh then.
create or replace function public.bs_week_start() returns timestamptz
language sql stable as $$
  select (date_trunc('week', now() at time zone 'Europe/London')) at time zone 'Europe/London'
$$;

create or replace function public.bs_hash(t text) returns text
language sql immutable as $$
  select encode(sha256(convert_to(t, 'UTF8')), 'hex')
$$;

-------------------------------------------------------------------------------
-- 1. Make a new player
-------------------------------------------------------------------------------
create or replace function public.create_player(p_first text, p_second text, p_year integer)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_nick  text;
  v_token text;
  v_id    uuid;
begin
  if p_first is null or not (p_first = any(bs_first_words())) then
    return json_build_object('ok', false, 'error', 'bad_word');
  end if;
  if p_second is null or not (p_second = any(bs_second_words())) then
    return json_build_object('ok', false, 'error', 'bad_word');
  end if;
  if p_year is null or p_year < 0 or p_year > 6 then
    return json_build_object('ok', false, 'error', 'bad_year');
  end if;
  -- a simple brake on someone filling the database with nicknames
  if (select count(*) from players where created_at > now() - interval '1 minute') >= 30 then
    return json_build_object('ok', false, 'error', 'busy');
  end if;

  v_nick  := p_first || ' ' || p_second;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into players (nickname, year_group, token_hash)
  values (v_nick, p_year, bs_hash(v_token))
  on conflict (nickname) do nothing
  returning id into v_id;

  if v_id is null then
    return json_build_object('ok', false, 'error', 'taken');
  end if;
  return json_build_object('ok', true, 'id', v_id, 'token', v_token, 'nickname', v_nick, 'year', p_year);
end $$;

-------------------------------------------------------------------------------
-- 2. Save a finished round
-------------------------------------------------------------------------------
create or replace function public.submit_round(p_id uuid, p_token text, p_level integer,
                                               p_caught integer, p_perfect integer, p_total integer)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_player  players%rowtype;
  v_points  integer;
  v_score   integer;
  v_best    integer;
  v_rank    integer;
begin
  select * into v_player from players where id = p_id;
  if not found or v_player.token_hash <> bs_hash(coalesce(p_token, '')) then
    return json_build_object('ok', false, 'error', 'unknown_player');
  end if;

  -- sanity checks: a 2 minute round can't hold more than about 40 things
  if p_level is null or p_level < 1 or p_level > 8
     or p_total   is null or p_total   < 0 or p_total   > 40
     or p_caught  is null or p_caught  < 0 or p_caught  > p_total
     or p_perfect is null or p_perfect < 0 or p_perfect > p_caught then
    return json_build_object('ok', false, 'error', 'bad_round');
  end if;
  -- a round lasts 2 minutes, so two rounds can't finish within 100 seconds of each other
  if exists (select 1 from rounds where player_id = p_id and played_at > now() - interval '100 seconds') then
    return json_build_object('ok', false, 'error', 'too_soon');
  end if;

  -- points are worked out here, not trusted from the device: 3 for a perfect catch, 1 otherwise
  v_points := p_perfect * 3 + (p_caught - p_perfect);
  v_score  := v_points * p_level;

  insert into rounds (player_id, level, points, score, caught, perfect, total)
  values (p_id, p_level, v_points, v_score, p_caught, p_perfect, p_total);

  select max(score) into v_best from rounds where player_id = p_id and played_at >= bs_week_start();

  -- position this week within the player's year group (1 = top)
  select count(*) + 1 into v_rank
  from (
    select r.player_id, max(r.score) as best
    from rounds r join players p on p.id = r.player_id
    where r.played_at >= bs_week_start() and p.year_group = v_player.year_group and not p.hidden
    group by r.player_id
  ) b
  where b.best > v_best;

  return json_build_object('ok', true, 'points', v_points, 'score', v_score,
                           'week_best', v_best, 'year_rank', v_rank, 'year', v_player.year_group);
end $$;

-------------------------------------------------------------------------------
-- 3. This week's leaderboard (p_year null = whole school), plus where a player stands
-------------------------------------------------------------------------------
create or replace function public.leaderboard(p_year integer default null, p_id uuid default null,
                                              p_limit integer default 10)
returns json
language plpgsql security definer set search_path = public stable as $$
declare
  v_top json;
  v_me  json;
begin
  with best as (
    select p.id, p.nickname, p.year_group, max(r.score) as score, min(r.played_at) as first_at
    from rounds r join players p on p.id = r.player_id
    where r.played_at >= bs_week_start() and not p.hidden
      and (p_year is null or p.year_group = p_year)
    group by p.id, p.nickname, p.year_group
  ), ranked as (
    select *, rank() over (order by score desc) as rank,
              row_number() over (order by score desc, first_at asc) as rn
    from best
  )
  select
    (select coalesce(json_agg(json_build_object('rank', rank, 'nickname', nickname,
                                                'year', year_group, 'score', score) order by rn), '[]'::json)
       from ranked where rn <= least(greatest(coalesce(p_limit, 10), 1), 50)),
    (select json_build_object('rank', rank, 'score', score, 'of', (select count(*) from ranked))
       from ranked where id = p_id)
  into v_top, v_me;

  return json_build_object('top', v_top, 'me', v_me, 'week_start', bs_week_start());
end $$;

-------------------------------------------------------------------------------
-- 4. Check a nickname is still known (for a device that has been away a while)
-------------------------------------------------------------------------------
create or replace function public.check_player(p_id uuid, p_token text)
returns json
language sql security definer set search_path = public stable as $$
  select coalesce(
    (select json_build_object('ok', true, 'nickname', nickname, 'year', year_group)
       from players where id = p_id and token_hash = bs_hash(coalesce(p_token, ''))),
    json_build_object('ok', false))
$$;

-------------------------------------------------------------------------------
-- Who may call what: the website (anon) may call only the four functions above.
-------------------------------------------------------------------------------
revoke all on function public.create_player(text, text, integer) from public;
revoke all on function public.submit_round(uuid, text, integer, integer, integer, integer) from public;
revoke all on function public.leaderboard(integer, uuid, integer) from public;
revoke all on function public.check_player(uuid, text) from public;
grant execute on function public.create_player(text, text, integer) to anon, authenticated;
grant execute on function public.submit_round(uuid, text, integer, integer, integer, integer) to anon, authenticated;
grant execute on function public.leaderboard(integer, uuid, integer) to anon, authenticated;
grant execute on function public.check_player(uuid, text) to anon, authenticated;

-------------------------------------------------------------------------------
-- Handy commands for you (run them on their own in the SQL Editor when needed):
--
--   Take a nickname off the leaderboard:
--     update public.players set hidden = true where nickname = 'Captain Big Ears';
--
--   Delete a player and all their scores completely:
--     delete from public.players where nickname = 'Captain Big Ears';
--
--   See this week's busiest players:
--     select p.nickname, count(*) from rounds r join players p on p.id = r.player_id
--     where r.played_at >= bs_week_start() group by 1 order by 2 desc;
-------------------------------------------------------------------------------
