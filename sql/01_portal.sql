-- ============================================================
-- Harmonia Animal · Portal (login único, pessoas, perfis, acessos)
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists portal_perfis (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  niveis jsonb not null default '{}'
);

create table if not exists portal_modulos (
  id text primary key,
  nome text not null,
  descricao text,
  url text,
  ordem int not null default 0,
  por_unidade boolean not null default false,
  ativo boolean not null default true
);

create table if not exists portal_pessoas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  usuario text not null unique,
  senha_hash text not null,
  trocar_senha boolean not null default true,
  perfil_id uuid references portal_perfis(id) on delete set null,
  master boolean not null default false,
  ativo boolean not null default true,
  falhas int not null default 0,
  bloqueado_ate timestamptz,
  criado_em timestamptz not null default now()
);

create table if not exists portal_acessos (
  pessoa_id uuid not null references portal_pessoas(id) on delete cascade,
  modulo_id text not null references portal_modulos(id) on delete cascade,
  nivel text not null check (nivel in ('usa','gerencia')),
  unidades text[] not null default '{}',
  primary key (pessoa_id, modulo_id)
);

create table if not exists portal_sessoes (
  token_hash text primary key,
  pessoa_id uuid not null references portal_pessoas(id) on delete cascade,
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null
);

alter table portal_perfis enable row level security;
alter table portal_modulos enable row level security;
alter table portal_pessoas enable row level security;
alter table portal_acessos enable row level security;
alter table portal_sessoes enable row level security;
revoke all on portal_perfis, portal_modulos, portal_pessoas, portal_acessos, portal_sessoes from anon, authenticated;

-- ---------- helpers internos ----------
create or replace function portal__sessao(p_token text)
returns portal_pessoas language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas; s portal_sessoes;
begin
  select * into s from portal_sessoes where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if s.token_hash is null or s.expira_em < now() then
    raise exception 'SESSAO: Sua sessão expirou. Entre novamente.';
  end if;
  select * into r from portal_pessoas where id = s.pessoa_id and ativo;
  if r.id is null then raise exception 'SESSAO: Seu acesso foi desativado.'; end if;
  if s.expira_em < now() + interval '25 days' then
    update portal_sessoes set expira_em = now() + interval '30 days' where token_hash = s.token_hash;
  end if;
  return r;
end $$;

create or replace function portal__master(p_token text)
returns portal_pessoas language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas;
begin
  r := portal__sessao(p_token);
  if not r.master then raise exception 'Somente o acesso master pode fazer isso.'; end if;
  return r;
end $$;

create or replace function portal__nivel(p_pessoa portal_pessoas, p_modulo text)
returns text language sql stable security definer set search_path = public as $$
  select case when p_pessoa.master then 'gerencia'
              else (select nivel from portal_acessos where pessoa_id = p_pessoa.id and modulo_id = p_modulo) end
$$;

create or replace function portal__pessoa_json(r portal_pessoas)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'nome', r.nome, 'usuario', r.usuario, 'master', r.master,
    'trocar_senha', r.trocar_senha, 'perfil', (select nome from portal_perfis where id = r.perfil_id))
$$;

