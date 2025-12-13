#!/bin/bash
# scripts/backup.sh

# --- Configuration ---
BACKUP_DIR="/backups"
DB_NAME="${POSTGRES_DB:-mydatabase}"
DB_USER="${POSTGRES_USER:-myuser}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump.enc"

# LIRE LE MOT DE PASSE DE CHIFFREMENT DEPUIS LE FICHIER SECRET
if [ -z "$BACKUP_PASS_FILE" ]; then
    echo "Erreur: BACKUP_PASS_FILE n'est pas défini."
    exit 1
fi

ENCRYPTION_PASS=$(cat "$BACKUP_PASS_FILE" | tr -d '\n')

if [ -z "$ENCRYPTION_PASS" ]; then
    echo "Erreur: Le secret de chiffrement de sauvegarde est vide."
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Erreur : Le répertoire de sauvegarde $BACKUP_DIR n'existe pas ou n'est pas monté."
  exit 1
fi

echo "--- Démarrage de la sauvegarde chiffrée de la base de données $DB_NAME ---"

# Utilisation de pg_dump et chiffrement à la volée
pg_dump -Fc -U "$DB_USER" -d "$DB_NAME" | \
openssl enc -aes-256-cbc -e -pass pass:"$ENCRYPTION_PASS" -out "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
  echo "Sauvegarde chiffrée réussie : $OUTPUT_FILE"
  echo "Taille : $(du -h $OUTPUT_FILE | awk '{print $1}')"
else
  echo "Erreur lors de la sauvegarde ou du chiffrement."
fi