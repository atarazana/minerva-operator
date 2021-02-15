export GO111MODULE=on

export APP_NAME=minerva
export OPERATOR_NAME=${APP_NAME}-operator
export OPERATOR_IMAGE=${OPERATOR_NAME}-image

export ORGANIZATION=atarazana
export DOMAIN=${ORGANIZATION}.com
export GROUP=apps
export API_VERSION=${APP_NAME}.${DOMAIN}/v1

export PROJECT_NAME=${OPERATOR_NAME}-system

export USERNAME=cvicens

# If you go back to 0.0.1 delete ./bundle !!!

# Comment for 0.0.2
export VERSION=0.0.1
# Uncomment for 0.0.2
#export FROM_VERSION=0.0.1
#export VERSION=0.0.2

# Channels
export CHANNELS=alpha,beta
export DEFAULT_CHANNEL=beta
