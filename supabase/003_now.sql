-- 데이터베이스의 현재 시각 (기기마다 시계가 달라도 남은 시간을 똑같이 보여 주려고)
create or replace function public.sudoku_now() returns timestamptz
language sql stable set search_path = '' as $$ select now() $$;
revoke execute on function public.sudoku_now() from public;
grant execute on function public.sudoku_now() to anon, authenticated;
