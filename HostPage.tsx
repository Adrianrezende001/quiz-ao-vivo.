import { useEffect, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { Board, Confetti, Options } from './components';
import { Player, Reveal, ranking, rpc, secondsLeft } from './supabase';
import { useAutoClose, useClock, useRoom } from './useRoom';

type Draft = {
  kind: 'mc' | 'tf';
  prompt: string;
  options: string[];
  correct: number;
  time: number;
  double: boolean;
  explanation: string;
};

const blank = (): Draft => ({
  kind: 'mc',
  prompt: '',
  options: ['', '', '', ''],
  correct: 0,
  time: 20,
  double: false,
  explanation: '',
});

// Remove alternativas em branco e ajusta a posição da resposta correta.
function toPayload(d: Draft) {
  const base = { prompt: d.prompt, time_limit: d.time, double_points: d.double, explanation: d.explanation };
  if (d.kind === 'tf') return { ...base, kind: 'tf', correct_index: d.correct };
  const options = d.options.map((o) => o.trim()).filter((o) => o !== '');
  const correctText = (d.options[d.correct] ?? '').trim();
  return { ...base, kind: 'mc', options, correct_index: options.indexOf(correctText) };
}

// Exporta a classificação para abrir no Excel (separador ponto e vírgula, padrão brasileiro).
function exportCsv(players: Player[]) {
  const lines = players.map((p, i) => `${i + 1};"${p.nickname.replace(/"/g, '""')}";${p.score}`);
  const csv = ['Posição;Apelido;Pontos', ...lines].join('\n');
  const url = URL.createObjectURL(new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = 'classificacao.csv';
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function Builder() {
  const [title, setTitle] = useState('Quiz da aula');
  const [qs, setQs] = useState<Draft[]>([blank()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const edit = (i: number, patch: Partial<Draft>) =>
    setQs((all) => all.map((q, j) => (j === i ? { ...q, ...patch } : q)));

  const editOption = (i: number, k: number, text: string) =>
    setQs((all) =>
      all.map((q, j) => (j === i ? { ...q, options: q.options.map((o, n) => (n === k ? text : o)) } : q)),
    );

  async function create() {
    setBusy(true);
    setError('');
    try {
      const made = await rpc<{ room_id: string; pin: string; host_key: string }>('create_room', {
        p_title: title,
      });
      // A chave do professor fica só neste navegador. Não a mostre para os alunos.
      localStorage.setItem(`quiz-host:${made.room_id}`, JSON.stringify({ key: made.host_key, pin: made.pin }));
      await rpc('save_quiz', {
        p_room_id: made.room_id,
        p_host_key: made.host_key,
        p_questions: qs.map(toPayload),
      });
      location.assign(`/professor/${made.room_id}`);
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  }

  return (
    <main>
      <h1>Criar quiz</h1>
      <div className="card">
        <input className="wide" value={title} maxLength={80} onChange={(e) => setTitle(e.target.value)} placeholder="Nome do quiz" />
      </div>

      {qs.map((q, i) => (
        <div className="card" key={i}>
          <div className="row">
            <select value={q.kind} onChange={(e) => edit(i, { kind: e.target.value as Draft['kind'], correct: 0 })}>
              <option value="mc">Múltipla escolha</option>
              <option value="tf">Verdadeiro ou falso</option>
            </select>
            <select value={q.time} onChange={(e) => edit(i, { time: Number(e.target.value) })}>
              {[10, 15, 20, 30, 45, 60].map((t) => (
                <option key={t} value={t}>
                  {t} segundos
                </option>
              ))}
            </select>
            <label className="row">
              <input type="checkbox" checked={q.double} onChange={(e) => edit(i, { double: e.target.checked })} />
              Pontos em dobro
            </label>
            {qs.length > 1 && (
              <button className="ghost" onClick={() => setQs(qs.filter((_, j) => j !== i))}>
                Remover
              </button>
            )}
          </div>

          <input className="wide mt" placeholder="Enunciado da pergunta" value={q.prompt} onChange={(e) => edit(i, { prompt: e.target.value })} />

          {q.kind === 'mc' ? (
            <>
              <p className="small">Marque a correta. Deixe em branco as alternativas que não usar (mínimo 2).</p>
              {q.options.map((o, k) => (
                <div className="row mt" key={k}>
                  <input type="radio" name={`certa-${i}`} checked={q.correct === k} onChange={() => edit(i, { correct: k })} />
                  <input className="wide" placeholder={`Alternativa ${k + 1}`} value={o} onChange={(e) => editOption(i, k, e.target.value)} />
                </div>
              ))}
            </>
          ) : (
            ['Verdadeiro', 'Falso'].map((t, k) => (
              <label className="row mt" key={t}>
                <input type="radio" name={`certa-${i}`} checked={q.correct === k} onChange={() => edit(i, { correct: k })} />
                {t}
              </label>
            ))
          )}

          <input className="wide mt" placeholder="Explicação da resposta (opcional)" value={q.explanation} onChange={(e) => edit(i, { explanation: e.target.value })} />
        </div>
      ))}

      <div className="row">
        <button className="ghost" disabled={busy} onClick={() => setQs([...qs, blank()])}>
          + Pergunta
        </button>
        <button disabled={busy} onClick={create}>
          {busy ? 'Criando sala…' : 'Criar sala'}
        </button>
      </div>
      {error && <p className="error">{error}</p>}
    </main>
  );
}

export function HostRoom({ roomId }: { roomId: string }) {
  const { room, players, questions, offset, moves, refresh } = useRoom(roomId);
  const now = useClock(offset);
  useAutoClose(room, offset);
  // Quantos alunos estão com a conexão ativa agora (atualiza a cada 5 segundos).
  const [connected, setConnected] = useState(0);
  useEffect(() => {
    const load = () => {
      rpc<number>('connected_count', { p_room_id: roomId }).then(setConnected).catch(() => {});
    };
    load();
    const id = window.setInterval(load, 5000);
    return () => window.clearInterval(id);
  }, [roomId]);
  const [reveal, setReveal] = useState<Reveal | null>(null);
  const [error, setError] = useState('');
  const saved = JSON.parse(localStorage.getItem(`quiz-host:${roomId}`) || 'null') as { key: string; pin: string } | null;

  // Ao encerrar uma pergunta, busca o gabarito (só o servidor libera depois do tempo).
  useEffect(() => {
    setReveal(null);
    if (room?.status === 'reveal') {
      rpc<Reveal>('get_reveal', { p_room_id: roomId })
        .then(setReveal)
        .catch((e: Error) => setError(e.message));
    }
  }, [room?.status, room?.current_index, roomId]);

  if (!saved) {
    return (
      <main>
        <div className="card">
          Esta sala foi criada em outro navegador. Abra o painel no mesmo navegador em que criou o jogo.
        </div>
      </main>
    );
  }
  if (!room) return <main><p>Carregando sala…</p></main>;

  const key = saved.key;
  const sorted = ranking(players);
  const q = questions.find((x) => x.position === room.current_index);
  const isLast = room.current_index + 1 >= room.question_count;
  const joinUrl = `${location.origin}/entrar/${saved.pin}`;

  async function act(fn: string, extra: Record<string, unknown> = {}) {
    setError('');
    try {
      await rpc(fn, { p_room_id: roomId, p_host_key: key, ...extra });
      await refresh();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  function endSession() {
    if (confirm('Encerrar a sessão? Ninguém mais poderá entrar.')) act('host_end_room');
  }

  return (
    <main>
      {error && <p className="error">{error}</p>}

      {room.status === 'lobby' && (
        <div className="grid2">
          <div className="card center">
            <p>
              Entre em <b>{location.host}/entrar</b> e digite o PIN
            </p>
            <div className="pin">{saved.pin}</div>
            <div className="qr">
              <QRCodeSVG value={joinUrl} size={200} />
            </div>
            <p className="small">Ou aponte a câmera para o QR Code</p>
          </div>
          <div className="card">
            <h2>
              {connected} conectado(s) agora · {players.length} entrado(s)
            </h2>
            {room.locked && <p className="error">Entrada bloqueada</p>}
            <div className="row">
              <button disabled={players.length === 0 || room.question_count === 0} onClick={() => act('host_start')}>
                Iniciar partida
              </button>
              <button className="ghost" onClick={() => act('host_set_locked', { p_locked: !room.locked })}>
                {room.locked ? 'Liberar entrada' : 'Bloquear entrada'}
              </button>
            </div>
            <ul className="list">
              {sorted.map((p) => (
                <li key={p.id}>
                  {p.nickname}
                  <button className="danger" onClick={() => act('host_remove_player', { p_player_id: p.id })}>
                    remover
                  </button>
                </li>
              ))}
            </ul>
            <button className="danger mt" onClick={endSession}>
              Encerrar sessão
            </button>
          </div>
        </div>
      )}

      {room.status === 'question' && q && (
        <>
          <div className="row between">
            <span>
              Pergunta {room.current_index + 1} de {room.question_count}
            </span>
            <span className="timer">{secondsLeft(room.ends_at, now)}</span>
          </div>
          <h1 className="prompt">{q.prompt}</h1>
          <Options q={q} />
          <div className="row between">
            <span>
              {room.answer_count} de {players.length} alunos responderam
            </span>
            <button className="ghost" onClick={() => act('host_close_question')}>
              Encerrar respostas agora
            </button>
          </div>
        </>
      )}

      {room.status === 'reveal' && q && (
        <>
          <h1 className="prompt">{q.prompt}</h1>
          <Options q={q} correct={reveal?.correct_index} />
          {reveal?.explanation && <p className="explain">💡 {reveal.explanation}</p>}
          <p>{reveal?.answer_count ?? room.answer_count} respostas recebidas</p>
          <h2>Top 5</h2>
          <Board players={sorted} moves={moves} />
          <button onClick={() => act('host_next')}>{isLast ? 'Ver pódio final' : 'Próxima pergunta'}</button>
        </>
      )}

      {room.status === 'finished' && (
        <>
          <h1 className="center">🏆 Pódio final</h1>
          <Podium players={sorted} />
          <Confetti />
          <Board players={sorted} moves={moves} limit={sorted.length} />
          <div className="row">
            <button onClick={() => exportCsv(sorted)}>Exportar CSV</button>
            <button onClick={() => act('host_reset')}>Jogar novamente</button>
            <button className="danger" onClick={endSession}>
              Encerrar sessão
            </button>
          </div>
        </>
      )}

      {room.status === 'closed' && (
        <div className="card center">
          <h2>Sessão encerrada.</h2>
        </div>
      )}
    </main>
  );
}

function Podium({ players }: { players: Player[] }) {
  const medals = ['🥇', '🥈', '🥉'];
  return (
    <div className="podium">
      {[1, 0, 2].map((i) =>
        players[i] ? (
          <div className={`step s${i + 1}`} key={i}>
            <div className="medal">{medals[i]}</div>
            <strong>{players[i].nickname}</strong>
            <span>{players[i].score} pontos</span>
            <div className="block">{i + 1}º</div>
          </div>
        ) : null,
      )}
    </div>
  );
}
