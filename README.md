# acta-rele

Relé do CNJ para a Leia / ACTA ia: roda num servidor no Brasil e repassa as consultas ao Diário da Justiça (DJEN) e ao DataJud.
Só repassa dado público e não guarda nada. Só atende quem manda a chave do relé, que é gerada no próprio servidor.

Instalar ou atualizar (no VPS, como root):

    curl -fsSL https://raw.githubusercontent.com/tmsnery-jpg/acta-rele/main/rele_djen.sh | bash
