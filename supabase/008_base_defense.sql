-- 본진 지키기 + 본진 함락
-- · 방패: 본진 공격 중에 학생(모둠)마다 한 번, 30초 동안 내 본진을 못 빼앗게
-- · 함락: 본진의 빈칸을 모두 빼앗기면 함락되고 숫자 칸까지 9칸 전부 빼앗은 쪽 땅. 빼앗은 학생은 정복 기록(칭호), 빼앗긴 쪽은 역전 찬스 2장 (탈락 없음)
-- · 탈환: 함락된 쪽이 자기 본진 칸을 하나라도 되찾으면 탈환 (다시 함락될 수 있음)

alter table public.sudoku_rooms add column shield_until timestamptz[];
alter table public.sudoku_rooms add column shield_used boolean[];
alter table public.sudoku_rooms add column fallen boolean[];
alter table public.sudoku_rooms add column falls int not null default 0;
alter table public.sudoku_rooms add column last_fall_victim int;
alter table public.sudoku_rooms add column last_fall_by int;
alter table public.sudoku_rooms add column last_fall_num int;
alter table public.sudoku_rooms add column retakes int not null default 0;
alter table public.sudoku_rooms add column last_retake int;
alter table public.sudoku_players add column conquers int not null default 0;

-- 학생: 방패 쓰기 (본진 공격 중, 내 모둠/나에게 한 번)
create or replace function public.sudoku_shield(p_room uuid, p_num int, p_token uuid)
returns json
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  p int;
  su timestamptz[]; sd boolean[];
begin
  if not exists (select 1 from public.sudoku_tokens where room_id = p_room and num = p_num and token = p_token) then
    return json_build_object('r','bad_player');
  end if;
  perform pg_advisory_xact_lock(hashtext(p_room::text));
  select * into r from public.sudoku_rooms where id = p_room;
  if r.status <> 'playing' then return json_build_object('r','not_playing'); end if;
  if not r.base_open then return json_build_object('r','not_open'); end if;
  select team into p from public.sudoku_players where room_id = p_room and num = p_num;
  if p is null then return json_build_object('r','bad_player'); end if;
  sd := coalesce(r.shield_used, array_fill(false, array[r.n]));
  if sd[p+1] then return json_build_object('r','used'); end if;
  su := coalesce(r.shield_until, array_fill(null::timestamptz, array[r.n]));
  sd[p+1] := true; su[p+1] := now() + interval '30 seconds';
  update public.sudoku_rooms set shield_used = sd, shield_until = su where id = p_room;
  return json_build_object('r','ok');
end $$;
revoke execute on function public.sudoku_shield(uuid,int,uuid) from public;
grant execute on function public.sudoku_shield(uuid,int,uuid) to anon, authenticated;

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
  v_q int; v_touch boolean := false; v_fall boolean := false; v_retake boolean := false;
  v_fallen boolean[];
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

  -- 방패: 친구 본진이 방패 중이면 못 빼앗는다
  v_q := r.init_owner[p_cell+1];
  if r.base[p_cell+1] and v_q <> p and coalesce(r.shield_until[v_q+1] > now(), false) then
    return json_build_object('r','shielded');
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
        continue when r.base[nb+1] and r.init_owner[nb+1] <> p and coalesce(r.shield_until[r.init_owner[nb+1]+1] > now(), false);
        update public.sudoku_claims set prev_owner = player, player = p, by_num = p_num
         where room_id = p_room and cell = nb and player <> p;
        get diagnostics ins = row_count;
        if ins > 0 then v_got := v_got + 1; v_touch := v_touch or r.base[nb+1];
        elsif not exists (select 1 from public.sudoku_claims where room_id = p_room and cell = nb) then
          if r.init_owner[nb+1] <> p then
            insert into public.sudoku_claims (room_id, cell, player, prev_owner, value, by_num, solved)
            values (p_room, nb, p, r.init_owner[nb+1], 0, p_num, false);
            v_got := v_got + 1; v_touch := v_touch or r.base[nb+1];
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

  -- 본진 함락 / 탈환
  v_touch := v_touch or r.base[p_cell+1];
  if v_touch and r.base_open then
    v_fallen := coalesce(r.fallen, array_fill(false, array[r.n]));
    if r.base[p_cell+1] and v_q = p and v_fallen[p+1] then
      v_fallen[p+1] := false; v_retake := true;
      update public.sudoku_rooms set retakes = retakes + 1, last_retake = p where id = p_room;
    end if;
    for v_q in
      select bc.q from (
        select o-1 as cell, x as q from unnest(r.init_owner) with ordinality t(x,o) where r.base[o]
      ) bc left join public.sudoku_claims c4 on c4.room_id = p_room and c4.cell = bc.cell
      group by bc.q
      having count(*) filter (where r.puzzle[bc.cell+1] = 0) > 0
         and count(*) filter (where r.puzzle[bc.cell+1] = 0 and coalesce(c4.player, bc.q) = bc.q) = 0
    loop
      if v_q <> p and not v_fallen[v_q+1] then
        v_fallen[v_q+1] := true; v_fall := true;
        -- 함락: 숫자 칸까지 본진 9칸 전부 함락한 쪽 땅
        update public.sudoku_claims set prev_owner = player, player = p, by_num = p_num
         where room_id = p_room and player <> p
           and cell in (select o-1 from unnest(r.init_owner) with ordinality t(x,o) where r.base[o] and x = v_q);
        insert into public.sudoku_claims (room_id, cell, player, prev_owner, value, by_num, solved)
        select p_room, o-1, p, v_q, 0, p_num, false
          from unnest(r.init_owner) with ordinality t(x,o)
         where r.base[o] and x = v_q
           and not exists (select 1 from public.sudoku_claims c5 where c5.room_id = p_room and c5.cell = o-1);
        update public.sudoku_rooms set falls = falls + 1, last_fall_victim = v_q, last_fall_by = p, last_fall_num = p_num where id = p_room;
        update public.sudoku_players set conquers = conquers + 1 where room_id = p_room and num = p_num;
        update public.sudoku_players set tickets = tickets + 2 where room_id = p_room and team = v_q;
      end if;
    end loop;
    update public.sudoku_rooms set fallen = v_fallen where id = p_room;
  end if;

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
    'gold', v_gold, 'got', v_got, 'fall', v_fall, 'retake', v_retake,
    'refreshed', coalesce(v_full,'') = 'refresh', 'reblank', coalesce(v_full,'') = 'reblank',
    'kind', case when v_gold then 'gold' when v_ticket then 'ticket' when v_para then 'para'
                 when cur_owner = p then 'def' when cur_owner = -1 then 'neutral' else 'atk' end);
end $$;

