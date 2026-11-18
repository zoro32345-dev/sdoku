-- 010. 점수(공격·수비) 알림도 실시간에서 뺍니다 (2026-11-19)
--
-- 왜:
--   한 칸을 맞히면 알림이 두 번 나갔습니다.
--     1) sudoku_claims 에 "이 칸을 1번이 먹었다"   ← 꼭 필요
--     2) sudoku_players 에 "1번 점수가 1 올랐다"   ← 1) 만 보면 알 수 있음
--   둘 다 교실 전원에게 가서, 알림이 두 배였습니다.
--
-- 어떻게:
--   늘 바뀌는 atk·def·para 는 아무도 구독하지 않는 sudoku_tokens 로 옮깁니다.
--   tickets·golds 는 가끔만 바뀌니 sudoku_players 에 그대로 두고,
--   실제로 바뀔 때만 적습니다(= 그때만 알림이 나갑니다).
--   보는 쪽은 1) 알림만 보고 점수를 스스로 세고, 30초마다 서버 값으로 맞춥니다.
--
-- 효과: 게임당 알림 16,300 → 8,200 (큰 지도 18명 기준, 한 달 245번)
--
-- 같이 고치는 파일: online/common.js (fetchPlayers), online/index.html·teacher.html (onClaim)
--
-- 되돌리려면: 3단계의 새줄을 옛줄로 되돌려 다시 실행하고,
--             common.js 의 fetchPlayers 를 sudoku_players 직접 읽기로 되돌립니다.

-- ── 1단계. 조용한 표에 점수 칸 만들기 ──────────────────────
alter table public.sudoku_tokens
  add column if not exists atk  int not null default 0,
  add column if not exists def  int not null default 0,
  add column if not exists para int not null default 0;

-- ── 2단계. 지금 돌고 있는 방이 있으면 세던 수를 옮겨 둡니다 ──
update public.sudoku_tokens t
   set atk = p.atk, def = p.def, para = p.para
  from public.sudoku_players p
 where p.room_id = t.room_id and p.num = t.num
   and (p.atk > 0 or p.def > 0 or p.para > 0);

-- ── 3단계. 맞혔을 때 적는 자리 나누기 ──────────────────────
do $outer$
declare
  src text;
  옛줄 text :=
'  update public.sudoku_players
     set atk = atk + (cur_owner <> p)::int, def = def + (cur_owner = p)::int,
         para = para + (v_para or v_ticket)::int, tickets = tickets - v_ticket::int, golds = golds + v_gold::int
   where room_id = p_room and num = p_num;';
  새줄 text :=
'  -- 늘 바뀌는 것 → 아무도 안 보는 표 (알림 안 나감)
  update public.sudoku_tokens
     set atk = atk + (cur_owner <> p)::int, def = def + (cur_owner = p)::int,
         para = para + (v_para or v_ticket)::int
   where room_id = p_room and num = p_num;
  -- 가끔만 바뀌는 것 → 보던 표 (바뀔 때만 알림)
  if v_ticket or v_gold then
    update public.sudoku_players
       set tickets = tickets - v_ticket::int, golds = golds + v_gold::int
     where room_id = p_room and num = p_num;
  end if;';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sudoku_claim';

  if src is null then raise exception 'sudoku_claim 함수를 못 찾았습니다'; end if;
  if position(옛줄 in src) = 0 then
    if position('update public.sudoku_tokens
     set atk = atk' in src) > 0 then
      raise notice '이미 바뀌어 있습니다 — 그냥 넘어갑니다';
      return;
    end if;
    raise exception '바꿀 줄을 못 찾았습니다 — 함수가 그 사이에 바뀐 것 같습니다';
  end if;

  execute replace(src, 옛줄, 새줄);
end $outer$;

-- ── 4단계. 방이 끝나면 점수도 같이 옮겨 적기 ───────────────
--     (009 에서 만든 방아쇠에 atk·def·para 를 더합니다)
create or replace function public.sudoku_copy_miss()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  update public.sudoku_players p
     set miss = t.miss, atk = t.atk, def = t.def, para = t.para
    from public.sudoku_tokens t
   where t.room_id = p.room_id and t.num = p.num
     and p.room_id = new.id
     and (p.miss, p.atk, p.def, p.para) is distinct from (t.miss, t.atk, t.def, t.para);
  return new;
end $fn$;

-- ── 5단계. 읽을 때는 두 표를 합쳐서 ────────────────────────
--     sudoku_tokens 에는 입장 열쇠(token)가 들어 있어 학생이 직접 읽으면 안 됩니다.
--     그래서 점수만 골라 내주는 함수를 따로 둡니다.
create or replace function public.sudoku_players_view(p_room uuid)
returns table (
  num int, team int, atk int, def int, miss int, para int,
  boxes int, golds int, tickets int, conquers int, joined_at timestamptz
)
language sql
security definer
set search_path to ''
stable
as $v$
  select p.num, p.team,
         coalesce(t.atk, p.atk), coalesce(t.def, p.def),
         coalesce(t.miss, p.miss), coalesce(t.para, p.para),
         p.boxes, p.golds, p.tickets, p.conquers, p.joined_at
    from public.sudoku_players p
    left join public.sudoku_tokens t
      on t.room_id = p.room_id and t.num = p.num
   where p.room_id = p_room
   order by p.num;
$v$;

grant execute on function public.sudoku_players_view(uuid) to anon, authenticated;
