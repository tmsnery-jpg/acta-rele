#!/usr/bin/env bash
# Relé do CNJ para a Leia: roda num servidor no Brasil e repassa as consultas ao Diário da Justiça (DJEN) e ao DataJud.
# O CNJ recusa, com 403, as chamadas ao Diário vindas de fora do país (o Render fica nos EUA), e o DataJud recusa o servidor
# do Render com 429 ou deixa a consulta esgotar o tempo.
#
# Uso (no VPS, como root ou usuário com sudo):   bash rele_djen.sh
# O que faz: instala o Docker se faltar, sobe um Caddy que só aceita chamadas com a chave (cabeçalho X-Acta-Chave)
# e imprime as variáveis para colocar no Render: ACTA_DJEN_URL, ACTA_DJEN_CHAVE e ACTA_DATAJUD_URL.
#   /comunicacao...  -> https://comunicaapi.pje.jus.br/api/v1/comunicacao...      (Diário)
#   /datajud/...     -> https://api-publica.datajud.cnj.jus.br/...                (DataJud; desde 13/11/2026)
# O relé só repassa: não guarda nada. Pode rodar de novo quantas vezes quiser (mantém a mesma chave e os mesmos endereços).
set -euo pipefail
# precisa de root (Docker, portas 80/443): se veio como usuário comum, reexecuta com sudo
if [ "$(id -u)" -ne 0 ]; then
  echo "pedindo permissão de administrador (sudo)..."; exec sudo -E bash "$0" "$@"
fi
command -v docker >/dev/null 2>&1 || { echo "instalando o Docker..."; curl -fsSL https://get.docker.com | sh >/dev/null; }
IP=$(curl -fsS https://api.ipify.org)
PAIS=$(curl -fsS https://ipinfo.io/country 2>/dev/null || echo "?")
HOST=$(echo "$IP" | tr . -).sslip.io
mkdir -p /opt/acta-rele
if [ -f /opt/acta-rele/chave ]; then
  CHAVE=$(cat /opt/acta-rele/chave)
else
  CHAVE=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
  echo "$CHAVE" > /opt/acta-rele/chave; chmod 600 /opt/acta-rele/chave
fi
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
# portas 80/443 livres -> HTTPS automático (Let's Encrypt, nome <ip>.sslip.io); ocupadas -> HTTP na 8081
if ss -ltn 2>/dev/null | grep -qE ':(80|443) '; then
  MODO=http; SITE=":8081"; PORTAS="-p 8081:8081"; RAIZ="http://$IP:8081"
else
  MODO=https; SITE="$HOST"; PORTAS="-p 80:80 -p 443:443"; RAIZ="https://$HOST"
fi
URL="$RAIZ/comunicacao"
gerar_caddyfile() {
  echo "$SITE {"
  echo "  @ok header X-Acta-Chave \"$CHAVE\""
  echo "  handle @ok {"
  echo "    handle_path /datajud/* {"
  echo "      reverse_proxy https://api-publica.datajud.cnj.jus.br {"
  echo "        header_up Host api-publica.datajud.cnj.jus.br"
  echo "        header_up -X-Acta-Chave"
  echo "      }"
  echo "    }"
  echo "    handle {"
  echo "      rewrite * /api/v1{uri}"
  echo "      reverse_proxy https://comunicaapi.pje.jus.br {"
  echo "        header_up Host comunicaapi.pje.jus.br"
  echo "        header_up -X-Acta-Chave"
  echo "        header_up User-Agent \"$UA\""
  echo "        header_up Referer \"https://comunica.pje.jus.br/\""
  echo "        header_up Accept-Language \"pt-BR,pt;q=0.9\""
  echo "      }"
  echo "    }"
  echo "  }"
  echo "  respond \"nao autorizado\" 403"
  echo "}"
}
gerar_caddyfile > /opt/acta-rele/Caddyfile
docker rm -f acta-rele >/dev/null 2>&1 || true
docker run -d --name acta-rele --restart unless-stopped $PORTAS \
  -v /opt/acta-rele/Caddyfile:/etc/caddy/Caddyfile:ro -v acta_caddy_data:/data caddy:2 >/dev/null
sleep 5
echo "=============================================================="
echo "Servidor no pais: $PAIS   (precisa ser BR)"
echo "Rele no ar em modo $MODO."
echo "Variaveis do Render (as duas primeiras nao mudam em relacao a instalacao anterior):"
echo "ACTA_DJEN_URL=$URL"
echo "ACTA_DJEN_CHAVE=$CHAVE"
echo "ACTA_DATAJUD_URL=$RAIZ/datajud"
echo "=============================================================="
echo "Teste do Diario (deve responder um JSON com 'items'):"
sleep 8
INI=$(date -d '-10 days' +%F); FIM=$(date +%F)
curl -s -m 40 -H "X-Acta-Chave: $CHAVE" "$URL?numeroOab=138327&ufOab=RS&dataDisponibilizacaoInicio=$INI&dataDisponibilizacaoFim=$FIM&itensPorPagina=1&pagina=1" | head -c 300
echo
# Chave publica do DataJud: e a mesma para todos, publicada pelo CNJ em https://datajud-wiki.cnj.jus.br/api-publica/acesso (muda sem aviso).
DJ_CHAVE='cDZHYzlZa0JadVREZDJCendQbXY6SkJlTzNjLV9TRENyQk1RdnFKZGRQdw=='
echo "Teste do DataJud (200 = funcionando; 401 = a chave publica do CNJ mudou; 429 = recusou por excesso, mesmo do Brasil):"
COD=$(curl -s -m 40 -o /tmp/acta_rele_datajud.json -w '%{http_code}' -X POST -H "X-Acta-Chave: $CHAVE" -H "Authorization: APIKey $DJ_CHAVE" \
  -H 'Content-Type: application/json' -d '{"size":0,"query":{"match_all":{}}}' "$RAIZ/datajud/api_publica_trt4/_search" || true)
echo "DataJud pelo rele: HTTP ${COD:-sem resposta}  $(head -c 160 /tmp/acta_rele_datajud.json 2>/dev/null)"
rm -f /tmp/acta_rele_datajud.json