create or replace function portal__nova_sessao(p_pessoa uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare tk text := encode(gen_random_bytes(32), 'hex');
begin
  delete from portal_sessoes where expira_em < now();
  insert into portal_sessoes (token_hash, pessoa_id, expira_em)
  values (encode(digest(tk, 'sha256'), 'hex'), p_pessoa, now() + interval '30 days');
  return tk;
end $$;

-- ---------- públicas ----------
create or replace function portal_status()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('configurado', exists (select 1 from portal_pessoas))
$$;

create or replace function portal_primeiro_acesso(p_nome text, p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas;
begin
  perform pg_advisory_xact_lock(918273);
  if exists (select 1 from portal_pessoas) then raise exception 'O portal já foi configurado. Entre com seu usuário.'; end if;
  if coalesce(trim(p_nome), '') = '' or coalesce(trim(p_usuario), '') = '' then raise exception 'Preencha nome e usuário.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  insert into portal_pessoas (nome, usuario, senha_hash, trocar_senha, master)
  values (trim(p_nome), lower(trim(p_usuario)), crypt(p_senha, gen_salt('bf', 8)), false, true) returning * into r;
  return jsonb_build_object('token', portal__nova_sessao(r.id), 'pessoa', portal__pessoa_json(r));
end $$;

create or replace function portal_login(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas;
begin
  select * into r from portal_pessoas where usuario = lower(trim(coalesce(p_usuario, '')));
  if r.id is not null and r.bloqueado_ate > now() then
    return jsonb_build_object('erro', 'Muitas tentativas erradas. Aguarde 5 minutos e tente de novo.');
  end if;
  if r.id is null or not r.ativo or r.senha_hash <> crypt(coalesce(p_senha, ''), r.senha_hash) then
    if r.id is not null then
      update portal_pessoas set
        falhas = case when falhas + 1 >= 5 then 0 else falhas + 1 end,
        bloqueado_ate = case when falhas + 1 >= 5 then now() + interval '5 minutes' else null end
      where id = r.id;
    end if;
    return jsonb_build_object('erro', 'Usuário ou senha incorretos.');
  end if;
  update portal_pessoas set falhas = 0, bloqueado_ate = null where id = r.id;
  return jsonb_build_object('token', portal__nova_sessao(r.id), 'pessoa', portal__pessoa_json(r));
end $$;

create or replace function portal_sair(p_token text)
returns void language sql security definer set search_path = public, extensions as $$
  delete from portal_sessoes where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

create or replace function portal_trocar_senha(p_token text, p_atual text, p_nova text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas;
begin
  r := portal__sessao(p_token);
  if r.senha_hash <> crypt(coalesce(p_atual, ''), r.senha_hash) then raise exception 'A senha atual não confere.'; end if;
  if length(coalesce(p_nova, '')) < 6 then raise exception 'A nova senha precisa ter pelo menos 6 caracteres.'; end if;
  if p_nova = p_atual then raise exception 'A nova senha precisa ser diferente da atual.'; end if;
  update portal_pessoas set senha_hash = crypt(p_nova, gen_salt('bf', 8)), trocar_senha = false where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function portal_eu(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas;
begin
  r := portal__sessao(p_token);
  return jsonb_build_object('pessoa', portal__pessoa_json(r), 'modulos', (
    select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'nome', m.nome, 'descricao', m.descricao, 'url', m.url,
      'por_unidade', m.por_unidade,
      'nivel', case when r.master then 'gerencia' else a.nivel end,
      'unidades', case when r.master then array['barao','bonfim'] else a.unidades end) order by m.ordem, m.nome), '[]')
    from portal_modulos m
    left join portal_acessos a on a.modulo_id = m.id and a.pessoa_id = r.id
    where m.ativo and coalesce(m.url, '') <> '' and (r.master or a.nivel is not null)));
end $$;

create or replace function portal_acesso(p_token text, p_modulo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r portal_pessoas; niv text; uni text[];
begin
  r := portal__sessao(p_token);
  niv := portal__nivel(r, p_modulo);
  if niv is null then raise exception 'Você não tem acesso a este módulo. Fale com a administração.'; end if;
  if r.master then uni := array['barao','bonfim'];
  else select unidades into uni from portal_acessos where pessoa_id = r.id and modulo_id = p_modulo; end if;
  return jsonb_build_object('pessoa', portal__pessoa_json(r), 'nivel', niv, 'unidades', uni);
end $$;

-- ---------- administração (somente master) ----------
create or replace function portal_admin_dados(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform portal__master(p_token);
  return jsonb_build_object(
    'pessoas', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'usuario', p.usuario,
        'perfil_id', p.perfil_id, 'master', p.master, 'ativo', p.ativo, 'trocar_senha', p.trocar_senha,
        'acessos', (select coalesce(jsonb_agg(jsonb_build_object('modulo_id', a.modulo_id, 'nivel', a.nivel, 'unidades', a.unidades)), '[]')
                    from portal_acessos a where a.pessoa_id = p.id)) order by p.ativo desc, p.nome), '[]') from portal_pessoas p),
    'perfis', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'niveis', niveis) order by nome), '[]') from portal_perfis),
    'modulos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'descricao', descricao, 'url', url,
        'ordem', ordem, 'por_unidade', por_unidade, 'ativo', ativo) order by ordem, nome), '[]') from portal_modulos));
