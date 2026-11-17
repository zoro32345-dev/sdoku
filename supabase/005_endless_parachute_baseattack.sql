-- 끝없는 판 + 낙하산 + 본진 공격
-- · 칸(claims)에 solved 추가: 땅 주인은 남기고 숫자만 다시 빈칸으로 만들 수 있게
-- · 9×9 판이 다 채워지면 숫자를 섞어 새 문제로 (같은 모양의 빈칸, 숫자만 바뀜 → 답은 여전히 하나)
-- · 둘 곳이 하나도 없는 학생은 아무 빈칸이나 풀 수 있다 (낙하산)
-- · 선생님이 본진 공격을 열면 모든 판이 '공격용 문제'(본진도 빈칸이 될 수 있는 문제)로 바뀐다

alter table public.sudoku_claims add column solved boolean not null default true;
alter table public.sudoku_rooms add column base_open boolean not null default false;
alter table public.sudoku_rooms add column refreshes int not null default 0;
alter table public.sudoku_rooms add column last_block int;
alter table public.sudoku_secrets add column mask_closed boolean[];
alter table public.sudoku_secrets add column mask_open boolean[];

-- 판 하나(p_bx, p_by)를 새 문제로. 학생이 직접 부르지 못하는 내부용 함수.
create or replace function public.sudoku_refresh_block(p_room uuid, p_bx int, p_by int)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  s public.sudoku_secrets;
  perm int[];
  w int; rr int; cc int; idx int;
  sol smallint[]; puz smallint[]; m boolean[];
  given boolean;
begin
  select * into r from public.sudoku_rooms where id = p_room;
  select * into s from public.sudoku_secrets where room_id = p_room;
  perm := (select array_agg(x order by random()) from generate_series(1,9) x);
  w := r.k * 9; sol := s.solution; puz := r.puzzle;
  m := case when r.base_open then s.mask_open else s.mask_closed end;
  for rr in 0..8 loop
    for cc in 0..8 loop
      idx := (p_by*9 + rr)*w + p_bx*9 + cc + 1;
      given := coalesce(m[idx], puz[idx] <> 0);
      sol[idx] := perm[sol[idx]];
      puz[idx] := case when given then sol[idx] else 0 end;
    end loop;
  end loop;
  update public.sudoku_secrets set solution = sol where room_id = p_room;
  update public.sudoku_rooms set puzzle = puz, refreshes = refreshes + 1, last_block = p_by * r.k + p_bx where id = p_room;
  update public.sudoku_claims set solved = false, value = 0
   where room_id = p_room and solved
     and (cell / w) / 9 = p_by and (cell % w) / 9 = p_bx;
end $$;
revoke execute on function public.sudoku_refresh_block(uuid,int,int) from public, anon, authenticated;

-- 선생님: 본진 공격 열기 → 모든 판을 공격용 문제로
create or replace function public.sudoku_open_bases(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  v_bx int; v_by int;
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_room::text));
  select * into r from public.sudoku_rooms where id = p_room;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if r.base_open then return json_build_object('r','ok'); end if;
  update public.sudoku_rooms set base_open = true where id = p_room;
  for v_by in 0..r.k-1 loop
    for v_bx in 0..r.k-1 loop
      perform public.sudoku_refresh_block(p_room, v_bx, v_by);
    end loop;
  end loop;
  return json_build_object('r','ok');
end $$;

