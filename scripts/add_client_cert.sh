#!/bin/bash
################################################################################
# Script pour ajouter un certificat client pour un nouveau poste
# Ce certificat sera mappé vers un utilisateur PostgreSQL existant
################################################################################
set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CERT_DIR="${CERT_DIR:-./certs}"
CONTAINER_NAME="${CONTAINER_NAME:-percona_postgres_tde}"
DAYS_VALID="${DAYS_VALID:-3650}"
PG_IDENT_FILE="${PG_IDENT_FILE:-./postgres-config/pg_ident.conf}"

usage() {
    echo ""
    echo "Usage: $0 <nom_certificat> <utilisateur_postgresql> [mot_de_passe_pfx]"
    echo ""
    echo "Arguments:"
    echo "  nom_certificat       Nom unique pour le certificat (sera le CN)"
    echo "                       Convention: app_<nom_poste> ou backup_<nom_poste>"
    echo "  utilisateur_postgresql  Utilisateur PostgreSQL cible (ex: app_user, backup_user)"
    echo "  mot_de_passe_pfx     Mot de passe pour le fichier PFX (optionnel)"
    echo ""
    echo "Exemples:"
    echo "  $0 app_pc_bureau app_user"
    echo "  $0 app_laptop_jean app_user MonMotDePasse123"
    echo "  $0 backup_nas backup_user"
    echo ""
    exit 1
}

# Vérification des arguments
if [ $# -lt 2 ]; then
    usage
fi

CERT_NAME="$1"
PG_USER="$2"
PFX_PASSWORD="${3:-$(openssl rand -base64 16)}"

echo ""
echo -e "${GREEN}=========================================="
echo "  Génération de Certificat Client mTLS"
echo -e "==========================================${NC}"
echo ""
echo "Nom du certificat (CN): $CERT_NAME"
echo "Utilisateur PostgreSQL: $PG_USER"
echo "Répertoire des certs:   $CERT_DIR"
echo ""

# Créer le répertoire si nécessaire
mkdir -p "$CERT_DIR"

# Vérifier si le container est en cours d'exécution pour récupérer la CA
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}→ Récupération de la CA depuis le container...${NC}"
    docker cp "${CONTAINER_NAME}:/etc/certs/ca.crt" "$CERT_DIR/ca.crt"
    docker cp "${CONTAINER_NAME}:/etc/certs/ca.key" "$CERT_DIR/ca.key"
    CA_FROM_CONTAINER=true
else
    # Vérifier si les fichiers CA existent localement
    if [ ! -f "$CERT_DIR/ca.crt" ] || [ ! -f "$CERT_DIR/ca.key" ]; then
        echo -e "${RED}Erreur: Le container $CONTAINER_NAME n'est pas en cours d'exécution"
        echo -e "et les fichiers CA ne sont pas présents dans $CERT_DIR${NC}"
        echo ""
        echo "Démarrez d'abord les services: docker compose up -d"
        exit 1
    fi
    CA_FROM_CONTAINER=false
fi

# Vérifier que la CA existe
if [ ! -f "$CERT_DIR/ca.crt" ] || [ ! -f "$CERT_DIR/ca.key" ]; then
    echo -e "${RED}Erreur: Fichiers CA manquants dans $CERT_DIR${NC}"
    exit 1
fi

CLIENT_PREFIX="$CERT_DIR/client_${CERT_NAME}"

# Vérifier si le certificat existe déjà
if [ -f "${CLIENT_PREFIX}.crt" ]; then
    echo -e "${YELLOW}Attention: Un certificat existe déjà pour '$CERT_NAME'${NC}"
    read -p "Voulez-vous le remplacer? (o/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Oo]$ ]]; then
        echo "Annulé."
        exit 0
    fi
fi

echo ""
echo -e "${YELLOW}→ Génération du certificat client...${NC}"

