// Edge Function "ticket-notify" — DMs do bot do INFERNUM no Discord.
//  • Tickets: chamada pelos gatilhos de supabase/notificacoes_discord.sql com { id } do aviso.
//  • Acesso ao site (aprovado, readmitido, recusado): supabase/notificacoes_membros.sql,
//    com { id, type: 'member' }.
//
// Publicar: Supabase → Edge Functions → Deploy a new function → Via Editor,
// nome "ticket-notify", cole este arquivo e publique.
// Segredo: Supabase → Edge Functions → Secrets → DISCORD_BOT_TOKEN = token do bot
// (nunca coloque o token aqui no código nem no site).
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente nas Edge Functions.
import { createClient } from 'npm:@supabase/supabase-js@2';

const SITE = Deno.env.get('SITE_URL') || 'https://infernumcla.com.br';
const DISCORD = 'https://discord.com/api/v10';

// Evita que o título do ticket vire formatação ou link no Discord
const clean = (s) => String(s || '').replace(/[\\*_~`|>\[\]()]/g, (c) => `\\${c}`).replace(/@/g, '@​').slice(0, 100);

function message(n) {
  const link = `${SITE}/#/ticket/${n.ticket_id}`;
  const title = `**“${clean(n.title)}”**`;
  if (n.kind === 'reply') return `🔥 **INFERNUM** · A liderança respondeu seu ticket ${title}.\n👉 Veja a resposta: ${link}`;
  if (n.kind === 'assigned') return `🙋 **INFERNUM** · **${clean(n.actor)}** assumiu o atendimento do seu ticket ${title}.\n👉 ${link}`;
  return `✅ **INFERNUM** · Seu ticket ${title} foi encerrado como resolvido. Se ainda precisar de ajuda, é só responder por lá.\n👉 ${link}`;
}

function memberMessage(n) {
  if (n.kind === 'approved') return `🔥 **INFERNUM** · Seu acesso ao site do clã foi aprovado! Bem-vindo ao INFERNUM.
👉 ${SITE}`;
  if (n.kind === 'readmitted') return `🔥 **INFERNUM** · Seu retorno ao clã foi aprovado! Bem-vindo de volta ao INFERNUM.
👉 ${SITE}`;
  return '**INFERNUM** · Seu pedido de acesso ao site do clã não foi aprovado. Em caso de dúvida, fale com a liderança no Discord.';
}

async function discord(path, body, token) {
  const r = await fetch(`${DISCORD}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bot ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Discord ${r.status}: ${data?.message || 'erro'}${data?.code ? ` (código ${data.code})` : ''}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('ok');
  const { id, type } = await req.json().catch(() => ({}));
  const member = type === 'member';
  if (!Number.isInteger(id)) return new Response('id inválido', { status: 400 });

  const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  // Só avisos pendentes são enviados, e uma única vez (chamadas repetidas não fazem nada)
  const { data: n, error } = await sb.rpc(member ? 'claim_member_notification' : 'claim_ticket_notification', { p_id: id });
  if (error) return new Response(error.message, { status: 500 });
  if (!n) return new Response('nada a enviar');

  const fail = async (msg) => {
    await sb.rpc(member ? 'fail_member_notification' : 'fail_ticket_notification', { p_id: id, p_error: msg });
    return new Response(msg, { status: 200 });
  };
  const token = Deno.env.get('DISCORD_BOT_TOKEN');
  if (!token) return fail('Segredo DISCORD_BOT_TOKEN não cadastrado');
  if (!n.discord_id) return fail(member ? 'A conta não entrou com o Discord' : 'O autor não entrou com o Discord');

  try {
    const dm = await discord('/users/@me/channels', { recipient_id: n.discord_id }, token);
    await discord(`/channels/${dm.id}/messages`, { content: member ? memberMessage(n) : message(n), allowed_mentions: { parse: [] } }, token);
    return new Response('enviado');
  } catch (e) {
    return fail(String(e?.message || e));
  }
});
