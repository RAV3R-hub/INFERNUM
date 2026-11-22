# INFERNUM · Eventos do Clã

Site do clã **INFERNUM** para confirmar presença nos eventos semanais do Diablo Immortal.
O nome e o lema aparecem no topo e na tela de login, e podem ser trocados no [`config.js`](config.js).

- Membros entram com o **Discord** e respondem **Vou / Não vou** em cada evento.
- Ao confirmar presença, o membro também informa se vai usar o **Discord** no evento. Oficiais veem um 🎧 ao lado de quem vai estar no Discord: nas listas, no painel de times (com a contagem por time) e nos textos copiados.
- Membros comuns **não veem as respostas dos outros**: nem as listas "Vão / Não vão / Sem resposta" nem os contadores dos eventos. Só oficiais e o líder veem.
- Cada membro cadastra **classe** (DH, Cruzado, Mago, BK, Monge, Druida, Bárbaro, Necromante, Bruxo, Tempest), os **atributos** (Armadura, Perfurar Armadura, Potência, Resistência, Ressonância) e, se quiser, um **telefone**. Ao clicar em "Vou", o membro confirma ou corrige a classe e os atributos.
- **Líder e oficiais** criam, editam, repetem e apagam eventos, e aprovam novos membros.
- **Montagem de times** com quem confirmou presença: formato **Guerra** (12 times de 8: Exaltação, Eminência, Renome e Orgulho, de 1 a 3 cada) ou **Rito** (até 10 times de 8).
- **Frequência**: depois do evento, um oficial marca quem realmente compareceu. O painel mostra a % de presença de cada membro, quem confirmou e faltou e quem não respondeu.
- Em cada evento aparece quem vai, quem não vai e quem ainda não respondeu. Os botões "Copiar lista" e "Copiar times" geram textos prontos para colar no Discord.

Tudo é gratuito: o site fica no **GitHub Pages** e os dados ficam no **Supabase** (plano free).

> Abrindo o `index.html` sem configurar nada, o site roda em **modo demonstração**, com dados fictícios.

---

## Passo a passo (cerca de 20 minutos, feito uma única vez)

### 1. Criar o banco no Supabase
1. Crie uma conta em https://supabase.com e clique em **New project** (escolha a região *South America (São Paulo)*).
2. Quando o projeto estiver pronto, abra **SQL Editor**, cole todo o conteúdo de [`supabase/schema.sql`](supabase/schema.sql) e clique em **Run**.
3. Em **Project Settings → API**, copie a **Project URL** e a chave **anon public** (ou **publishable**).

### 2. Criar o aplicativo no Discord
1. Acesse https://discord.com/developers/applications → **New Application** (dê o nome do clã).
2. Vá em **OAuth2** e copie o **Client ID**. Clique em **Reset Secret** e copie o **Client Secret**.
3. Ainda em **OAuth2 → Redirects**, adicione:
   `https://SEU-PROJETO.supabase.co/auth/v1/callback`
   (use a sua Project URL + `/auth/v1/callback`) e salve.

### 3. Ligar o Discord no Supabase
1. No Supabase: **Authentication → Sign In / Providers → Discord**, ative e cole o Client ID e o Client Secret.

### 4. Publicar o site no GitHub Pages
1. Edite o [`config.js`](config.js): coloque o nome do clã, a Project URL e a chave anon.
2. Crie um repositório público no GitHub e envie os arquivos `index.html`, `app.js`, `styles.css` e `config.js`.
3. No repositório: **Settings → Pages → Branch: main / (root) → Save**. Em 1 ou 2 minutos o site estará em
   `https://SEU-USUARIO.github.io/NOME-DO-REPO/`.
4. No Supabase: **Authentication → URL Configuration**:
   - **Site URL**: o endereço do site acima.
   - **Redirect URLs**: adicione o mesmo endereço.

### 5. Tornar-se líder
1. Abra o site e entre com o Discord. Você verá "Aguardando aprovação". Isso é esperado.
2. No Supabase, abra o **SQL Editor** e rode (trocando pelo seu nome no Discord):
   ```sql
   update public.profiles set role = 'leader' where discord_name = 'SeuNomeNoDiscord';
   ```
3. Recarregue o site. Agora você é o líder: vá em **Membros** e promova os oficiais.

### 6. Convidar o clã
Mande o link no Discord do clã. Cada pessoa entra com o Discord e aparece em **Membros → Aguardando aprovação**. Um oficial ou o líder clica em **Aprovar**.

---

## Permissões

