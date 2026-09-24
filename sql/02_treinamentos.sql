-- ============================================================
-- Harmonia Animal · Módulo Treinamentos
-- ============================================================
create table if not exists treino_treinamentos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  conteudo text,
  data date not null,
  hora_inicio time not null,
  hora_fim time,
  modalidade text not null default 'presencial' check (modalidade in ('presencial','online','hibrido')),
  local_texto text,
  responsavel text,
  obrigatorio boolean not null default true,
  funcoes text[] not null default '{}',
  segredo text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  sessao_aberta boolean not null default false,
  geo_lat double precision,
  geo_lng double precision,
  raio_m int not null default 150,
  sorteios jsonb not null default '[]',
  criado_em timestamptz not null default now()
);

create table if not exists treino_presencas (
  id uuid primary key default gen_random_uuid(),
  treinamento_id uuid not null references treino_treinamentos(id) on delete cascade,
  pessoa_id uuid not null references portal_pessoas(id) on delete cascade,
  assinado_em timestamptz not null default now(),
  modo text not null,
  lat double precision,
  lng double precision,
  distancia_m int,
  status text not null,
  atrasado boolean not null default false,
  unique (treinamento_id, pessoa_id)
);

create table if not exists treino_atividades (
  id uuid primary key default gen_random_uuid(),
  treinamento_id uuid not null references treino_treinamentos(id) on delete cascade,
  ordem int not null default 0,
  tipo text not null check (tipo in ('quiz','enquete','aberta','link')),
  titulo text not null default '',
  dados jsonb not null default '{}',
  anonima boolean not null default false,
  liberada boolean not null default false
);

create table if not exists treino_respostas (
  id uuid primary key default gen_random_uuid(),
  atividade_id uuid not null references treino_atividades(id) on delete cascade,
  pessoa_id uuid not null references portal_pessoas(id) on delete cascade,
  resposta jsonb not null,
  nota numeric,
  respondido_em timestamptz not null default now(),
  unique (atividade_id, pessoa_id)
);

alter table treino_treinamentos enable row level security;
alter table treino_presencas enable row level security;
alter table treino_atividades enable row level security;
alter table treino_respostas enable row level security;
revoke all on treino_treinamentos, treino_presencas, treino_atividades, treino_respostas from anon, authenticated;

-- ---------- helpers internos ----------
create or replace function treino__usa(p_token text)
returns portal_pessoas language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas;
begin
  me := portal__sessao(p_token);
  if portal__nivel(me, 'treinamentos') is null then raise exception 'Você não tem acesso aos Treinamentos.'; end if;
  return me;
end $$;

create or replace function treino__ger(p_token text)
returns portal_pessoas language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas;
begin
  me := portal__sessao(p_token);
  if coalesce(portal__nivel(me, 'treinamentos'), '') <> 'gerencia' then
    raise exception 'Somente quem gerencia os Treinamentos pode fazer isso.';
  end if;
  return me;
end $$;

create or replace function treino__codigo(p_segredo text, p_janela bigint)
returns text language sql immutable set search_path = public, extensions as $$
  select lpad(((('x0' || substr(encode(hmac(p_janela::text, p_segredo, 'sha256'), 'hex'), 1, 7))::bit(32)::int) % 1000000)::text, 6, '0')
$$;

create or replace function treino__ativ_publica(a treino_atividades)
returns jsonb language sql immutable as $$
  select jsonb_build_object('id', a.id, 'tipo', a.tipo, 'titulo', a.titulo, 'anonima', a.anonima, 'liberada', a.liberada,
    'dados', case when a.tipo = 'quiz' then jsonb_build_object('perguntas',
      (select coalesce(jsonb_agg(q - 'correta' order by o), '[]') from jsonb_array_elements(coalesce(a.dados->'perguntas', '[]')) with ordinality x(q, o)))
      else a.dados end)
$$;

create or replace function treino__gabarito(a treino_atividades)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(q->'correta' order by o), '[]') from jsonb_array_elements(coalesce(a.dados->'perguntas', '[]')) with ordinality x(q, o)
$$;

