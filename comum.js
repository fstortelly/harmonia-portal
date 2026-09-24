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
  const modulo = titulo && titulo !== 'Harmonia Animal' ? `<span class="modulo-nome">${esc(titulo)}</span>` : '';
  return `<header class="top"><a class="marca" href="/" aria-label="Harmonia Animal, voltar ao portal">
      <img class="logo" src="/logo.png" alt="Harmonia Animal" onerror="this.outerHTML=LOGO_RESERVA">${modulo}</a>
    <div class="quem">${esc(nome || '')}${extra}</div></header>`;
}
// Usado só se o arquivo logo.png não estiver no repositório.
const LOGO_RESERVA = CRUZ + '<span>Harmonia Animal</span>';

// ---------- arquivos (Supabase Storage, espaço privado "treinamentos") ----------
const LIMITE_ARQUIVO = 50 * 1024 * 1024;
function _cabStorage(ct) {
  const h = { apikey: CFG.key };
  if (CFG.key.startsWith('eyJ')) h.Authorization = 'Bearer ' + CFG.key;
  if (ct) h['Content-Type'] = ct;
  return h;
}
const _urlObjeto = cam => `${CFG.url}/storage/v1/object/treinamentos/${cam.split('/').map(encodeURIComponent).join('/')}`;
async function storageEnviar(cam, file) {
  let r;
  try { r = await fetch(_urlObjeto(cam), { method:'POST', headers:{ ..._cabStorage(file.type || 'application/octet-stream'), 'x-upsert':'false' }, body:file }); }
  catch { throw new Error('Sem conexão. O arquivo não foi enviado.'); }
  if (!r.ok) { let m = ''; try { m = (await r.json()).message || ''; } catch {} throw new Error('Não foi possível enviar o arquivo' + (m ? ': ' + m : '.')); }
}
async function storageBaixar(cam) {
  const r = await fetch(_urlObjeto(cam), { headers:_cabStorage() });
  if (!r.ok) throw new Error('Não foi possível abrir o arquivo. Tente de novo.');
  return r.blob();
}
async function storageExcluir(cam) {
  try { await fetch(`${CFG.url}/storage/v1/object/treinamentos`, { method:'DELETE', headers:_cabStorage('application/json'), body:JSON.stringify({ prefixes:[cam] }) }); } catch {}
}
function tamanhoTxt(b) {
  if (!b) return '';
  return b < 1024 * 1024 ? Math.max(1, Math.round(b / 1024)) + ' KB' : (b / 1024 / 1024).toFixed(1).replace('.', ',') + ' MB';
}
const visualizavel = mime => /^(application\/pdf|image\/)/.test(mime || '');