-- 방 만들기: 공격용 문제 모양(p_mask_open)도 함께 받는다
drop function public.sudoku_create_room(text,int,int,int,text,int,smallint[],smallint[],smallint[],boolean[]);
create or replace function public.sudoku_create_room(
  p_mode text, p_n int, p_students int, p_k int, p_diff text, p_duration int,
  p_puzzle smallint[], p_solution smallint[], p_owner smallint[], p_base boolean[], p_mask_open boolean[]
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
  if cardinality(p_puzzle) <> c or cardinality(p_solution) <> c or cardinality(p_owner) <> c
     or cardinality(p_base) <> c or cardinality(p_mask_open) <> c then raise exception 'bad_length'; end if;
  for i in 1..c loop
    if p_solution[i] not between 1 and 9 then raise exception 'bad_solution'; end if;
    if p_puzzle[i] <> 0 and p_puzzle[i] <> p_solution[i] then raise exception 'bad_puzzle'; end if;
    if p_owner[i] < -1 or p_owner[i] >= p_n then raise exception 'bad_owner'; end if;
    if p_base[i] and p_puzzle[i] = 0 then raise exception 'bad_base'; end if;
  end loop;

  delete from public.sudoku_rooms where created_at < now() - interval '2 days';

  loop
    v_code := lpad((floor(random()*10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.sudoku_rooms where code = v_code and status <> 'ended');
  end loop;

  insert into public.sudoku_rooms (code, mode, n, students, k, diff, duration_sec, puzzle, init_owner, base, blanks)
  values (v_code, p_mode, p_n, v_students, p_k, p_diff, p_duration, p_puzzle, p_owner, p_base,
          (select count(*) from unnest(p_puzzle) x where x = 0))
  returning id into v_room;
  insert into public.sudoku_secrets (room_id, host_key, solution, mask_closed, mask_open)
  values (v_room, v_host, p_solution, (select array_agg(x <> 0 order by o) from unnest(p_puzzle) with ordinality t(x,o)), p_mask_open);

  return json_build_object('room_id', v_room, 'code', v_code, 'host_key', v_host);
end $$;

-- 칸 풀기
create or replace function public.sudoku_claim(p_room uuid, p_num int, p_token uuid, p_cell int, p_value int)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
  ex public.sudoku_claims;
  cl record;
  p int;
  w int; row_i int; col_i int; c int; cr int; ccol int;
  nbs int[] := '{}';
  cur_owner int;
  v_sol smallint;
  ins int;
  v_para boolean := false;
  own int[]; blank boolean[];
  v_bx int; v_by int; v_left int;
  v_refreshed boolean := false;
begin
  -- 한 방의 칸 풀기는 한 번에 하나씩 (동시에 눌러도 꼬이지 않게)
  perform pg_advisory_xact_lock(hashtext(p_room::text));

  select * into r from public.sudoku_rooms where id = p_room;
  if not found then return json_build_object('r','no_room'); end if;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if r.ends_at is not null and now() >= r.ends_at then
    update public.sudoku_rooms set status = 'ended' where id = p_room and status = 'playing';
    return json_build_object('r','time_up');
  end if;

  select * into t from public.sudoku_tokens where room_id = p_room and num = p_num;
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
  select * into ex from public.sudoku_claims where room_id = p_room and cell = p_cell;
  if found and ex.solved then return json_build_object('r','taken'); end if;

  cur_owner := coalesce(ex.player, r.init_owner[p_cell+1]);
  if cur_owner <> p then
    row_i := p_cell / w; col_i := p_cell % w;
    if row_i > 0 then nbs := nbs || (p_cell - w); end if;
    if row_i < w - 1 then nbs := nbs || (p_cell + w); end if;
    if col_i > 0 then nbs := nbs || (p_cell - 1); end if;
    if col_i < w - 1 then nbs := nbs || (p_cell + 1); end if;
    if not exists (
      select 1 from unnest(nbs) nb
      left join public.sudoku_claims c2 on c2.room_id = p_room and c2.cell = nb
      where coalesce(c2.player, r.init_owner[nb+1]) = p
    ) then
      -- 낙하산: 이 학생(모둠)이 둘 수 있는 칸이 하나도 없을 때만 허락
      own := r.init_owner::int[];
      blank := array(select x = 0 from unnest(r.puzzle) with ordinality t2(x,o) order by o);
      for cl in select cell, player, solved from public.sudoku_claims where room_id = p_room loop
        own[cl.cell+1] := cl.player;
        if cl.solved then blank[cl.cell+1] := false; end if;
      end loop;
      for c in 0..w*w-1 loop
        if blank[c+1] then
          cr := c / w; ccol := c % w;
          if own[c+1] = p
             or (cr > 0 and own[c-w+1] = p) or (cr < w-1 and own[c+w+1] = p)
             or (ccol > 0 and own[c] = p) or (ccol < w-1 and own[c+2] = p) then
            return json_build_object('r','illegal');
          end if;
        end if;
      end loop;
      v_para := true;
    end if;
  end if;

  select solution[p_cell+1] into v_sol from public.sudoku_secrets where room_id = p_room;
  if p_value <> v_sol then
    update public.sudoku_tokens set last_wrong_at = now() where room_id = p_room and num = p_num;
    update public.sudoku_players set miss = miss + 1 where room_id = p_room and num = p_num;
    return json_build_object('r','wrong');
  end if;

  if ex.cell is not null then
    update public.sudoku_claims
       set player = p, prev_owner = cur_owner, value = p_value, by_num = p_num, solved = true, created_at = now()
     where room_id = p_room and cell = p_cell and not solved;
  else
    insert into public.sudoku_claims (room_id, cell, player, prev_owner, value, by_num, solved)
    values (p_room, p_cell, p, cur_owner, p_value, p_num, true) on conflict do nothing;
  end if;
  get diagnostics ins = row_count;
  if ins = 0 then return json_build_object('r','taken'); end if;

  update public.sudoku_players
     set atk = atk + (cur_owner <> p)::int, def = def + (cur_owner = p)::int
   where room_id = p_room and num = p_num;

  -- 이 칸이 있는 9×9 판이 다 채워졌으면 새 문제로
  v_bx := (p_cell % w) / 9; v_by := (p_cell / w) / 9;
  select count(*) into v_left
    from generate_series(0,8) a, generate_series(0,8) b
   where r.puzzle[(v_by*9+a)*w + v_bx*9+b + 1] = 0
     and not exists (select 1 from public.sudoku_claims c3
                      where c3.room_id = p_room and c3.cell = (v_by*9+a)*w + v_bx*9+b and c3.solved);
  if v_left = 0 then
    perform public.sudoku_refresh_block(p_room, v_bx, v_by);
    v_refreshed := true;
  end if;

  return json_build_object('r','ok', 'prev', cur_owner, 'para', v_para, 'refreshed', v_refreshed,
    'kind', case when v_para then 'para' when cur_owner = p then 'def' when cur_owner = -1 then 'neutral' else 'atk' end);
end $$;

revoke execute on function
  public.sudoku_create_room(text,int,int,int,text,int,smallint[],smallint[],smallint[],boolean[],boolean[]),
  public.sudoku_open_bases(uuid,uuid)
from public;
grant execute on function
  public.sudoku_create_room(text,int,int,int,text,int,smallint[],smallint[],smallint[],boolean[],boolean[]),
  public.sudoku_open_bases(uuid,uuid)
to anon, authenticated;
