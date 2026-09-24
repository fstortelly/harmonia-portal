// Funções compartilhadas por todas as telas do portal.
const CFG = window.HARMONIA_CFG;
const H = {
  get token() { try { return localStorage.getItem('harmonia_token'); } catch { return null; } },
  set token(v) { try { v ? localStorage.setItem('harmonia_token', v) : localStorage.removeItem('harmonia_token'); } catch {} }
};
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const MES = ['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'];
const hojeISO = () => { const d = new Date(); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10); };
const dataBR = iso => iso ? `${iso.slice(8,10)}/${iso.slice(5,7)}/${iso.slice(0,4)}` : '';
const horaDe = ts => new Date(ts).toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit' });
const UNIDADES = { barao:'Barão', bonfim:'Bonfim' };
const NIVEIS = { usa:'Usa', gerencia:'Gerencia' };

async function rpc(fn, args = {}) {
  const headers = { 'Content-Type':'application/json', apikey: CFG.key };
  if (CFG.key.startsWith('eyJ')) headers.Authorization = 'Bearer ' + CFG.key;
  let r;
  try { r = await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, { method:'POST', headers, body: JSON.stringify(args) }); }
  catch { throw new Error('Sem conexão com a internet. Tente de novo.'); }
  const txt = await r.text(); let d = null;
  try { d = txt ? JSON.parse(txt) : null; } catch { d = txt; }
  if (!r.ok) {
    const msg = (d && d.message) || 'Não foi possível concluir. Tente de novo.';
    if (msg.startsWith('SESSAO:')) { H.token = null; irLogin(); throw new Error(msg.slice(7).trim()); }
    throw new Error(msg);
  }
  return d;
}
function irLogin() { location.href = '/?volta=' + encodeURIComponent(location.pathname + location.search); }

let _toastT;
function toast(msg, erro) {
  $$('.toast').forEach(e => e.remove());
  const el = document.createElement('div'); el.className = 'toast' + (erro ? ' erro' : ''); el.textContent = msg;
  el.setAttribute('role', erro ? 'alert' : 'status');
  document.body.appendChild(el); clearTimeout(_toastT); _toastT = setTimeout(() => el.remove(), 4500);
}
function posicao() {
  return new Promise(res => {
    if (!navigator.geolocation) return res(null);
    navigator.geolocation.getCurrentPosition(p => res({ lat:p.coords.latitude, lng:p.coords.longitude }),
      () => res(null), { enableHighAccuracy:true, timeout:12000, maximumAge:0 });
  });
}
const CRUZ = '<svg class="cruz" viewBox="0 0 24 24" aria-hidden="true"><path fill="#13877F" d="M9 2h6v7h7v6h-7v7H9v-7H2V9h7z"/></svg>';
function cabecalho(titulo, nome, extra = '') {
  return `<header class="top"><a class="marca" href="/">${CRUZ}<span>${esc(titulo)}</span></a>
    <div class="quem">${esc(nome || '')}${extra}</div></header>`;
}
