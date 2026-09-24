# Harmonia Animal · Portal

## Estrutura
- index.html: login, menu de módulos e administração (pessoas, perfis, módulos)
- config.js: endereço e chave pública do Supabase (não precisa trocar depois)
- comum.js e estilo.css: partes compartilhadas por todas as telas
- modulos/treinamentos.html: módulo de Treinamentos
- sql/: scripts do banco, rodar em ordem (01, depois 02)

## Colocar no ar (uma vez só)
1. Supabase, projeto harmonia-escala > SQL Editor > New query: colar sql/01_portal.sql e rodar. Depois o sql/02_treinamentos.sql.
2. Copiar a chave pública (Project Settings > API Keys > publishable, ou anon public) para o config.js.
3. GitHub: criar o repositório harmonia-portal e subir todos os arquivos, mantendo as pastas.
4. Vercel: Add New > Project > importar harmonia-portal > Deploy (sem mudar configurações).
5. Abrir o endereço e criar o acesso master na tela de configuração inicial.

## Alterações futuras
Trocar só o arquivo que mudou no GitHub. O Vercel publica sozinho.
Scripts novos do banco virão numerados (03, 04...) e rodam uma vez no SQL Editor.
