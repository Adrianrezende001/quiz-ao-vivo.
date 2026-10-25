-- =====================================================================
-- TESTES DO BANCO - QUIZ AO VIVO
-- Rode depois do schema.sql, no SQL Editor do Supabase.
-- Se a última mensagem for "TODOS OS TESTES PASSARAM", está tudo certo.
-- Os dados de teste são apagados no final.
-- =====================================================================

-- Ajudante: executa um comando e confirma que ele FALHA com a mensagem esperada.
create or replace function public.teste_erro(p_sql text, p_msg text)
returns void
language plpgsql
as $$
declare
  ok boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_msg || '%' then
      ok := true;
    else
      raise;
    end if;
  end;
  if not ok then
    raise exception 'FALHA: esperava o erro "%" e nada aconteceu', p_msg;
  end if;
end $$;

do $$
declare
  r jsonb;
  res jsonb;
  rid uuid;
  hk text;
  pin text;
  qs jsonb;
  bad jsonb;
  tok_ana text;
  tok_bia text;
  tok_caio text;
  st text;
  cur int;
  cnt int;
  sc int;
  nick text;
begin
  -- 1. Sala e PIN ------------------------------------------------------
  r := public.create_room('Aula de teste');
  rid := (r->>'room_id')::uuid;
  pin := r->>'pin';
  hk := r->>'host_key';
  assert pin ~ '^[0-9]{6}$', 'PIN deve ter 6 dígitos';
  raise notice 'OK 1: sala criada com PIN %', pin;

  -- 2. Quiz: salvar e recusar dados inválidos ------------------------
  qs := '[
    {"kind":"mc","prompt":"2 + 2?","options":["3","4","5"],"correct_index":1,"time_limit":20,"explanation":"2 + 2 = 4"},
    {"kind":"tf","prompt":"A Terra é plana?","correct_index":1,"time_limit":10,"double_points":true}
  ]'::jsonb;
  assert public.save_quiz(rid, hk, qs) = 2, 'deveria salvar 2 perguntas';
  assert (select options from public.questions where room_id = rid and position = 1) = array['Verdadeiro', 'Falso'],
    'verdadeiro/falso deve ter as opções fixas';

  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, 'chave-errada', qs), 'NOT_HOST');
  bad := '[{"kind":"mc","prompt":"x","options":["a","b"],"correct_index":0,"time_limit":5}]';
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, hk, bad), 'INVALID_TIME');
  bad := '[{"kind":"mc","prompt":"x","options":["a","b"],"correct_index":5,"time_limit":20}]';
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, hk, bad), 'INVALID_CORRECT');
  bad := '[{"kind":"mc","prompt":"x","options":["a"],"correct_index":0,"time_limit":20}]';
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, hk, bad), 'INVALID_OPTIONS');
  bad := '[{"kind":"xx","prompt":"x","options":["a","b"],"correct_index":0,"time_limit":20}]';
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, hk, bad), 'INVALID_KIND');
  bad := '[{"kind":"mc","prompt":"   ","options":["a","b"],"correct_index":0,"time_limit":20}]';
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, hk, bad), 'PROMPT_REQUIRED');
  select question_count into cnt from public.rooms where id = rid;
  assert cnt = 2, 'as tentativas inválidas não podem ter apagado o quiz';
  raise notice 'OK 2: quiz salvo e entradas inválidas recusadas';

  -- 3. Alunos entram com apelidos repetidos ---------------------------
  r := public.join_room(pin, 'Ana');
  tok_ana := r->>'token';
  assert r->>'nickname' = 'Ana', 'o primeiro Ana deve manter o nome';
  r := public.join_room(pin, 'Ana');
  assert r->>'nickname' = 'Ana 2', 'o segundo Ana deve virar Ana 2';
  r := public.join_room(pin, 'ana');
  assert r->>'nickname' = 'ana 3', 'ana repetido (sem diferença de maiúsculas) deve virar ana 3';
  r := public.join_room(pin, 'Bia');
  tok_bia := r->>'token';
  r := public.join_room(pin, 'Caio');
  tok_caio := r->>'token';

  select count(*) into cnt from public.players where room_id = rid;
  assert cnt = 5, 'deveriam existir 5 alunos';
  perform public.teste_erro(format('select public.join_room(%L,%L)', '000000', 'Zé'), 'PIN_NOT_FOUND');
  perform public.teste_erro(format('select public.join_room(%L,%L)', pin, '   '), 'NICKNAME_REQUIRED');
  raise notice 'OK 3: alunos entraram e apelidos repetidos receberam número';

  -- 3b. Presença: quem avisou nos últimos 30 s conta como conectado ----
  cnt := public.connected_count(rid);
  assert cnt = 5, 'os 5 alunos recém-entrados deveriam contar como conectados';
  update public.player_secrets set last_seen = now() - interval '60 seconds' where token = tok_caio;
  cnt := public.connected_count(rid);
  assert cnt = 4, 'aluno sem sinal há 60 s deixa de contar como conectado';
  set role anon;
  perform public.heartbeat(tok_caio);
  perform public.teste_erro(format('select public.heartbeat(%L)', 'token-falso'), 'INVALID_SESSION');
  reset role;
  cnt := public.connected_count(rid);
  assert cnt = 5, 'o sinal de vida volta a contar o aluno como conectado';
  raise notice 'OK 3b: presença dos alunos conferida';

  -- 4. Professor bloqueia a entrada -----------------------------------
  perform public.host_set_locked(rid, hk, true);
  perform public.teste_erro(format('select public.join_room(%L,%L)', pin, 'Dani'), 'ROOM_LOCKED');
  perform public.host_set_locked(rid, hk, false);
  raise notice 'OK 4: sala bloqueada recusa novos alunos';

  -- 5. Início da partida ----------------------------------------------
  perform public.host_start(rid, hk);
  select status, current_index into st, cur from public.rooms where id = rid;
  assert st = 'question' and cur = 0, 'a partida deveria começar na pergunta 1';
  perform public.teste_erro(format('select public.host_start(%L,%L)', rid, hk), 'ALREADY_STARTED');
  perform public.teste_erro(format('select public.host_next(%L,%L)', rid, 'chave-errada'), 'NOT_HOST');
  perform public.teste_erro(format('select public.host_next(%L,%L)', rid, hk), 'NOT_REVEALED');
  raise notice 'OK 5: partida iniciada, avanço bloqueado enquanto a pergunta está aberta';

  -- 6. Respostas: 10 s de 20 s decorridos = 750 pontos ----------------
  update public.rooms
     set started_at = now() - interval '10 seconds',
         ends_at = now() + interval '10 seconds'
   where id = rid;

  set role anon;
  perform public.submit_answer(tok_ana, 1);   -- correta
  perform public.submit_answer(tok_bia, 0);   -- errada
  perform public.teste_erro(format('select public.submit_answer(%L,%L)', tok_ana, 1), 'ALREADY_ANSWERED');
  perform public.teste_erro(format('select public.submit_answer(%L,%L)', tok_caio, 7), 'INVALID_OPTION');
  perform public.teste_erro(format('select public.submit_answer(%L,%L)', 'token-falso', 1), 'INVALID_SESSION');
  reset role;

  select score into sc from public.players where nickname = 'Ana' and room_id = rid;
  assert sc = 750, format('Ana deveria ter 750 pontos e tem %s', sc);
  select score into sc from public.players where nickname = 'Bia' and room_id = rid;
  assert sc = 0, 'resposta errada deve valer 0 pontos';
  select answer_count into cnt from public.rooms where id = rid;
  assert cnt = 2, 'deveriam ser contadas 2 respostas';
  raise notice 'OK 6: pontuação calculada no servidor, duplicadas e inválidas recusadas';

  -- 7. Permissões: aluno não lê gabarito, não altera pontos -----------
  set role anon;
  select count(*) into cnt from public.questions;   -- leitura permitida
  assert cnt = 2, 'aluno deveria ver as perguntas';
  perform public.teste_erro('select * from public.answer_keys', 'permission denied');
  perform public.teste_erro('select * from public.room_secrets', 'permission denied');
  perform public.teste_erro('select * from public.player_secrets', 'permission denied');
  perform public.teste_erro('select * from public.answers', 'permission denied');
  perform public.teste_erro(format('update public.players set score = 9999 where room_id = %L', rid), 'permission denied');
  perform public.teste_erro(format('insert into public.rooms (title) values (%L)', 'invasao'), 'permission denied');
  perform public.teste_erro(format('select public.check_host(%L,%L)', rid, hk), 'permission denied');
  perform public.teste_erro(format('select public.start_question(%L,0)', rid), 'permission denied');
  perform public.teste_erro(format('select public.save_quiz(%L,%L,%L::jsonb)', rid, 'chave-errada', '[]'), 'NOT_HOST');
  reset role;
  raise notice 'OK 7: aluno não consegue ler gabarito, chaves nem alterar pontos';

  -- 8. Tempo acaba: respostas fecham sozinhas e o gabarito aparece -----
  update public.rooms set ends_at = now() - interval '5 seconds' where id = rid;
  set role anon;
  perform public.teste_erro(format('select public.submit_answer(%L,%L)', tok_caio, 0), 'ANSWER_CLOSED');
  res := public.get_reveal(rid);
  reset role;
  assert (res->>'correct_index')::int = 1, 'gabarito da pergunta 1 deveria ser 1';
  assert res->>'explanation' = '2 + 2 = 4', 'explicação incorreta';
  assert (res->>'answer_count')::int = 2, 'o gabarito deveria informar 2 respostas';
  select status into st from public.rooms where id = rid;
  assert st = 'reveal', 'a sala deveria estar em revelação';
  raise notice 'OK 8: respostas fecham no prazo e o gabarito só aparece depois';

  -- 9. Próxima pergunta (em dobro): 5 s de 10 s = 750 x 2 = 1500 ------
  perform public.host_next(rid, hk);
  select status, current_index into st, cur from public.rooms where id = rid;
  assert st = 'question' and cur = 1, 'deveria ir para a pergunta 2';
  update public.rooms
     set started_at = now() - interval '5 seconds',
         ends_at = now() + interval '5 seconds'
   where id = rid;
  set role anon;
  perform public.submit_answer(tok_ana, 1);
  perform public.submit_answer(tok_bia, 1);
  reset role;
  select score into sc from public.players where nickname = 'Ana' and room_id = rid;
  assert sc = 2250, format('Ana deveria ter 2250 pontos e tem %s', sc);
  select score into sc from public.players where nickname = 'Bia' and room_id = rid;
  assert sc = 1500, format('Bia deveria ter 1500 pontos e tem %s', sc);
  raise notice 'OK 9: pergunta em dobro vale o dobro';

  -- 10. Fim da partida, ranking e reconexão ---------------------------
  update public.rooms set ends_at = now() - interval '5 seconds' where id = rid;
  perform public.get_reveal(rid);
  perform public.host_next(rid, hk);
  select status into st from public.rooms where id = rid;
  assert st = 'finished', 'a partida deveria estar encerrada';

  select nickname into nick from public.players
   where room_id = rid order by score desc, joined_at asc limit 1;
  assert nick = 'Ana', 'Ana deveria estar em primeiro no ranking';

  set role anon;
  perform public.teste_erro(format('select public.join_room(%L,%L)', pin, 'Novo'), 'ROOM_ENDED');
  res := public.rejoin(tok_ana);
  reset role;
  assert (res->>'score')::int = 2250, 'reconexão deveria devolver os 2250 pontos';
  assert public.rejoin('token-falso') is null, 'token falso não pode reconectar ninguém';
  raise notice 'OK 10: ranking correto, reconexão preserva pontos, entrada fechada após o fim';

  -- 11. Jogar novamente -----------------------------------------------
  perform public.teste_erro(format('select public.host_reset(%L,%L)', rid, 'chave-errada'), 'NOT_HOST');
  perform public.host_reset(rid, hk);
  select status into st from public.rooms where id = rid;
  assert st = 'lobby', 'reiniciar deveria voltar para a sala de espera';
  select count(*) into cnt from public.players where room_id = rid and score <> 0;
  assert cnt = 0, 'reiniciar deveria zerar os pontos';
  select count(*) into cnt from public.answers where room_id = rid;
  assert cnt = 0, 'reiniciar deveria apagar as respostas';
  raise notice 'OK 11: jogar novamente zera tudo';

  -- 12. Encerrar a sessão ---------------------------------------------
  perform public.host_end_room(rid, hk);
  set role anon;
  perform public.teste_erro(format('select public.join_room(%L,%L)', pin, 'Tarde'), 'ROOM_ENDED');
  reset role;
  raise notice 'OK 12: sessão encerrada não aceita novos alunos';

  -- 13. Fórmula de pontuação (conferida com contas à mão) -------------
  assert public.calc_points(0, 20, false) = 1000, 'resposta instantânea = 1000';
  assert public.calc_points(0.3, 20, false) = 1000, 'abaixo de 0,5 s = 1000';
  assert public.calc_points(0.5, 10, false) = 975, '0,5 s de 10 s = 975';
  assert public.calc_points(5, 20, false) = 875, '5 s de 20 s = 875';
  assert public.calc_points(10, 20, false) = 750, '10 s de 20 s = 750';
  assert public.calc_points(20, 20, false) = 500, 'no limite do tempo = 500';
  assert public.calc_points(100, 20, false) = 500, 'passou do tempo continua em 500';
  assert public.calc_points(5, 10, true) = 1500, 'em dobro: 750 x 2 = 1500';
  raise notice 'OK 13: fórmula de pontuação confere';

  -- 14. Tempo real ligado para sala e alunos --------------------------
  select count(*) into cnt from pg_publication_tables
   where pubname = 'supabase_realtime' and tablename in ('rooms', 'players');
  assert cnt = 2, 'rooms e players deveriam estar no tempo real';
  raise notice 'OK 14: tempo real configurado';

  -- Limpeza -------------------------------------------------------------
  delete from public.rooms where id = rid;
end $$;

drop function if exists public.teste_erro(text, text);

select 'TODOS OS TESTES PASSARAM' as resultado;
