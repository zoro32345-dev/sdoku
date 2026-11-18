-- 황금 칸 + 피버 타임 + 역전 찬스 + 칭호용 기록
-- · 황금 칸: 선생님 화면이 1분쯤마다 만든다. 누구나(거리 상관없이) 풀 수 있고, 맞히면 둘레 8칸까지 내 땅
-- · 피버 타임: 선생님이 누르면 1분 동안 틀려도 쉬지 않는다
-- · 역전 찬스: 땅이 가장 적은 학생 3명(모둠전은 꼴찌 모둠)에게 "아무 빈칸이나 1번" 표를 준다
-- · 칭호: 낙하산(para), 3×3 마무리(boxes), 황금 칸(golds) 횟수를 학생별로 센다

alter table public.sudoku_rooms add column gold_cell int;
alter table public.sudoku_rooms add column golds int not null default 0;
alter table public.sudoku_rooms add column gold_by int;
alter table public.sudoku_rooms add column gold_by_num int;
alter table public.sudoku_rooms add column gold_last int;
alter table public.sudoku_rooms add column fever_until timestamptz;
alter table public.sudoku_rooms add column chances int not null default 0;
alter table public.sudoku_players add column para int not null default 0;
alter table public.sudoku_players add column boxes int not null default 0;
alter table public.sudoku_players add column golds int not null default 0;
alter table public.sudoku_players add column tickets int not null default 0;

-- 선생님: 황금 칸 만들기 (이미 살아 있는 황금 칸이 있으면 그대로)
create or replace function public.sudoku_spawn_gold(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  v_cell int;
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_room::text));
  select * into r from public.sudoku_rooms where id = p_room;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if r.gold_cell is not null and r.puzzle[r.gold_cell+1] = 0
     and not exists (select 1 from public.sudoku_claims where room_id = p_room and cell = r.gold_cell and solved) then
    return json_build_object('r','ok','cell',r.gold_cell);
  end if;
  select o-1 into v_cell
    from unnest(r.puzzle) with ordinality t(x,o)
   where x = 0
     and not exists (select 1 from public.sudoku_claims c where c.room_id = p_room and c.cell = o-1 and c.solved)
   order by random() limit 1;
  if v_cell is null then return json_build_object('r','no_blank'); end if;
  update public.sudoku_rooms set gold_cell = v_cell, golds = golds + 1 where id = p_room;
  return json_build_object('r','ok','cell',v_cell);
end $$;

-- 선생님: 피버 타임 1분
create or replace function public.sudoku_fever(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  update public.sudoku_rooms set fever_until = now() + interval '60 seconds'
   where id = p_room and status = 'playing';
  if not found then return json_build_object('r','not_playing'); end if;
  return json_build_object('r','ok');
end $$;

-- 선생님: 역전 찬스 (땅이 가장 적은 3명, 모둠전은 꼴찌 모둠 하나)
create or replace function public.sudoku_chance(p_room uuid, p_host uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  v_owners int[];
  v_nums int[];
begin
  if not exists (select 1 from public.sudoku_secrets where room_id = p_room and host_key = p_host) then
    return json_build_object('r','not_host');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_room::text));
  select * into r from public.sudoku_rooms where id = p_room;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  with own as (
    select o-1 as cell, coalesce(c.player, x) as owner
      from unnest(r.init_owner) with ordinality t(x,o)
      left join public.sudoku_claims c on c.room_id = p_room and c.cell = o-1
  ), joined as (
    select distinct team from public.sudoku_players where room_id = p_room
  ), land as (
    select j.team, (select count(*) from own where own.owner = j.team) as n from joined j
  )
  select array_agg(team order by n, team) into v_owners
    from (select team, n from land order by n, random()
          limit case when r.mode = 'team' then 1 else least(3, greatest(1, (select count(*) from land) - 1)) end) z;  -- 1등은 빼고
  if v_owners is null then return json_build_object('r','nobody'); end if;
  update public.sudoku_players set tickets = tickets + 1 where room_id = p_room and team = any(v_owners);
  select array_agg(num order by num) into v_nums from public.sudoku_players where room_id = p_room and team = any(v_owners);
  update public.sudoku_rooms set chances = chances + 1 where id = p_room;
  return json_build_object('r','ok','owners',to_json(v_owners),'nums',to_json(v_nums));
