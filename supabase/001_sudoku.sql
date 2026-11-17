-- 스도쿠왕 쟁탈전: 동시 대결용 데이터베이스
-- 학생 기기는 표에 직접 쓰지 못하고, 아래 함수(채점·입장 등)를 통해서만 바꿀 수 있다.
-- 정답(sudoku_secrets)과 학생 열쇠(sudoku_tokens)는 학생 쪽에서 읽을 수 없다.

-- ===== 표 =====
create table public.sudoku_rooms (
  id           uuid primary key default gen_random_uuid(),
  code         text not null,                       -- 입장 코드 4자리
  n            int  not null check (n between 2 and 100),
  k            int  not null check (k between 1 and 5), -- 9×9 판을 k×k장
  diff         text not null check (diff in ('easy','normal','hard')),
  duration_sec int  not null check (duration_sec between 60 and 3600),
  status       text not null default 'lobby' check (status in ('lobby','playing','ended')),
  puzzle       smallint[] not null,                 -- 보이는 숫자 (0 = 빈칸)
  init_owner   smallint[] not null,                 -- 시작할 때 땅 주인 (-1 = 중립)
  base         boolean[]  not null,                 -- 본진 칸
  blanks       int  not null,                       -- 빈칸 수
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  ends_at      timestamptz
);
create unique index sudoku_rooms_code_live on public.sudoku_rooms(code) where status <> 'ended';

create table public.sudoku_secrets (
  room_id  uuid primary key references public.sudoku_rooms(id) on delete cascade,
  host_key uuid not null,          -- 방을 만든 선생님 기기만 아는 열쇠
  solution smallint[] not null     -- 정답
);

create table public.sudoku_players (
  room_id   uuid not null references public.sudoku_rooms(id) on delete cascade,
  num       int  not null,         -- 학생 번호 (1부터)
  joined_at timestamptz not null default now(),
  atk int not null default 0,
  def int not null default 0,
  miss int not null default 0,
  primary key (room_id, num)
);

create table public.sudoku_tokens (
  room_id uuid not null,
  num     int  not null,
  token   uuid not null default gen_random_uuid(),  -- 학생 기기만 아는 열쇠
  last_wrong_at timestamptz,
  primary key (room_id, num),
  foreign key (room_id, num) references public.sudoku_players(room_id, num) on delete cascade
);

create table public.sudoku_claims (
  room_id    uuid not null references public.sudoku_rooms(id) on delete cascade,
  cell       int  not null,
  player     int  not null,        -- 0부터 (번호 - 1)
  prev_owner int  not null,
  created_at timestamptz not null default now(),
  primary key (room_id, cell)      -- 한 칸은 한 번만: 먼저 맞힌 사람만 성공
);

-- ===== 접근 규칙 =====
alter table public.sudoku_rooms   enable row level security;
alter table public.sudoku_secrets enable row level security;
alter table public.sudoku_players enable row level security;
alter table public.sudoku_tokens  enable row level security;
alter table public.sudoku_claims  enable row level security;

-- 읽기만 허용 (정답·열쇠 표는 규칙이 없으므로 아무도 못 읽음)
create policy "sudoku rooms read"   on public.sudoku_rooms   for select to anon, authenticated using (true);
create policy "sudoku players read" on public.sudoku_players for select to anon, authenticated using (true);
create policy "sudoku claims read"  on public.sudoku_claims  for select to anon, authenticated using (true);

revoke insert, update, delete on public.sudoku_rooms, public.sudoku_players, public.sudoku_claims from anon, authenticated;
revoke all on public.sudoku_secrets, public.sudoku_tokens from anon, authenticated;

-- ===== 함수 =====

-- 방 만들기 (선생님 기기가 문제를 만들어 보낸다)
create or replace function public.sudoku_create_room(
  p_n int, p_k int, p_diff text, p_duration int,
  p_puzzle smallint[], p_solution smallint[], p_owner smallint[], p_base boolean[]
) returns json
language plpgsql security definer set search_path = '' as $$
declare
  w int := p_k * 9;
  c int := w * w;
  v_code text;
  v_room uuid;
  v_host uuid := gen_random_uuid();
  i int;
