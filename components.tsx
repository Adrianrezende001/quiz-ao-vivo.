import { Moves, Player, Question, SHAPES } from './supabase';

const CONFETTI_COLORS = ['#e21b3c', '#1368ce', '#ffd23f', '#26890c', '#ffffff'];

// Alternativas coloridas. Sem onPick, só mostram (projetor). Com correct, mostram a resposta.
export function Options({
  q,
  correct,
  onPick,
}: {
  q: Question;
  correct?: number;
  onPick?: (i: number) => void;
}) {
  return (
    <div className="opts">
      {q.options.map((o, i) => {
        const state = correct === undefined ? '' : correct === i ? 'correct' : 'wrong';
        return (
          <button key={i} className={`opt c${i} ${state}`} disabled={!onPick} onClick={() => onPick?.(i)}>
            {SHAPES[i]} {o}
          </button>
        );
      })}
    </div>
  );
}

// Classificação. Mostra só os primeiros "limit" lugares, com setas de quem subiu ou desceu.
export function Board({
  players,
  moves = {},
  limit = 5,
  me,
}: {
  players: Player[];
  moves?: Moves;
  limit?: number;
  me?: string;
}) {
  return (
    <ol className="board">
      {players.slice(0, limit).map((p, i) => (
        <li key={p.id} className={p.id === me ? 'me' : ''}>
          <span>
            {i + 1}. {p.nickname}{' '}
            {moves[p.id] && (
              <span className={`arrow ${moves[p.id]}`}>{moves[p.id] === 'up' ? '▲' : '▼'}</span>
            )}
          </span>
          <b>{p.score}</b>
        </li>
      ))}
    </ol>
  );
}

// Confete de celebração (só CSS, leve para celulares).
export function Confetti() {
  return (
    <div className="confetti" aria-hidden="true">
      {Array.from({ length: 60 }, (_, i) => (
        <i
          key={i}
          style={{
            left: `${(i * 37) % 100}%`,
            animationDelay: `${((i * 13) % 30) / 10}s`,
            background: CONFETTI_COLORS[i % CONFETTI_COLORS.length],
          }}
        />
      ))}
    </div>
  );
}