-- ---------- quem usa ----------
create or replace function treino_meus(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas; perf text;
begin
  me := treino__usa(p_token);
  select nome into perf from portal_perfis where id = me.perfil_id;
  return (select coalesce(jsonb_agg(s.x order by s.x->>'data' desc, s.x->>'hora_inicio' desc), '[]') from (
    select jsonb_build_object('id', t.id, 'titulo', t.titulo, 'conteudo', t.conteudo, 'data', t.data,
      'hora_inicio', to_char(t.hora_inicio, 'HH24:MI'), 'hora_fim', to_char(t.hora_fim, 'HH24:MI'),
      'modalidade', t.modalidade, 'local_texto', t.local_texto, 'responsavel', t.responsavel, 'obrigatorio', t.obrigatorio,
      'presente', p.id is not null, 'assinado_em', p.assinado_em,
      'n_atividades', (select count(*) from treino_atividades a where a.treinamento_id = t.id),
      'atividades', case when p.id is null then '[]'::jsonb else (
        select coalesce(jsonb_agg(treino__ativ_publica(a) || jsonb_build_object('minha', r.resposta, 'nota', r.nota,
          'gabarito', case when r.id is not null and a.tipo = 'quiz' then treino__gabarito(a) end) order by a.ordem), '[]')
        from treino_atividades a
        left join treino_respostas r on r.atividade_id = a.id and r.pessoa_id = me.id
        where a.treinamento_id = t.id and (a.liberada or r.id is not null)) end) as x
    from treino_treinamentos t
    left join treino_presencas p on p.treinamento_id = t.id and p.pessoa_id = me.id
    where cardinality(t.funcoes) = 0 or perf = any(t.funcoes) or p.id is not null) s);
end $$;

create or replace function treino_validar_codigo(p_codigo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare t record; w bigint := floor(extract(epoch from now()) / 15)::bigint; tk bigint := floor(extract(epoch from now()) / 60)::bigint;
begin
  if p_codigo is null or p_codigo !~ '^\d{6}$' then raise exception 'Digite os 6 números que aparecem na tela.'; end if;
  for t in select * from treino_treinamentos where sessao_aberta loop
    if p_codigo in (treino__codigo(t.segredo, w), treino__codigo(t.segredo, w - 1), treino__codigo(t.segredo, w - 2)) then
      return jsonb_build_object('treino_id', t.id, 'titulo', t.titulo, 'modalidade', t.modalidade,
        'tem_local', t.geo_lat is not null,
        'ticket', tk::text || '.' || substr(encode(hmac('ticket:' || tk::text, t.segredo, 'sha256'), 'hex'), 1, 20));
    end if;
  end loop;
  raise exception 'Código inválido ou expirado. Digite o código que está na tela agora.';
end $$;

create or replace function treino_assinar(p_token text, p_treino uuid, p_ticket text, p_modo text, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas; t treino_treinamentos; tk bigint; v_modo text; dist int; st text := 'ok'; atr boolean;
begin
  me := treino__usa(p_token);
  select * into t from treino_treinamentos where id = p_treino;
  if t.id is null or not t.sessao_aberta then raise exception 'A lista de presença deste treinamento está fechada.'; end if;
  if p_ticket is null or p_ticket !~ '^\d+\.[0-9a-f]{20}$' then raise exception 'Código inválido. Digite o código da tela novamente.'; end if;
  tk := split_part(p_ticket, '.', 1)::bigint;
  if split_part(p_ticket, '.', 2) <> substr(encode(hmac('ticket:' || tk::text, t.segredo, 'sha256'), 'hex'), 1, 20)
     or floor(extract(epoch from now()) / 60)::bigint - tk > 5 then
    raise exception 'O código expirou. Digite o código que está na tela agora.';
  end if;
  if exists (select 1 from treino_presencas where treinamento_id = t.id and pessoa_id = me.id) then
    return jsonb_build_object('ja_assinado', true, 'titulo', t.titulo, 'treino_id', t.id);
  end if;
  v_modo := case t.modalidade when 'online' then 'online' when 'presencial' then 'presencial'
            else case when p_modo = 'online' then 'online' else 'presencial' end end;
  if v_modo = 'presencial' and t.geo_lat is not null then
    if p_lat is null or p_lng is null then
      st := 'sem_localizacao';
    else
      dist := round(2 * 6371000 * asin(sqrt(
        power(sin(radians(p_lat - t.geo_lat) / 2), 2) +
        cos(radians(t.geo_lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - t.geo_lng) / 2), 2))));
      if dist > t.raio_m then st := 'fora_do_local'; end if;
    end if;
  end if;
  atr := now() > ((t.data + t.hora_inicio) at time zone 'America/Sao_Paulo') + interval '15 minutes';
  insert into treino_presencas (treinamento_id, pessoa_id, modo, lat, lng, distancia_m, status, atrasado)
  values (t.id, me.id, v_modo, p_lat, p_lng, dist, st, atr);
  return jsonb_build_object('ok', true, 'status', st, 'atrasado', atr, 'titulo', t.titulo, 'modo', v_modo, 'treino_id', t.id);
end $$;

create or replace function treino_responder(p_token text, p_atividade uuid, p_resposta jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas; a treino_atividades; v_nota numeric; tot int := 0; ac int := 0; i int; n int; sel jsonb;
begin
  me := treino__usa(p_token);
  select * into a from treino_atividades where id = p_atividade;
  if a.id is null then raise exception 'Atividade não encontrada.'; end if;
  if not exists (select 1 from treino_presencas where treinamento_id = a.treinamento_id and pessoa_id = me.id) then
    raise exception 'Assine a presença deste treinamento para responder.';
  end if;
  if not a.liberada then raise exception 'Esta atividade não está aberta para respostas agora.'; end if;
  if exists (select 1 from treino_respostas where atividade_id = a.id and pessoa_id = me.id) then
    raise exception 'Você já respondeu esta atividade.';
  end if;
  if a.tipo = 'quiz' then
    tot := jsonb_array_length(coalesce(a.dados->'perguntas', '[]'));
    if jsonb_typeof(p_resposta->'respostas') is distinct from 'array' or jsonb_array_length(p_resposta->'respostas') <> tot then
      raise exception 'Responda todas as perguntas.';
    end if;
    for i in 0..tot - 1 loop
      if coalesce(p_resposta->'respostas'->>i, '') !~ '^\d+$' then raise exception 'Responda todas as perguntas.'; end if;
      if (p_resposta->'respostas'->>i)::int = (a.dados->'perguntas'->i->>'correta')::int then ac := ac + 1; end if;
    end loop;
    v_nota := case when tot > 0 then round(ac::numeric * 10 / tot, 1) end;
  elsif a.tipo = 'enquete' then
    sel := p_resposta->'opcoes';
    n := jsonb_array_length(coalesce(a.dados->'opcoes', '[]'));
    if jsonb_typeof(sel) is distinct from 'array' or jsonb_array_length(sel) = 0 then raise exception 'Escolha uma opção.'; end if;
    if jsonb_array_length(sel) > 1 and not coalesce((a.dados->>'multipla')::boolean, false) then raise exception 'Escolha só uma opção.'; end if;
    if exists (select 1 from jsonb_array_elements_text(sel) v where case when v ~ '^\d+$' then v::int >= n else true end) then
      raise exception 'Opção inválida.';
    end if;
  elsif a.tipo = 'aberta' then
    if coalesce(trim(p_resposta->>'texto'), '') = '' then raise exception 'Escreva sua resposta.'; end if;
  end if;
  insert into treino_respostas (atividade_id, pessoa_id, resposta, nota) values (a.id, me.id, p_resposta, v_nota);
  return jsonb_build_object('ok', true, 'nota', v_nota, 'acertos', ac, 'total', tot,
    'gabarito', case when a.tipo = 'quiz' then treino__gabarito(a) end);
end $$;

-- ---------- quem gerencia ----------
create or replace function treino_ger_dados(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform treino__ger(p_token);
  return jsonb_build_object(
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object('id', pe.id, 'nome', pe.nome, 'perfil', pf.nome, 'ativo', pe.ativo,
        'convocavel', pe.ativo and exists (select 1 from portal_acessos ac where ac.pessoa_id = pe.id and ac.modulo_id = 'treinamentos'))
        order by pe.nome), '[]')
      from portal_pessoas pe left join portal_perfis pf on pf.id = pe.perfil_id),
    'perfis', (select coalesce(jsonb_agg(nome order by nome), '[]') from portal_perfis),
    'treinamentos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'titulo', titulo, 'conteudo', conteudo, 'data', data,
        'hora_inicio', to_char(hora_inicio, 'HH24:MI'), 'hora_fim', to_char(hora_fim, 'HH24:MI'), 'modalidade', modalidade,
        'local_texto', local_texto, 'responsavel', responsavel, 'obrigatorio', obrigatorio, 'funcoes', funcoes,
        'sessao_aberta', sessao_aberta, 'tem_local', geo_lat is not null, 'raio_m', raio_m, 'sorteios', sorteios)
        order by data desc, hora_inicio desc), '[]') from treino_treinamentos),
    'presencas', (select coalesce(jsonb_agg(jsonb_build_object('treinamento_id', treinamento_id, 'pessoa_id', pessoa_id,
        'assinado_em', assinado_em, 'modo', modo, 'distancia_m', distancia_m, 'status', status, 'atrasado', atrasado)), '[]')
        from treino_presencas),
    'atividades', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'treinamento_id', a.treinamento_id, 'ordem', a.ordem,
        'tipo', a.tipo, 'titulo', a.titulo, 'dados', a.dados, 'anonima', a.anonima, 'liberada', a.liberada,
        'n_respostas', (select count(*) from treino_respostas r where r.atividade_id = a.id)) order by a.ordem), '[]')
        from treino_atividades a),
    'notas', (select coalesce(jsonb_agg(jsonb_build_object('treinamento_id', a.treinamento_id, 'pessoa_id', r.pessoa_id, 'nota', r.nota)), '[]')
        from treino_respostas r join treino_atividades a on a.id = r.atividade_id where a.tipo = 'quiz'));
