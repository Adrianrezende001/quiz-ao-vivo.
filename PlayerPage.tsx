import { FormEvent, useEffect, useState } from 'react';
import { Board, Confetti, Options } from './components';
import { GameError, Me, Reveal, Room, ranking, rpc, secondsLeft } from './supabase';
import { useAutoClose, useClock, useRoom } from './useRoom';

const KEY = 'quiz-player';
const readMe = (): Me | null => JSON.parse(localStorage.getItem(KEY) || 'null');

export default function PlayerPage({ pin }: { pin?: string }) {
  const [me, setMe] = useState<Me | null>(readMe);
  const [checking, setChecking] = useState(() => readMe() !== null);

  function leave() {
    localStorage.removeItem(KEY);
    setMe(null);
  }

  // Ao abrir de novo (ex.: a internet caiu), volta para a partida com os pontos guardados.
  useEffect(() => {
    const saved = readMe();
    if (!saved) return;
    rpc('rejoin', { p_token: saved.token })
      .then((back) => {
        if (!back) leave();
      })
      .catch(() => {})
      .finally(() => setChecking(false));
  }, []);

  if (checking) return <main><p className="center">Reconectando…</p></main>;
  if (!me || (pin && me.pin !== pin)) return <JoinForm initialPin={pin} onJoined={setMe} />;
  return <Play me={me} onLeave={leave} />;
}

function JoinForm({ initialPin, onJoined }: { initialPin?: string; onJoined: (me: Me) => void }) {
  const [pin, setPin] = useState(initialPin ?? '');
  const [nick, setNick] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function join(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      const r = await rpc<{ room_id: string; player_id: string; token: string; nickname: string }>('join_room', {
        p_pin: pin.trim(),
        p_nickname: nick.trim(),
      });
      const me: Me = { roomId: r.room_id, playerId: r.player_id, token: r.token, nickname: r.nickname, pin: pin.trim() };
      localStorage.setItem(KEY, JSON.stringify(me));
      onJoined(me);
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  }

  return (
    <main>
      <h1>Entrar no quiz</h1>
      <form className="card" onSubmit={join}>
        <input
          className="wide"
          inputMode="numeric"
          maxLength={6}
          placeholder="PIN de 6 dígitos"
          value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          style={{ fontSize: '1.6rem', textAlign: 'center' }}
        />
        <input
          className="wide mt"
          maxLength={16}
          placeholder="Seu apelido"
          value={nick}
          onChange={(e) => setNick(e.target.value)}
          style={{ fontSize: '1.3rem' }}
        />
        <button className="mt wide" type="submit" disabled={busy || pin.length !== 6 || !nick.trim()}>
          {busy ? 'Entrando…' : 'Entrar'}
        </button>
        {error && <p className="error mt">{error}</p>}
      </form>
    </main>
  );
}

