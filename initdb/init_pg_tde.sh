#!/bin/bash
set -e

# ============================================================
# Script d'initialisation PostgreSQL avec pg_tde
# ============================================================
# Ce script est exécuté par l'entrypoint de Percona PostgreSQL
# pendant la phase d'initialisation.
#
# Il configure:
# 1. L'extension pg_tde avec un fournisseur de clés fichier
# 2. Une clé de chiffrement master
# 3. Les utilisateurs PostgreSQL à partir de CLIENT_NAMES
#
# PGDATA: /data/db (défini par l'image Percona)
# Keyring: /data/db/pg_tde_keys.per
# ============================================================

# --- Lecture du mot de passe de la BDD depuis le Secret Docker ---
PASSWORD_FILE="${POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password_secret}"

if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Erreur: Le fichier de mot de passe $PASSWORD_FILE n'existe pas."
    exit 1
fi

# Lire le mot de passe du fichier secret (supprime les nouvelles lignes)
DB_PASSWORD=$(cat "$PASSWORD_FILE" | tr -d '\n')

if [ -z "$DB_PASSWORD" ]; then
    echo "Erreur: Le mot de passe de la base de données est vide."
    exit 1
fi
# -----------------------------------------------------------------

echo "Configuration de pg_tde..."
echo "PGDATA: ${PGDATA:-/data/db}"
echo "Chemin du keyring: ${PG_TDE_KEYRING_FILE:-/data/db/pg_tde_keys.per}"

# Créer le répertoire parent du keyring si nécessaire
KEYRING_FILE="${PG_TDE_KEYRING_FILE:-/data/db/pg_tde_keys.per}"
KEYRING_DIR=$(dirname "$KEYRING_FILE")
mkdir -p "$KEYRING_DIR"

# ============================================================
# Configuration de l'extension pg_tde
# ============================================================
echo "Installation et configuration de l'extension pg_tde..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Créer l'extension pg_tde
    CREATE EXTENSION IF NOT EXISTS pg_tde;
    
    -- Ajouter le fournisseur de clés fichier
    SELECT pg_tde_add_database_key_provider_file('local-file', '$KEYRING_FILE');
    
    -- Créer la clé de chiffrement master
    SELECT pg_tde_create_key_using_database_key_provider('master-key', 'local-file');
    
    -- Définir la clé par défaut pour la base de données
    SELECT pg_tde_set_key_using_database_key_provider('master-key', 'local-file');
    
    -- ============================================================
    -- Configuration du Global Key Provider pour les restaurations
    -- ============================================================
    -- Le Global Key Provider permet de restaurer des sauvegardes
    -- avec des tables TDE dans de nouvelles bases de données
    SELECT pg_tde_add_global_key_provider_file('global-file', '$KEYRING_FILE');
    SELECT pg_tde_create_key_using_global_key_provider('global-master-key', 'global-file');
EOSQL

echo "✓ pg_tde configuré avec succès"
echo "  - Provider local: local-file ($KEYRING_FILE)"
echo "  - Clé locale: master-key"
echo "  - Provider global: global-file ($KEYRING_FILE)"
echo "  - Clé globale: global-master-key (pour les restaurations)"
echo "  - Pour créer des tables chiffrées: CREATE TABLE ... USING tde_heap;"

echo "Configuration pg_tde terminée."

# ============================================================
# Création dynamique des utilisateurs PostgreSQL
# ============================================================
# Les utilisateurs sont créés à partir de la variable CLIENT_NAMES
# Mapping des rôles (position dans la liste):
#   1er = ADMIN (ALL PRIVILEGES)
#   2ème = APP_USER (CRUD sur les tables)
#   3ème = BACKUP (SELECT only)
# ============================================================

echo "Création des utilisateurs PostgreSQL..."

# Valeur par défaut si CLIENT_NAMES n'est pas défini
CLIENT_NAMES=${CLIENT_NAMES:-"admin,app_user,backup_user"}

# Convertir la liste séparée par virgules en lignes
CLIENT_LIST=$(echo "$CLIENT_NAMES" | tr ',' '\n')

