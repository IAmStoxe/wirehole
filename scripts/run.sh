#!/bin/bash

# Available parameters are:
# --down - stops and removes containers of running services
# --logs - displays logs output
# --pull - pulls fresh images before starting containers

set -ea

./scripts/templater.sh ./scripts/.env.template ./scripts/.env.vars > ./.env

[ -f .env ] && source .env

UNKNOWN_POSITIONAL_PARAMS=()

while [ "$#" -gt 0 ]; do
    key="$1"

    case $key in
        --down)
            DOWN="$1"
            shift # past parameter
            ;;
        --logs)
            LOGS="$1"
            shift # past parameter
            ;;
        --pull)
            PULL="$1"
            shift # past parameter
            ;;
        *)    # unknown option
            UNKNOWN_POSITIONAL_PARAMS+=("$1")
            shift # past parameter
            ;;
    esac
done

if [ "${#UNKNOWN_POSITIONAL_PARAMS[@]}" -ne 0 ]; then
    printf '%s\n' "Unrecognized parameters: '${UNKNOWN_POSITIONAL_PARAMS[*]}'"
    printf '%s\n' "Available parameters are:"
    printf '%s\n' "--down - stops and removes containers of running services"
    printf '%s\n' "--logs - displays logs output for all services"
    printf '%s\n' "--pull - pulls fresh images before starting containers"
    exit 0
fi

COMPOSE_PROFILES_PREFIX="COMPOSE_PROFILES=${COMPOSE_PROFILES}"
printf '%s\n' "Start with profiles: ${COMPOSE_PROFILES}"

DOCKER_COMPOSE_CONFIG="${COMPOSE_PROFILES_PREFIX} docker-compose -f docker-compose.yml"
DOCKER_COMPOSE_UP_OPTIONS=""

OVERRIDE_YML="docker-compose.override.yml"
if test -f "$OVERRIDE_YML"; then
    DOCKER_COMPOSE_CONFIG+=" -f ${OVERRIDE_YML}"
fi

#### DOWN ####
DOCKER_COMPOSE_DOWN=("${DOCKER_COMPOSE_CONFIG}" "down --remove-orphans")
if [ "${SERVICE_NAME:=false}" != "false" ]; then
#    DOCKER_COMPOSE_DOWN=("${DOCKER_COMPOSE_DOWN[@]}" "${SERVICE_NAME}")
    DOCKER_COMPOSE_DOWN=("${DOCKER_COMPOSE_CONFIG}" "rm -sv" "${SERVICE_NAME}")
fi

if [ "${DOWN}" == "--down" ]; then
    printf '%s\n' "Stopping containers, removing containers and networks ..."
    printf '%s\n' "Running command: ${DOCKER_COMPOSE_DOWN[*]}"
    eval "${DOCKER_COMPOSE_DOWN[@]}"
    exit 0;
fi
#### END DOWN ####

#### LOG ####
DOCKER_COMPOSE_LOGS=("${DOCKER_COMPOSE_CONFIG}" "logs" "${SERVICE_NAME}")
if [ "${SERVICE_NAME:=false}" != "false" ]; then
    DOCKER_COMPOSE_LOGS=("${DOCKER_COMPOSE_LOGS[@]}" "${SERVICE_NAME}")
fi

if [ "${LOGS}" == "--logs" ]; then
    printf '%s\n' "Displaying logs output ..."
    printf '%s\n' "Running command: ${DOCKER_COMPOSE_LOGS[*]}"
    eval "${DOCKER_COMPOSE_LOGS[@]}"
    exit 0;
fi
#### END LOG ####

#### UP ####
DOCKER_COMPOSE_UP=("${DOCKER_COMPOSE_CONFIG}" "up" "${DOCKER_COMPOSE_UP_OPTIONS}")

DOCKER_COMPOSE=(
    "${DOCKER_COMPOSE_DOWN[@]}" "&&"
    "${DOCKER_COMPOSE_UP[@]}"
)

DOCKER_COMPOSE_PULL=("${DOCKER_COMPOSE_CONFIG}" "pull")

if [ "${PULL}" == "--pull" ]; then
    printf '%s\n' "Enforced pull of fresh images ..."
    DOCKER_COMPOSE=("${DOCKER_COMPOSE[@]:0:3}" "${DOCKER_COMPOSE_PULL[@]}" "&&" "${DOCKER_COMPOSE[@]:3}")
fi

if [ "${SERVICE_NAME:=false}" != "false" ]; then
    DOCKER_COMPOSE=("${DOCKER_COMPOSE[@]}" "${SERVICE_NAME}")
fi

printf '%s\n' "Running command: ${DOCKER_COMPOSE[*]}"

eval "${DOCKER_COMPOSE[@]}"
#### END UP ####

set +a