| Ação | Membro | Oficial | Líder |
|---|:-:|:-:|:-:|
| Ver eventos e responder Vou/Não vou | ✔ | ✔ | ✔ |
| Editar o próprio perfil (personagem, classe, atributos, telefone) | ✔ | ✔ | ✔ |
| Ver o próprio time (sem médias/totais) | ✔ | ✔ | ✔ |
| Ver quem respondeu Vou / Não vou e quem vai estar no Discord | | ✔ | ✔ |
| Painel "Meu perfil" com a própria frequência | ✔ | ✔ | ✔ |
| Abrir o perfil de outro membro | | ✔ | ✔ |
| Sugerir times automaticamente | | ✔ | ✔ |
| Definir prazo, travar times e decidir pedidos de saída | | ✔ | ✔ |
| Pedir para sair depois do prazo ou com times travados | ✔ | | |
| Ler e escrever anotações internas (exceto sobre si mesmo) | | ✔ | ✔ |
| Ver todos os times, médias/totais e copiar times | | ✔ | ✔ |
| Ver a lista de membros e os telefones | | ✔ | ✔ |
| Criar / editar / apagar eventos | | ✔ | ✔ |
| Montar times | | ✔ | ✔ |
| Ver o histórico de alterações do evento e quem alterou cada sala por último | | ✔ | ✔ |
| Registrar presença real e ver a frequência | | ✔ | ✔ |
| Aprovar, recusar ou remover membros comuns | | ✔ | ✔ |
| Editar o nick de membros comuns (e de quem aguarda aprovação) | | ✔ | ✔ |
| Editar o nick de oficiais | | | ✔ |
| Remover oficiais e readmitir ex-membros | | | ✔ |
| Promover a oficial ou líder | | | ✔ |

As regras ficam no próprio banco (Row Level Security), então ninguém consegue burlar alterando o site.

## Como usar no dia a dia

**Montar times** (oficial ou líder): abra o evento e clique em **⚔ Montar times**, depois escolha **Guerra** ou **Rito**.
À esquerda ficam os confirmados ainda sem time, que dá para ordenar por atributo ou filtrar por classe. Clique em um membro e depois no time, ou arraste. Para tirar alguém, clique no × ou arraste de volta para a lista.
As mudanças ficam num **rascunho**: quem foi movido ganha uma marca dourada, e a barra no topo mostra quantas alterações faltam salvar.
Clique em **💾 Salvar** para publicar os times, ou em **Descartar** para voltar ao que estava salvo. O site avisa se você tentar sair da página sem salvar.
Se outro oficial tiver salvado os mesmos times enquanto você editava, o site pergunta antes de substituir.
Cada time aceita no máximo 8 pessoas. O seletor **Média / Totalizador / Ocultar** troca entre a média e a soma dos 5 atributos de cada time. **Ocultar** mostra só o nome e a classe de cada membro; no painel de montagem, a lista "Sem time" continua com os atributos, para ajudar na escolha. Ele aparece no painel de montagem e também na seção "Times" da página do evento, só para oficiais e o líder. A escolha fica lembrada no seu navegador e vale para os dois lugares.

**✨ Sugerir times:** no painel de montagem, o botão monta uma sugestão usando a **Ressonância** como medida de força. Na Guerra há três modos:
- **Foco Exaltação:** os mais fortes preenchem Exaltação 1, 2 e 3; depois Eminência, Renome e Orgulho.
- **Foco 2/2:** Exaltação 1 e 2 com os mais fortes, Exaltação 3 vazia; Eminência 1 e 2 em seguida, Eminência 3 vazia; Renome e Orgulho completas.
- **Foco 1 Exaltação:** os mais fortes só na Exaltação 1, com Exaltação 2 e 3 vazias; Eminência, Renome e Orgulho completas.

Em todos os modos, os mais fortes vão para as salas mais altas, e as salas da mesma categoria (ex.: Eminência 1, 2 e 3) ficam com quantidade de membros e Ressonância total equilibradas.
No Rito há o modo **Equilibrado**, que distribui os confirmados em times completos de 8, com a Ressonância equilibrada.
A sugestão entra como **rascunho**: ajuste o que quiser e clique em **💾 Salvar**.

**⏳ Prazo para responder:** ao criar ou editar um evento, escolha até quando os membros podem responder (ex.: "2h antes", que é o padrão; ou "Sem prazo").
Os cards mostram "⏳ Responda até …". Depois do prazo, aparece "⛔ Respostas encerradas" e os membros não conseguem mais mudar a resposta.