end $$;

create or replace function treino_ger_salvar_treino(p_token text, p jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare rid uuid; fs text[]; rec record;
begin
  perform treino__ger(p_token);
  if coalesce(trim(p->>'titulo'), '') = '' or coalesce(p->>'data', '') = '' or coalesce(p->>'hora_inicio', '') = '' then
    raise exception 'Preencha título, data e horário de início.';
  end if;
  fs := coalesce(array(select jsonb_array_elements_text(coalesce(p->'funcoes', '[]'::jsonb))), '{}');
  if coalesce(p->>'id', '') = '' then
    insert into treino_treinamentos (titulo, conteudo, data, hora_inicio, hora_fim, modalidade, local_texto, responsavel, obrigatorio, funcoes, raio_m)
    values (trim(p->>'titulo'), p->>'conteudo', (p->>'data')::date, (p->>'hora_inicio')::time, nullif(p->>'hora_fim', '')::time,
            coalesce(p->>'modalidade', 'presencial'), p->>'local_texto', p->>'responsavel',
            coalesce((p->>'obrigatorio')::boolean, true), fs, coalesce(nullif(p->>'raio_m', '')::int, 150))
    returning id into rid;
  else
    update treino_treinamentos set titulo = trim(p->>'titulo'), conteudo = p->>'conteudo', data = (p->>'data')::date,
      hora_inicio = (p->>'hora_inicio')::time, hora_fim = nullif(p->>'hora_fim', '')::time,
      modalidade = coalesce(p->>'modalidade', modalidade), local_texto = p->>'local_texto', responsavel = p->>'responsavel',
      obrigatorio = coalesce((p->>'obrigatorio')::boolean, obrigatorio), funcoes = fs,
      raio_m = coalesce(nullif(p->>'raio_m', '')::int, raio_m)
    where id = (p->>'id')::uuid returning id into rid;
  end if;
  delete from treino_atividades where treinamento_id = rid and id not in (
    select (x->>'id')::uuid from jsonb_array_elements(coalesce(p->'atividades', '[]')) x where coalesce(x->>'id', '') <> '');
  for rec in select value as x, ordinality as o from jsonb_array_elements(coalesce(p->'atividades', '[]')) with ordinality loop
    if coalesce(rec.x->>'id', '') = '' then
      insert into treino_atividades (treinamento_id, ordem, tipo, titulo, dados, anonima)
      values (rid, rec.o, rec.x->>'tipo', coalesce(rec.x->>'titulo', ''), coalesce(rec.x->'dados', '{}'), coalesce((rec.x->>'anonima')::boolean, false));
    else
      update treino_atividades set ordem = rec.o, tipo = rec.x->>'tipo', titulo = coalesce(rec.x->>'titulo', ''),
        dados = coalesce(rec.x->'dados', '{}'), anonima = coalesce((rec.x->>'anonima')::boolean, false)
      where id = (rec.x->>'id')::uuid and treinamento_id = rid;
    end if;
  end loop;
  return rid;
end $$;

create or replace function treino_ger_excluir(p_token text, p_treino uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform treino__ger(p_token);
  delete from treino_treinamentos where id = p_treino;
end $$;

create or replace function treino_ger_sessao(p_token text, p_treino uuid, p_abrir boolean, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform treino__ger(p_token);
  update treino_treinamentos set sessao_aberta = p_abrir,
    geo_lat = case when p_abrir and p_lat is not null then p_lat else geo_lat end,
    geo_lng = case when p_abrir and p_lng is not null then p_lng else geo_lng end
  where id = p_treino;
end $$;

create or replace function treino_ger_codigo(p_token text, p_treino uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare t treino_treinamentos; e double precision := extract(epoch from now()); w bigint := floor(extract(epoch from now()) / 15)::bigint;
begin
  perform treino__ger(p_token);
  select * into t from treino_treinamentos where id = p_treino;
  if t.id is null or not t.sessao_aberta then return jsonb_build_object('aberta', false); end if;
  return jsonb_build_object('aberta', true, 'codigo', treino__codigo(t.segredo, w), 'restante', 15 - (e - w * 15),
    'presentes', (select coalesce(jsonb_agg(jsonb_build_object('nome', pe.nome, 'perfil', pf.nome, 'assinado_em', p.assinado_em,
        'status', p.status, 'modo', p.modo, 'atrasado', p.atrasado) order by p.assinado_em desc), '[]')
      from treino_presencas p join portal_pessoas pe on pe.id = p.pessoa_id left join portal_perfis pf on pf.id = pe.perfil_id
      where p.treinamento_id = t.id),
    'atividades', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'tipo', a.tipo, 'titulo', a.titulo, 'liberada', a.liberada,
        'n_respostas', (select count(*) from treino_respostas r where r.atividade_id = a.id)) order by a.ordem), '[]')
      from treino_atividades a where a.treinamento_id = t.id));
