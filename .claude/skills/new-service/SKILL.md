---
name: new-service
description: Entrevista socrática para criar um novo serviço no homelab — uma pergunta de cada vez até ter tudo o que é preciso (imagem, VMID, IP, porta, recursos, volumes, segredos, rota Traefik), depois faz scaffold com `make new-service` e delega a um agente o preenchimento dos ficheiros. Usar quando o utilizador correr /new-service ou pedir para adicionar um serviço ao homelab.
---

# Novo serviço (entrevista socrática)

Não escrevas nenhum ficheiro até a entrevista terminar e o utilizador confirmar o resumo.

## 1. Recolher contexto (antes de perguntar)

Lê, sem mostrar ao utilizador:
- `inventory/hosts.yml` e `inventory/host_vars/*.yml` → VMIDs e IPs já usados.
- `inventory/group_vars/proxmox.yml` → rede (CIDR, gateway).
- `roles/traefik/templates/routes/` → hostnames já usados.
- Um role existente (ex.: `roles/nextcloud/`) como referência de estilo.

Usa isto para propor valores livres por defeito e detetar conflitos.

## 2. Entrevista

Uma pergunta de cada vez. Em cada uma: propõe um valor por defeito sensato, explica em uma linha porquê, e questiona respostas incoerentes (ex.: 512 MB para uma app Java, IP fora do CIDR, VMID ocupado). Salta perguntas cuja resposta já é óbvia pelas anteriores.

1. **O quê** — que aplicação é e qual o objetivo? (nome curto em minúsculas = nome do serviço)
2. **Imagem** — imagem Docker oficial e tag? Prefere tag fixa a `latest`.
3. **Porta** — porta HTTP interna da app?
4. **Rede** — VMID e IP (propõe os próximos livres).
5. **Recursos** — cores, memória, swap, disco. Precisa de GPU ou `features` extra além de `nesting=1`?
6. **Dados** — que caminhos precisam de persistir? (volumes em `/opt/<nome>/...`)
7. **Configuração** — variáveis de ambiente? Quais são segredos (vão para `.env` + `.env.example`, lidos com `lookup('env', ...)` em `inventory/group_vars/<nome>.yml`) e quais são config não secreta (`inventory/group_vars/<nome>.yml`)?
8. **Dependências** — precisa de base de dados, redis ou outro container no mesmo compose?
9. **Exposição** — rota Traefik `<nome>.{{ homelab_domain }}`? Hostname diferente? Precisa de websockets, headers ou backend HTTPS?
10. **Extra** — algo depois do arranque (utilizador admin, modelo a descarregar, DNS no pihole)?

Pára quando tiveres resposta para tudo o que é relevante — não faças perguntas por fazer.

## 3. Confirmar

Mostra um resumo compacto (tabela) com todas as decisões e a lista de ficheiros que serão criados/alterados. Espera "sim" explícito. Se houver duas abordagens possíveis (ex.: BD no mesmo compose vs LXC próprio), apresenta os trade-offs e deixa o utilizador decidir.

## 4. Gerar

1. Corre `make new-service NAME=<nome> VMID=<vmid> IP=<ip> PORT=<porta>` — nunca copies ficheiros de outro serviço à mão.
2. Lança um agente `general-purpose` com um brief autocontido: o resumo confirmado, os caminhos gerados pelo scaffold, e estas regras:
   - Editar apenas os ficheiros do novo serviço (+ `.env.example`, `inventory/group_vars/<nome>.yml` e `.env` se houver segredos).
   - Preencher `roles/<nome>/templates/compose.yml.j2` (imagem, volumes, env, dependências) e ajustar `inventory/host_vars/<nome>-server.yml`.
   - Ajustar a rota Traefik só se o hostname/opções diferirem do default.
   - Seguir YAGNI/KISS/DRY e o `CLAUDE.md` do projeto; indentação 2 espaços.
   - No fim correr `make syntax-check PLAYBOOK=playbooks/<nome>/deploy.yml` e `make lint`, e reportar o resultado.
3. Revê o diff do agente e mostra ao utilizador um resumo curto.

## 5. Próximos passos

Indica (não executes, não faças commit):
- `make deploy NAME=<nome>`
- `make traefik-reload` (novo `Host(...)` → novo SAN no certificado)
