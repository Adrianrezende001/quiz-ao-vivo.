-- =====================================================================
-- QUIZ AO VIVO - configuração do banco de dados (Supabase)
-- Cole ESTE ARQUIVO INTEIRO no SQL Editor do Supabase e clique em Run.
-- Pode ser executado mais de uma vez sem causar erro.
-- =====================================================================


-- ---------- 1. TABELAS ----------

-- Sala da partida. Não guarda PIN nem chave do professor.
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Quiz',
  status text not null default 'lobby'
    check (status in ('lobby', 'question', 'reveal', 'finished', 'closed')),
  locked boolean not null default false,      -- professor bloqueou a entrada
  question_count int not null default 0,
  current_index int not null default 0,       -- número da pergunta atual (começa em 0)
  started_at timestamptz,                     -- quando a pergunta atual começou
  ends_at timestamptz,                        -- quando as respostas se encerram
  answer_count int not null default 0,        -- respostas recebidas na pergunta atual
  created_at timestamptz not null default now()
);

-- PIN e chave do professor. Ninguém lê esta tabela diretamente.
create table if not exists public.room_secrets (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  pin text not null unique,
  host_key text not null
);

-- Perguntas. Não contêm a resposta correta (ela fica em answer_keys).
create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  position int not null,                      -- ordem da pergunta (começa em 0)
  kind text not null check (kind in ('mc', 'tf')),   -- mc = múltipla escolha, tf = verdadeiro/falso
  prompt text not null,
  options text[] not null,
  time_limit int not null check (time_limit between 10 and 60),
  double_points boolean not null default false,
  unique (room_id, position)
);

-- Gabarito e explicação. Ninguém lê esta tabela diretamente.
create table if not exists public.answer_keys (
  question_id uuid primary key references public.questions(id) on delete cascade,
  correct_index int not null,
  explanation text
);

-- Alunos e pontuação.
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  nickname text not null,
  score int not null default 0,
  joined_at timestamptz not null default now()
);
create unique index if not exists players_nickname_unique
  on public.players (room_id, lower(nickname));

-- Token secreto de cada aluno, usado para reconectar. Ninguém lê diretamente.
create table if not exists public.player_secrets (
  player_id uuid primary key references public.players(id) on delete cascade,
  token text not null unique
);
-- Último sinal de vida do aluno (fica fora do tempo real para não gerar tráfego).
alter table public.player_secrets add column if not exists last_seen timestamptz not null default now();

-- Respostas. Ninguém lê diretamente: os alunos não veem as respostas dos colegas.
create table if not exists public.answers (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  chosen_index int not null,
  is_correct boolean not null,
  points int not null default 0,
  answered_at timestamptz not null default now(),
  unique (question_id, player_id)             -- uma resposta por aluno por pergunta
);


-- ---------- 2. SEGURANÇA: RLS E PERMISSÕES ----------

alter table public.rooms enable row level security;
alter table public.room_secrets enable row level security;
alter table public.questions enable row level security;
alter table public.answer_keys enable row level security;
alter table public.players enable row level security;
alter table public.player_secrets enable row level security;
alter table public.answers enable row level security;

-- Remove qualquer acesso direto de visitantes e usuários logados.
revoke all on all tables in schema public from anon, authenticated;

-- Acesso de leitura apenas ao que todos podem ver.
grant usage on schema public to anon, authenticated;
grant select on public.rooms, public.players, public.questions to anon, authenticated;

drop policy if exists "salas visiveis" on public.rooms;
create policy "salas visiveis" on public.rooms for select using (true);

drop policy if exists "alunos visiveis" on public.players;
create policy "alunos visiveis" on public.players for select using (true);

drop policy if exists "perguntas visiveis" on public.questions;
create policy "perguntas visiveis" on public.questions for select using (true);

-- As demais tabelas não têm política alguma: ninguém acessa direto.
-- Toda escrita e toda leitura sensível passam pelas funções abaixo.


-- ---------- 3. REGRAS DO JOGO (todas executadas no servidor) ----------

-- Pontuação: 1000 x (1 - tempo decorrido / (2 x tempo total)), arredondado.
-- Até 0,5 s recebe 1000. Perguntas em dobro valem o dobro.
create or replace function public.calc_points(p_elapsed numeric, p_time_limit int, p_double boolean)
returns int
language plpgsql immutable
as $$
declare
  base int;
begin
  if p_elapsed < 0.5 then
    base := 1000;
  else
    base := round(1000 * (1 - least(greatest(p_elapsed, 0), p_time_limit) / (2.0 * p_time_limit)))::int;
  end if;
  return base * case when p_double then 2 else 1 end;
end $$;

