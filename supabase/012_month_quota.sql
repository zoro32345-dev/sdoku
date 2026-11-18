-- 012. 이번 달 몇 번 더 할 수 있는지도 같이 세어 줍니다 (2026-11-19)
--
-- 무료는 두 군데서 막힙니다.
--   1) 동시 접속 200개  → 지금 몇 반이 하고 있나 (011)
--   2) 월 메시지 200만  → 이번 달 몇 번 더 할 수 있나 (이 파일)
--
-- 메시지 어림:
--   칸 하나가 바뀔 때마다 그 방에 붙은 사람 수만큼 알림이 나갑니다.
--     = 푼 칸 x (학생 수 + 1)      ← +1 은 선생님 화면
--   되찾은 칸, 새 문제로 바뀐 칸 때문에 실제로는 조금 더 나가서 1.2배로 봅니다.
--
-- 'cells'(한 판에 푸는 칸)만 돌려주고 남은 횟수는 화면에서 셉니다.
-- 선생님이 고른 인원에 따라 한 판 값이 달라지기 때문입니다.
--
-- 같이 고치는 파일: online/teacher.html (남은횟수 / 자리그리기)

create or replace function public.sudoku_load()
returns json
language sql
security definer
set search_path to ''
stable
as $$
  with 산방 as (
    select r.id from public.sudoku_rooms r
     where r.status in ('lobby', 'playing')
       and r.created_at > now() - interval '3 hours'
  ),
  지금 as (
    select (select count(*) from 산방) as 방수,
           (select count(*) from public.sudoku_players p
             where p.room_id in (select id from 산방)) as 학생수
  ),
  이번달 as (
    select r.id,
           (select count(*) from public.sudoku_players p where p.room_id = r.id) as 사람,
           (select count(*) from public.sudoku_claims  c where c.room_id = r.id) as 칸
      from public.sudoku_rooms r
     where r.created_at >= date_trunc('month', now())
  ),
  쓴것 as (
    select coalesce(sum((칸 * (사람 + 1) * 1.2))::bigint, 0)              as 메시지,
           count(*) filter (where 사람 >= 2 and 칸 > 0)                    as 게임수,
           coalesce(avg(칸) filter (where 사람 >= 5 and 칸 > 50), 0)::int  as 칸평균
      from 이번달
  )
  select json_build_object(
    'rooms',  방수,
    'people', 학생수 + 방수,
    'cap',    200,
    'left',   greatest(0, 200 - (학생수 + 방수)),
    'used',   메시지,
    'msgcap', 2000000,
    'played', 게임수,
    'cells',  greatest(100, coalesce(nullif(칸평균, 0), 350))
  ) from 지금, 쓴것;
$$;

grant execute on function public.sudoku_load() to anon, authenticated;
