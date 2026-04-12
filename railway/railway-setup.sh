#!/bin/bash
set -e

# ---------------------------------------------------------
# FORCE NODE 20 ENVIRONMENT
# ---------------------------------------------------------
export NVM_DIR="/home/frappe/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20
echo "-> Node version: $(node --version)"
# ---------------------------------------------------------

# -> Run entrypoint
# somehow when specify custom cmd in railway,
# it doesn't run entrypoint first, so we need to run it here.
sudo /usr/local/bin/railway-entrypoint.sh

echo "-> Create empty common site config"
echo "{}" > /home/frappe/bench/sites/common_site_config.json

echo "-> Create new site with ERPNext"
bench new-site ${RFP_DOMAIN_NAME} \
    --admin-password ${RFP_SITE_ADMIN_PASSWORD} \
    --no-mariadb-socket \
    --db-root-password ${RFP_DB_ROOT_PASSWORD} \
    --install-app erpnext
bench use ${RFP_DOMAIN_NAME}

echo "-> Enable scheduler"
bench enable-scheduler

echo "-> Install POS Next"
bench --site ${RFP_DOMAIN_NAME} install-app pos_next

echo "-> Run migrations"
bench --site ${RFP_DOMAIN_NAME} migrate

echo "-> Build POS Next frontend assets (Node $(node --version))"
bench build --app pos_next

echo "-> Smoke test: checking if site responds on port 80"
MAX_RETRIES=10
RETRY_DELAY=5
for i in $(seq 1 $MAX_RETRIES); do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: ${RFP_DOMAIN_NAME}" \
        http://localhost/ 2>/dev/null || echo "000")
    echo "   Attempt $i/$MAX_RETRIES -- HTTP $HTTP_STATUS"
    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
        echo "-> Site is UP (HTTP $HTTP_STATUS)"
        break
    fi
    if [ "$i" = "$MAX_RETRIES" ]; then
        echo "WARNING: Site did not respond with 200/301/302 after $MAX_RETRIES attempts."
        echo "         Check nginx: nginx -t"
        echo "         Check supervisor: supervisorctl status"
        echo "         Check gunicorn log: cat /home/frappe/bench/logs/web.error.log"
    fi
    sleep $RETRY_DELAY
done

echo "-> Setup complete."