**Próximos → Passados:** quando o evento começa, o card ganha o selo **Agora**. **20 minutos depois do horário de início**, o evento sai de **Próximos** e vai sozinho para **Passados**, mesmo com a página aberta.

**🔒 Travar times:** no painel de montagem, o botão **🔓 Travar times** trava os times. Com os times travados, quem está escalado não sai sozinho: o botão "Não vou" vira **"Não vou poder ir…"**, e o membro informa o motivo.
Quem não está escalado continua respondendo normalmente enquanto o prazo estiver aberto. Oficiais e o líder continuam podendo editar os times e mudar a própria resposta.

**⚠ Pedidos de saída:** os pedidos aparecem na página do evento para oficiais e o líder, com o nome, o time e o motivo.
- **Aceitar saída:** o membro passa para "Não vou" e sai do time.
- **Manter:** o membro continua confirmado.

O card do evento mostra "⚠ N pedido(s) de saída", e no painel de montagem o membro que pediu aparece com ⚠. O membro pode cancelar o próprio pedido enquanto o oficial não decide.

**📝 Anotações internas:** no perfil de um membro, oficiais e líder podem registrar observações (ex.: "troca de turno às quintas").
Só oficiais e o líder veem as anotações, e ninguém vê as anotações sobre si mesmo. Cada um apaga as próprias; o líder pode apagar qualquer uma. Na lista de Membros, o selo 📝 mostra quem tem anotações.

**Como o membro vê o próprio time:** depois que os times são salvos, o card do evento mostra o selo **"Seu time: …"**.
A página do evento mostra o aviso **"Você está no time …"** e **só o time dele**, com o nome e a classe de cada integrante, sem os atributos.
O membro não vê os outros times, nem as médias ou os totais, nem o botão "Copiar times". O banco também só entrega a ele os dados do próprio time.
O site não manda notificação; use **📋 Copiar times** para avisar no Discord.

**Meu perfil** (menu do topo, para todos: membros, oficiais e líder): é o painel individual de cada um.
Oficiais e líder também abrem o **perfil de qualquer membro**: basta clicar no membro na lista de **Membros** ou no nome dele na tabela de **Frequência**.
Nesse caso, o painel também mostra o telefone (se informado) e o botão "← Membros" para voltar, mas não tem "Editar perfil", porque cada um edita só o próprio (a staff pode trocar só o nick, em **✎ Editar nick**).
No próprio painel, o botão **📷 Trocar foto** troca a foto de perfil na hora, sem abrir o formulário. Ela também pode ser trocada em **✎ Editar perfil**.
Trocar ou remover a foto nesse formulário não apaga o que já foi digitado (nome, telefone, classe e atributos), inclusive no cadastro de quem acabou de entrar.
Membros comuns não conseguem abrir o perfil de outra pessoa. O painel mostra:
- os dados do membro, com um botão para editar o perfil;
- a frequência no período escolhido, as presenças, a sequência atual de presenças e quantas vezes confirmou e faltou;
- os próximos eventos, com a resposta dada e o time, destacando os que ainda estão sem resposta;
- os 5 atributos comparados com a média do clã;
- os últimos eventos, com o resultado de cada um (presente, confirmou e faltou, avisou, faltou sem responder);
- o histórico das próprias alterações de nome, classe e atributos. Se alguém mudar a resposta para "Não vou", sai do time automaticamente.

**🕘 Histórico de alterações do evento** (oficiais e líder): na página do evento, o botão **🕘 Histórico de alterações** mostra quem mudou o quê, do mais recente para o mais antigo, com o nome, o cargo, a data e a hora:
- criação do evento e edições (nome, data, tipo, prazo para responder e descrição);
- formato dos times, times renomeados, times travados e destravados;
- cada sala (ex.: Exaltação 1): quem entrou e quem saiu. Saídas automáticas (o membro marcou "Não vou" ou teve a saída aceita) aparecem identificadas.

Em cada sala, na página do evento e no painel **⚔ Montar times**, aparece **✎ Nome · data e hora** do **último oficial ou líder** que alterou aquela sala.
Se outro oficial salvar os times enquanto você edita, o aviso antes de substituir diz quem foi e a que horas.
Os membros comuns não veem o histórico. Ele começa a contar a partir de quando o [`supabase/historico_eventos.sql`](supabase/historico_eventos.sql) for executado (veja **Dicas**).

