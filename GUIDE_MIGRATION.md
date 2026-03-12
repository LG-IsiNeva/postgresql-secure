# Guide de migration vers la nouvelle configuration des certificats

## Contexte

Suite au problème d'erreur SSL après redémarrage, nous avons modifié la configuration pour :
1. **Rendre le script `generate_certs.sh` idempotent** - il ne régénère plus les certificats existants
2. **Utiliser un bind mount local** (`./certs/`) au lieu d'un volume Docker géré
3. **Empêcher la réexécution automatique** du service `cert_generator`

## Modifications apportées

### 1. Script de génération ([init-ssl/generate_certs.sh](init-ssl/generate_certs.sh))

Le script vérifie maintenant si les certificats existent avant de les générer :

```bash
# Pour la CA
if [ -f "$CERT_DIR/ca.crt" ] && [ -f "$CERT_DIR/ca.key" ]; then
    echo "CA existante trouvée, génération ignorée"
else
    # Génération de la CA...
fi

# Pour le certificat serveur
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo "Certificat serveur existant trouvé, génération ignorée"
else
    # Génération du certificat serveur...
fi

# Pour chaque certificat client
if [ -f "$CLIENT_PREFIX.crt" ] && [ -f "$CLIENT_PREFIX.key" ] && [ -f "$CLIENT_PREFIX.pfx" ]; then
    echo "Certificat client existant trouvé, génération ignorée"
else
    # Génération du certificat client...
fi
```

### 2. Docker Compose ([docker-compose.yml](docker-compose.yml))

**Avant** :
```yaml
services:
  cert_generator:
    volumes:
      - certs:/etc/certs  # Volume Docker géré
  db:
    volumes:
      - certs:/etc/certs:ro

volumes:
  certs:  # Volume Docker géré
```

**Après** :
```yaml
services:
  cert_generator:
    volumes:
      - ./certs:/etc/certs  # Bind mount local
    restart: "no"  # Ne pas redémarrer
  db:
    volumes:
      - ./certs:/etc/certs:ro

volumes:
  # Le volume certs a été supprimé
```

## Processus de migration

### Prérequis

Les certificats actuels sont déjà dans `./certs/` (copie effectuée lors de la Phase 1).

### Étape 1 : Arrêter les conteneurs (SANS supprimer les volumes)

```bash
cd /home/ubuntu/system/postgresql-secure
docker compose down
```

**IMPORTANT** : N'utilisez PAS l'option `-v` qui supprimerait le volume `postgres_data` (vos données PostgreSQL).

### Étape 2 : Vérifier les certificats locaux

```bash
ls -lh ./certs/
```

**Attendu** : Vous devriez voir tous les certificats avec les dates du 10 mars 2026 :
- ca.crt, ca.key, ca.srl
- server.crt, server.key
- client_admin.{crt,key,pfx}
- client_app_user.{crt,key,pfx}
- client_backup_user.{crt,key,pfx}
- client_app_developer.{crt,key,pfx}

### Étape 3 : Supprimer l'ancien volume Docker (optionnel)

```bash
# Sauvegarder le volume avant suppression (recommandé)
sudo tar -czf ~/backup-certs-volume-$(date +%Y%m%d).tar.gz \
  /var/lib/docker/volumes/postgresql-secure_certs/_data/

# Supprimer le volume
docker volume rm postgresql-secure_certs
```

**Note** : Cette étape est optionnelle. Le volume ne sera plus utilisé même s'il existe.

### Étape 4 : Redémarrer les services

```bash
docker compose up -d
```

### Étape 5 : Vérifier la migration

**Vérifier les logs du cert_generator** :
```bash
docker compose logs cert_generator
```

**Attendu** :
```
[1/3] CA existante trouvée, génération ignorée
  → CA: /etc/certs/ca.crt
  → Clé: /etc/certs/ca.key
[2/3] Certificat serveur existant trouvé, génération ignorée
  → Certificat: /etc/certs/server.crt
  → Clé: /etc/certs/server.key
[3/3] Génération des certificats Clients (mTLS)...

→ Certificat client existant pour: admin (génération ignorée)
  → Certificat: /etc/certs/client_admin.crt
  → Clé: /etc/certs/client_admin.key
  → PKCS#12: /etc/certs/client_admin.pfx
...
```

**Vérifier que PostgreSQL utilise les bons certificats** :
```bash
docker exec percona_postgres_tde ls -l /etc/certs/
```

**Vérifier la validité de la chaîne SSL** :
```bash
docker exec percona_postgres_tde openssl verify -CAfile /etc/certs/ca.crt /etc/certs/server.crt
```

**Attendu** : `/etc/certs/server.crt: OK`

**Vérifier le fingerprint du CA** :
```bash
docker exec percona_postgres_tde openssl x509 -in /etc/certs/ca.crt -noout -fingerprint
```

**Attendu** : `SHA1 Fingerprint=5E:CC:A8:FB:1F:CF:98:39:80:1B:E9:2E:64:AA:4A:68:18:2A:22:11`

(Le même que dans le volume Docker actuel)

### Étape 6 : Tester la connexion

Testez la connexion depuis votre client Windows avec les certificats mis à jour (cf. [GUIDE_CONNEXION_WINDOWS.md](GUIDE_CONNEXION_WINDOWS.md)).

## Avantages de la nouvelle configuration