end $$;

create or replace function treino_ger_liberar(p_token text, p_atividade uuid, p_liberar boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform treino__ger(p_token);
  update treino_atividades set liberada = p_liberar where id = p_atividade;
end $$;

create or replace function treino_ger_resultado(p_token text, p_atividade uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a treino_atividades;
begin
  perform treino__ger(p_token);
  select * into a from treino_atividades where id = p_atividade;
  if a.id is null then raise exception 'Atividade não encontrada.'; end if;
  return jsonb_build_object('id', a.id, 'tipo', a.tipo, 'titulo', a.titulo, 'dados', a.dados, 'anonima', a.anonima, 'liberada', a.liberada,
    'presentes', (select count(*) from treino_presencas where treinamento_id = a.treinamento_id),
    'respostas', (select coalesce(jsonb_agg(jsonb_build_object('nome', case when a.anonima then null else pe.nome end,
        'resposta', r.resposta, 'nota', r.nota) order by case when a.anonima then random() else 0 end, r.respondido_em), '[]')
      from treino_respostas r join portal_pessoas pe on pe.id = r.pessoa_id where r.atividade_id = a.id));
end $$;

create or replace function treino_ger_presenca(p_token text, p_treino uuid, p_pessoa uuid, p_marcar boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform treino__ger(p_token);
  if p_marcar then
    insert into treino_presencas (treinamento_id, pessoa_id, modo, status, atrasado)
    values (p_treino, p_pessoa, 'manual', 'manual', false) on conflict do nothing;
  else
    delete from treino_presencas where treinamento_id = p_treino and pessoa_id = p_pessoa;
  end if;
end $$;

create or replace function treino_ger_sortear(p_token text, p_treino uuid, p_sem_repetir boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare t treino_treinamentos; g record; nomes jsonb;
begin
  perform treino__ger(p_token);
  select * into t from treino_treinamentos where id = p_treino;
  select coalesce(jsonb_agg(pe.nome), '[]') into nomes
    from treino_presencas p join portal_pessoas pe on pe.id = p.pessoa_id where p.treinamento_id = p_treino;
  select pe.id, pe.nome into g
    from treino_presencas p join portal_pessoas pe on pe.id = p.pessoa_id
   where p.treinamento_id = p_treino
     and (not p_sem_repetir or not exists (select 1 from jsonb_array_elements(t.sorteios) s where s->>'pessoa_id' = pe.id::text))
   order by random() limit 1;
  if g.id is null then raise exception 'Ninguém disponível para o sorteio: ninguém assinou ainda, ou todos já foram sorteados.'; end if;
  update treino_treinamentos set sorteios = sorteios || jsonb_build_array(jsonb_build_object('pessoa_id', g.id, 'nome', g.nome, 'em', now()))
   where id = p_treino;
  return jsonb_build_object('nome', g.nome, 'nomes', nomes);
end $$;

-- ---------- permissões ----------
revoke all on function treino__usa(text), treino__ger(text), treino__codigo(text, bigint),
  treino__ativ_publica(treino_atividades), treino__gabarito(treino_atividades) from public, anon, authenticated;
grant execute on function treino_meus(text), treino_validar_codigo(text),
  treino_assinar(text, uuid, text, text, double precision, double precision), treino_responder(text, uuid, jsonb),
  treino_ger_dados(text), treino_ger_salvar_treino(text, jsonb), treino_ger_excluir(text, uuid),
  treino_ger_sessao(text, uuid, boolean, double precision, double precision), treino_ger_codigo(text, uuid),
  treino_ger_liberar(text, uuid, boolean), treino_ger_resultado(text, uuid), treino_ger_presenca(text, uuid, uuid, boolean),
  treino_ger_sortear(text, uuid, boolean)
to anon, authenticated;