end $$;

-- 칸 풀기: 황금 칸, 피버, 역전 찬스 표, 칭호 기록 추가
create or replace function public.sudoku_claim(p_room uuid, p_num int, p_token uuid, p_cell int, p_value int)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  t public.sudoku_tokens;
  ex public.sudoku_claims;
  pl public.sudoku_players;
  cl record;
  p int;
  w int; row_i int; col_i int; c int; cr int; ccol int; nb int; a int; b int;
  nbs int[] := '{}';
  cur_owner int;
  v_sol smallint;
  ins int;
  v_para boolean := false;
  v_ticket boolean := false;
  v_gold boolean := false;
  v_fever boolean;
  v_got int := 0;
  own int[]; blank boolean[];
  v_gx int; v_gy int; v_left int;
  v_full text;
begin
  perform pg_advisory_xact_lock(hashtext(p_room::text));

  select * into r from public.sudoku_rooms where id = p_room;
  if not found then return json_build_object('r','no_room'); end if;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if r.ends_at is not null and now() >= r.ends_at then
    update public.sudoku_rooms set status = 'ended' where id = p_room and status = 'playing';
    return json_build_object('r','time_up');
  end if;
  v_fever := r.fever_until is not null and now() < r.fever_until;

  select * into t from public.sudoku_tokens where room_id = p_room and num = p_num;
  if not found or t.token <> p_token then return json_build_object('r','bad_player'); end if;
  select * into pl from public.sudoku_players where room_id = p_room and num = p_num;
  if not found or pl.team is null then return json_build_object('r','bad_player'); end if;
  p := pl.team;
  if not v_fever and t.last_wrong_at is not null and now() < t.last_wrong_at + interval '5 seconds' then
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

  v_gold := r.gold_cell is not null and p_cell = r.gold_cell;
  cur_owner := coalesce(ex.player, r.init_owner[p_cell+1]);
  if cur_owner <> p and not v_gold then
    row_i := p_cell / w; col_i := p_cell % w;
    if row_i > 0 then nbs := nbs || (p_cell - w); end if;
    if row_i < w - 1 then nbs := nbs || (p_cell + w); end if;
    if col_i > 0 then nbs := nbs || (p_cell - 1); end if;
    if col_i < w - 1 then nbs := nbs || (p_cell + 1); end if;
    if not exists (
      select 1 from unnest(nbs) x
      left join public.sudoku_claims c2 on c2.room_id = p_room and c2.cell = x
      where coalesce(c2.player, r.init_owner[x+1]) = p
    ) then
      own := r.init_owner::int[];
      blank := array(select x = 0 from unnest(r.puzzle) with ordinality t2(x,o) order by o);
      for cl in select cell, player, solved from public.sudoku_claims where room_id = p_room loop
        own[cl.cell+1] := cl.player;
        if cl.solved then blank[cl.cell+1] := false; end if;
      end loop;
      v_para := true;
      for c in 0..w*w-1 loop
        if blank[c+1] then
          cr := c / w; ccol := c % w;
          if own[c+1] = p
             or (cr > 0 and own[c-w+1] = p) or (cr < w-1 and own[c+w+1] = p)
             or (ccol > 0 and own[c] = p) or (ccol < w-1 and own[c+2] = p) then
            v_para := false; exit;
          end if;
        end if;
      end loop;
      if not v_para then
        -- 둘 곳이 있는데 멀리 있는 칸: 역전 찬스 표가 있어야 한다
        if pl.tickets > 0 then v_ticket := true;
        else return json_build_object('r','illegal');
        end if;
      end if;
    end if;
  end if;

  select solution[p_cell+1] into v_sol from public.sudoku_secrets where room_id = p_room;
  if p_value <> v_sol then
    if not v_fever then
      update public.sudoku_tokens set last_wrong_at = now() where room_id = p_room and num = p_num;
    end if;
    update public.sudoku_players set miss = miss + 1 where room_id = p_room and num = p_num;
    return json_build_object('r','wrong','fever',v_fever);
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

  -- 황금 칸: 둘레 8칸도 내 땅 (본진은 본진 공격이 열렸을 때만)
  if v_gold then
    row_i := p_cell / w; col_i := p_cell % w;
    for a in -1..1 loop
      for b in -1..1 loop
        continue when a = 0 and b = 0;
        continue when row_i + a < 0 or row_i + a >= w or col_i + b < 0 or col_i + b >= w;
        nb := (row_i + a) * w + col_i + b;
        continue when r.base[nb+1] and not r.base_open;
        update public.sudoku_claims set prev_owner = player, player = p, by_num = p_num
         where room_id = p_room and cell = nb and player <> p;
        get diagnostics ins = row_count;
        if ins > 0 then v_got := v_got + 1;
        elsif not exists (select 1 from public.sudoku_claims where room_id = p_room and cell = nb) then
          if r.init_owner[nb+1] <> p then
            insert into public.sudoku_claims (room_id, cell, player, prev_owner, value, by_num, solved)
            values (p_room, nb, p, r.init_owner[nb+1], 0, p_num, false);
            v_got := v_got + 1;
          end if;
        end if;
      end loop;
    end loop;
    update public.sudoku_rooms set gold_cell = null, gold_by = p, gold_by_num = p_num, gold_last = p_cell where id = p_room;
  end if;

  update public.sudoku_players
     set atk = atk + (cur_owner <> p)::int, def = def + (cur_owner = p)::int,
         para = para + (v_para or v_ticket)::int, tickets = tickets - v_ticket::int, golds = golds + v_gold::int
   where room_id = p_room and num = p_num;

  -- 이 칸이 있는 3×3이 다 채워졌으면: 다시 비우기, 판의 3×3이 모두 한 번씩 찼으면 판 전체 새 문제
  v_gx := (p_cell % w) / 3; v_gy := (p_cell / w) / 3;
  select count(*) into v_left
    from generate_series(0,2) ga, generate_series(0,2) gb
   where r.puzzle[(v_gy*3+ga)*w + v_gx*3+gb + 1] = 0
     and not exists (select 1 from public.sudoku_claims c3
                      where c3.room_id = p_room and c3.cell = (v_gy*3+ga)*w + v_gx*3+gb and c3.solved);
  if v_left = 0 then
    v_full := public.sudoku_box_full(p_room, v_gx, v_gy);
    update public.sudoku_players set boxes = boxes + 1 where room_id = p_room and num = p_num;
  end if;

  return json_build_object('r','ok', 'prev', cur_owner, 'para', v_para, 'ticket', v_ticket,
    'gold', v_gold, 'got', v_got,
    'refreshed', coalesce(v_full,'') = 'refresh', 'reblank', coalesce(v_full,'') = 'reblank',
    'kind', case when v_gold then 'gold' when v_ticket then 'ticket' when v_para then 'para'
                 when cur_owner = p then 'def' when cur_owner = -1 then 'neutral' else 'atk' end);
end $$;

revoke execute on function
  public.sudoku_spawn_gold(uuid,uuid), public.sudoku_fever(uuid,uuid), public.sudoku_chance(uuid,uuid)
from public;
grant execute on function
  public.sudoku_spawn_gold(uuid,uuid), public.sudoku_fever(uuid,uuid), public.sudoku_chance(uuid,uuid)
to anon, authenticated;
