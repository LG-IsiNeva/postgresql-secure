#!/bin/bash
# scripts/restore.sh

# --- Configuration ---
DB_NAME="${POSTGRES_DB:-mydatabase}"
DB_USER="${POSTGRES_USER:-myuser}"

# LIRE LE MOT DE PASSE DE CHIFFREMENT DEPUIS LE FICHIER SECRET
if [ -z "$BACKUP_PASS_FILE" ]; then
    echo "Erreur: BACKUP_PASS_FILE n'est pas défini."
    exit 1
fi

ENCRYPTION_PASS=$(cat "$BACKUP_PASS_FILE" | tr -d '\n')

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

# Création d'une nouvelle base de données temporaire pour la restauration
TEMP_DB_NAME="${DB_NAME}_restore_temp"
echo "Création de la base de données temporaire : $TEMP_DB_NAME"
createdb -U "$DB_USER" "$TEMP_DB_NAME"

# Déchiffrement à la volée et restauration
openssl enc -aes-256-cbc -d -pass pass:"$ENCRYPTION_PASS" -in "$INPUT_FILE" | \
pg_restore -U "$DB_USER" -d "$TEMP_DB_NAME" --clean --if-exists

if [ $? -eq 0 ]; then
  echo "Restauration réussie dans la base de données temporaire $TEMP_DB_NAME."
else
  echo "Erreur lors du déchiffrement ou de la restauration."
  dropdb -U "$DB_USER" "$TEMP_DB_NAME" 2>/dev/null
  exit 1
fi
