-- 푼 칸의 숫자도 기록 (모든 화면에 숫자를 보여 주기 위해. 맞힌 뒤에는 공개되어도 괜찮은 값)
alter table public.sudoku_claims add column value smallint not null default 0;

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

  insert into public.sudoku_claims (room_id, cell, player, prev_owner, value)
  values (p_room, p_cell, p, cur_owner, p_value) on conflict do nothing;
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
