# Guide d'Administration — Sauvegardes & Renouvellement des Certificats

> **Public visé** : administrateur système responsable de l'infrastructure PostgreSQL-TDE.
> Ce guide couvre les procédures critiques pour assurer la continuité de service.

---

## Table des matières

1. [Vérifier l'état des certificats](#1-vérifier-létat-des-certificats)
2. [Renouveler les certificats](#2-renouveler-les-certificats)
   - [Stratégie recommandée](#stratégie-recommandée)
   - [Renouveler uniquement le certificat serveur (CA intacte)](#21-renouveler-uniquement-le-certificat-serveur-ca-intacte)
   - [Renouveler la CA complète](#22-renouveler-la-ca-complète-impact-majeur)
   - [Renouveler un certificat client individuel](#23-renouveler-un-certificat-client-individuel)
3. [Ajouter un nouveau certificat client](#3-ajouter-un-nouveau-certificat-client)
4. [Sauvegarder la base de données](#4-sauvegarder-la-base-de-données)
5. [Restaurer la base de données](#5-restaurer-la-base-de-données)
6. [Récupération des données chiffrées (TDE)](#6-récupération-des-données-chiffrées-tde)
7. [Archivage hors-site — éléments critiques](#7-archivage-hors-site--éléments-critiques)

---

## 1. Vérifier l'état des certificats

### Vérifier les dates d'expiration

```bash
# CA
openssl x509 -in ./certs/ca.crt -noout -dates

# Certificat serveur
openssl x509 -in ./certs/server.crt -noout -dates

# Certificats clients (un par un ou en boucle)
for f in ./certs/client_*.crt; do
  echo "--- $f ---"
  openssl x509 -in "$f" -noout -subject -dates
done
```

### Vérifier depuis l'intérieur du container

```bash
docker exec percona_postgres_tde openssl x509 \
  -in /etc/certs/server.crt -noout -dates
```

### Résumé rapide — un seul appel

```bash
for f in ./certs/*.crt; do
  printf "%-45s  expiration: " "$f"
  openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2
done
```

---

## 2. Renouveler les certificats

### Stratégie recommandée

| Scénario | Impact | Durée d'intervention estimée |
|---|---|---|
| Renouveler seulement le certificat **serveur** (CA toujours valide) | Faible — redémarrage PostgreSQL uniquement | ~10 min |
| Renouveler seulement un **certificat client** | Très faible — pas de redémarrage | ~5 min |
| Renouveler la **CA complète** | Élevé — tous les certificats à regénérer, tous les clients à mettre à jour | ~30 min + distribution |

**Règle pratique** : si la CA n'a pas encore expiré, renouveler uniquement le certificat serveur ou les clients. Ne régénérer la CA que si elle approche de l'expiration (< 90 jours restants).

---

### 2.1 Renouveler uniquement le certificat serveur (CA intacte)

> Cas le plus courant : le certificat serveur expire mais la CA est encore valide.

**Pré-requis** : `ca.crt` et `ca.key` doivent être présents dans `./certs/`.

```bash
cd /chemin/vers/postgresql-secure

# Sauvegarder l'ancien certificat
cp ./certs/server.crt ./certs/server.crt.bak.$(date +%Y%m%d)
cp ./certs/server.key ./certs/server.key.bak.$(date +%Y%m%d)

# Charger les variables d'environnement
source .env

# Générer une nouvelle clé et une CSR
openssl req -new -nodes -text \
  -out ./certs/server.csr \
  -keyout ./certs/server.key \
  -subj "/C=FR/ST=IDF/L=Paris/O=PostgreSQL-TDE/OU=Database/CN=percona_postgres_tde"

# Construire le SAN (adapter FQDN_IP et FQDN_URL si définis dans .env)
SAN="DNS:percona_postgres_tde,DNS:localhost,DNS:db,IP:127.0.0.1"
[ -n "$FQDN_IP" ]  && SAN="${SAN},IP:${FQDN_IP}"
[ -n "$FQDN_URL" ] && SAN="${SAN},DNS:${FQDN_URL}"

# Signer avec la CA existante
openssl x509 -req -in ./certs/server.csr -text -days ${DAYS_VALID:-3650} \
  -extfile <(printf "subjectAltName=$SAN") \
  -CA ./certs/ca.crt \
  -CAkey ./certs/ca.key \
  -CAcreateserial \
  -out ./certs/server.crt

rm ./certs/server.csr

# Corriger les permissions (PostgreSQL UID=26 dans Percona)
chmod 600 ./certs/server.key
chmod 644 ./certs/server.crt

# Redémarrer PostgreSQL pour prendre en compte le nouveau certificat
docker compose restart db

# Vérifier que le service est healthy
docker compose ps
```

**Vérification post-renouvellement :**

```bash
# Lire la nouvelle date d'expiration
openssl x509 -in ./certs/server.crt -noout -dates

# Tester la connexion SSL depuis l'hôte
docker exec percona_postgres_tde psql \
  -U postgres -d secure_db -p 5434 \
  -c "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();"
```

---

### 2.2 Renouveler la CA complète (impact majeur)

> À utiliser uniquement si la CA expire ou est compromise.
> **Conséquence** : tous les certificats existants deviennent invalides — tous les clients doivent recevoir les nouveaux certificats.

```bash
cd /chemin/vers/postgresql-secure
source .env

# 1. Sauvegarder tous les anciens certificats
mkdir -p ./certs/backup_$(date +%Y%m%d)
cp ./certs/*.crt ./certs/*.key ./certs/*.pfx ./certs/backup_$(date +%Y%m%d)/ 2>/dev/null || true

# 2. Supprimer les anciens certificats pour forcer la régénération
rm -f ./certs/ca.crt ./certs/ca.key ./certs/ca.srl
rm -f ./certs/server.crt ./certs/server.key
rm -f ./certs/client_*.crt ./certs/client_*.key ./certs/client_*.pfx

# 3. Regénérer tous les certificats via le service cert_generator
docker compose run --rm cert_generator

# 4. Redémarrer PostgreSQL
docker compose restart db

# 5. Vérifier
docker compose ps
openssl x509 -in ./certs/ca.crt -noout -dates
```

**Après regénération de la CA — actions obligatoires :**

- Distribuer `ca.crt` à tous les clients (pour qu'ils puissent vérifier le nouveau serveur).
- Distribuer les nouveaux fichiers `.pfx` à chaque utilisateur concerné.
- Sur Windows, supprimer l'ancienne CA de `Cert:\LocalMachine\Root` et importer la nouvelle.
- Sur les outils de connexion (DBeaver, pgAdmin, psql), mettre à jour les chemins vers `ca.crt`, `client.crt`, `client.key`.

---

### 2.3 Renouveler un certificat client individuel

> Utiliser ce script pour renouveler ou remplacer le certificat d'un utilisateur sans toucher aux autres.

```bash
cd /chemin/vers/postgresql-secure

# Syntaxe : ./scripts/add_client_cert.sh <nom_cert> <utilisateur_pg> [mdp_pfx]
# Le script remplace le certificat si le CN existe déjà (confirmation interactive)

./scripts/add_client_cert.sh admin admin
./scripts/add_client_cert.sh app_user app_user
./scripts/add_client_cert.sh backup_user backup_user
./scripts/add_client_cert.sh app_developer app_developer

# Recharger la configuration PostgreSQL (pas de redémarrage nécessaire)
docker exec percona_postgres_tde psql -U postgres -c 'SELECT pg_reload_conf();'
```

---

## 3. Ajouter un nouveau certificat client

> Pour un nouveau poste ou un nouvel utilisateur qui se connecte à une identité PostgreSQL existante.

```bash
# Exemple : nouveau PC "pc_comptabilite" qui se connecte en tant qu'app_user
./scripts/add_client_cert.sh pc_comptabilite app_user "MonMotDePassePFX"

# Recharger la config PostgreSQL
docker exec percona_postgres_tde psql -U postgres -c 'SELECT pg_reload_conf();'
```

Le script ajoute automatiquement le mapping dans `postgres-config/pg_ident.conf` et affiche les instructions pour l'installation Windows.

---

## 4. Sauvegarder la base de données

### Sauvegarde manuelle

```bash
# Depuis l'hôte, exécuter le script dans le container
docker exec percona_postgres_tde bash /usr/local/bin/backup.sh
```

Le fichier de sauvegarde est créé dans `./backups/` sous le format :
`secure_db_YYYYMMDD_HHMMSS.dump.enc`

Il est **doublement protégé** :
- Chiffrement `AES-256-CBC + PBKDF2` via le secret `secrets/backup_encryption_pass.txt`
- Les données on-disk sont déjà chiffrées par TDE (`pg_tde`)

### Automatiser la sauvegarde (cron)

```bash
# Sur l'hôte — sauvegarde quotidienne à 2h du matin
crontab -e
# Ajouter :
0 2 * * * docker exec percona_postgres_tde bash /usr/local/bin/backup.sh >> /var/log/pg_backup.log 2>&1
```

### Rotation des sauvegardes

```bash
# Supprimer les sauvegardes de plus de 30 jours
find ./backups/ -name "*.dump.enc" -mtime +30 -delete
```

---

## 5. Restaurer la base de données

### Pré-requis

- Le fichier `.dump.enc` à restaurer
- Le fichier `secrets/backup_encryption_pass.txt` (même mot de passe que lors de la sauvegarde)
- Le container `db` en fonctionnement (TDE doit être initialisé)

### Procédure de restauration

```bash
# Le script restaure dans une base temporaire "secure_db_restore_temp"
# pour permettre la vérification avant de remplacer la base originale

docker exec -e BACKUP_PASS_FILE=/run/secrets/backup_pass_secret \
  percona_postgres_tde bash /usr/local/bin/restore.sh \
  /backups/secure_db_20260420_020000.dump.enc
```

### Vérifier la restauration

```bash
# Se connecter à la base temporaire
docker exec percona_postgres_tde psql \
  -U postgres -d secure_db_restore_temp -p 5434 \
  -c "\dt"

# Compter les lignes d'une table critique
docker exec percona_postgres_tde psql \
  -U postgres -d secure_db_restore_temp -p 5434 \
  -c "SELECT count(*) FROM ma_table_critique;"
```

### Basculer vers la base restaurée (si vérification OK)

```bash
# Renommer pour remplacer la base originale
# ATTENTION : cette opération est irréversible — sauvegarder l'originale d'abord

docker exec percona_postgres_tde psql -U postgres -p 5434 << 'EOF'
-- Déconnecter toutes les sessions actives de la base originale
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'secure_db' AND pid <> pg_backend_pid();

-- Renommer la base originale en archive
ALTER DATABASE secure_db RENAME TO secure_db_old;

-- Promouvoir la base restaurée
ALTER DATABASE secure_db_restore_temp RENAME TO secure_db;
EOF
```

---

## 6. Récupération des données chiffrées (TDE)

### Comprendre le double chiffrement

Ce système utilise **deux couches de chiffrement indépendantes** :

| Couche | Technologie | Clé/Secret | Localisation |
|---|---|---|---|
| **Données at-rest** | `pg_tde` (Percona) | Clé maître TDE | `/data/db/pg_tde_keys.per` (dans le volume Docker) |
| **Sauvegardes** | `openssl AES-256-CBC` | Passphrase | `secrets/backup_encryption_pass.txt` |

**Pour récupérer les données, les DEUX clés sont nécessaires.**

### Identifier la configuration TDE active

```bash
# Vérifier le provider et la clé actifs
docker exec percona_postgres_tde psql \
  -U postgres -d secure_db -p 5434 \
  -c "SELECT * FROM pg_tde_default_key_info();"

# Lister tous les providers configurés
docker exec percona_postgres_tde psql \
  -U postgres -d secure_db -p 5434 \
  -c "SELECT * FROM pg_tde_key_provider_list();"
```

### Sauvegarder le trousseau TDE (pg_tde_keys.per)

Le fichier `pg_tde_keys.per` est stocké dans le **volume Docker** `postgres_data` sous `PGDATA`.

```bash
# Copier le trousseau depuis le container vers l'hôte
docker cp percona_postgres_tde:/data/db/pg_tde_keys.per \
  ./backups/pg_tde_keys_$(date +%Y%m%d).per

# Vérifier que le fichier n'est pas vide
ls -lh ./backups/pg_tde_keys_*.per
```

> **CRITIQUE** : ce fichier doit être sauvegardé séparément des sauvegardes `.dump.enc` et stocké en lieu sûr (hors-site ou dans un gestionnaire de secrets). Sans lui, les sauvegardes sont irrécupérables.

### Scénario de récupération complète (sinistre total)

En cas de perte du serveur, voici les étapes pour reconstruire :

```bash
# 1. Recréer l'infrastructure
git clone <repo> postgresql-secure
cd postgresql-secure
cp .env.exemple .env
# Renseigner les secrets depuis les archives hors-site :
#   - secrets/*.txt
#   - certs/*.crt, *.key, *.pfx

# 2. Restaurer le trousseau TDE dans le volume AVANT de démarrer
docker compose up cert_generator  # Générer les certs SSL
docker compose up -d db           # Démarrer PostgreSQL (initialise TDE)

# Copier le trousseau sauvegardé dans le container
docker cp ./backups/pg_tde_keys_YYYYMMDD.per \
  percona_postgres_tde:/data/db/pg_tde_keys.per
docker exec percona_postgres_tde chown 26:26 /data/db/pg_tde_keys.per
docker exec percona_postgres_tde chmod 600 /data/db/pg_tde_keys.per

# Redémarrer pour que pg_tde recharge le trousseau
docker compose restart db

# 3. Restaurer la sauvegarde
docker exec -e BACKUP_PASS_FILE=/run/secrets/backup_pass_secret \
  percona_postgres_tde bash /usr/local/bin/restore.sh \
  /backups/secure_db_YYYYMMDD_HHMMSS.dump.enc

# 4. Vérifier et promouvoir (voir §5)
```

### Déchiffrer manuellement une sauvegarde (hors PostgreSQL)

Si le container est inaccessible mais que vous avez `openssl` :

```bash
# Déchiffrer le dump vers un fichier binaire pg_dump
openssl enc -aes-256-cbc -pbkdf2 -d \
  -pass pass:"$(cat secrets/backup_encryption_pass.txt)" \
  -in ./backups/secure_db_YYYYMMDD_HHMMSS.dump.enc \
  -out ./backups/secure_db_YYYYMMDD.dump

# Le fichier .dump peut ensuite être restauré avec pg_restore
# sur n'importe quel PostgreSQL avec pg_tde configuré
pg_restore -U postgres -d target_db ./backups/secure_db_YYYYMMDD.dump
```

---

## 7. Archivage hors-site — éléments critiques

### Inventaire des secrets à archiver

Ces fichiers doivent être sauvegardés **hors-site**, dans un endroit sécurisé (gestionnaire de mots de passe, coffre, stockage chiffré séparé) :

| Fichier | Rôle | Impact si perdu |
|---|---|---|
| `secrets/backup_encryption_pass.txt` | Déchiffrement des sauvegardes | Sauvegardes irrécupérables |
| `secrets/postgres_password.txt` | Accès superuser PostgreSQL | Perte d'accès admin |
| `certs/ca.crt` + `certs/ca.key` | Autorité de certification | Impossible de renouveler les certs sans régénérer la CA |
| `pg_tde_keys.per` (copie depuis le volume) | Clé maître TDE | Données at-rest irrécupérables |
| `.env` (fichier de configuration actif) | Toute la configuration | Reconstruction plus difficile |

### Checklist de sauvegarde hors-site (à faire après chaque changement majeur)

- [ ] `secrets/backup_encryption_pass.txt` archivé
- [ ] `secrets/postgres_password.txt` archivé
- [ ] `certs/ca.crt` et `certs/ca.key` archivés
- [ ] `pg_tde_keys.per` exporté depuis le volume et archivé
- [ ] `.env` (sans les mots de passe en clair si possible) archivé
- [ ] Date du dernier archivage notée ici : `____/____/________`

### Vérifier qu'une sauvegarde est lisible (test trimestriel recommandé)

```bash
# Test de déchiffrement sans restauration complète
openssl enc -aes-256-cbc -pbkdf2 -d \
  -pass pass:"$(cat secrets/backup_encryption_pass.txt)" \
  -in ./backups/$(ls -t ./backups/*.dump.enc | head -1) \
  -out /tmp/test_decrypt.dump && \
  echo "OK — dump déchiffré avec succès" && \
  rm /tmp/test_decrypt.dump || \
  echo "ERREUR — vérifier backup_encryption_pass.txt"
```

---

*Dernière mise à jour : 2026-04-20*
