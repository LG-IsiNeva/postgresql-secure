#!/bin/bash
# ============================================================
# Vérification des utilisateurs PostgreSQL et leurs droits
# ============================================================

# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CONTAINER_NAME="${CONTAINER_NAME:-percona_postgres_tde}"
DB_NAME="${POSTGRES_DB:-secure_db}"
DB_USER="${POSTGRES_USER:-postgres}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Vérification des utilisateurs PostgreSQL${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# 1. Vérifier que le conteneur est en cours d'exécution
echo -e "${YELLOW}[1/6] Vérification du conteneur...${NC}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "  ${GREEN}✓${NC} Conteneur '$CONTAINER_NAME' en cours d'exécution"
else
    echo -e "  ${RED}✗${NC} Conteneur '$CONTAINER_NAME' non trouvé ou arrêté"
    exit 1
fi

# 2. Lister tous les utilisateurs
echo ""
echo -e "${YELLOW}[2/6] Liste des utilisateurs PostgreSQL...${NC}"
docker exec "$CONTAINER_NAME" sh -c 'PGPASSWORD=$(cat /run/secrets/postgres_password_secret) psql -U postgres -d secure_db -c "SELECT usename, usecreatedb, usesuper FROM pg_user WHERE usename != '"'"'postgres'"'"' ORDER BY usename;"'

# 3. Vérifier les droits sur la base de données
echo ""
echo -e "${YELLOW}[3/6] Droits accordés sur les objets...${NC}"
docker exec "$CONTAINER_NAME" sh -c 'PGPASSWORD=$(cat /run/secrets/postgres_password_secret) psql -U postgres -d secure_db -c "SELECT grantee, privilege_type, table_name FROM information_schema.table_privileges WHERE grantee NOT IN ('"'"'postgres'"'"', '"'"'PUBLIC'"'"') ORDER BY grantee, table_name LIMIT 20;"'

# 4. Vérifier les droits sur le schéma public
echo ""
echo -e "${YELLOW}[4/6] Droits sur le schéma public...${NC}"
docker exec "$CONTAINER_NAME" sh -c 'PGPASSWORD=$(cat /run/secrets/postgres_password_secret) psql -U postgres -d secure_db -c "SELECT nspname, nspacl FROM pg_namespace WHERE nspname = '"'"'public'"'"';"'

# 5. Vérifier les privilèges par défaut
echo ""
echo -e "${YELLOW}[5/6] Privilèges par défaut configurés...${NC}"
docker exec "$CONTAINER_NAME" sh -c 'PGPASSWORD=$(cat /run/secrets/postgres_password_secret) psql -U postgres -d secure_db -c "SELECT pg_get_userbyid(defaclrole) as role, CASE defaclobjtype WHEN '"'"'r'"'"' THEN '"'"'Tables'"'"' WHEN '"'"'S'"'"' THEN '"'"'Sequences'"'"' END as type, array_to_string(defaclacl, '"'"', '"'"') as acl FROM pg_default_acl;"'

# 6. Vérifier le mapping des certificats (pg_ident.conf)
echo ""
echo -e "${YELLOW}[6/6] Mapping des certificats (pg_ident.conf)...${NC}"
if [ -f "./postgres-config/pg_ident.conf" ]; then
    echo -e "  ${BLUE}Contenu de pg_ident.conf:${NC}"
    grep -v "^#" ./postgres-config/pg_ident.conf | grep -v "^$" | while read -r line; do
        echo -e "  ${CYAN}→${NC} $line"
    done
else
    echo -e "  ${YELLOW}!${NC} Fichier pg_ident.conf non trouvé localement"
fi

# Résumé des rôles attendus
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Mapping des rôles attendus (selon CLIENT_NAMES)${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Position 1${NC} → ${GREEN}ADMIN${NC}      : ALL PRIVILEGES"
echo -e "  ${CYAN}Position 2${NC} → ${GREEN}APP_USER${NC}   : SELECT, INSERT, UPDATE, DELETE"
echo -e "  ${CYAN}Position 3${NC} → ${GREEN}BACKUP${NC}     : SELECT only"
echo -e "  ${CYAN}Position 4${NC} → ${GREEN}DEVELOPER${NC}  : CREATE, ALTER, DROP, CRUD"
echo -e "  ${CYAN}Position 5+${NC}→ ${GREEN}BACKUP${NC}     : SELECT only (par défaut)"
echo ""

# Test de connexion pour chaque utilisateur
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Test de connexion et droits des utilisateurs${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# Liste des utilisateurs à tester
for USER in admin app_user backup_user app_developer; do
    SECRET_FILE="./secrets/${USER}_password.txt"
    if [ -f "$SECRET_FILE" ]; then
        PASSWORD=$(cat "$SECRET_FILE" | tr -d '\n')
        
        # Tester la connexion
        if docker exec "$CONTAINER_NAME" sh -c "PGPASSWORD='$PASSWORD' psql -U $USER -d $DB_NAME -c 'SELECT 1;'" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $USER : Connexion OK"
            
            # Tester si peut créer des tables
            CREATE_RESULT=$(docker exec "$CONTAINER_NAME" sh -c "PGPASSWORD='$PASSWORD' psql -U $USER -d $DB_NAME -c 'CREATE TABLE _test_perm (id int);'" 2>&1)
            if echo "$CREATE_RESULT" | grep -q "CREATE TABLE"; then
                echo -e "      ${CYAN}→${NC} Peut créer des tables"
                docker exec "$CONTAINER_NAME" sh -c "PGPASSWORD='$PASSWORD' psql -U $USER -d $DB_NAME -c 'DROP TABLE _test_perm;'" > /dev/null 2>&1
            else
                echo -e "      ${CYAN}→${NC} Ne peut pas créer de tables"
            fi
        else
            echo -e "  ${RED}✗${NC} $USER : Échec de connexion"
        fi
    else
        echo -e "  ${YELLOW}!${NC} $USER : Fichier secret non trouvé"
    fi
done

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  ✓ Vérification terminée${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