end $$;

create or replace function portal_admin_salvar_pessoa(p_token text, p jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare me portal_pessoas; rid uuid; usr text := lower(trim(coalesce(p->>'usuario', ''))); ac jsonb;
begin
  me := portal__master(p_token);
  if coalesce(trim(p->>'nome'), '') = '' or usr = '' then raise exception 'Preencha nome e usuário.'; end if;
  if usr !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 caracteres, só letras sem acento, números, ponto, hífen ou sublinhado.'; end if;
  if exists (select 1 from portal_pessoas where usuario = usr and id::text <> coalesce(p->>'id', '')) then
    raise exception 'Já existe alguém com o usuário "%".', usr;
  end if;
  if coalesce(p->>'id', '') = '' then
    if length(coalesce(p->>'senha', '')) < 6 then raise exception 'A senha provisória precisa ter pelo menos 6 caracteres.'; end if;
    insert into portal_pessoas (nome, usuario, senha_hash, trocar_senha, perfil_id, master, ativo)
    values (trim(p->>'nome'), usr, crypt(p->>'senha', gen_salt('bf', 8)), true, nullif(p->>'perfil_id', '')::uuid,
            coalesce((p->>'master')::boolean, false), true)
    returning id into rid;
  else
    rid := (p->>'id')::uuid;
    if rid = me.id and (coalesce((p->>'master')::boolean, true) = false or coalesce((p->>'ativo')::boolean, true) = false) then
      raise exception 'Você não pode remover o seu próprio acesso master.';
    end if;
    update portal_pessoas set nome = trim(p->>'nome'), usuario = usr, perfil_id = nullif(p->>'perfil_id', '')::uuid,
      master = coalesce((p->>'master')::boolean, master), ativo = coalesce((p->>'ativo')::boolean, ativo)
    where id = rid;
    if coalesce((p->>'ativo')::boolean, true) = false then delete from portal_sessoes where pessoa_id = rid; end if;
  end if;
  delete from portal_acessos where pessoa_id = rid;
  for ac in select value from jsonb_array_elements(coalesce(p->'acessos', '[]')) loop
    if coalesce(ac->>'nivel', '') in ('usa', 'gerencia') then
      insert into portal_acessos (pessoa_id, modulo_id, nivel, unidades)
      values (rid, ac->>'modulo_id', ac->>'nivel',
              coalesce(array(select jsonb_array_elements_text(coalesce(ac->'unidades', '[]'))), '{}'));
    end if;
  end loop;
  return rid;
end $$;

create or replace function portal_admin_resetar_senha(p_token text, p_pessoa uuid, p_senha text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform portal__master(p_token);
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha provisória precisa ter pelo menos 6 caracteres.'; end if;
  update portal_pessoas set senha_hash = crypt(p_senha, gen_salt('bf', 8)), trocar_senha = true, falhas = 0, bloqueado_ate = null
  where id = p_pessoa;
  delete from portal_sessoes where pessoa_id = p_pessoa;
end $$;

create or replace function portal_admin_salvar_perfil(p_token text, p jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare rid uuid;
begin
  perform portal__master(p_token);
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Dê um nome ao perfil.'; end if;
  if exists (select 1 from portal_perfis where lower(nome) = lower(trim(p->>'nome')) and id::text <> coalesce(p->>'id', '')) then
    raise exception 'Já existe um perfil com esse nome.';
  end if;
  if coalesce(p->>'id', '') = '' then
    insert into portal_perfis (nome, niveis) values (trim(p->>'nome'), coalesce(p->'niveis', '{}')) returning id into rid;
  else
    update portal_perfis set nome = trim(p->>'nome'), niveis = coalesce(p->'niveis', '{}') where id = (p->>'id')::uuid returning id into rid;
  end if;
  return rid;
end $$;

create or replace function portal_admin_excluir_perfil(p_token text, p_perfil uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform portal__master(p_token);
  delete from portal_perfis where id = p_perfil;
end $$;

create or replace function portal_admin_salvar_modulo(p_token text, p jsonb)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare mid text := lower(trim(coalesce(p->>'id', '')));
begin
  perform portal__master(p_token);
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Dê um nome ao módulo.'; end if;
  if mid = '' then
    mid := trim(both '-' from regexp_replace(lower(translate(trim(p->>'nome'),
      'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')), '[^a-z0-9]+', '-', 'g'));
    if exists (select 1 from portal_modulos where id = mid) then mid := mid || '-' || substr(md5(random()::text), 1, 4); end if;
    insert into portal_modulos (id, nome, descricao, url, ordem, por_unidade, ativo)
    values (mid, trim(p->>'nome'), p->>'descricao', nullif(trim(p->>'url'), ''), coalesce(nullif(p->>'ordem', '')::int, 50),
            coalesce((p->>'por_unidade')::boolean, false), coalesce((p->>'ativo')::boolean, true));
  else
    update portal_modulos set nome = trim(p->>'nome'), descricao = p->>'descricao', url = nullif(trim(p->>'url'), ''),
      ordem = coalesce(nullif(p->>'ordem', '')::int, ordem), por_unidade = coalesce((p->>'por_unidade')::boolean, por_unidade),
      ativo = coalesce((p->>'ativo')::boolean, ativo)
    where id = mid;
  end if;
  return mid;
end $$;

-- ---------- permissões ----------
revoke all on function portal__sessao(text), portal__master(text), portal__nivel(portal_pessoas, text),
  portal__pessoa_json(portal_pessoas), portal__nova_sessao(uuid) from public, anon, authenticated;
grant execute on function portal_status(), portal_primeiro_acesso(text, text, text), portal_login(text, text),
  portal_sair(text), portal_trocar_senha(text, text, text), portal_eu(text), portal_acesso(text, text),
  portal_admin_dados(text), portal_admin_salvar_pessoa(text, jsonb), portal_admin_resetar_senha(text, uuid, text),
  portal_admin_salvar_perfil(text, jsonb), portal_admin_excluir_perfil(text, uuid), portal_admin_salvar_modulo(text, jsonb)
to anon, authenticated;

-- ---------- dados iniciais ----------
insert into portal_modulos (id, nome, descricao, url, ordem, por_unidade) values
  ('treinamentos', 'Treinamentos', 'Presença, atividades e sorteios', 'modulos/treinamentos.html', 10, false),
  ('escala', 'Escala', 'Plantões e trocas', null, 20, false),
  ('estoque', 'Estoque', 'Produtos, vacinas, compras e temperatura', 'https://harmonia-estoque.vercel.app', 30, true),
  ('especialistas', 'Especialistas', 'Atendimentos e fechamento', 'https://harmonia-especialistas.vercel.app', 40, false),
  ('gestao', 'Gestão', 'Tarefas da gestão', null, 50, false)
on conflict (id) do nothing;

insert into portal_perfis (nome, niveis) values
  ('Veterinária', '{"treinamentos":"usa","escala":"usa"}'),
  ('Auxiliar', '{"treinamentos":"usa","escala":"usa"}'),
  ('Recepção', '{"treinamentos":"usa"}'),
  ('Gestora', '{"treinamentos":"gerencia","escala":"gerencia","estoque":"gerencia"}'),
  ('Especialista', '{"especialistas":"usa"}')
on conflict (nome) do nothing;
