// Edge Function "rivals-share" — Clãs rivais compartilhados entre o INFERNUM e a FOR HONOR.
// As leituras ficam no Supabase do INFERNUM. O site da FOR HONOR chama esta função com o
// login de lá; antes de qualquer coisa ela pergunta ao Supabase da FOR HONOR (função
// officer_can, que já existe lá) se a pessoa é líder ou oficial com a permissão:
//   • rivals_view   → listar as leituras
//   • rivals_import → importar e apagar leituras
//
// Publicar (no Supabase do INFERNUM): Edge Functions → Deploy a new function → Via Editor,
// nome "rivals-share", cole este arquivo e publique. Depois, nos detalhes da função,
// DESLIGUE "Verify JWT with legacy secret" (o login vem do Supabase da FOR HONOR, não daqui).
// Nenhum segredo novo: a URL e a chave anon da FOR HONOR abaixo são públicas (estão no site deles).
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente nas Edge Functions.
import { createClient } from 'npm:@supabase/supabase-js@2';

const PARTNER = {
  name: 'FOR HONOR',
  url: 'https://oxwuryqvoariuxypviae.supabase.co',
  anon: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im94d3VyeXF2b2FyaXV4eXB2aWFlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ1MDg5NDIsImV4cCI6MjExMDA4NDk0Mn0.0BbpUJBjkX1kJs1okN9zFpiBwXnO3od3g2CldvAQMjM',
};
const ORIGINS = ['https://forhonorcla.com.br', 'https://www.forhonorcla.com.br'];
const ATTRS = ['armor', 'armor_pen', 'potency', 'resistance', 'resonance'];

const intOrNull = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0 || n > 10_000_000) throw new Error('Atributo inválido');
  return n;
};
const text = (v, max) => String(v ?? '').trim().slice(0, max);

function cors(req) {
  const origin = req.headers.get('origin') || '';
  return {
    'Access-Control-Allow-Origin': ORIGINS.includes(origin) ? origin : ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
}

// Nome de quem está logado no site da FOR HONOR (para o registro de quem importou ou apagou)
async function partnerName(token) {
  const h = { apikey: PARTNER.anon, Authorization: `Bearer ${token}` };
  const u = await fetch(`${PARTNER.url}/auth/v1/user`, { headers: h });
  if (!u.ok) return 'Desconhecido';
  const { id } = await u.json().catch(() => ({}));
  if (!id) return 'Desconhecido';
  const r = await fetch(`${PARTNER.url}/rest/v1/profiles?select=game_name,google_name&id=eq.${encodeURIComponent(id)}`, { headers: h });
  const p = r.ok ? (await r.json().catch(() => []))[0] : null;
  return text(p?.game_name || p?.google_name || 'Desconhecido', 60);
}

// Pergunta ao Supabase da FOR HONOR, com o login da própria pessoa, se ela pode fazer isso
async function partnerCan(token, key) {
  const r = await fetch(`${PARTNER.url}/rest/v1/rpc/officer_can`, {
    method: 'POST',
    headers: { apikey: PARTNER.anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_key: key }),
  });
  if (!r.ok) return false;
  return (await r.json().catch(() => false)) === true;
}


Deno.serve(async (req) => {
  const headers = { ...cors(req), 'Content-Type': 'application/json' };
  const reply = (body, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response('ok', { headers });
  if (req.method !== 'POST') return reply({ error: 'Use POST' }, 405);

  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return reply({ error: 'Faça login no site do clã' }, 401);
  const body = await req.json().catch(() => ({}));
  const action = body?.action;
  const need = action === 'list' ? 'rivals_view' : action === 'import' || action === 'delete' ? 'rivals_import' : null;
  if (!need) return reply({ error: 'Ação inválida' }, 400);
  if (!(await partnerCan(token, need))) {
    return reply({ error: need === 'rivals_view' ? 'Só a liderança com permissão vê os clãs rivais' : 'Só a liderança com permissão importa ou apaga leituras' }, 403);
  }

  const sb = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
  try {
    if (action === 'list') {
      const s = await sb.from('rival_scans').select('*').order('scanned_on').order('id');
      if (s.error) throw s.error;
      const players = [];
      for (let from = 0; ; from += 1000) {
        const r = await sb.from('rival_players').select('*').order('id').range(from, from + 999);
        if (r.error) throw r.error;
        players.push(...r.data);
        if (r.data.length < 1000) break;
      }
      const log = await sb.from('rival_scan_log').select('*').order('created_at', { ascending: false }).limit(300);
      if (log.error) throw log.error;
      return reply({ scans: s.data, players, log: log.data });
    }

    if (action === 'delete') {
      const id = Number(body.id);
      if (!Number.isInteger(id)) return reply({ error: 'Leitura inválida' }, 400);
      const sc = await sb.from('rival_scans').select('id, clan_name, scanned_on').eq('id', id).maybeSingle();
      if (sc.error) throw sc.error;
      if (!sc.data) return reply({ ok: true });
      const n = await sb.from('rival_players').select('id', { count: 'exact', head: true }).eq('scan_id', id);
      const lg = await sb.from('rival_scan_log').insert({ scan_id: id, action: 'delete', clan_name: sc.data.clan_name, scanned_on: sc.data.scanned_on,
        players: n.count ?? null, actor_clan: PARTNER.name, actor_name: await partnerName(token) });
      if (lg.error) throw lg.error;
      const r = await sb.from('rival_scans').delete().eq('id', id);
      if (r.error) throw r.error;
      return reply({ ok: true });
    }

    // Importar a leitura de um clã (o site já tirou os repetidos)
    const clan = text(body.clan_name, 60);
    if (!clan) return reply({ error: 'Informe o nome do clã' }, 400);
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Sao_Paulo' });
    const day = String(body.scanned_on || '');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day > today) return reply({ error: 'Data da leitura inválida' }, 400);
    const list = Array.isArray(body.players) ? body.players : [];
    if (!list.length || list.length > 150) return reply({ error: 'A leitura precisa ter de 1 a 150 jogadores' }, 400);
    const players = list.map((p) => ({
      name: text(p?.name, 60),
      ...Object.fromEntries(ATTRS.map((k) => [k, intOrNull(p?.[k])])),
      note: text(p?.note, 200) || null,
    })).filter((p) => p.name);
    if (!players.length) return reply({ error: 'Nenhum jogador com nome na leitura' }, 400);
    const num = body.clan_number == null || body.clan_number === '' ? null : Number(body.clan_number);

    const who = await partnerName(token);
    const s = await sb.from('rival_scans').insert({
      clan_name: clan, clan_number: Number.isSafeInteger(num) ? num : null, scanned_on: day,
      source: text(body.source, 200) || null, created_by: null, imported_by: PARTNER.name, imported_by_name: who,
    }).select('id').single();
    if (s.error) throw s.error;
    const r = await sb.from('rival_players').insert(players.map((p) => ({ ...p, scan_id: s.data.id })));
    if (r.error) { await sb.from('rival_scans').delete().eq('id', s.data.id); throw r.error; }
    await sb.from('rival_scan_log').insert({ scan_id: s.data.id, action: 'import', clan_name: clan, scanned_on: day,
      players: players.length, actor_clan: PARTNER.name, actor_name: who });
    return reply({ id: s.data.id });
  } catch (e) {
    return reply({ error: e?.message || 'Erro no banco compartilhado' }, e?.message === 'Atributo inválido' ? 400 : 500);
  }
});