begin
  if p_k < 1 or p_k > 5 or (3*p_k)*(3*p_k) < 2*p_n then raise exception 'bad_size'; end if;
  if cardinality(p_puzzle) <> c or cardinality(p_solution) <> c
     or cardinality(p_owner) <> c or cardinality(p_base) <> c then raise exception 'bad_length'; end if;
  for i in 1..c loop
    if p_solution[i] not between 1 and 9 then raise exception 'bad_solution'; end if;
    if p_puzzle[i] <> 0 and p_puzzle[i] <> p_solution[i] then raise exception 'bad_puzzle'; end if;
    if p_owner[i] < -1 or p_owner[i] >= p_n then raise exception 'bad_owner'; end if;
    if p_base[i] and p_puzzle[i] = 0 then raise exception 'bad_base'; end if;
  end loop;

  -- 하루 지난 방은 정리
  delete from public.sudoku_rooms where created_at < now() - interval '1 day';

  loop
    v_code := lpad((floor(random()*10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.sudoku_rooms where code = v_code and status <> 'ended');
  end loop;

  insert into public.sudoku_rooms (code, n, k, diff, duration_sec, puzzle, init_owner, base, blanks)
  values (v_code, p_n, p_k, p_diff, p_duration, p_puzzle, p_owner, p_base,
          (select count(*) from unnest(p_puzzle) x where x = 0))
  returning id into v_room;
  insert into public.sudoku_secrets (room_id, host_key, solution) values (v_room, v_host, p_solution);

  return json_build_object('room_id', v_room, 'code', v_code, 'host_key', v_host);
end $$;

-- 학생 입장 (같은 번호는 처음 들어온 기기만. 새로고침해도 열쇠가 있으면 다시 들어옴)
create or replace function public.sudoku_join(p_code text, p_num int, p_token uuid default null)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
begin
  select * into r from public.sudoku_rooms where code = p_code and status <> 'ended'
    order by created_at desc limit 1;
  if not found then return json_build_object('r','no_room'); end if;
  if p_num is null or p_num < 1 or p_num > r.n then return json_build_object('r','bad_num', 'n', r.n); end if;

  select * into t from public.sudoku_tokens where room_id = r.id and num = p_num;
  if found then
    if p_token is not null and t.token = p_token then
      return json_build_object('r','ok', 'room_id', r.id, 'token', t.token);
    end if;
    return json_build_object('r','taken');
  end if;

  insert into public.sudoku_players (room_id, num) values (r.id, p_num) on conflict do nothing;
  insert into public.sudoku_tokens (room_id, num) values (r.id, p_num) returning * into t;
  return json_build_object('r','ok', 'room_id', r.id, 'token', t.token);
end $$;

-- 선생님: 번호 풀어 주기 (학생이 기기를 바꿨을 때)
create or replace function public.sudoku_release(p_room uuid, p_host uuid, p_num int)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  delete from public.sudoku_tokens where room_id = p_room and num = p_num;
  return json_build_object('r','ok');
end $$;

-- 선생님: 시작
create or replace function public.sudoku_start(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  update public.sudoku_rooms
     set status = 'playing', started_at = now(), ends_at = now() + make_interval(secs => duration_sec)
   where id = p_room and status = 'lobby';
  return json_build_object('r','ok');
end $$;

-- 선생님: 끝내기
create or replace function public.sudoku_finish(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  update public.sudoku_rooms
     set status = 'ended', ends_at = least(coalesce(ends_at, now()), now())
   where id = p_room and status <> 'ended';
  return json_build_object('r','ok');
end $$;

-- 학생: 칸 풀기 (채점과 "먼저 맞힌 사람" 판정을 여기서 한다)
create or replace function public.sudoku_claim(p_room uuid, p_num int, p_token uuid, p_cell int, p_value int)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
  p int := p_num - 1;
  w int; row_i int; col_i int;
  nbs int[] := '{}';
  cur_owner int;
  v_sol smallint;
  ins int;
begin
  select * into r from public.sudoku_rooms where id = p_room;
  if not found then return json_build_object('r','no_room'); end if;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if now() >= r.ends_at then
    update public.sudoku_rooms set status = 'ended' where id = p_room and status = 'playing';
    return json_build_object('r','time_up');
  end if;

  select * into t from public.sudoku_tokens where room_id = p_room and num = p_num for update;
  if not found or t.token <> p_token then return json_build_object('r','bad_player'); end if;
  if t.last_wrong_at is not null and now() < t.last_wrong_at + interval '5 seconds' then
    return json_build_object('r','cooldown',
      'wait', ceil(extract(epoch from (t.last_wrong_at + interval '5 seconds' - now()))));
  end if;

  w := r.k * 9;
  if p_cell is null or p_cell < 0 or p_cell >= w*w or p_value not between 1 and 9 then
    return json_build_object('r','illegal');
  end if;
  if r.puzzle[p_cell+1] <> 0 then return json_build_object('r','illegal'); end if;
  if exists (select 1 from public.sudoku_claims where room_id = p_room and cell = p_cell) then
    return json_build_object('r','taken');
  end if;

  cur_owner := r.init_owner[p_cell+1];
  if cur_owner <> p then
    row_i := p_cell / w; col_i := p_cell % w;
    if row_i > 0     then nbs := nbs || (p_cell - w); end if;
    if row_i < w - 1 then nbs := nbs || (p_cell + w); end if;
    if col_i > 0     then nbs := nbs || (p_cell - 1); end if;
    if col_i < w - 1 then nbs := nbs || (p_cell + 1); end if;
    if not exists (
      select 1 from unnest(nbs) nb
      left join public.sudoku_claims c on c.room_id = p_room and c.cell = nb
      where coalesce(c.player, r.init_owner[nb+1]) = p
    ) then
      return json_build_object('r','illegal');
    end if;
  end if;

  select solution[p_cell+1] into v_sol from public.sudoku_secrets where room_id = p_room;
  if p_value <> v_sol then
    update public.sudoku_tokens set last_wrong_at = now() where room_id = p_room and num = p_num;
    update public.sudoku_players set miss = miss + 1 where room_id = p_room and num = p_num;
    return json_build_object('r','wrong');
  end if;

  insert into public.sudoku_claims (room_id, cell, player, prev_owner)
  values (p_room, p_cell, p, cur_owner) on conflict do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then return json_build_object('r','taken'); end if;

  update public.sudoku_players
     set atk = atk + (cur_owner <> p)::int, def = def + (cur_owner = p)::int
   where room_id = p_room and num = p_num;

  if (select count(*) from public.sudoku_claims where room_id = p_room) >= r.blanks then
    update public.sudoku_rooms set status = 'ended', ends_at = now() where id = p_room and status = 'playing';
  end if;

  return json_build_object('r','ok', 'prev', cur_owner,
    'kind', case when cur_owner = p then 'def' when cur_owner = -1 then 'neutral' else 'atk' end);
end $$;

revoke execute on function
  public.sudoku_create_room(int,int,text,int,smallint[],smallint[],smallint[],boolean[]),
  public.sudoku_join(text,int,uuid),
  public.sudoku_release(uuid,uuid,int),
  public.sudoku_start(uuid,uuid),
  public.sudoku_finish(uuid,uuid),
  public.sudoku_claim(uuid,int,uuid,int,int)
from public;
grant execute on function
  public.sudoku_create_room(int,int,text,int,smallint[],smallint[],smallint[],boolean[]),
  public.sudoku_join(text,int,uuid),
  public.sudoku_release(uuid,uuid,int),
  public.sudoku_start(uuid,uuid),
  public.sudoku_finish(uuid,uuid),
  public.sudoku_claim(uuid,int,uuid,int,int)
to anon, authenticated;

-- ===== 실시간 알림 =====
alter publication supabase_realtime add table public.sudoku_rooms, public.sudoku_players, public.sudoku_claims;