function Play({ me, onLeave }: { me: Me; onLeave: () => void }) {
  const { room, players, questions, offset, moves } = useRoom(me.roomId);
  const now = useClock(offset);
  useAutoClose(room, offset);
  const [picked, setPicked] = useState<{ index: number; choice: number } | null>(null);
  const [reveal, setReveal] = useState<Reveal | null>(null);
  const [error, setError] = useState('');
  const [removed, setRemoved] = useState(false);

  const status = room?.status;
  const index = room?.current_index ?? -1;
  const q = questions.find((x) => x.position === index);
  const left = secondsLeft(room?.ends_at ?? null, now);
  const ranked = ranking(players);
  const place = ranked.findIndex((p) => p.id === me.playerId);
  const pos = place >= 0 ? `${place + 1}º` : '-';
  const score = place >= 0 ? ranked[place].score : 0;
  const answered = picked !== null && picked.index === index;
  const choice = answered && picked ? picked.choice : null;

  // Avisa que o aluno continua conectado (a cada 15 s e ao voltar para a aba).
  useEffect(() => {
    const beat = () => {
      rpc('heartbeat', { p_token: me.token }).catch((e: GameError) => {
        if (e.code === 'INVALID_SESSION') setRemoved(true);
      });
    };
    beat();
    const id = window.setInterval(beat, 15000);
    const onVisible = () => {
      if (document.visibilityState === 'visible') beat();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearInterval(id);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [me.token]);

  // Na revelação, busca o gabarito uma vez.
  useEffect(() => {
    setReveal(null);
    if (status === 'reveal') {
      rpc<Reveal>('get_reveal', { p_room_id: me.roomId })
        .then(setReveal)
        .catch(() => {});
    }
  }, [status, index, me.roomId]);

  async function answer(i: number) {
    setError('');
    try {
      await rpc('submit_answer', { p_token: me.token, p_chosen: i });
      setPicked({ index, choice: i });
    } catch (e) {
      const err = e as GameError;
      // Já respondeu (ex.: a página recarregou): não é erro para o aluno.
      if (err.code === 'ALREADY_ANSWERED') setPicked({ index, choice: -1 });
      else setError(err.message);
    }
  }

  if (!room) return <main><p className="center">Carregando…</p></main>;

  function screen(r: Room): JSX.Element {
    if (r.status === 'closed') {
      return <div className="card center"><h2>A sala foi encerrada pelo professor.</h2></div>;
    }
    if (r.status === 'lobby') {
      return (
        <div className="card center pulse">
          <h2>Você está dentro! 🎉</h2>
          <p>Aguarde o professor iniciar a partida.</p>
        </div>
      );
    }
    if (r.status === 'question') {
      if (!q) return <p className="center">Carregando pergunta…</p>;
      return (
        <>
          <div className="timer center">{left}</div>
          <h2 className="prompt">{q.prompt}</h2>
          {answered ? (
            <div className="card center">
              <h2>✅ Resposta registrada!</h2>
              <p>Aguarde o resultado.</p>
            </div>
          ) : (
            <Options q={q} onPick={left > 0 ? answer : undefined} />
          )}
        </>
      );
    }
    if (r.status === 'reveal') {
      const feedback =
        choice === null ? '⏰ Você não respondeu a tempo.'
        : choice === -1 ? 'Resposta registrada.'
        : !reveal ? 'Calculando…'
        : choice === reveal.correct_index ? '🎉 Você acertou!'
        : '❌ Não foi dessa vez.';
      return (
        <>
          {q && <h2 className="prompt">{q.prompt}</h2>}
          {q && <Options q={q} correct={reveal?.correct_index} />}
          <p className="feedback">{feedback}</p>
          {reveal?.explanation && <p className="explain">💡 {reveal.explanation}</p>}
          <p className="center">Você está em {pos} com {score} pontos</p>
          {moves[me.playerId] === 'up' && <p className="trend">▲ Você subiu no ranking!</p>}
          {moves[me.playerId] === 'down' && <p className="trend down">▼ Você caiu no ranking</p>}
          <Board players={ranked} moves={moves} me={me.playerId} />
        </>
      );
    }
    return (
      <>
        <h2 className="center">🏆 Fim da partida!</h2>
        <Confetti />
        <p className="center">Você ficou em {pos} lugar com {score} pontos.</p>
        <Board players={ranked} moves={moves} limit={ranked.length} me={me.playerId} />
      </>
    );
  }

  return (
    <main>
      <div className="row between">
        <span>👤 {me.nickname}</span>
        <span>⭐ {score} pts</span>
      </div>
      {removed ? (
        <div className="card center">
          <h2>Você saiu da sala ou foi removido pelo professor.</h2>
        </div>
      ) : (
        screen(room)
      )}
      {error && <p className="error">{error}</p>}
      <p className="center">
        <button className="ghost" onClick={onLeave}>
          Sair desta sala
        </button>
      </p>
    </main>
  );
}
