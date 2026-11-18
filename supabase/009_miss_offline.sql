-- 009. 「틀린 횟수」를 실시간 알림에서 뺍니다 (2026-11-19)
--
-- 왜:
--   아이가 답을 틀릴 때마다 sudoku_players.miss 를 1 올렸는데,
--   sudoku_players 는 교실 전원이 지켜보는 표라서 한 번 틀릴 때마다
--   참가자 수만큼 실시간 알림이 나갔습니다.
--   18명 한 반 게임에서 틀린 답이 1,494번 → 알림 28,386번.
--   그런데 이 숫자는 게임이 끝나고 「🎯 정확왕」 뽑을 때만 씁니다.
--
-- 어떻게:
--   1) 틀린 횟수를 아무도 구독하지 않는 sudoku_tokens 로 옮깁니다.
--   2) 방이 끝나는 순간 sudoku_players 로 한 번만 옮겨 적습니다.
--      (showEnd() 가 fetchPlayers 를 다시 읽으므로 정확왕은 그대로 나옵니다)
--
-- 효과: 게임당 알림 44,700 → 16,300 (63% 감소)
--
-- 되돌리려면: 아래 2단계의 'sudoku_tokens' 를 'sudoku_players' 로 바꿔 다시 실행하고,
--             drop trigger sudoku_miss_on_end on public.sudoku_rooms;

-- ── 1단계. 틀린 횟수를 담을 칸 ─────────────────────────────
alter table public.sudoku_tokens
  add column if not exists miss int not null default 0;

-- 지금 돌고 있는 방이 있으면 세던 수를 옮겨 둡니다 (안 그러면 0부터 다시 셉니다)
update public.sudoku_tokens t
   set miss = p.miss
  from public.sudoku_players p
 where p.room_id = t.room_id and p.num = t.num and p.miss > 0;

-- ── 2단계. 틀렸을 때 적는 자리 바꾸기 ──────────────────────
-- 함수가 300줄이라 통째로 다시 쓰지 않고, 그 한 줄만 바꿔 끼웁니다.
-- 못 찾으면 아무것도 바꾸지 않고 멈춥니다.
do $outer$
declare
  src text;
  옛줄 text := '    update public.sudoku_players set miss = miss + 1 where room_id = p_room and num = p_num;';
  새줄 text := '    update public.sudoku_tokens set miss = miss + 1 where room_id = p_room and num = p_num;';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sudoku_claim';

  if src is null then
    raise exception 'sudoku_claim 함수를 못 찾았습니다';
  end if;
  if position(옛줄 in src) = 0 then
    if position(새줄 in src) > 0 then
      raise notice '이미 바뀌어 있습니다 — 그냥 넘어갑니다';
      return;
    end if;
    raise exception '바꿀 줄을 못 찾았습니다 — 함수가 그 사이에 바뀐 것 같습니다';
  end if;

  execute replace(src, 옛줄, 새줄);
end $outer$;

-- ── 3단계. 방이 끝나면 한 번만 옮겨 적기 ───────────────────
create or replace function public.sudoku_copy_miss()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  update public.sudoku_players p
     set miss = t.miss
    from public.sudoku_tokens t
   where t.room_id = p.room_id and t.num = p.num
     and p.room_id = new.id
     and p.miss is distinct from t.miss;
  return new;
end $fn$;

drop trigger if exists sudoku_miss_on_end on public.sudoku_rooms;
create trigger sudoku_miss_on_end
after update of status on public.sudoku_rooms
for each row
when (new.status = 'ended' and old.status is distinct from 'ended')
execute function public.sudoku_copy_miss();
