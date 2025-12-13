#!/bin/bash
# ============================================================
# Vérification de pg_tde (Transparent Data Encryption)
# ============================================================
# Ce script vérifie que pg_tde est correctement configuré et
# fonctionnel sur PostgreSQL.
# ============================================================

set -e

# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="${CONTAINER_NAME:-percona_postgres_tde}"
DB_NAME="${POSTGRES_DB:-secure_db}"
DB_USER="${POSTGRES_USER:-postgres}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Vérification de pg_tde (Transparent Data Encryption)${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# Fonction pour exécuter une commande SQL
run_sql() {
    docker exec "$CONTAINER_NAME" sh -c "PGPASSWORD=\$(cat /run/secrets/postgres_password_secret) psql -U $DB_USER -d $DB_NAME -t -c \"$1\"" 2>/dev/null
}

# Fonction pour exécuter une commande SQL avec affichage
run_sql_display() {
    docker exec "$CONTAINER_NAME" sh -c "PGPASSWORD=\$(cat /run/secrets/postgres_password_secret) psql -U $DB_USER -d $DB_NAME -c \"$1\"" 2>/dev/null
}

# 1. Vérifier que le conteneur est en cours d'exécution
echo -e "${YELLOW}[1/7] Vérification du conteneur...${NC}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "  ${GREEN}✓${NC} Conteneur '$CONTAINER_NAME' en cours d'exécution"
else
    echo -e "  ${RED}✗${NC} Conteneur '$CONTAINER_NAME' non trouvé ou arrêté"
    exit 1
fi

# 2. Vérifier shared_preload_libraries
echo -e "${YELLOW}[2/7] Vérification de shared_preload_libraries...${NC}"
SHARED_LIBS=$(run_sql "SHOW shared_preload_libraries;" | xargs)
if echo "$SHARED_LIBS" | grep -q "pg_tde"; then
    echo -e "  ${GREEN}✓${NC} pg_tde est chargé dans shared_preload_libraries"
    echo -e "  ${BLUE}→${NC} $SHARED_LIBS"
else
    echo -e "  ${RED}✗${NC} pg_tde n'est pas dans shared_preload_libraries"
    exit 1
fi

# 3. Vérifier l'extension pg_tde
echo -e "${YELLOW}[3/7] Vérification de l'extension pg_tde...${NC}"
EXT_VERSION=$(run_sql "SELECT extversion FROM pg_extension WHERE extname = 'pg_tde';" | xargs)
if [ -n "$EXT_VERSION" ]; then
    echo -e "  ${GREEN}✓${NC} Extension pg_tde installée (version $EXT_VERSION)"
else
    echo -e "  ${RED}✗${NC} Extension pg_tde non installée"
    exit 1
fi

# 4. Vérifier le fournisseur de clés
echo -e "${YELLOW}[4/7] Vérification du fournisseur de clés...${NC}"
run_sql_display "SELECT id, name, type, options FROM pg_tde_list_all_database_key_providers();"
PROVIDER_COUNT=$(run_sql "SELECT COUNT(*) FROM pg_tde_list_all_database_key_providers();" | xargs)
if [ "$PROVIDER_COUNT" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} $PROVIDER_COUNT fournisseur(s) de clés configuré(s)"
else
    echo -e "  ${RED}✗${NC} Aucun fournisseur de clés configuré"
    exit 1
fi

# 5. Vérifier la clé de chiffrement
echo -e "${YELLOW}[5/7] Vérification de la clé de chiffrement...${NC}"
run_sql_display "SELECT key_name, provider_name, key_creation_time FROM pg_tde_key_info();"
KEY_NAME=$(run_sql "SELECT key_name FROM pg_tde_key_info();" | xargs)
if [ -n "$KEY_NAME" ]; then
    echo -e "  ${GREEN}✓${NC} Clé de chiffrement '$KEY_NAME' configurée"
else
    echo -e "  ${RED}✗${NC} Aucune clé de chiffrement configurée"
    exit 1
fi

# 6. Vérifier l'access method tde_heap
echo -e "${YELLOW}[6/7] Vérification de l'access method tde_heap...${NC}"
AM_EXISTS=$(run_sql "SELECT COUNT(*) FROM pg_am WHERE amname = 'tde_heap';" | xargs)
if [ "$AM_EXISTS" -eq 1 ]; then
    echo -e "  ${GREEN}✓${NC} Access method 'tde_heap' disponible"
else
    echo -e "  ${RED}✗${NC} Access method 'tde_heap' non disponible"
    exit 1
fi

# 7. Test fonctionnel : créer et vérifier une table chiffrée
echo -e "${YELLOW}[7/7] Test fonctionnel de chiffrement...${NC}"

# Créer une table de test chiffrée
run_sql "DROP TABLE IF EXISTS _tde_test_table;" > /dev/null 2>&1
run_sql "CREATE TABLE _tde_test_table (id SERIAL PRIMARY KEY, secret TEXT) USING tde_heap;" > /dev/null 2>&1
run_sql "INSERT INTO _tde_test_table (secret) VALUES ('TEST_SECRET_DATA_12345');" > /dev/null 2>&1

# Vérifier que la table est chiffrée
IS_ENCRYPTED=$(run_sql "SELECT pg_tde_is_encrypted('_tde_test_table'::regclass);" | xargs)
if [ "$IS_ENCRYPTED" = "t" ]; then
    echo -e "  ${GREEN}✓${NC} Table de test créée et chiffrée"
else
    echo -e "  ${RED}✗${NC} La table de test n'est pas chiffrée"
    run_sql "DROP TABLE IF EXISTS _tde_test_table;" > /dev/null 2>&1
    exit 1
fi

# Vérifier que les données ne sont pas visibles sur le disque
FILE_PATH=$(run_sql "SELECT pg_relation_filepath('_tde_test_table'::regclass);" | xargs)
echo -e "  ${BLUE}→${NC} Fichier de données: $FILE_PATH"

# Forcer l'écriture sur disque
run_sql "CHECKPOINT;" > /dev/null 2>&1

# Vérifier avec strings
STRINGS_OUTPUT=$(docker exec "$CONTAINER_NAME" sh -c "strings /data/db/$FILE_PATH 2>/dev/null | grep -c 'TEST_SECRET_DATA' || true")
if [ "$STRINGS_OUTPUT" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} Données chiffrées sur le disque (non lisibles en clair)"
else
    echo -e "  ${YELLOW}!${NC} Attention: données potentiellement visibles sur le disque"
fi

# Nettoyer la table de test
run_sql "DROP TABLE IF EXISTS _tde_test_table;" > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Table de test supprimée"

# Résumé
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  ✓ pg_tde est correctement configuré et fonctionnel !${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "Pour créer des tables chiffrées, utilisez:"
echo -e "  ${BLUE}CREATE TABLE ma_table (...) USING tde_heap;${NC}"
echo ""
