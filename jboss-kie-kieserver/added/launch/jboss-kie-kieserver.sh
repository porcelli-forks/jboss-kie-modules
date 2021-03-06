#!/bin/bash

source "${JBOSS_HOME}/bin/launch/launch-common.sh"
source "${JBOSS_HOME}/bin/launch/jboss-kie-wildfly-common.sh"
source "${JBOSS_HOME}/bin/launch/logging.sh"
source "${JBOSS_HOME}/bin/launch/jboss-kie-wildfly-security.sh"

function prepareEnv() {
    # please keep these in alphabetical order
    unset AUTO_CONFIGURE_EJB_TIMER
    unset DROOLS_SERVER_FILTER_CLASSES
    unset JBPM_HT_CALLBACK_CLASS
    unset JBPM_HT_CALLBACK_METHOD
    unset JBPM_LOOP_LEVEL_DISABLED
    unset KIE_EXECUTOR_RETRIES
    unset_kie_security_env
    unset KIE_SERVER_CONTAINER_DEPLOYMENT
    unset KIE_SERVER_CONTROLLER_HOST
    unset KIE_SERVER_CONTROLLER_PORT
    unset KIE_SERVER_CONTROLLER_PROTOCOL
    unset KIE_SERVER_CONTROLLER_SERVICE
    unset KIE_SERVER_HOST
    unset KIE_SERVER_ID
    unset KIE_SERVER_LOCATION
    unset KIE_SERVER_MGMT_DISABLED
    unset KIE_SERVER_PERSISTENCE_DIALECT
    unset KIE_SERVER_PERSISTENCE_DS
    unset KIE_SERVER_PERSISTENCE_SCHEMA
    unset KIE_SERVER_PERSISTENCE_TM
    unset KIE_SERVER_PORT
    unset KIE_SERVER_PROTOCOL
    unset KIE_SERVER_ROUTE_NAME
    unset KIE_SERVER_ROUTER_HOST
    unset KIE_SERVER_ROUTER_PORT
    unset KIE_SERVER_ROUTER_PROTOCOL
    unset KIE_SERVER_ROUTER_SERVICE
    unset KIE_SERVER_URL
    unset KIE_SERVER_USE_SECURE_ROUTE_NAME
    unset KIE_SERVER_STARTUP_STRATEGY
    unset KIE_SERVER_SYNC_DEPLOY
    unset PROMETHEUS_SERVER_EXT_DISABLED
}

function preConfigure() {
    configure_EJB_Timer_datasource
}

function configureEnv() {
    configure
}

function configure() {
    # configure_server_env always has to be first
    configure_server_env
    configure_controller_access
    configure_router_access
    configure_server_location
    configure_server_persistence
    configure_server_security
    configure_server_sync_deploy
    configure_drools
    configure_executor
    configure_jbpm
    configure_kie_server_mgmt
    # configure_server_state always has to be last
    configure_server_state
    configure_prometheus
}