**⇄ Mover entre as listas** (oficial ou líder): na página do evento, o botão **⇄** ao lado de cada nome passa o membro para **Vou**, **Não vou** ou **Sem resposta**, até o evento terminar.
Para "Vou", a classe e os atributos vêm do perfil. Cada mudança fica no **🕘 Histórico de alterações** do evento, com quem fez e quando. Precisa do [`supabase/presenca_lideranca.sql`](supabase/presenca_lideranca.sql).

**Registrar presença** (oficial ou líder): depois que o evento começa, ele mostra o aviso **📋 Registrar presença**.
A lista já vem marcada com quem confirmou "Vou"; basta desmarcar quem faltou e marcar quem apareceu sem avisar.

**🧑‍✈️ Contas pilotadas** (para quem joga com mais de uma conta do jogo): em **Meu perfil → Contas pilotadas**, o piloto pode:
- **Cadastrar uma conta sem login**: uma conta do jogo que só ele joga. Ela vai para "Aguardando aprovação" e um oficial ou o líder aprova.
- **Pedir acesso a uma conta existente** (que já tem dono no site): o dono aprova no perfil dele, ou um oficial ou o líder aprova em **Membros → Pedidos de piloto**.

Depois de aprovado, aparece no topo o seletor **"Respondendo como"**: o piloto escolhe a conta e responde aos eventos (Vou e Não vou, classe e atributos, Discord, pedido de saída) por ela.
- Cada conta tem a própria frequência, os próprios times e o próprio histórico.
- Uma conta pode ter vários pilotos, e o dono também continua respondendo.
- Os oficiais veem quem respondeu (ex.: "respondido por Fulano") e o selo 🧑‍✈️ nas listas e nos times.
- No painel de times aparece um alerta quando a mesma pessoa controla 2 ou mais contas confirmadas no mesmo evento.
- O dono pode remover pilotos a qualquer momento; oficiais e líder também, e ainda podem adicionar pilotos direto no perfil da conta.
- Ao remover do clã alguém que é o único piloto de contas sem login, o site oferece remover essas contas junto.
- **Só piloto:** quem se cadastrou apenas para responder pelas contas que pilota. Oficiais (com a permissão "Gerenciar pilotos de contas") e o líder marcam no **✎ Editar** da lista de membros.
  Não conta como membro: fica fora do rank de força, da frequência, das contagens e das listas dos eventos, e aparece na seção recolhida **Só pilotos** da página Membros.
  Não responde com a própria conta (em "Respondendo como" aparecem só as contas que pilota) e não pode ser pilotado. Precisa do [`supabase/so_piloto.sql`](supabase/so_piloto.sql).

**📰 Malah News** (menu do topo): o jornal do clã, com imagens publicadas por oficiais e líder.
Todos os membros veem as edições, da mais nova para a mais antiga; clicando na imagem, ela abre no tamanho original.
Para publicar, oficiais e líder usam **+ Nova edição** e escolhem a imagem (PNG, JPG, WEBP ou GIF), o título e uma legenda opcional. Cada edição pode ser editada (título e legenda) ou apagada.
As imagens ficam num espaço **privado** do Supabase: só membros logados conseguem vê-las. Imagens muito grandes são otimizadas antes do envio.
O menu mostra um ponto vermelho quando há uma edição nova que você ainda não viu.

**Membros** (oficiais e líder):
- **Remover do clã:** o líder escolhe "Remover do clã…" no seletor de cargo; o oficial usa o botão "Remover", que só aparece para membros comuns. Informe um motivo (opcional).
  A pessoa perde o acesso e vai para a lista recolhida **Ex-membros**, no fim da página, com a data, quem removeu e o motivo.
  Presenças passadas, alterações e anotações ficam guardadas. Somente as respostas e vagas em times de eventos futuros são apagadas, e o telefone é descartado.
- **Recusar:** em "Aguardando aprovação", o botão **Recusar** move a pessoa direto para Ex-membros.
- **Voltar ao clã:** se um ex-membro entrar de novo no site, ele vê "Você não faz mais parte do clã" e pode clicar em **Pedir para voltar**. O pedido aparece em "Aguardando aprovação". O líder também pode clicar em **Readmitir** na lista de ex-membros.
- **Histórico no clã:** no perfil de cada membro aparecem todas as mudanças de cargo (entrou, aprovado, promovido, removido, voltou), com data, quem fez e o motivo.
- **Histórico:** cada mudança de nome do personagem, nome do Discord, classe ou atributos fica registrada com a data. O botão 🕘 ao lado do membro mostra o histórico, com a diferença de cada atributo (ex.: Potência 4.692 → 5.332, +640).
- **Nome e foto do Discord** são atualizados automaticamente a cada login.
- **Busca:** encontra um membro pelo nome atual ou por um nome antigo, que aparece como "antes: …".
- **⬇ Exportar CSV:** baixa uma planilha separada por `;`, que abre direto no Excel. Ela traz personagem, Discord, cargo, classe, os 5 atributos, telefone, a frequência dos últimos 90 dias e a data de entrada.

