# ------------------------------------------
# - Stage: 01 - builder
# ------------------------------------------

# This image is also based on frappe/bench which we use for production
# https://github.com/pipech/erpnext-docker-debian/blob/master/Dockerfile
FROM pipech/erpnext-docker-debian:version-15-latest AS builder

# These variable has been set from base image
# $systemUser, $benchFolderName
USER $systemUser
WORKDIR /home/$systemUser/$benchFolderName

RUN echo "-> Start builder" \
    ### remove unused sites, created by base image
    && rm -rf /home/$systemUser/$benchFolderName/sites/site1.local \
    ### [HOTFIX] Railway used IPv6 (Does not support IPv4),  https://docs.railway.com/guides/private-networking#caveats
    ### https://github.com/frappe/frappe/issues/33981
    && sed -i 's/socket\.AF_INET, socket\.SOCK_STREAM/socket.AF_INET6, socket.SOCK_STREAM/g' /home/frappe/bench/apps/frappe/frappe/utils/connections.py \
    ### install POS Next app
    && bench get-app https://github.com/BrainWise-DEV/pos_next.git --branch version-15 \
    && echo "-> Builder done!"


# ------------------------------------------
# - Stage: 02 - production
# ------------------------------------------

# Image version should also match with stage 01
# (Check pipech/erpnext-docker-debian Dockerfile)
# https://github.com/frappe/frappe_docker/blob/main/images/bench/Dockerfile
FROM frappe/bench:v5.22.9

# this env should match stage 01
# (Check pipech/erpnext-docker-debian Dockerfile)
ENV systemUser=frappe
ENV benchFolderName=bench

# Copied bench folder from build stage
COPY --from=builder --chown=$systemUser /home/$systemUser/$benchFolderName /home/$systemUser/$benchFolderName

# Copy template
COPY /railway/temp_nginx.conf /home/$systemUser/temp_nginx.conf
COPY /railway/temp_supervisor.conf /home/$systemUser/temp_supervisor.conf

USER root
WORKDIR /home/$systemUser/$benchFolderName

# [fix] "debconf: unable to initialize frontend: Dialog"
# https://github.com/moby/moby/issues/27988
ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# Install Node 20 BEFORE bench build so assets compile with Node 20
# ---------------------------------------------------------
USER frappe
RUN bash -c "source ~/.nvm/nvm.sh \
    && nvm install 20 \
    && nvm alias default 20 \
    && nvm use 20 \
    && npm install -g yarn"

USER root
# Symlink Node 20 binaries globally so nginx/supervisor/scripts can call node/npm/yarn directly
RUN bash -c "ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/node /usr/bin/node \
    && ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/npm /usr/bin/npm \
    && ln -sf /home/frappe/.nvm/versions/node/v20.*/bin/yarn /usr/bin/yarn"
# ---------------------------------------------------------

RUN echo "-> Install nginx & supervisor" \
    # apt-get update
    && apt-get update \
    && apt-get install -y \
    # nginx for serving files
    nginx \
    # supervisor to run multiple server per container
    supervisor \
    && echo "-> Cleaning installation" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "-> Remove nginx default site" \
    && rm /etc/nginx/sites-enabled/default \
    && echo "-> Rebuilding bench (with Node 20)" \
    && su $systemUser -c "bash -c 'source ~/.nvm/nvm.sh && nvm use 20 && bench build'" \
    && su $systemUser -c "cp -r /home/$systemUser/$benchFolderName/sites /home/$systemUser/$benchFolderName/built_sites"

COPY --chown=$systemUser --chmod=0755 /railway/railway-setup.sh /home/$systemUser/$benchFolderName/railway-setup.sh
COPY --chown=$systemUser --chmod=0755 /railway/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY --chown=$systemUser --chmod=0755 /railway/railway-cmd.sh /usr/local/bin/railway-cmd.sh

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/local/bin/railway-cmd.sh"]


EXPOSE 80
