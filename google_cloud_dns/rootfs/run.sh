#!/usr/bin/env bashio
set -e

# Derived in part from:
# https://github.com/home-assistant/addons/blob/master/duckdns/data/run.sh

CONFIG_DIR=/config
CERT_DIR=/data/letsencrypt
WORK_DIR=/data/workdir

# Google Cloud DNS
GOOGLE_CLOUD_DNS_PROJECT=$(bashio::config 'project')
GOOGLE_CLOUD_DNS_ZONE=$(bashio::config 'zone')
GOOGLE_CLOUD_DNS_EMAIL=$(bashio::config 'email')
GOOGLE_CLOUD_DNS_KEYFILE=$(bashio::config 'keyfile')
GOOGLE_CLOUD_DNS_KEYFILE="${CONFIG_DIR}/${GOOGLE_CLOUD_DNS_KEYFILE}"
GOOGLE_CLOUD_DNS_KEYPASS=$(bashio::config 'keyfile_password')
GOOGLE_CLOUD_DNS_PEMFILE="${WORK_DIR}/gcp.pem"
GOOGLE_CLOUD_DNS_DOMAIN=$(bashio::config 'domain')
GOOGLE_CLOUD_DNS_HOSTNAME=$(bashio::config 'hostname')
GOOGLE_CLOUD_DNS_TTL=$(bashio::config 'ttl')
GOOGLE_CLOUD_DNS_AUTHFILE="${WORK_DIR}/gcp.auth"
export GOOGLE_CLOUD_DNS_PROJECT
export GOOGLE_CLOUD_DNS_ZONE
export GOOGLE_CLOUD_DNS_EMAIL
export GOOGLE_CLOUD_DNS_KEYPASS
export GOOGLE_CLOUD_DNS_PEMFILE
export GOOGLE_CLOUD_DNS_TTL
export GOOGLE_CLOUD_DNS_AUTHFILE

if bashio::config.has_value 'hostname'
then
    FQDN="${GOOGLE_CLOUD_DNS_HOSTNAME}.${GOOGLE_CLOUD_DNS_DOMAIN}"
else
    FQDN="${GOOGLE_CLOUD_DNS_DOMAIN}"
fi
export FQDN

# Let's Encrypt
LE_ACCEPT_TERMS=$(bashio::config 'lets_encrypt.accept_terms')
LE_CERTFILE=$(bashio::config 'lets_encrypt.certfile')
LE_KEYFILE=$(bashio::config 'lets_encrypt.keyfile')
LE_DNS_DELAY=$(bashio::config 'lets_encrypt.dns_delay')
LE_RENEWAL_PERIOD=$(bashio::config 'lets_encrypt.renewal_period')
LE_UPDATE_FILE="${WORK_DIR}/${FQDN}.update"
export LE_CERTFILE
export LE_KEYFILE
export LE_DNS_DELAY

if bashio::config.has_value 'ipv4'
then
    CONFIG_IPV4=$(bashio::config 'ipv4')
else
    CONFIG_IPV4='https://api.ipify.org/'
fi

if bashio::config.has_value 'ipv6'
then
    CONFIG_IPV6=$(bashio::config 'ipv6')
else
    CONFIG_IPV6='https://api6.ipify.org/'
fi

WAIT_TIME=$(bashio::config 'scan_interval')

# Function that performs a renewal
function le_renew() {
    bashio::log.info "Renewing certificate for domain: ${FQDN}"

    EXIT_CODE=0
    dehydrated --cron --hook /hooks.sh --challenge dns-01 --domain "${FQDN}" \
        --out "${CERT_DIR}" --config "${WORK_DIR}/config" \
        --force \
        || EXIT_CODE=${?}

    if [ $EXIT_CODE -eq 0 ]
    then
        rm -f "${WORK_DIR}/*.update"
        touch "${LE_UPDATE_FILE}"
        LE_UPDATE=$(date +%s -r "${LE_UPDATE_FILE}")
        bashio::log.info "Renewal successful for domain: ${FQDN}"
    else
        bashio::log.warning "Renewal failed for domain: ${FQDN}"
    fi
}

# Register/generate certificate if terms accepted
if [ "${LE_ACCEPT_TERMS}" = 'true' ]
then
    # Init folder structs
    mkdir -p "${CERT_DIR}"
    mkdir -p "${WORK_DIR}"

    # Clean up possible stale lock file
    if [ -e "${WORK_DIR}/lock" ]
    then
        rm -f "${WORK_DIR}/lock"
        bashio::log.warning "Reseting dehydrated lock file"
    fi

    # Generate new certs
    if [ ! -d "${CERT_DIR}/live" ]
    then
        # Create empty dehydrated config file so that this dir will be used for storage
        touch "${WORK_DIR}/config"
        dehydrated --register --accept-terms --config "${WORK_DIR}/config"
    fi

    if [ -e "${LE_UPDATE_FILE}" ]; then
        LE_UPDATE=$(date +%s -r "${LE_UPDATE_FILE}")
    else
        LE_UPDATE=0
    fi
fi

LAST_IPV4=
LAST_IPV6=

# Convert private PKCS #12 key file to PEM
EXIT_CODE=0
openssl pkcs12 -in "${GOOGLE_CLOUD_DNS_KEYFILE}" -passin env:GOOGLE_CLOUD_DNS_KEYPASS -nodes -nocerts -out "${GOOGLE_CLOUD_DNS_PEMFILE}" \
    || EXIT_CODE=${?}

if [ ${EXIT_CODE} -ne 0 ]
then
    bashio::log.fatal "Unable to read private key file ${GOOGLE_CLOUD_DNS_KEYFILE}"
    exit 1
fi

# Update and wait
while true
do
    [[ ${CONFIG_IPV4} != *:/* ]] && IPV4=${CONFIG_IPV4} || IPV4=$(curl -s -m 10 "${CONFIG_IPV4}") || true
    [[ ${CONFIG_IPV6} != *:/* ]] && IPV6=${CONFIG_IPV6} || IPV6=$(curl -s -m 10 "${CONFIG_IPV6}") || true

    if [ "${IPV4}" != '' ] && [ "${IPV4}" != "${LAST_IPV4}" ]
    then
        EXIT_CODE=0
        /google_cloud_update_dns.sh set "${FQDN}" A "${IPV4}" || EXIT_CODE=${?}

        if [ $EXIT_CODE -eq 0 ]
        then
            LAST_IPV4="${IPV4}"
            bashio::log.debug "IPv4 record set to ${IPV4} for domain: ${FQDN}"
        else
            bashio::log.warning "IPv4 record registration failed for domain: ${FQDN}"
        fi
    fi

    if [ "${IPV6}" != '' ] && [ "${IPV6}" != "${LAST_IPV6}" ]
    then
        EXIT_CODE=0
        /google_cloud_update_dns.sh set "${FQDN}" AAAA "${IPV6}" || EXIT_CODE=${?}
        
        if [ $EXIT_CODE -eq 0 ]
        then
            LAST_IPV6="${IPV6}"
            bashio::log.debug "IPv6 record set to ${IPV6} for domain: ${FQDN}"
        else
            bashio::log.warning "IPv6 record registration failed for domain: ${FQDN}"
        fi
    fi

    if [ "${LE_ACCEPT_TERMS}" = 'true' ]
    then
        NOW="$(date +%s)"

        if [ $((NOW - LE_UPDATE)) -ge "${LE_RENEWAL_PERIOD}" ]
        then
            le_renew
        fi
    fi
    
    sleep "${WAIT_TIME}"
done
