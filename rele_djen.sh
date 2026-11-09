#!/usr/bin/env bash
# Relé do DJEN para a Leia: roda num servidor no Brasil e repassa as consultas ao Diário da Justiça
# (o CNJ recusa, com 403, chamadas vindas de fora do país — o Render fica nos EUA).
#
# Uso (no VPS, como root ou usuário com sudo):   bash rele_djen.sh
# O que faz: instala o Docker se faltar, sobe um Caddy que só aceita chamadas com a chave (cabeçalho X-Acta-Chave)
# e imprime as duas variáveis para colocar no Render (grupo acta-segredos): ACTA_DJEN_URL e ACTA_DJEN_CHAVE.
# Pode rodar de novo quantas vezes quiser (mantém a mesma chave).
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
  MODO=http; SITE=":8081"; PORTAS="-p 8081:8081"; URL="http://$IP:8081/comunicacao"
else
  MODO=https; SITE="$HOST"; PORTAS="-p 80:80 -p 443:443"; URL="https://$HOST/comunicacao"
fi
{
  echo "$SITE {"
  echo "  @ok header X-Acta-Chave \"$CHAVE\""
  echo "  handle @ok {"
  echo "    rewrite * /api/v1{uri}"
  echo "    reverse_proxy https://comunicaapi.pje.jus.br {"
  echo "      header_up Host comunicaapi.pje.jus.br"
  echo "      header_up -X-Acta-Chave"
  echo "      header_up User-Agent \"$UA\""
  echo "      header_up Referer \"https://comunica.pje.jus.br/\""
  echo "      header_up Accept-Language \"pt-BR,pt;q=0.9\""
  echo "    }"
  echo "  }"
  echo "  respond \"nao autorizado\" 403"
  echo "}"
} > /opt/acta-rele/Caddyfile
docker rm -f acta-rele >/dev/null 2>&1 || true
docker run -d --name acta-rele --restart unless-stopped $PORTAS \
  -v /opt/acta-rele/Caddyfile:/etc/caddy/Caddyfile:ro -v acta_caddy_data:/data caddy:2 >/dev/null
sleep 5
echo "=============================================================="
echo "Servidor no pais: $PAIS   (precisa ser BR)"
echo "Rele no ar em modo $MODO."
echo "Cole estas duas linhas no Render (Environment Groups > acta-segredos > Add from .env):"
echo "ACTA_DJEN_URL=$URL"
echo "ACTA_DJEN_CHAVE=$CHAVE"
echo "=============================================================="
echo "Teste (deve responder um JSON com 'items'):"
sleep 8
INI=$(date -d '-10 days' +%F); FIM=$(date +%F)
curl -s -m 40 -H "X-Acta-Chave: $CHAVE" "$URL?numeroOab=138327&ufOab=RS&dataDisponibilizacaoInicio=$INI&dataDisponibilizacaoFim=$FIM&itensPorPagina=1&pagina=1" | head -c 300
echo
