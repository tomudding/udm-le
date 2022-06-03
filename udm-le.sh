#!/bin/sh

set -e

# Load environment variables
. /mnt/data/udm-le/udm-le.env

# Setup variables for later
DOCKER_VOLUMES="-v ${UDM_LE_PATH}/lego/:/.lego/"
LEGO_ARGS="--dns ${DNS_PROVIDER} --email ${CERT_EMAIL} --key-type rsa2048"
RESTART_SERVICES=${RESTART_SERVICES:-false}
FORCE_DEPLOY=false

deploy_certs() {
    # Deploy certificates for the controller, captive portal, dns resolver, and radius server
    if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${NETWORK_HOST}".crt -mmin -5)" ] || [ "${FORCE_DEPLOY}" == true ]; then
        echo 'New ${NETWORK_HOST} certificate was generated, time to deploy it'

        cp -f ${UDM_LE_PATH}/lego/certificates/${NETWORK_HOST}.crt ${UBIOS_CERT_PATH}/unifi-core.crt
        cp -f ${UDM_LE_PATH}/lego/certificates/${NETWORK_HOST}.key ${UBIOS_CERT_PATH}/unifi-core.key
        chmod 644 ${UBIOS_CERT_PATH}/unifi-core.crt ${UBIOS_CERT_PATH}/unifi-core.key

        RESTART_SERVICES=true
    fi

    if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${CAPTIVE_HOST}".crt -mmin -5)" ] || [ "${FORCE_DEPLOY}" == true ]; then
        echo 'New ${CAPTIVE_HOST} certificate was generated, time to deploy it'

        cp -f ${UDM_LE_PATH}/lego/certificates/${CAPTIVE_HOST}.crt ${UBIOS_CERT_PATH}/unifi-captive-core.crt
        cp -f ${UDM_LE_PATH}/lego/certificates/${CAPTIVE_HOST}.key ${UBIOS_CERT_PATH}/unifi-captive-core.key
        chmod 644 ${UBIOS_CERT_PATH}/unifi-captive-core.crt ${UBIOS_CERT_PATH}/unifi-captive-core.key

        podman exec -it unifi-os openssl x509 -in ${UNIFIOS_CERT_PATH}/unifi-captive-core.crt > ${UNIFIOS_CERT_PATH}/unifi-captive-core-server-only.crt
        podman exec -it unifi-os openssl pkcs12 -export -inkey ${UNIFIOS_CERT_PATH}/unifi-captive-core.key -in ${UNIFIOS_CERT_PATH}/unifi-captive-core-server-only.crt -out /usr/lib/unifi/data/unifi-captive-core-key-plus-server-only-cert.p12 -name unifi -password pass:aircontrolenterprise
        podman exec -it unifi-os cp /usr/lib/unifi/data/keystore /usr/lib/unifi/data/keystore_$(date +"%Y-%m-%d_%Hh%Mm%Ss").backup
        podman exec -it unifi-os keytool -delete -alias unifi -keystore /usr/lib/unifi/data/keystore -deststorepass aircontrolenterprise
        podman exec -it unifi-os keytool -importkeystore -deststorepass aircontrolenterprise -destkeypass aircontrolenterprise -destkeystore /usr/lib/unifi/data/keystore -srckeystore /usr/lib/unifi/data/unifi-captive-core-key-plus-server-only-cert.p12 -srcstoretype PKCS12 -srcstorepass aircontrolenterprise -alias unifi -noprompt

        RESTART_SERVICES=true
    fi

    if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${DNS_HOST}".crt -mmin -5)" ] || [ "${FORCE_DEPLOY}" == true ]; then
        echo 'New ${DNS_HOST} certificate was generated, time to deploy it'

        # Auto deploying is broken because Podman crashes.
        # podman exec -it pihole mkdir -p /etc/letsencrypt/live/${DNS_HOST}
        # podman cp ${UDM_LE_PATH}/lego/certificates/${DNS_HOST}.crt pihole:/etc/letsencrypt/live/${DNS_HOST}/fullchain.pem
        # podman cp ${UDM_LE_PATH}/lego/certificates/${DNS_HOST}.key pihole:/etc/letsencrypt/live/${DNS_HOST}/privkey.pem
        # podman exec -it pihole chown www-data -R /etc/letsencrypt/live
        # podman cp /mnt/data/pihole/certs/external.conf pihole:/etc/lighttpd/external.conf
        # podman exec -it pihole service lighttpd restart
    fi

    if [ "$(find -L "${UDM_LE_PATH}"/lego -type f -name "${RADIUS_HOST}".crt -mmin -5)" ] || [ "${FORCE_DEPLOY}" == true ]; then
        echo 'New ${RADIUS_HOST} certificate was generated, time to deploy it'

        cp -f ${UDM_LE_PATH}/lego/certificates/${RADIUS_HOST}.crt ${UBIOS_RADIUS_CERT_PATH}/server.pem
        cp -f ${UDM_LE_PATH}/lego/certificates/${RADIUS_HOST}.key ${UBIOS_RADIUS_CERT_PATH}/server-key.pem
        chmod 600 ${UBIOS_RADIUS_CERT_PATH}/server.pem ${UBIOS_RADIUS_CERT_PATH}/server-key.pem
        rc.radiusd restart &>/dev/null
    fi
}