# 1. Générer la clé privée et la demande de certificat
openssl req -new -nodes -text \
    -out "${CLIENT_PREFIX}.csr" \
    -keyout "${CLIENT_PREFIX}.key" \
    -subj "/C=FR/ST=IDF/L=Paris/O=PostgreSQL-TDE/OU=Clients/CN=$CERT_NAME"

# 2. Signer le certificat avec la CA
openssl x509 -req -in "${CLIENT_PREFIX}.csr" -text -days $DAYS_VALID \
    -CA "$CERT_DIR/ca.crt" \
    -CAkey "$CERT_DIR/ca.key" \
    -CAcreateserial \
    -out "${CLIENT_PREFIX}.crt"

# 3. Créer le fichier PFX pour Windows
openssl pkcs12 -export -out "${CLIENT_PREFIX}.pfx" \
    -inkey "${CLIENT_PREFIX}.key" \
    -in "${CLIENT_PREFIX}.crt" \
    -certfile "$CERT_DIR/ca.crt" \
    -passout pass:"${PFX_PASSWORD}" \
    -name "PostgreSQL Client - $CERT_NAME"

# 4. Nettoyage
rm "${CLIENT_PREFIX}.csr"
chmod 600 "${CLIENT_PREFIX}.key" "${CLIENT_PREFIX}.pfx"
chmod 644 "${CLIENT_PREFIX}.crt"

# 5. Supprimer la clé CA de l'hôte (sécurité)
if [ "$CA_FROM_CONTAINER" = true ]; then
    rm -f "$CERT_DIR/ca.key"
    echo -e "${GREEN}✓ Clé CA supprimée de l'hôte (sécurité)${NC}"
fi

echo ""
echo -e "${GREEN}✓ Certificat généré avec succès!${NC}"
echo ""
echo "Fichiers créés:"
echo "  - Certificat: ${CLIENT_PREFIX}.crt"
echo "  - Clé privée: ${CLIENT_PREFIX}.key"
echo "  - Format PFX: ${CLIENT_PREFIX}.pfx"
echo ""
echo -e "${YELLOW}Mot de passe PFX: ${PFX_PASSWORD}${NC}"
echo ""

# 6. Ajouter le mapping dans pg_ident.conf
echo -e "${YELLOW}→ Ajout du mapping dans pg_ident.conf...${NC}"

# Vérifier si le mapping existe déjà
if grep -q "^cert_map[[:space:]]*${CERT_NAME}[[:space:]]" "$PG_IDENT_FILE" 2>/dev/null; then
    echo -e "${YELLOW}Le mapping existe déjà dans pg_ident.conf${NC}"
else
    # Ajouter le mapping
    echo "cert_map    ${CERT_NAME}       ${PG_USER}" >> "$PG_IDENT_FILE"
    echo -e "${GREEN}✓ Mapping ajouté: ${CERT_NAME} → ${PG_USER}${NC}"
fi

echo ""
echo -e "${GREEN}=========================================="
echo "  Configuration Terminée"
echo -e "==========================================${NC}"
echo ""
echo "PROCHAINES ÉTAPES:"
echo ""
echo "1. Recharger la configuration PostgreSQL:"
echo "   docker exec $CONTAINER_NAME psql -U postgres -c 'SELECT pg_reload_conf();'"
echo ""
echo "2. Transférer les fichiers vers le poste Windows:"
echo "   - $CERT_DIR/ca.crt"
echo "   - ${CLIENT_PREFIX}.pfx"
echo ""
echo "3. Sur Windows, importer les certificats:"
echo "   Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\\LocalMachine\\Root"
echo "   \$pwd = ConvertTo-SecureString -String '${PFX_PASSWORD}' -Force -AsPlainText"
echo "   Import-PfxCertificate -FilePath client_${CERT_NAME}.pfx -CertStoreLocation Cert:\\CurrentUser\\My -Password \$pwd"
echo ""
echo "4. Se connecter avec psql ou un client PostgreSQL en utilisant:"
echo "   - Utilisateur: ${PG_USER}"
echo "   - Certificat:  client_${CERT_NAME}.crt/pfx"
echo ""