-- Horário do servidor: o site usa para o cronômetro ficar igual em todos os celulares.
create or replace function public.server_time()
returns timestamptz
language sql stable
as $$ select now() $$;

-- Aluno avisa que continua conectado (o site envia a cada 15 segundos).
create or replace function public.heartbeat(p_token text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.player_secrets set last_seen = now() where token = p_token;
  if not found then raise exception 'INVALID_SESSION'; end if;
end $$;

-- Quantos alunos estão conectados agora (avisaram nos últimos 30 segundos).
create or replace function public.connected_count(p_room_id uuid)
returns int
language sql stable security definer set search_path = public
as $$
  select count(*)::int
  from public.players p
  join public.player_secrets s on s.player_id = p.id
  where p.room_id = p_room_id and s.last_seen > now() - interval '30 seconds'
$$;

-- Confere a chave do professor. Gera erro se a chave estiver errada.
create or replace function public.check_host(p_room_id uuid, p_host_key text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.room_secrets
    where room_id = p_room_id and host_key = p_host_key
  ) then
    raise exception 'NOT_HOST';
  end if;
end $$;

-- Cria uma sala. Devolve o PIN (para os alunos) e a chave do professor (só para o professor).
create or replace function public.create_room(p_title text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_room uuid;
  v_pin text;
  v_key text := gen_random_uuid()::text;
begin
  insert into public.rooms (title)
  values (left(coalesce(nullif(btrim(p_title), ''), 'Quiz'), 80))
  returning id into v_room;

  loop
    v_pin := lpad(floor(random() * 1000000)::int::text, 6, '0');
    begin
      insert into public.room_secrets (room_id, pin, host_key)
      values (v_room, v_pin, v_key);
      exit;
    exception when unique_violation then
      null;  -- PIN repetido: tenta outro
    end;
  end loop;

  return jsonb_build_object('room_id', v_room, 'pin', v_pin, 'host_key', v_key);
end $$;

-- Salva o quiz inteiro. Só é permitido antes de a partida começar.
create or replace function public.save_quiz(p_room_id uuid, p_host_key text, p_questions jsonb)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  q jsonb;
  v_pos int := 0;
  v_kind text;
  v_prompt text;
  v_opts text[];
  v_correct int;
  v_time int;
  v_qid uuid;
begin
  perform public.check_host(p_room_id, p_host_key);
  if (select status from public.rooms where id = p_room_id) <> 'lobby' then
    raise exception 'QUIZ_LOCKED_AFTER_START';
  end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) not between 1 and 50 then
    raise exception 'INVALID_QUESTION_LIST';
  end if;

  delete from public.questions where room_id = p_room_id;  -- os gabaritos são apagados junto

  for q in select value from jsonb_array_elements(p_questions) loop
    v_kind := q->>'kind';
    v_prompt := btrim(coalesce(q->>'prompt', ''));
    v_time := (q->>'time_limit')::int;
    v_correct := (q->>'correct_index')::int;

    if v_kind = 'tf' then
      v_opts := array['Verdadeiro', 'Falso'];
    elsif v_kind = 'mc' then
      select array_agg(btrim(x.value) order by x.ord) into v_opts
      from jsonb_array_elements_text(q->'options') with ordinality as x(value, ord);
    else
      raise exception 'INVALID_KIND';
    end if;

    if v_prompt = '' then raise exception 'PROMPT_REQUIRED'; end if;
    if coalesce(array_length(v_opts, 1), 0) not between 2 and 4 then raise exception 'INVALID_OPTIONS'; end if;
    if exists (select 1 from unnest(v_opts) o where o = '') then raise exception 'EMPTY_OPTION'; end if;
    if v_correct is null or v_correct not between 0 and array_length(v_opts, 1) - 1 then
      raise exception 'INVALID_CORRECT';
    end if;
    if v_time is null or v_time not between 10 and 60 then raise exception 'INVALID_TIME'; end if;

    insert into public.questions (room_id, position, kind, prompt, options, time_limit, double_points)
    values (p_room_id, v_pos, v_kind, v_prompt, v_opts, v_time,
            coalesce((q->>'double_points')::boolean, false))
    returning id into v_qid;
    v_pos := v_pos + 1;

    insert into public.answer_keys (question_id, correct_index, explanation)
    values (v_qid, v_correct, nullif(btrim(coalesce(q->>'explanation', '')), ''));
  end loop;

  update public.rooms set question_count = v_pos where id = p_room_id;
  return v_pos;
end $$;

-- Aluno entra com o PIN e um apelido. Devolve um token secreto para reconectar.
create or replace function public.join_room(p_pin text, p_nickname text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_room uuid;
  v_status text;
  v_locked boolean;
  v_base text;
  v_name text;
  v_n int := 1;
  v_player uuid;
  v_token text := gen_random_uuid()::text;
begin
  select r.id, r.status, r.locked into v_room, v_status, v_locked
  from public.room_secrets s
  join public.rooms r on r.id = s.room_id
  where s.pin = btrim(coalesce(p_pin, ''));

  if v_room is null then raise exception 'PIN_NOT_FOUND'; end if;
  if v_status in ('finished', 'closed') then raise exception 'ROOM_ENDED'; end if;
  if v_locked then raise exception 'ROOM_LOCKED'; end if;
  if (select count(*) from public.players where room_id = v_room) >= 100 then
    raise exception 'ROOM_FULL';
  end if;

  v_base := left(btrim(coalesce(p_nickname, '')), 16);
  if v_base = '' then raise exception 'NICKNAME_REQUIRED'; end if;

  -- Apelido repetido recebe um número: "Ana", "Ana 2", "Ana 3"...
  v_name := v_base;
  loop
    begin
      insert into public.players (room_id, nickname) values (v_room, v_name)
      returning id into v_player;
      exit;
    exception when unique_violation then
      v_n := v_n + 1;
      v_name := v_base || ' ' || v_n;
    end;
  end loop;

  insert into public.player_secrets (player_id, token) values (v_player, v_token);

  return jsonb_build_object('room_id', v_room, 'player_id', v_player,
                            'token', v_token, 'nickname', v_name);
end $$;

-- Aluno que perdeu a internet volta com o token guardado no celular.
create or replace function public.rejoin(p_token text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('room_id', p.room_id, 'player_id', p.id,
                            'nickname', p.nickname, 'score', p.score)
  from public.player_secrets s
  join public.players p on p.id = s.player_id
  where s.token = p_token
$$;

-- Aluno envia a alternativa escolhida. O servidor confere prazo, opção e duplicidade,
-- e calcula os pontos. O aluno nunca envia pontos.
create or replace function public.submit_answer(p_token text, p_chosen int)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_player uuid;
  v_room uuid;
  v_status text;
  v_index int;
  v_ends timestamptz;
  v_started timestamptz;
  v_q record;
  v_elapsed numeric;
  v_correct boolean;
  v_points int;
begin
  select p.id, p.room_id into v_player, v_room
  from public.player_secrets s
  join public.players p on p.id = s.player_id
  where s.token = p_token;
  if v_player is null then raise exception 'INVALID_SESSION'; end if;

  -- Trava a linha da sala: as respostas são processadas uma de cada vez.
  select status, current_index, ends_at, started_at
    into v_status, v_index, v_ends, v_started
  from public.rooms where id = v_room for update;

  -- 1 segundo de tolerância para atraso da internet.
  if v_status <> 'question' or now() > v_ends + interval '1 second' then
    raise exception 'ANSWER_CLOSED';
  end if;

  select q.id, q.options, q.time_limit, q.double_points, k.correct_index
    into v_q
  from public.questions q
  join public.answer_keys k on k.question_id = q.id
  where q.room_id = v_room and q.position = v_index;

  if p_chosen is null or p_chosen < 0 or p_chosen >= coalesce(array_length(v_q.options, 1), 0) then
    raise exception 'INVALID_OPTION';
  end if;
  if exists (select 1 from public.answers where question_id = v_q.id and player_id = v_player) then
    raise exception 'ALREADY_ANSWERED';
  end if;

  v_correct := (p_chosen = v_q.correct_index);
  v_elapsed := extract(epoch from (now() - v_started));
  v_points := case when v_correct
                   then public.calc_points(v_elapsed, v_q.time_limit, v_q.double_points)
                   else 0 end;

  insert into public.answers (room_id, question_id, player_id, chosen_index, is_correct, points)
  values (v_room, v_q.id, v_player, p_chosen, v_correct, v_points);

  update public.players set score = score + v_points where id = v_player;
  update public.rooms set answer_count = answer_count + 1 where id = v_room;
end $$;

-- Fecha as respostas quando o tempo acaba. Pode ser chamada por qualquer tela:
-- é idempotente, então o resultado é sempre o mesmo.
create or replace function public.close_if_expired(p_room_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update public.rooms set status = 'reveal'
  where id = p_room_id and status = 'question'
    and now() > ends_at + interval '1 second'
$$;

-- Devolve o gabarito e a explicação. Só funciona depois que as respostas fecharam.
create or replace function public.get_reveal(p_room_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_result jsonb;
begin
  perform public.close_if_expired(p_room_id);
  select * into v_room from public.rooms where id = p_room_id;
  if v_room.status <> 'reveal' then raise exception 'NOT_REVEALED'; end if;

  select jsonb_build_object('correct_index', k.correct_index,
                            'explanation', k.explanation,
                            'answer_count', v_room.answer_count)
    into v_result
  from public.questions q
  join public.answer_keys k on k.question_id = q.id
  where q.room_id = p_room_id and q.position = v_room.current_index;

  return v_result;
end $$;

-- Função interna: começa uma pergunta e marca o horário no servidor.
create or replace function public.start_question(p_room_id uuid, p_index int)
returns void
language plpgsql
as $$
declare
  v_time int;
begin
  select time_limit into v_time from public.questions
  where room_id = p_room_id and position = p_index;

  update public.rooms
     set status = 'question',
         current_index = p_index,
         answer_count = 0,
         started_at = now(),
         ends_at = now() + make_interval(secs => v_time)
   where id = p_room_id;
end $$;


-- ---------- 4. AÇÕES DO PROFESSOR (exigem a chave privada) ----------

create or replace function public.host_start(p_room_id uuid, p_host_key text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  if (select status from public.rooms where id = p_room_id) <> 'lobby' then
    raise exception 'ALREADY_STARTED';
  end if;
  if (select question_count from public.rooms where id = p_room_id) = 0 then
    raise exception 'NO_QUESTIONS';
  end if;
  perform public.start_question(p_room_id, 0);
end $$;

-- Encerra as respostas antes do tempo.
create or replace function public.host_close_question(p_room_id uuid, p_host_key text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  update public.rooms set status = 'reveal'
  where id = p_room_id and status = 'question';
end $$;

-- Avança para a próxima pergunta, ou termina a partida na última.
create or replace function public.host_next(p_room_id uuid, p_host_key text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_status text;
  v_index int;
  v_count int;
begin
  perform public.check_host(p_room_id, p_host_key);
  select status, current_index, question_count into v_status, v_index, v_count
  from public.rooms where id = p_room_id for update;

  if v_status <> 'reveal' then raise exception 'NOT_REVEALED'; end if;

  if v_index + 1 < v_count then
    perform public.start_question(p_room_id, v_index + 1);
    return 'question';
  end if;

  update public.rooms set status = 'finished' where id = p_room_id;
  return 'finished';
end $$;

-- Bloqueia ou libera a entrada de novos alunos.
create or replace function public.host_set_locked(p_room_id uuid, p_host_key text, p_locked boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  update public.rooms set locked = p_locked where id = p_room_id;
end $$;

-- Remove um aluno da sala.
create or replace function public.host_remove_player(p_room_id uuid, p_host_key text, p_player_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  delete from public.players where id = p_player_id and room_id = p_room_id;
end $$;

-- Encerra a sessão: ninguém mais entra.
create or replace function public.host_end_room(p_room_id uuid, p_host_key text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  update public.rooms set status = 'closed' where id = p_room_id;
end $$;

-- "Jogar novamente": zera pontos e volta para a sala de espera. Só após o pódio.
create or replace function public.host_reset(p_room_id uuid, p_host_key text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.check_host(p_room_id, p_host_key);
  if (select status from public.rooms where id = p_room_id) <> 'finished' then
    raise exception 'NOT_FINISHED';
  end if;
  delete from public.answers where room_id = p_room_id;
  update public.players set score = 0 where room_id = p_room_id;
  update public.rooms
     set status = 'lobby', current_index = 0, answer_count = 0,
         started_at = null, ends_at = null
   where id = p_room_id;
end $$;


-- ---------- 5. PERMISSÕES DAS FUNÇÕES ----------
-- Fecha tudo e libera somente as funções que o site usa.

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_room(text),
  public.save_quiz(uuid, text, jsonb),
  public.join_room(text, text),
  public.rejoin(text),
  public.submit_answer(text, int),
  public.close_if_expired(uuid),
  public.get_reveal(uuid),
  public.host_start(uuid, text),
  public.host_close_question(uuid, text),
  public.host_next(uuid, text),
  public.host_set_locked(uuid, text, boolean),
  public.host_remove_player(uuid, text, uuid),
  public.host_end_room(uuid, text),
  public.host_reset(uuid, text),
  public.calc_points(numeric, int, boolean),
  public.server_time(),
  public.heartbeat(text),
  public.connected_count(uuid)
to anon, authenticated;


-- ---------- 6. TEMPO REAL ----------
-- Avisa os celulares e o projetor quando a sala ou a lista de alunos mudam.
-- "full" faz as remoções também chegarem com o código da sala.
alter table public.rooms replica identity full;
alter table public.players replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.rooms, public.players;
exception
  when duplicate_object then null;   -- já estava configurado
  when undefined_object then null;   -- ambiente sem Supabase (teste local)
end $$;