function configure_EJB_Timer_datasource {

    source $JBOSS_HOME/bin/launch/datasource-common.sh

    local autoConfigure=${AUTO_CONFIGURE_EJB_TIMER:-true}
    if [ "${autoConfigure^^}" = "TRUE" ]; then
        log_info "EJB Timer will be auto configured if any datasource is configured via DB_SERVICE_PREFIX_MAPPING or DATASOURCES envs."

        # configure the EJB timer datasource based on DB_SERVICE_PREFIX_MAPPING
        if [ -n "${DB_SERVICE_PREFIX_MAPPING}" ]; then
            log_info "configuring EJB Timer Datasource based on DB_SERVICE_PREFIX_MAPPING env"
            local serviceMappingName=${DB_SERVICE_PREFIX_MAPPING%=*}
            local prefix=${DB_SERVICE_PREFIX_MAPPING#*=}
            local service=${serviceMappingName^^}
            service=${service//-/_}

            DB_SERVICE_PREFIX_MAPPING="${serviceMappingName}=EJB_TIMER,${DB_SERVICE_PREFIX_MAPPING}"
            TIMER_SERVICE_DATA_STORE="${serviceMappingName}"
            EJB_TIMER_DRIVER=${serviceMappingName##*-}

            set_url $prefix
            set_timer_env $prefix $service
        elif [ -n "${DATASOURCES}" ]; then
            log_info "configuring EJB Timer Datasource based on DATASOURCES env"
            # Make sure that the EJB datasource is configured first, in this way the timer's default-data-store wil be the
            # EJBTimer datasource
            local dsPrefix="${DATASOURCES%,*}"
            DATASOURCES="EJB_TIMER,${DATASOURCES}"
            set_url $dsPrefix
            set_timer_env $dsPrefix
            TIMER_SERVICE_DATA_STORE="EJB_TIMER"

            # default value for ${prefix)_NONXA should be true
            if [ -z "$(eval echo \$${dsPrefix}_NONXA)" ]; then
                eval ${dsPrefix}_NONXA="true"
            fi
        fi
    fi
}

# Sets the NONXA url if only the PREFIX_XA_CONNECTION_PROPERTY_URL is provided.
# $1 - datasource prefix
function set_url {
    local prefixedUrl=$(find_env "${1}_URL")
    url=$(find_env "${1}_XA_CONNECTION_PROPERTY_URL" "${prefixedUrl}")
    if [ "${prefixedUrl}x" = "x" ]; then
        eval ${1}_URL="${url}"
    fi
}

function set_timer_env {
    local prefix=$1
    local service=$2

    declare_timer_common_variables $prefix
    set_timer_defaults $prefix
    declare_xa_variables $prefix $service
}

function declare_timer_common_variables {
    local common_vars=(DRIVER JNDI USERNAME PASSWORD TX_ISOLATION \
                            XA_CONNECTION_PROPERTY_URL MAX_POOL_SIZE \
                            MIN_POOL_SIZE CONNECTION_CHECKER EXCEPTION_SORTER \
                            BACKGROUND_VALIDATION BACKGROUND_VALIDATION_MILLIS)

    for var in ${common_vars[@]}; do
        local value=$(find_env "${prefix}_${var}")
        if [[ -n ${value} ]]; then
            eval EJB_TIMER_${var}="${value}"
        fi
    done
}

function set_timer_defaults {
    if [ "x${EJB_TIMER_JNDI}" != "x" ]; then
        EJB_TIMER_JNDI="${EJB_TIMER_JNDI}_EJBTimer"
    else
        EJB_TIMER_JNDI=$(find_env "${prefix}_JNDI" "java:jboss/datasources/ejb_timer")
    fi

    EJB_TIMER_MAX_POOL_SIZE=${EJB_TIMER_MAX_POOL_SIZE:-"10"}
    EJB_TIMER_MIN_POOL_SIZE=${EJB_TIMER_MIN_POOL_SIZE:-"10"}
    EJB_TIMER_TX_ISOLATION="${EJB_TIMER_TX_ISOLATION:-TRANSACTION_READ_COMMITTED}"

    if [[ $EJB_TIMER_DRIVER = *"mysql"* ]]; then
        local url=$(find_env "${prefix}_URL")
        url=$(find_env "${prefix}_XA_CONNECTION_PROPERTY_URL" "${url}")
        if [ "x${url}" != "x" ]; then
            EJB_TIMER_XA_CONNECTION_PROPERTY_URL="${url}?pinGlobalTxToPhysicalConnection=true"
        else
            EJB_TIMER_XA_CONNECTION_PROPERTY_PinGlobalTxToPhysicalConnection="true"
        fi
    fi
}

function get_svc_var {
    local var=$1
    local prop=$2
    local prefix=$3
    local svc=$4

    local var_name=${prefix}_XA_CONNECTION_PROPERTY_${prop}
    local value=$(find_env ${var_name})
    if [[ -z ${value} ]]; then
        value=$(find_env "${prefix}_SERVICE_${var}")
        if [[ -n ${svc} && -z ${value} ]]; then
            value=$(find_env "${svc}_SERVICE_${var}")
        fi
    fi
    if [[ -n ${value} ]]; then
        eval export EJB_TIMER_XA_CONNECTION_PROPERTY_${prop}="${value}"
    fi
}

function declare_xa_variables {
    local prefix=$1
    local service=$2
    local url=$(find_env "${prefix}_URL")
    url=$(find_env "${prefix}_XA_CONNECTION_PROPERTY_URL" "${url}")
    if [ "x${url}" == "x" ]; then
        database=$(find_env "${prefix}_DATABASE")
        xa_database=$(find_env "${prefix}_XA_CONNECTION_PROPERTY_DatabaseName")
        EJB_TIMER_XA_CONNECTION_PROPERTY_DatabaseName=${xa_database:-${database}}
        get_svc_var "HOST" "ServerName" $prefix $service
        if [[ $EJB_TIMER_DRIVER = *"mysql"* ]] || [[ $EJB_TIMER_DRIVER = *"mariadb"* ]]; then
            get_svc_var "PORT" "Port" $prefix $service
        else
            get_svc_var "PORT" "PortNumber" $prefix $service
        fi

        #postgresql/mariadb/mysql with custom drivers are not correctly configured if no PREFIX_URL is set
        if [[ $EJB_TIMER_DRIVER = *"postgresql"* ]] || [[ $EJB_TIMER_DRIVER = *"mysql"* ]] || [[ $EJB_TIMER_DRIVER = *"mariadb"* ]]; then
            local serviceHost=$(find_env "${service}_SERVICE_HOST")
            local host=$(find_env "${prefix}_SERVICE_HOST" "${serviceHost}")
            local servicePort=$(find_env "${service}_SERVICE_PORT")
            local port=$(find_env "${prefix}_SERVICE_PORT" "${servicePort}")
            local database=$(find_env "${prefix}_DATABASE")
            local dbType="postgresql"
            if [[ $EJB_TIMER_DRIVER = *"mysql"* ]]; then
                dbType="mysql"
            fi
            if [[ $EJB_TIMER_DRIVER = *"mariadb"* ]]; then
                dbType="mariadb"
            fi
            eval ${prefix}_URL="jdbc:${dbType}://${host}:${port}/${database}"
        fi
    fi
}

function configure_server_env {
    # source the KIE config
    source $JBOSS_HOME/bin/launch/kieserver-env.sh
    # set the KIE environment
    setKieEnv
    # dump the KIE environment
    dumpKieEnv | tee ${JBOSS_HOME}/kieEnv
    # save the environment for use by the probes
    sed -ri "s/^([^:]+): *(.*)$/\1=\"\2\"/" ${JBOSS_HOME}/kieEnv
}

function configure_controller_access {
    # We will only support one controller, whether running by itself or in business central.
    local kieServerControllerService="${KIE_SERVER_CONTROLLER_SERVICE}"
    kieServerControllerService=${kieServerControllerService^^}
    kieServerControllerService=${kieServerControllerService//-/_}
    # host
    local kieServerControllerHost="${KIE_SERVER_CONTROLLER_HOST}"
    if [ "${kieServerControllerHost}" = "" ]; then
        kieServerControllerHost=$(find_env "${kieServerControllerService}_SERVICE_HOST")
    fi
    if [ "${kieServerControllerHost}" != "" ]; then
        # protocol
        local kieServerControllerProtocol=$(find_env "KIE_SERVER_CONTROLLER_PROTOCOL" "http")
        # port
        local kieServerControllerPort="${KIE_SERVER_CONTROLLER_PORT}"
        if [ "${kieServerControllerPort}" = "" ]; then
            kieServerControllerPort=$(find_env "${kieServerControllerService}_SERVICE_PORT" "8080")
        fi
        # path
        local kieServerControllerPath="/rest/controller"
        if [ "${kieServerControllerProtocol}" = "ws" ]; then
            kieServerControllerPath="/websocket/controller"
        fi
        # url
        local kieServerControllerUrl=$(build_simple_url "${kieServerControllerProtocol}" "${kieServerControllerHost}" "${kieServerControllerPort}" "${kieServerControllerPath}")
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.controller=${kieServerControllerUrl}"
    fi
    # user/pwd
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.controller.user=\"$(get_kie_server_controller_user)\""
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.controller.pwd=\"$(esc_kie_server_controller_pwd)\""
    # token
    local kieServerControllerToken="$(get_kie_server_controller_token)"
    if [ "${kieServerControllerToken}" != "" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.controller.token=\"${kieServerControllerToken}\""
    fi
}

function configure_router_access {
    local kieServerRouterService="${KIE_SERVER_ROUTER_SERVICE}"
    kieServerRouterService=${kieServerRouterService^^}
    kieServerRouterService=${kieServerRouterService//-/_}
    # host
    local kieServerRouterHost="${KIE_SERVER_ROUTER_HOST}"
    if [ "${kieServerRouterHost}" = "" ]; then
        kieServerRouterHost=$(find_env "${kieServerRouterService}_SERVICE_HOST")
    fi
    if [ "${kieServerRouterHost}" != "" ]; then
        # protocol
        local kieServerRouterProtocol=$(find_env "KIE_SERVER_ROUTER_PROTOCOL" "http")
        # port
        local kieServerRouterPort="${KIE_SERVER_ROUTER_PORT}"
        if [ "${kieServerRouterPort}" = "" ]; then
            kieServerRouterPort=$(find_env "${kieServerRouterService}_SERVICE_PORT" "9000")
        fi
        # url
        local kieServerRouterUrl=$(build_simple_url "${kieServerRouterProtocol}" "${kieServerRouterHost}" "${kieServerRouterPort}" "")
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.router=${kieServerRouterUrl}"
    fi
}

function configure_drools() {
    # should the server filter classes?
    if [ "x${DROOLS_SERVER_FILTER_CLASSES}" != "x" ]; then
        # if specified, respect value
        local droolsServerFilterClasses=$(echo "${DROOLS_SERVER_FILTER_CLASSES}" | tr "[:upper:]" "[:lower:]")
        if [ "${droolsServerFilterClasses}" = "true" ]; then
            DROOLS_SERVER_FILTER_CLASSES="true"
        else
            DROOLS_SERVER_FILTER_CLASSES="false"
        fi
    else
        # otherwise, filter classes by default
        DROOLS_SERVER_FILTER_CLASSES="true"
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.drools.server.filter.classes=${DROOLS_SERVER_FILTER_CLASSES}"
}

# ---------- KIE SERVER LOCATION URL VIA ROUTE ----------
# External location of all KIE Servers via a Route.
# Example template parameters:
#
# - name: KIE_SERVER_ROUTE_NAME
#   value: "${APPLICATION_NAME}-kieserver"
# - name: KIE_SERVER_USE_SECURE_ROUTE_NAME
#   value: "${KIE_SERVER_USE_SECURE_ROUTE_NAME}"
# - name: HOSTNAME_HTTP
#   value: "${KIE_SERVER_HOSTNAME_HTTP}"
# - name: HOSTNAME_HTTPS
#   value: "${KIE_SERVER_HOSTNAME_HTTPS}"
#
# ---------- EXPLICIT KIE SERVER LOCATION ----------
# Internal location of each KIE Server per each Pod's IP (retrieved via the Downward API).
# Example template parameters:
#
# - name: KIE_SERVER_PROTOCOL
#   value: "${KIE_SERVER_PROTOCOL}"
# - name: KIE_SERVER_HOST
#   valueFrom:
#     fieldRef:
#       fieldPath: status.podIP
# - name: KIE_SERVER_PORT
#   value: "${KIE_SERVER_PORT}"
#
function configure_server_location() {
    # KIE_SERVER_LOCATION matches our env-to-property naming convention,
    # but KIE_SERVER_URL kept here for backwards compatibility
    local location="${KIE_SERVER_LOCATION:-$KIE_SERVER_URL}"
    if [ -z "${location}" ]; then
        local protocol="${KIE_SERVER_PROTOCOL,,}"
        local host="${KIE_SERVER_HOST}"
        local defaultInsecureHost="${HOSTNAME_HTTP:-${HOSTNAME:-localhost}}"
        local defaultSecureHost="${HOSTNAME_HTTPS:-${defaultInsecureHost}}"
        local port="${KIE_SERVER_PORT}"
        local path="/services/rest/server"
        local routeName="${KIE_SERVER_ROUTE_NAME}"
        if [ -n "${routeName}" ]; then
            if [ "${KIE_SERVER_USE_SECURE_ROUTE_NAME^^}" = "TRUE" ]; then
                routeName="secure-${routeName}"
                protocol="${protocol:-https}"
                host="${host:-${defaultSecureHost}}"
                port="${port:-443}"
            else
                protocol="${protocol:-http}"
                host="${host:-${defaultInsecureHost}}"
                port="${port:-80}"
            fi
            location=$(build_route_url "${routeName}" "${protocol}" "${host}" "${port}" "${path}")
        else
            if [ "${protocol}" = "https" ]; then
                host="${host:-${defaultSecureHost}}"
                port="${port:-8443}"
            else
                protocol="${protocol:-http}"
                host="${host:-${defaultInsecureHost}}"
                port="${port:-8080}"
            fi
            location=$(build_simple_url "${protocol}" "${host}" "${port}" "${path}")
        fi
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.location=${location}"
}

function configure_server_persistence() {
    # dialect
    if [ "${KIE_SERVER_PERSISTENCE_DIALECT}" = "" ]; then
        KIE_SERVER_PERSISTENCE_DIALECT="org.hibernate.dialect.H2Dialect"
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.persistence.dialect=${KIE_SERVER_PERSISTENCE_DIALECT}"
    # datasource
    if [ "${KIE_SERVER_PERSISTENCE_DS}" = "" ]; then
        if [ "x${DB_JNDI}" != "x" ]; then
            KIE_SERVER_PERSISTENCE_DS="${DB_JNDI}"
        else
            KIE_SERVER_PERSISTENCE_DS="java:/jboss/datasources/ExampleDS"
        fi
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.persistence.ds=${KIE_SERVER_PERSISTENCE_DS}"
    # transactions
    if [ "${KIE_SERVER_PERSISTENCE_TM}" = "" ]; then
        #KIE_SERVER_PERSISTENCE_TM="org.hibernate.service.jta.platform.internal.JBossAppServerJtaPlatform"
        KIE_SERVER_PERSISTENCE_TM="org.hibernate.engine.transaction.jta.platform.internal.JBossAppServerJtaPlatform"
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.persistence.tm=${KIE_SERVER_PERSISTENCE_TM}"
    # default schema
    if [ "${KIE_SERVER_PERSISTENCE_SCHEMA}" != "" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.persistence.schema=${KIE_SERVER_PERSISTENCE_SCHEMA}"
    fi
}

function configure_server_security() {
    # add eap users (see jboss-kie-wildfly-security.sh)
    add_kie_admin_user
    add_kie_server_user
    print_user_information "kieserver"
    # user/pwd
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.user=\"$(get_kie_server_user)\""
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.pwd=\"$(esc_kie_server_pwd)\""
    # token
    local kieServerToken="$(get_kie_server_token)"
    if [ "${kieServerToken}" != "" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.token=\"${kieServerToken}\""
    fi
    # domain
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.domain=\"$(get_kie_server_domain)\""
    # bypass auth user
    local kieServerBypassAuthUser="$(get_kie_server_bypass_auth_user)"
    if [ "${kieServerBypassAuthUser}" != "" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.bypass.auth.user=\"${kieServerBypassAuthUser}\""
    fi
}

function configure_server_sync_deploy() {
    # server sync deploy (true by default)
    local kieServerSyncDeploy="true";
    if [ "${KIE_SERVER_SYNC_DEPLOY// /}" != "" ]; then
        kieServerSyncDeploy=$(echo "${KIE_SERVER_SYNC_DEPLOY}" | tr "[:upper:]" "[:lower:]")
        if [ "${kieServerSyncDeploy}" != "true" ]; then
            kieServerSyncDeploy="false"
        fi
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.sync.deploy=${kieServerSyncDeploy}"
}

function configure_executor() {
    # kie executor number of retries
    if [ "${KIE_EXECUTOR_RETRIES}" != "" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.executor.retry.count=${KIE_EXECUTOR_RETRIES}"
    fi
}

# Enable/disable the jbpm capabilities according with the product
function configure_jbpm() {
    if [ "${JBOSS_PRODUCT}" = "rhpam-kieserver" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.jbpm.ejb.timer.tx=true"
        if [ "${JBPM_HT_CALLBACK_METHOD}" != "" ]; then
            JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.jbpm.ht.callback=${JBPM_HT_CALLBACK_METHOD}"
        fi
        if [ "${JBPM_HT_CALLBACK_CLASS}" != "" ]; then
            JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.jbpm.ht.custom.callback=${JBPM_HT_CALLBACK_CLASS}"
        fi
        if [ "${JBPM_LOOP_LEVEL_DISABLED}" != "" ]; then
            # yes, this starts with -Djbpm not -Dorg.jbpm
            JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Djbpm.loop.level.disabled=${JBPM_LOOP_LEVEL_DISABLED}"
        fi
    elif [ "${JBOSS_PRODUCT}" = "rhdm-kieserver" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.jbpm.server.ext.disabled=true -Dorg.jbpm.ui.server.ext.disabled=true -Dorg.jbpm.case.server.ext.disabled=true"
    fi
}

function configure_kie_server_mgmt() {

    local ALLOWED_STARTUP_STRATEGY=("LocalContainersStartupStrategy" "ControllerBasedStartupStrategy" "OpenShiftStartupStrategy")
    local invalidStrategy=true

    # setting valid for both, rhpam and rhdm KIE server
    if [ "${KIE_SERVER_MGMT_DISABLED^^}" = "TRUE" ]; then
        JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.mgmt.api.disabled=true"
    fi

    if [ "x${KIE_SERVER_STARTUP_STRATEGY}" != "x" ]; then
        for strategy in ${ALLOWED_STARTUP_STRATEGY[@]}; do
            if [ "$strategy" = "${KIE_SERVER_STARTUP_STRATEGY}" ]; then
                invalidStrategy=false
                JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.startup.strategy=${KIE_SERVER_STARTUP_STRATEGY}"
            fi
        done

        if [ "$invalidStrategy" = "true" ]; then
            log_warning "The startup strategy ${KIE_SERVER_STARTUP_STRATEGY} is not valid, the valid strategies are LocalContainersStartupStrategy and ControllerBasedStartupStrategy"
        fi
    fi
}

function configure_server_state() {
    # replace all non-alphanumeric characters with a dash
    local kieServerId="${KIE_SERVER_ID//[^[:alnum:].-]/-}"
    if [ "x${kieServerId}" != "x" ]; then
        # can't start with a dash
        local firstChar="$(echo -n $kieServerId | head -c 1)"
        if [ "${firstChar}" = "-" ]; then
            kieServerId="0${kieServerId}"
        fi
        # can't end with a dash
        local lastChar="$(echo -n $kieServerId | tail -c 1)"
        if [ "${lastChar}" = "-" ]; then
            kieServerId="${kieServerId}0"
        fi
    else
        if [ "x${HOSTNAME}" != "x" ]; then
            # chop off trailing unique "dash number" so all servers use the same template
            kieServerId=$(echo "${HOSTNAME}" | sed -e 's/\(.*\)-[[:digit:]]\+-.*/\1/')
        else
            kieServerId="$(generate_random_id)"
        fi
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.id=${kieServerId}"

    # see scripts/jboss-kie-kieserver/configure.sh
    local kieServerRepo="${HOME}/.kie/repository"
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.server.repo=${kieServerRepo}"

    # see above: configure_server_env / kieserver-env.sh / setKieEnv
    if [ "${KIE_SERVER_CONTAINER_DEPLOYMENT}" != "" ]; then
        # ensure all KIE dependencies are pulled for offline use (this duplicates s2i process; TODO: short-circuit if possible?)
        $JBOSS_HOME/bin/launch/kieserver-pull.sh
        ERR=$?
        if [ $ERR -ne 0 ]; then
            log_error "Aborting due to error code $ERR from maven kjar dependency pull"
            exit $ERR
        fi

        # verify all KIE containers (this duplicates s2i process; TODO: short-circuit if possible?)
        $JBOSS_HOME/bin/launch/kieserver-verify.sh
        ERR=$?
        if [ $ERR -ne 0 ]; then
            log_error "Aborting due to error code $ERR from maven kjar verification"
            exit $ERR
        fi

        # create a KIE server state file with all configured containers and properties
        local stateFileInit="org.kie.server.services.impl.storage.file.KieServerStateFileInit"
        log_info "Attempting to generate kie server state file with 'java ${JBOSS_KIE_ARGS} ${stateFileInit}'"
        java ${JBOSS_KIE_ARGS} $(getKieJavaArgs) ${stateFileInit}
        ERR=$?
        if [ $ERR -ne 0 ]; then
            log_error "Aborting due to error code $ERR from kie server state file init"
            exit $ERR
        fi
    fi
}

function configure_prometheus() {
    if [ -n "${PROMETHEUS_SERVER_EXT_DISABLED}" ]; then
        if [ "${PROMETHEUS_SERVER_EXT_DISABLED^^}" = "TRUE" ]; then
            JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.prometheus.server.ext.disabled=true"
        elif [ "${PROMETHEUS_SERVER_EXT_DISABLED^^}" = "FALSE" ]; then
            JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dorg.kie.prometheus.server.ext.disabled=false"
        else
            log_error "Invalid value \"${PROMETHEUS_SERVER_EXT_DISABLED}\" for PROMETHEUS_SERVER_EXT_DISABLED. Must be \"true\" or \"false\"."
        fi
    fi
}

function generate_random_id() {
    cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}
