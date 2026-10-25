import { createClient } from '@supabase/supabase-js';

// Só a chave "anon" vai para o site. Ela é pública por desenho:
// quem protege os dados é o banco (regras de segurança do schema.sql).
export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
);

export type Status = 'lobby' | 'question' | 'reveal' | 'finished' | 'closed';

export interface Room {
  id: string;
  status: Status;
  locked: boolean;
  question_count: number;
  current_index: number;
  ends_at: string | null;
  answer_count: number;
}

export interface Question {
  position: number;
  kind: 'mc' | 'tf';
  prompt: string;
  options: string[];
  time_limit: number;
  double_points: boolean;
}

export interface Player {
  id: string;
  nickname: string;
  score: number;
  joined_at: string;
}

export interface Reveal {
  correct_index: number;
  explanation: string | null;
  answer_count: number;
}

export interface Me {
  roomId: string;
  playerId: string;
  token: string;
  nickname: string;
  pin: string;
}

export const SHAPES = ['▲', '◆', '●', '■'];

// Quem subiu ou desceu no ranking desde a última atualização.
export type Moves = Record<string, 'up' | 'down'>;

const MESSAGES: Record<string, string> = {
  PIN_NOT_FOUND: 'PIN não encontrado. Confira o código.',
  ROOM_LOCKED: 'O professor bloqueou a entrada nesta sala.',
  ROOM_ENDED: 'Esta sala já foi encerrada.',
  ROOM_FULL: 'A sala está cheia.',
  NICKNAME_REQUIRED: 'Digite um apelido.',
  NOT_HOST: 'Você não tem permissão para controlar esta sala.',
  ANSWER_CLOSED: 'O tempo acabou. Resposta não registrada.',
  ALREADY_ANSWERED: 'Você já respondeu esta pergunta.',
  INVALID_OPTION: 'Alternativa inválida.',
  INVALID_SESSION: 'Sua sessão expirou. Entre novamente.',
  NOT_REVEALED: 'Ainda não é hora de mostrar a resposta.',
  NO_QUESTIONS: 'Crie pelo menos uma pergunta antes de iniciar.',
  ALREADY_STARTED: 'A partida já começou.',
  NOT_FINISHED: 'Só é possível jogar de novo depois do pódio.',
  PROMPT_REQUIRED: 'Escreva o enunciado de todas as perguntas.',
  INVALID_OPTIONS: 'Cada pergunta de múltipla escolha precisa de 2 a 4 alternativas.',
  EMPTY_OPTION: 'Preencha as alternativas que você usar.',
  INVALID_CORRECT: 'Marque a resposta correta de cada pergunta.',
  INVALID_TIME: 'O tempo precisa ficar entre 10 e 60 segundos.',
};

export class GameError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

// Chama uma função do banco e traduz os erros para português.
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    const code = Object.keys(MESSAGES).find((k) => error.message.includes(k)) ?? '';
    throw new GameError(code, MESSAGES[code] ?? 'Falha de conexão. Tente novamente.');
  }
  return data as T;
}

// Converte o horário do banco (com microssegundos) para milissegundos.
export const toMs = (ts: string) => new Date(ts.replace(/(\.\d{3})\d+/, '$1')).getTime();

export const secondsLeft = (endsAt: string | null, now: number) =>
  endsAt ? Math.max(0, Math.ceil((toMs(endsAt) - now) / 1000)) : 0;

// Diferença entre o relógio deste aparelho e o relógio do servidor.
export async function serverOffset(): Promise<number> {
  const before = Date.now();
  const serverNow = await rpc<string>('server_time');
  return toMs(serverNow) - (before + Date.now()) / 2;
}

// Ordem do ranking: maior pontuação primeiro; em empate, quem entrou antes.
export const ranking = (players: Player[]) =>
  [...players].sort((a, b) => b.score - a.score || a.joined_at.localeCompare(b.joined_at));