restart_services() {
    # Restart services if certificates have been deployed, or we're forcing it on the command line
    if [ "${RESTART_SERVICES}" == true ]; then
        echo 'Restarting UniFi OS'
        unifi-os restart &>/dev/null
    else
        echo 'RESTART_SERVICES is false, skipping service restarts'
    fi
}

# Support alternative DNS resolvers
if [ "${DNS_RESOLVERS}" != "" ]; then
    LEGO_ARGS="${LEGO_ARGS} --dns.resolvers ${DNS_RESOLVERS}"
fi

# Setup all the domains
LEGO_ARGS_NETWORK="${LEGO_ARGS} -d ${NETWORK_HOST}"
LEGO_ARGS_CAPTIVE="${LEGO_ARGS} -d ${CAPTIVE_HOST}"
LEGO_ARGS_DNS="${LEGO_ARGS} -d ${DNS_HOST}"
LEGO_ARGS_RADIUS="${LEGO_ARGS} -d ${RADIUS_HOST}"

# Check for optional .secrets directory, and add it to the mounts if it exists
# Lego does not support AWS_ACCESS_KEY_ID_FILE or AWS_PROFILE_FILE so we'll try
# mounting the secrets directory into a place that Route53 will see.
if [ -d "${UDM_LE_PATH}/.secrets" ]; then
    DOCKER_VOLUMES="${DOCKER_VOLUMES} -v ${UDM_LE_PATH}/.secrets:/root/.aws/ -v ${UDM_LE_PATH}/.secrets:/root/.secrets/"
fi

# Setup persistent on_boot.d trigger
ON_BOOT_DIR='/mnt/data/on_boot.d'
ON_BOOT_FILE='99-udm-le.sh'
if [ -d "${ON_BOOT_DIR}" ] && [ ! -f "${ON_BOOT_DIR}/${ON_BOOT_FILE}" ]; then
    cp "${UDM_LE_PATH}/on_boot.d/${ON_BOOT_FILE}" "${ON_BOOT_DIR}/${ON_BOOT_FILE}"
    chmod 755 ${ON_BOOT_DIR}/${ON_BOOT_FILE}
fi

# Setup nightly cron job
CRON_FILE='/etc/cron.d/udm-le'
if [ ! -f "${CRON_FILE}" ]; then
    echo "0 3 * * * sh ${UDM_LE_PATH}/udm-le.sh renew" >${CRON_FILE}
    chmod 644 ${CRON_FILE}
    /etc/init.d/crond reload ${CRON_FILE}
fi

PODMAN_CMD="podman run --env-file=${UDM_LE_PATH}/udm-le.env -it --name=lego --network=host --rm ${DOCKER_VOLUMES} ${CONTAINER_IMAGE}:${CONTAINER_IMAGE_TAG}"

case $1 in
initial)
    # Create lego directory so the container can write to it
    if [ "$(stat -c '%u:%g' "${UDM_LE_PATH}/lego")" != "1000:1000" ]; then
            mkdir "${UDM_LE_PATH}"/lego
            chown 1000:1000 "${UDM_LE_PATH}"/lego
    fi

    echo 'Attempting initial certificate generation'
    ${PODMAN_CMD} ${LEGO_ARGS_NETWORK} --accept-tos run && ${PODMAN_CMD} ${LEGO_ARGS_CAPTIVE} --accept-tos run && ${PODMAN_CMD} ${LEGO_ARGS_DNS} --accept-tos run && ${PODMAN_CMD} ${LEGO_ARGS_RADIUS} --accept-tos run && deploy_certs && restart_services
    ;;
renew)
    echo 'Attempting certificate renewal'
    ${PODMAN_CMD} ${LEGO_ARGS_NETWORK} renew --days 60 && ${PODMAN_CMD} ${LEGO_ARGS_CAPTIVE} renew --days 60 && ${PODMAN_CMD} ${LEGO_ARGS_DNS} renew --days 60 && ${PODMAN_CMD} ${LEGO_ARGS_RADIUS} renew --days 60 && deploy_certs && restart_services
    ;;
force_deploy)
    echo 'Attempting to deploy (old) certificates...'
    FORCE_DEPLOY=true
    RESTART_SERVICES=true
    deploy_certs && restart_services
    ;;
esac