# Compteur pour déterminer le rôle
ROLE_INDEX=1

for CLIENT_NAME in $CLIENT_LIST; do
    # Supprimer les espaces blancs
    CLIENT_NAME=$(echo "$CLIENT_NAME" | xargs)
    
    if [ -z "$CLIENT_NAME" ]; then
        continue
    fi
    
    # Chemin du fichier secret pour ce client
    PASSWORD_SECRET_FILE="/run/secrets/${CLIENT_NAME}_password_secret"
    
    if [ ! -f "$PASSWORD_SECRET_FILE" ]; then
        echo "AVERTISSEMENT: Fichier secret $PASSWORD_SECRET_FILE non trouvé pour l'utilisateur $CLIENT_NAME"
        ROLE_INDEX=$((ROLE_INDEX + 1))
        continue
    fi
    
    # Lire le mot de passe depuis le fichier secret
    USER_PASSWORD=$(cat "$PASSWORD_SECRET_FILE" | tr -d '\n')
    
    if [ -z "$USER_PASSWORD" ]; then
        echo "AVERTISSEMENT: Mot de passe vide pour l'utilisateur $CLIENT_NAME"
        ROLE_INDEX=$((ROLE_INDEX + 1))
        continue
    fi
    
    echo "Création de l'utilisateur: $CLIENT_NAME (rôle #$ROLE_INDEX)"
    
    # Créer l'utilisateur
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        CREATE USER "$CLIENT_NAME" WITH PASSWORD '$USER_PASSWORD';
EOSQL
    
    # Attribuer les permissions selon le rôle
    case $ROLE_INDEX in
        1)
            # Premier utilisateur = ADMIN
            echo "  → Attribution des privilèges ADMIN (ALL PRIVILEGES)"
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                GRANT ALL PRIVILEGES ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
                GRANT ALL PRIVILEGES ON SCHEMA public TO "$CLIENT_NAME";
                GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$CLIENT_NAME";
                GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$CLIENT_NAME";
EOSQL
            ;;
        2)
            # Deuxième utilisateur = APP_USER
            echo "  → Attribution des privilèges APP_USER (CRUD)"
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
                GRANT USAGE ON SCHEMA public TO "$CLIENT_NAME";
                GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$CLIENT_NAME";
                GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$CLIENT_NAME";
EOSQL
            ;;
        3)
            # Troisième utilisateur = BACKUP (readonly)
            echo "  → Attribution des privilèges BACKUP (SELECT only + SEQUENCES)"
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
                GRANT USAGE ON SCHEMA public TO "$CLIENT_NAME";
                GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$CLIENT_NAME";
                GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO "$CLIENT_NAME";
EOSQL
            ;;
        4)
            # Quatrième utilisateur = DEVELOPER (droits de développement)
            echo "  → Attribution des privilèges DEVELOPER (CREATE, ALTER, DROP, CRUD)"
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                -- Connexion et utilisation du schéma
                GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
                GRANT USAGE, CREATE ON SCHEMA public TO "$CLIENT_NAME";
                
                -- Droits sur les tables (existantes et futures)
                GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$CLIENT_NAME";
                
                -- Droits sur les séquences
                GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$CLIENT_NAME";
                
                -- Droits pour créer des objets (tables, vues, fonctions, types)
                GRANT CREATE ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
EOSQL
            ;;
        *)
            # 5ème utilisateur et suivants = BACKUP (readonly) par défaut
            echo "  → Attribution des privilèges BACKUP (SELECT only) - rôle par défaut"
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$CLIENT_NAME";
                GRANT USAGE ON SCHEMA public TO "$CLIENT_NAME";
                GRANT SELECT ON ALL TABLES IN SCHEMA public TO "$CLIENT_NAME";
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "$CLIENT_NAME";
EOSQL
            ;;
    esac
    
    echo "  ✓ Utilisateur $CLIENT_NAME créé avec succès"
    ROLE_INDEX=$((ROLE_INDEX + 1))
done

echo "Création des utilisateurs terminée."