**Tipos de evento:** todo evento tem um tipo (Guerra das Sombras, Vigília, Rito do Exílio ou Outros), escolhido no formulário de criação.
O site sugere o tipo pelo nome digitado; por exemplo, "Guerra das Sombras – final" vira Guerra das Sombras, e nomes que não batem com nenhum tipo viram Outros.
O nome do evento continua livre; é o **tipo** que agrupa os eventos no filtro da Frequência.

Para **cadastrar um tipo novo**, abra o Supabase → **Table Editor** → tabela `event_types` → **Insert row** e preencha:
- `name`: o nome que aparece no site (ex.: "Assalto ao Cofre");
- `sort_order`: a posição na lista (menor aparece primeiro; o "Outros" usa 999 para ficar por último);
- deixe `active` marcado.

Para **esconder** um tipo que não é mais usado, desmarque `active`. Ele some da lista de novos eventos, mas os eventos antigos continuam com ele. O banco não deixa apagar um tipo que algum evento usa.
Os membros veem o tipo novo na próxima vez que abrirem o site.

**Frequência** (menu do topo, só oficiais e líder): mostra a % de presença de cada membro no período escolhido, quantas vezes confirmou e faltou, quantas vezes não respondeu e uma linha com os últimos eventos.
Só contam eventos com presença registrada e posteriores à entrada do membro. Clique no título de uma coluna para ordenar.

## Dicas
- **Atualizando o site:** se você já tinha executado uma versão anterior do `schema.sql`, rode o arquivo inteiro de novo no SQL Editor. Ele só acrescenta o que falta e não apaga dados. Ao publicar arquivos novos, aumente o número `?v=` no `index.html` para os navegadores baixarem a versão nova.
- **Ativar o histórico de alterações dos eventos:** no Supabase, abra o **SQL Editor**, cole todo o conteúdo de [`supabase/historico_eventos.sql`](supabase/historico_eventos.sql) e clique em **Run**. Ele só acrescenta o que falta, pode ser executado de novo e também está no fim do `schema.sql`. Enquanto ele não for executado, o site funciona normalmente, só sem o histórico.
- **Ativar o histórico de quem encerrou os tickets:** do mesmo jeito, cole todo o conteúdo de [`supabase/tickets_historico.sql`](supabase/tickets_historico.sql) no **SQL Editor** e clique em **Run**. Ele também só acrescenta o que falta, pode ser executado de novo e está no fim do `schema.sql`.
- **Ativar a edição de nick pela staff:** cole todo o conteúdo de [`supabase/editar_nick.sql`](supabase/editar_nick.sql) no **SQL Editor** e clique em **Run**. Ele só acrescenta uma função, pode ser executado de novo e está no fim do `schema.sql`. A permissão fica em **⚙️ Configurações → Membros → Editar o nick dos membros**.
- **Pedido de piloto pela busca do nick:** rode o [`supabase/busca_conta.sql`](supabase/busca_conta.sql) no **SQL Editor**. O membro comum digita pelo menos 3 letras do nick da conta (até 8 resultados). Pode ser executado de novo e está no fim do `schema.sql`.
- **Imagens e proteções do navegador:** as imagens de tickets e da Malah News são redesenhadas antes do envio, o que apaga os metadados (localização GPS, modelo do celular). No `index.html`, o supabase-js tem verificação de integridade (`integrity`) e há uma `Content-Security-Policy`: ao trocar o projeto do Supabase ou a versão do supabase-js, atualize o endereço e o hash ali.
- **Eventos semanais:** ao criar, escolha "Repetir por N semanas"; ou, num evento existente, use "Repetir na próxima semana".
- **Horários:** cada pessoa vê o horário no fuso do próprio celular ou PC.
- **Link direto:** "Copiar link" na página do evento gera um link para mandar no Discord.
- **Testar localmente:** rode `py -m http.server 8765` nesta pasta e abra http://localhost:8765. Para o login funcionar localmente, adicione `http://localhost:8765` às Redirect URLs do Supabase.
