import { Builder, HostRoom } from './HostPage';
import PlayerPage from './PlayerPage';

// Rotas simples pelo endereço: /professor, /professor/ID da sala, /entrar, /entrar/PIN
export default function App() {
  const [, section, param] = window.location.pathname.split('/');
  if (section === 'professor') return param ? <HostRoom roomId={param} /> : <Builder />;
  if (section === 'entrar') return <PlayerPage pin={param} />;
  return (
    <main className="center">
      <h1>🎯 Quiz ao vivo</h1>
      <p>Perguntas, pontos e ranking em tempo real na sua sala de aula.</p>
      <div className="row center">
        <a className="btn" href="/professor">Sou professor</a>
        <a className="btn ghost" href="/entrar">Sou aluno</a>
      </div>
    </main>
  );
}
