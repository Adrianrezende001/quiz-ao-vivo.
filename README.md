# Quiz ao vivo

Jogo de perguntas em sala de aula. O professor cria a sala e mostra o PIN e o QR Code. Os alunos entram pelo celular, sem conta, sem login e sem instalar nada.

## Antes de começar

Você já deve ter feito no Supabase: criar o projeto, rodar `supabase/schema.sql` e `supabase/testes.sql` no SQL Editor.

Se você já tinha rodado o `schema.sql` antes, rode o arquivo de novo no SQL Editor. Ele atualiza o banco sem apagar salas nem alunos.

## Passo 1: pegar as duas chaves do Supabase

1. No painel do Supabase, clique em **Project Settings** (engrenagem) e depois em **API**.
2. Copie a **Project URL** (algo como `https://abcdxyz.supabase.co`).
3. Copie a chave **anon public**.

Não copie a chave **service_role**. Ela nunca deve ir para o site.

## Passo 2: enviar o projeto para o GitHub

1. Crie uma conta gratuita em github.com.
2. Clique em **New repository**, dê o nome `quiz-ao-vivo` e clique em **Create repository**.
3. Na página do repositório, clique em **uploading an existing file**.
4. Descompacte o arquivo `quiz-ao-vivo.zip` e arraste **todos os arquivos e pastas de dentro** para a página.
5. Clique em **Commit changes**.

## Passo 3: colocar no ar com a Vercel

1. Acesse vercel.com e clique em **Sign up** com a sua conta do GitHub.
2. Clique em **Add New... > Project** e escolha o repositório `quiz-ao-vivo` em **Import**.
3. Antes de clicar em Deploy, abra **Environment Variables** e adicione:
   - `VITE_SUPABASE_URL` com a Project URL.
   - `VITE_SUPABASE_ANON_KEY` com a chave anon public.
4. Clique em **Deploy** e espere cerca de um minuto.
5. A Vercel mostra um endereço como `quiz-ao-vivo.vercel.app`. Esse é o link do jogo.

Se você mudar as variáveis depois, vá em **Deployments** e clique em **Redeploy**.

## Passo 4: testar com celulares antes da aula

1. No computador do professor, abra o link e clique em **Sou professor**.
2. Monte o quiz e clique em **Criar sala**. Deixe essa tela aberta no projetor.
3. Em pelo menos três celulares, abra o link e clique em **Sou aluno**, digite o PIN e um apelido.
4. Clique em **Iniciar partida** e responda ao mesmo tempo nos celulares.
5. Confira: a lista de alunos atualiza sem recarregar, o contador de conectados muda quando um aluno sai, o ranking aparece depois de cada pergunta com setas de subida e descida e o pódio aparece no final com confete.
6. Feche a aba de um celular no meio da partida e abra de novo. O aluno deve voltar ao jogo com os pontos.

## Problemas comuns

- **Tela branca no link:** as variáveis de ambiente estão erradas ou não foram aplicadas. Corrija e faça o Redeploy.
- **"PIN não encontrado":** confira os seis dígitos com o que aparece no projetor.
- **Painel do professor diz que a sala é de outro navegador:** a chave do professor fica guardada no navegador usado para criar a sala. Use o mesmo navegador e não limpe os dados do site durante a aula.
- **Tudo para de funcionar:** projetos gratuitos do Supabase podem pausar depois de dias sem uso. Abra o painel do Supabase e clique em **Restore project**.

## Rodar no próprio computador (opcional)

1. Instale o Node.js (versão LTS) em nodejs.org.
2. Copie `.env.example` para `.env.local` e preencha as duas variáveis.
3. No terminal, dentro da pasta do projeto, rode `npm install` e depois `npm run dev`.

## Segurança e limites

- Só a chave anon vai para o site. Os pontos são calculados no servidor, e o gabarito só é liberado depois que o tempo acaba.
- Qualquer pessoa com o link pode criar uma sala. Para uma aula isso costuma bastar, mas não há limite de salas.
