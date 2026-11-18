-- 3×3 다시 비우기
-- · 3×3 하나가 다 채워지면 그 3×3의 빈칸이던 자리를 다시 빈칸으로 (같은 문제, 땅 주인은 그대로)
-- · 한 9×9 판의 3×3 9개가 모두 한 번씩 채워지면 그 판은 숫자를 섞은 완전히 새 문제로
-- · 판마다 "채운 3×3"을 비트(9자리)로 기억한다: rooms.box_done[판번호+1]

alter table public.sudoku_rooms add column box_done int[];
alter table public.sudoku_rooms add column reblanks int not null default 0;
alter table public.sudoku_rooms add column last_box int;

-- 판을 새 문제로 바꿀 때 그 판의 "채운 3×3" 기록도 비운다
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
  bd int[];
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
  bd := coalesce(r.box_done, array_fill(0, array[r.k*r.k]));
  bd[p_by*r.k + p_bx + 1] := 0;
  update public.sudoku_secrets set solution = sol where room_id = p_room;
  update public.sudoku_rooms set puzzle = puz, refreshes = refreshes + 1, last_block = p_by * r.k + p_bx, box_done = bd
   where id = p_room;
  update public.sudoku_claims set solved = false, value = 0
   where room_id = p_room and solved
     and (cell / w) / 9 = p_by and (cell % w) / 9 = p_bx;
end $$;
revoke execute on function public.sudoku_refresh_block(uuid,int,int) from public, anon, authenticated;

-- 3×3 하나가 다 찼을 때 부르는 내부용 함수. 반환: 'reblank'(3×3만 다시 비움) 또는 'refresh'(판 전체 새 문제)
create or replace function public.sudoku_box_full(p_room uuid, p_gx int, p_gy int)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  r public.sudoku_rooms;
  w int; v_bx int; v_by int; b int; bit int; mask int; i int; ox int; oy int;
  bd int[];
begin
  select * into r from public.sudoku_rooms where id = p_room;
  w := r.k * 9; v_bx := p_gx / 3; v_by := p_gy / 3; b := v_by*r.k + v_bx;
  bit := (p_gy % 3)*3 + (p_gx % 3);
  bd := coalesce(r.box_done, array_fill(0, array[r.k*r.k]));
  mask := bd[b+1] | (1 << bit);
  -- 처음부터 빈칸이 없는 3×3(본진 등)은 이미 채운 것으로 친다
  for i in 0..8 loop
    if mask & (1 << i) = 0 then
      ox := v_bx*9 + (i % 3)*3; oy := v_by*9 + (i / 3)*3;
      if not exists (select 1 from generate_series(0,2) a, generate_series(0,2) c
                      where r.puzzle[(oy+a)*w + ox+c + 1] = 0) then
        mask := mask | (1 << i);
      end if;
    end if;
  end loop;
  if mask = 511 then
    perform public.sudoku_refresh_block(p_room, v_bx, v_by);
    return 'refresh';
  end if;
  bd[b+1] := mask;
  update public.sudoku_rooms set box_done = bd, reblanks = reblanks + 1, last_box = p_gy*(r.k*3) + p_gx
   where id = p_room;
  update public.sudoku_claims set solved = false, value = 0
   where room_id = p_room and solved
     and (cell / w) / 3 = p_gy and (cell % w) / 3 = p_gx;
  return 'reblank';
end $$;
revoke execute on function public.sudoku_box_full(uuid,int,int) from public, anon, authenticated;

-- 칸 풀기: 판 전체 대신 3×3이 다 찼는지 본다
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

  -- 이 칸이 있는 3×3이 다 채워졌으면: 다시 비우기, 판의 3×3이 모두 한 번씩 찼으면 판 전체 새 문제
  v_gx := (p_cell % w) / 3; v_gy := (p_cell / w) / 3;
  select count(*) into v_left
    from generate_series(0,2) a, generate_series(0,2) b
   where r.puzzle[(v_gy*3+a)*w + v_gx*3+b + 1] = 0
     and not exists (select 1 from public.sudoku_claims c3
                      where c3.room_id = p_room and c3.cell = (v_gy*3+a)*w + v_gx*3+b and c3.solved);
  if v_left = 0 then
    v_full := public.sudoku_box_full(p_room, v_gx, v_gy);
  end if;

  return json_build_object('r','ok', 'prev', cur_owner, 'para', v_para,
    'refreshed', coalesce(v_full,'') = 'refresh', 'reblank', coalesce(v_full,'') = 'reblank',
    'kind', case when v_para then 'para' when cur_owner = p then 'def' when cur_owner = -1 then 'neutral' else 'atk' end);
end $$;
