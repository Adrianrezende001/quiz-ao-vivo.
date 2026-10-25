import { useCallback, useEffect, useRef, useState } from 'react';
import { Moves, Player, Question, Room, ranking, rpc, serverOffset, supabase, toMs } from './supabase';

// Mantém sala, alunos e perguntas sincronizados com o banco em tempo real.
export function useRoom(roomId?: string) {
  const [room, setRoom] = useState<Room | null>(null);
  const [players, setPlayers] = useState<Player[]>([]);
  const [questions, setQuestions] = useState<Question[]>([]);
  const [offset, setOffset] = useState(0);
  const [moves, setMoves] = useState<Moves>({});
  const timer = useRef<number>(0);
  const moveTimer = useRef<number>(0);
  const lastPos = useRef<Record<string, number>>({});

  const refresh = useCallback(async () => {
    if (!roomId) return;
    const [r, p] = await Promise.all([
      supabase.from('rooms').select('*').eq('id', roomId).maybeSingle(),
      supabase.from('players').select('id, nickname, score, joined_at').eq('room_id', roomId),
    ]);
    if (r.data) setRoom(r.data as Room);
    if (p.data) setPlayers(p.data as Player[]);
  }, [roomId]);

  // Avisos seguidos viram uma única atualização (importante com 40 alunos).
  const soon = useCallback(() => {
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(refresh, 200);
  }, [refresh]);

  // Compara o ranking atual com o anterior para mostrar as setas de subida e descida.
  useEffect(() => {
    const next: Record<string, number> = {};
    const changed: Moves = {};
    ranking(players).forEach((p, i) => {
      next[p.id] = i;
      const before = lastPos.current[p.id];
      if (before !== undefined && before !== i) changed[p.id] = i < before ? 'up' : 'down';
    });
    lastPos.current = next;
    if (Object.keys(changed).length > 0) {
      setMoves(changed);
      window.clearTimeout(moveTimer.current);
      moveTimer.current = window.setTimeout(() => setMoves({}), 6000);
    }
  }, [players]);

  useEffect(() => {
    if (!roomId) return;
    refresh();
    supabase
      .from('questions')
      .select('position, kind, prompt, options, time_limit, double_points')
      .eq('room_id', roomId)
      .order('position')
      .then(({ data }) => {
        if (data) setQuestions(data as Question[]);
      });
    serverOffset().then(setOffset).catch(() => {});

    const channel = supabase
      .channel(`sala-${roomId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` }, soon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'players', filter: `room_id=eq.${roomId}` }, soon)
      .subscribe((status) => {
        // Ao (re)conectar, busca tudo de novo para não perder avisos.
        if (status === 'SUBSCRIBED') soon();
      });

    const onVisible = () => {
      if (document.visibilityState === 'visible') soon();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearTimeout(timer.current);
      document.removeEventListener('visibilitychange', onVisible);
      supabase.removeChannel(channel);
    };
  }, [roomId, refresh, soon]);

  useEffect(() => () => window.clearTimeout(moveTimer.current), []);

  return { room, players, questions, offset, moves, refresh };
}

// Relógio que anda junto com o servidor (para o cronômetro ficar igual em todos).
export function useClock(offset: number) {
  const [now, setNow] = useState(() => Date.now() + offset);
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now() + offset), 200);
    return () => window.clearInterval(id);
  }, [offset]);
  return now;
}

// Quando o tempo acaba, pede ao servidor para fechar as respostas (funciona em qualquer tela).
export function useAutoClose(room: Room | null, offset: number) {
  const id = room?.id;
  const status = room?.status;
  const endsAt = room?.ends_at;
  useEffect(() => {
    if (!id || status !== 'question' || !endsAt) return;
    const wait = toMs(endsAt) - (Date.now() + offset) + 1500;
    const t = window.setTimeout(() => {
      rpc('close_if_expired', { p_room_id: id }).catch(() => {});
    }, Math.max(wait, 0));
    return () => window.clearTimeout(t);
  }, [id, status, endsAt, offset]);
}
