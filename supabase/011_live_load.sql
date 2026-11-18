-- 011. 지금 몇 명이 붙어 있는지 세어 주는 함수 (2026-11-19)
--
-- 왜: Supabase 무료는 동시 접속 200개까지입니다.
--     한 반이 선생님 1 + 학생 수만큼 씁니다(18명 반이면 19개).
--     꽉 찬 줄 모르고 수업을 시작하면 아이들이 못 들어오니,
--     방 만들기 전에 자리가 있는지 보여 주고, 모자라면 물어봅니다.
--
-- 3시간 넘은 방은 세지 않습니다 — 선생님이 「끝내기」를 안 누르고 창을 닫으면
-- 'playing' 인 채로 남습니다. 안 그러면 영원히 자리를 차지한 것처럼 보입니다.
--
-- 같이 고치는 파일: online/teacher.html (자리보기 / 자리그리기)

create or replace function public.sudoku_load()
returns json
language sql
security definer
set search_path to ''
stable
as $$
  with 산방 as (
    select r.id
      from public.sudoku_rooms r
     where r.status in ('lobby', 'playing')
       and r.created_at > now() - interval '3 hours'
  ),
  센것 as (
    select (select count(*) from 산방) as 방수,
           (select count(*) from public.sudoku_players p
             where p.room_id in (select id from 산방)) as 학생수
  )
  select json_build_object(
    'rooms',  방수,
    'people', 학생수 + 방수,          -- 선생님 화면도 연결 하나씩 씁니다
    'cap',    200,
    'left',   greatest(0, 200 - (학생수 + 방수))
  ) from 센것;
$$;

grant execute on function public.sudoku_load() to anon, authenticated;
