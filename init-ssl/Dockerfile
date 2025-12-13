FROM percona/percona-distribution-postgresql:17.6-1
USER root
# OpenSSL est déjà installé dans l'image Percona
COPY generate_certs.sh /usr/local/bin/generate_certs.sh
RUN chmod +x /usr/local/bin/generate_certs.sh
# Rester en tant que root pour créer les fichiers avec les bonnes permissions
USER root