-- 모둠 대항전 + 무제한 시간
-- 개인전(solo): 땅 주인 = 학생 (n명). 모둠 대항(team): 땅 주인 = 모둠 (n개), 학생은 students명까지 번호로 들어와 모둠을 고른다.
-- duration_sec = 0 이면 무제한.

alter table public.sudoku_rooms add column mode text not null default 'solo' check (mode in ('solo','team'));
alter table public.sudoku_rooms add column students int;
update public.sudoku_rooms set students = n where students is null;
alter table public.sudoku_rooms drop constraint sudoku_rooms_duration_sec_check;
alter table public.sudoku_rooms add constraint sudoku_rooms_duration_sec_check check (duration_sec = 0 or duration_sec between 60 and 7200);

alter table public.sudoku_players add column team int;
update public.sudoku_players set team = num - 1 where team is null;

alter table public.sudoku_claims add column by_num int;

drop function public.sudoku_create_room(int,int,text,int,smallint[],smallint[],smallint[],boolean[]);
drop function public.sudoku_join(text,int,uuid);

-- 방 만들기
create or replace function public.sudoku_create_room(
  p_mode text, p_n int, p_students int, p_k int, p_diff text, p_duration int,
  p_puzzle smallint[], p_solution smallint[], p_owner smallint[], p_base boolean[]
) returns json
language plpgsql security definer set search_path = '' as $$
declare
  w int := p_k * 9;
  c int := w * w;
  v_code text;
  v_room uuid;
  v_host uuid := gen_random_uuid();
  v_students int;
  i int;
begin
  if p_mode not in ('solo','team') then raise exception 'bad_mode'; end if;
  if p_mode = 'team' then
    if p_n not between 2 and 10 or p_students not between 1 and 100 then raise exception 'bad_team'; end if;
    v_students := p_students;
  else
    v_students := p_n;
  end if;
  if not (p_duration = 0 or p_duration between 60 and 7200) then raise exception 'bad_duration'; end if;
  if p_k < 1 or p_k > 5 or (3*p_k)*(3*p_k) < 2*p_n then raise exception 'bad_size'; end if;
  if cardinality(p_puzzle) <> c or cardinality(p_solution) <> c
     or cardinality(p_owner) <> c or cardinality(p_base) <> c then raise exception 'bad_length'; end if;
  for i in 1..c loop
    if p_solution[i] not between 1 and 9 then raise exception 'bad_solution'; end if;
    if p_puzzle[i] <> 0 and p_puzzle[i] <> p_solution[i] then raise exception 'bad_puzzle'; end if;
    if p_owner[i] < -1 or p_owner[i] >= p_n then raise exception 'bad_owner'; end if;
    if p_base[i] and p_puzzle[i] = 0 then raise exception 'bad_base'; end if;
  end loop;

  -- 이틀 지난 방은 정리 (무제한 게임을 고려해 하루 → 이틀)
  delete from public.sudoku_rooms where created_at < now() - interval '2 days';

  loop
    v_code := lpad((floor(random()*10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.sudoku_rooms where code = v_code and status <> 'ended');
  end loop;

  insert into public.sudoku_rooms (code, mode, n, students, k, diff, duration_sec, puzzle, init_owner, base, blanks)
  values (v_code, p_mode, p_n, v_students, p_k, p_diff, p_duration, p_puzzle, p_owner, p_base,
          (select count(*) from unnest(p_puzzle) x where x = 0))
  returning id into v_room;
  insert into public.sudoku_secrets (room_id, host_key, solution) values (v_room, v_host, p_solution);

  return json_build_object('room_id', v_room, 'code', v_code, 'host_key', v_host);
end $$;

-- 학생 입장. 모둠 대항이면 모둠(p_team, 1부터)도 받는다. 모둠을 안 보내면 'need_team'과 모둠 수를 돌려준다.
create or replace function public.sudoku_join(p_code text, p_num int, p_team int default null, p_token uuid default null)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
  v_team int;
begin
  select * into r from public.sudoku_rooms where code = p_code and status <> 'ended'
    order by created_at desc limit 1;
  if not found then return json_build_object('r','no_room'); end if;
  if p_num is null or p_num < 1 or p_num > r.students then
    return json_build_object('r','bad_num', 'n', r.students);
  end if;

  select * into t from public.sudoku_tokens where room_id = r.id and num = p_num;
  if found then
    if p_token is not null and t.token = p_token then
      select team into v_team from public.sudoku_players where room_id = r.id and num = p_num;
      return json_build_object('r','ok', 'room_id', r.id, 'token', t.token, 'team', v_team);
    end if;
    return json_build_object('r','taken');
  end if;

  if r.mode = 'team' then
    if p_team is null or p_team < 1 or p_team > r.n then
      return json_build_object('r','need_team', 'teams', r.n);
    end if;
    v_team := p_team - 1;
  else
    v_team := p_num - 1;
  end if;

  insert into public.sudoku_players (room_id, num, team) values (r.id, p_num, v_team)
    on conflict (room_id, num) do update set team = excluded.team;
  insert into public.sudoku_tokens (room_id, num) values (r.id, p_num) returning * into t;
  return json_build_object('r','ok', 'room_id', r.id, 'token', t.token, 'team', v_team);
end $$;

-- 시작: 무제한이면 끝나는 시각 없음
create or replace function public.sudoku_start(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  update public.sudoku_rooms
     set status = 'playing', started_at = now(),
         ends_at = case when duration_sec = 0 then null else now() + make_interval(secs => duration_sec) end
   where id = p_room and status = 'lobby';
  return json_build_object('r','ok');
end $$;

create or replace function public.sudoku_finish(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  update public.sudoku_rooms
     set status = 'ended', ends_at = case when ends_at is null or ends_at > now() then now() else ends_at end
   where id = p_room and status <> 'ended';
  return json_build_object('r','ok');
end $$;

-- 칸 풀기: 땅은 학생의 모둠(개인전이면 자기 자신)에게
create or replace function public.sudoku_claim(p_room uuid, p_num int, p_token uuid, p_cell int, p_value int)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
  p int;
  w int; row_i int; col_i int;
  nbs int[] := '{}';
  cur_owner int;
  v_sol smallint;
  ins int;
begin
  select * into r from public.sudoku_rooms where id = p_room;
  if not found then return json_build_object('r','no_room'); end if;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if r.ends_at is not null and now() >= r.ends_at then
    update public.sudoku_rooms set status = 'ended' where id = p_room and status = 'playing';
    return json_build_object('r','time_up');
  end if;

  select * into t from public.sudoku_tokens where room_id = p_room and num = p_num for update;
  if not found or t.token <> p_token then return json_build_object('r','bad_player'); end if;
  select team into p from public.sudoku_players where room_id = p_room and num = p_num;
  if p is null then return json_build_object('r','bad_player'); end if;
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
    if row_i > 0 then nbs := nbs || (p_cell - w); end if;
    if row_i < w - 1 then nbs := nbs || (p_cell + w); end if;
    if col_i > 0 then nbs := nbs || (p_cell - 1); end if;
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

  insert into public.sudoku_claims (room_id, cell, player, prev_owner, value, by_num)
  values (p_room, p_cell, p, cur_owner, p_value, p_num) on conflict do nothing;
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
  public.sudoku_create_room(text,int,int,int,text,int,smallint[],smallint[],smallint[],boolean[]),
  public.sudoku_join(text,int,int,uuid)
from public;
grant execute on function
  public.sudoku_create_room(text,int,int,int,text,int,smallint[],smallint[],smallint[],boolean[]),
  public.sudoku_join(text,int,int,uuid)
to anon, authenticated;
