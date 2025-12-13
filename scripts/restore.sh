#!/bin/bash
# scripts/restore.sh
# Restauration d'une sauvegarde chiffrée de la base de données PostgreSQL
#
# IMPORTANT: La restauration utilise l'utilisateur postgres car:
# - L'extension pg_tde nécessite des droits superuser
# - Les privilèges par défaut doivent être restaurés
# - Les propriétaires d'objets doivent être définis correctement

# --- Configuration ---
DB_NAME="${POSTGRES_DB:-secure_db}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_PORT="${PGPORT:-5434}"
KEYRING_FILE="/data/db/pg_tde_keys.per"
KEY_NAME="global-master-key"
PROVIDER_NAME="global-file"

# LIRE LE MOT DE PASSE DE CHIFFREMENT DEPUIS LE FICHIER SECRET
if [ -z "$BACKUP_PASS_FILE" ]; then
    echo "Erreur: BACKUP_PASS_FILE n'est pas défini."
    exit 1
fi

ENCRYPTION_PASS=$(cat "$BACKUP_PASS_FILE" | tr -d '\n')

# LIRE LE MOT DE PASSE POSTGRES
POSTGRES_PASS_FILE="/run/secrets/postgres_password_secret"
if [ ! -f "$POSTGRES_PASS_FILE" ]; then
    echo "Erreur: Le fichier de mot de passe postgres n'existe pas."
    exit 1
fi

POSTGRES_PASS=$(cat "$POSTGRES_PASS_FILE" | tr -d '\n')

# --- Validation de l'entrée ---
if [ -z "$1" ]; then
  echo "Usage: ./restore.sh /chemin/vers/votre_fichier.dump.enc"
  exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
  echo "Erreur : Le fichier de sauvegarde '$INPUT_FILE' est introuvable."
  exit 1
fi

echo "--- Démarrage de la restauration chiffrée de $INPUT_FILE vers $DB_NAME ---"
echo "Utilisateur: $DB_USER | Port: $DB_PORT"

export PGPASSWORD="$POSTGRES_PASS"

# Création d'une nouvelle base de données temporaire pour la restauration
TEMP_DB_NAME="${DB_NAME}_restore_temp"
echo "Création de la base de données temporaire : $TEMP_DB_NAME"
dropdb -U "$DB_USER" -p "$DB_PORT" "$TEMP_DB_NAME" 2>/dev/null || true
createdb -U "$DB_USER" -p "$DB_PORT" "$TEMP_DB_NAME"

# Configuration de pg_tde dans la nouvelle base
echo "Configuration de pg_tde dans la base temporaire..."

# Création de l'extension
psql -U "$DB_USER" -d "$TEMP_DB_NAME" -p "$DB_PORT" -c "CREATE EXTENSION IF NOT EXISTS pg_tde;"
if [ $? -ne 0 ]; then
    echo "Erreur: Impossible de créer l'extension pg_tde"
    exit 1
fi

# Utilisation du Global Key Provider (partagé entre toutes les bases)
# pg_tde_set_default_key rend la clé disponible pour les nouvelles connexions
psql -U "$DB_USER" -d "$TEMP_DB_NAME" -p "$DB_PORT" -c "SELECT pg_tde_set_default_key_using_global_key_provider('$KEY_NAME', '$PROVIDER_NAME');"
if [ $? -ne 0 ]; then
    echo "Erreur: Impossible de définir la clé principale globale par défaut"
    exit 1
fi

# Vérification que la clé est bien configurée
echo "Vérification de la configuration TDE..."
KEY_CHECK=$(psql -U "$DB_USER" -d "$TEMP_DB_NAME" -p "$DB_PORT" -t -c "SELECT key_name FROM pg_tde_default_key_info();" | tr -d ' ')
if [ "$KEY_CHECK" != "$KEY_NAME" ]; then
    echo "Erreur: La clé TDE par défaut n'est pas correctement configurée (attendu: $KEY_NAME, obtenu: $KEY_CHECK)"
    exit 1
fi
echo "TDE configuré avec la clé: $KEY_CHECK"

# Déchiffrement à la volée et restauration (via socket Unix)
echo "Déchiffrement et restauration en cours..."
openssl enc -aes-256-cbc -pbkdf2 -d -pass pass:"$ENCRYPTION_PASS" -in "$INPUT_FILE" | \
pg_restore -U "$DB_USER" -d "$TEMP_DB_NAME" -p "$DB_PORT" --clean --if-exists --no-owner 2>&1 | grep -v "already exists" || true

echo ""
echo "=== Restauration terminée dans : $TEMP_DB_NAME ==="
echo ""
echo "Pour vérifier les données restaurées:"
echo "  psql -U $DB_USER -d $TEMP_DB_NAME -p $DB_PORT -c '\\dt'"
echo ""
echo "Pour remplacer la base originale par la restauration:"
echo "  dropdb -U $DB_USER -p $DB_PORT $DB_NAME"
echo "  psql -U $DB_USER -p $DB_PORT -c 'ALTER DATABASE $TEMP_DB_NAME RENAME TO $DB_NAME;'"

unset PGPASSWORD