### 1. Persistance garantie
- Les certificats sont dans `./certs/` sur l'hôte
- Visibles et sauvegardables facilement
- Pas de risque de perte avec `docker compose down -v`

### 2. Gestion simplifiée
- Copier les certificats vers les clients : `scp ./certs/ca.crt client@windows:`
- Versionner les certificats (avec .gitignore approprié)
- Remplacer manuellement un certificat si nécessaire

### 3. Stabilité
- Les certificats ne sont jamais régénérés automatiquement
- La chaîne de confiance reste cohérente entre redémarrages
- Plus d'erreur "Path does not chain with any of the trust anchors"

### 4. Traçabilité
- `ls -l ./certs/` montre quand les certificats ont été créés
- Facile de vérifier les dates d'expiration : `openssl x509 -in ./certs/ca.crt -noout -dates`

## Tester les futures mises à jour

Pour vérifier que le script idempotent fonctionne correctement :

```bash
# Arrêter et redémarrer les conteneurs
docker compose down
docker compose up -d

# Vérifier les logs du cert_generator
docker compose logs cert_generator

# Attendu : "existant trouvé, génération ignorée" pour tous les certificats
```

## Régénérer manuellement les certificats (si nécessaire)

Si vous devez régénérer les certificats (expiration, compromission, etc.) :

```bash
# 1. Arrêter les conteneurs
docker compose down

# 2. Sauvegarder les anciens certificats
mv ./certs ./certs.backup-$(date +%Y%m%d)
mkdir ./certs
touch ./certs/.gitkeeper

# 3. Redémarrer - le script générera de nouveaux certificats
docker compose up -d

# 4. Copier les nouveaux certificats vers les clients Windows
# (cf. GUIDE_CONNEXION_WINDOWS.md)
```

## Ajouter un nouveau client

Pour ajouter un nouvel utilisateur client (ex: `new_user`) :

```bash
# 1. Modifier .env
nano .env
# Ajouter "new_user" à CLIENT_NAMES : admin,app_user,backup_user,app_developer,new_user

# 2. Générer uniquement le nouveau certificat client
# Le script détectera que les autres certificats existent et ne les régénérera pas
docker compose up -d cert_generator

# 3. Vérifier
ls -l ./certs/client_new_user.*

# 4. Transférer vers le client
scp ./certs/client_new_user.pfx client@windows:
scp ./certs/ca.crt client@windows:
```

## Rollback (retour à l'ancienne configuration)

Si vous rencontrez des problèmes et voulez revenir à l'ancienne configuration :

```bash
# 1. Restaurer le docker-compose.yml depuis Git
git checkout docker-compose.yml

# 2. Restaurer le script generate_certs.sh
git checkout init-ssl/generate_certs.sh

# 3. Redémarrer
docker compose down
docker compose up -d
```

**Note** : Cela régénérera tous les certificats. Vous devrez mettre à jour les clients Windows.

## Questions fréquentes

### Q1 : Les certificats sont-ils sécurisés dans ./certs/ ?

**Réponse** : Oui, tant que :
- Les fichiers .key et .pfx ont les permissions 600 (lecture seule par le propriétaire)
- Le répertoire n'est pas ajouté à Git (vérifier .gitignore)
- L'accès SSH au serveur est protégé par clé

### Q2 : Que faire si je perds les certificats dans ./certs/ ?

**Réponse** :
1. Supprimer le répertoire : `rm -rf ./certs/`
2. Recréer : `mkdir ./certs && touch ./certs/.gitkeeper`
3. Redémarrer : `docker compose up -d`
4. Mettre à jour tous les clients Windows avec les nouveaux certificats

### Q3 : Les certificats expirent quand ?

**Réponse** :
```bash
openssl x509 -in ./certs/ca.crt -noout -dates
```

Avec `DAYS_VALID=3650`, les certificats actuels sont valides jusqu'au **7 mars 2036**.

### Q4 : Puis-je utiliser ces certificats pour d'autres services ?

**Réponse** : Oui, le CA (`ca.crt`) peut être réutilisé pour signer d'autres certificats. Le certificat serveur est spécifique à PostgreSQL (CN et SAN configurés pour ce service).

## Support

En cas de problème :
1. Vérifier les logs : `docker compose logs`
2. Vérifier les permissions : `ls -l ./certs/`
3. Tester la chaîne SSL : `openssl verify -CAfile ./certs/ca.crt ./certs/server.crt`
4. Consulter [GUIDE_CONNEXION_WINDOWS.md](GUIDE_CONNEXION_WINDOWS.md) pour les clients

## Fichiers modifiés

| Fichier | Modification | Statut |
|---------|-------------|---------|
| [init-ssl/generate_certs.sh](init-ssl/generate_certs.sh) | Ajout vérifications d'existence | ✅ Modifié |
| [docker-compose.yml](docker-compose.yml) | Bind mount + restart: no | ✅ Modifié |
| [GUIDE_CONNEXION_WINDOWS.md](GUIDE_CONNEXION_WINDOWS.md) | Guide client Windows | ✅ Créé |
| [GUIDE_MIGRATION.md](GUIDE_MIGRATION.md) | Ce guide | ✅ Créé |

---

**Date de migration** : 10 mars 2026
**Version des certificats** : Générés le 10 mars 2026 à 08:22 UTC
**Validité** : Jusqu'au 7 mars 2036
