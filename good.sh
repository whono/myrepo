Content-Type: multipart/mixed; boundary="MIMEBOUNDARY"
MIME-Version: 1.0

--MIMEBOUNDARY
Content-Disposition: attachment; filename="chef_bootstrap.sh"
Content-Transfer-Encoding: 7bit
Content-Type: text/x-shellscript
Mime-Version: 1.0

#!/bin/bash -e

# First let's mark the instance as unhealthy since the app is not running yet

echo 'waiting for userdata to finish' > /etc/brcp/go-healthz-config.yml.unhealthy

#  Check the last exit status using a trap.  
#  As you can see below in the case statement, if exit status is 0 exit cleanly. 
#  If exit status is 35 exit so Chef can reboot.
#  If status is anything else write a file to disk to let br_healthz utility pick it up.

on_exit() {
    case $? in
    0)
        # Exiting Cleanly 
        # Now let's cleanup the unhealthy file we created at the begining
        rm /etc/brcp/go-healthz-config.yml.unhealthy
        CURL_OUTPUT="$(curl http://127.0.0.1:1234)"
        echo "CURL_OUTPUT="$CURL_OUTPUT
        # Signal Success after waiting up to 20m && echo 2023-03-17T18:07:43Z minutes for the Healthcheck URL to return 200
        better-cfn-signal -healthcheck-url http://127.0.0.1:1234 -healthcheck-timeout 20m && echo 2023-03-17T18:07:43Z
        ;;
    35)
        echo "Exiting due to Chef desired reboot"
        ;;
    *)
        better-cfn-signal -failure
        echo 'Userdata execution failed' | tee /etc/brcp/go-healthz-config.yml.unhealthy

    esac
}
trap "on_exit" EXIT
#########################################
   ########## VARS & INIT ############
#########################################

SDLC=dev
ACCOUNTENV=npd

#If SDLC is blank then set it based on the ACCOUNTEV

if [[ "$SDLC" -eq "" ]]; then SDLC=$ACCOUNTENV ; fi

echo "SDLC is "
echo ${SDLC}

CHEFNODE=gto-willow_nva1_dev
CHEFROLE=br_gtopmh_hlf_role

# shebang is prepended thru terraform
# required settings
if grep "release 6" /etc/redhat-release; then
  EL_MAJOR='6'
else
  EL_MAJOR='7'
fi

NODE_NAME="$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/instance-id)" # this uses the EC2 instance ID as the node name

# optional
CHEF_ORGANIZATION="broadridge"
NODE_ENVIRONMENT="gto-willow_nva1_dev"            # E.g. development, staging, onebox ...

# declare vars
AWS_CLI_URL=""
CHEF_INSTALLER=""
CHEF_BOOTSTRAP_ARN=""
JQ_LOCATION=""
CHEF_SERVER_FQDN=""

##############
#
#  Setting Chef vars
#

set_non_prod_vars () {
  AWS_CLI_URL="https://nexus.devops.broadridge.net/repository/3rdParty_RAW/awscli-bundle.zip"
  #note installer URL will have to change based on OS type and version
  CHEF_VERSION="17.7.29"
  CHEF_INSTALLER="https://nexus.devops.broadridge.net/repository/CHEF/files/stable/chef/${CHEF_VERSION}/el/${EL_MAJOR}/chef-${CHEF_VERSION}-1.el${EL_MAJOR}.x86_64.rpm"
  CHEF_BOOTSTRAP_ARN="arn:aws:iam::455269238913:role/chef-bootstrap"
  JQ_LOCATION="https://nexus.devops.broadridge.net/repository/3rdParty_RAW/jq_linux64"
  CHEF_SERVER_FQDN="https://chef.devops.broadridge.net" # The FQDN of your Chef Server
  RUBYGEMS_URL="https://nexus.devops.broadridge.net/repository/RubyGems.org"
  S3_BUCKET="br-ss-app-data"
}

set_prod_vars () {
  AWS_CLI_URL="https://nexus.devops.broadridge.net/repository/3rdParty_RAW/awscli-bundle.zip"
  #note installer URL will have to change based on OS type and version
  CHEF_VERSION="17.7.29"
  CHEF_INSTALLER="https://nexus.devops.broadridge.net/repository/CHEF/files/stable/chef/${CHEF_VERSION}/el/${EL_MAJOR}/chef-${CHEF_VERSION}-1.el${EL_MAJOR}.x86_64.rpm"
  CHEF_BOOTSTRAP_ARN="arn:aws:iam::481633605765:role/chef-bootstrap"
  JQ_LOCATION="https://nexus.devops.broadridge.net/repository/3rdParty_RAW/jq_linux64"
  CHEF_SERVER_FQDN="https://chef.devops.broadridge.net" # The FQDN of your Chef Server
  RUBYGEMS_URL="https://nexus.devops.broadridge.net/repository/RubyGems.org"
  S3_BUCKET="br-ss-chef-data"
}



# switch off the lowercase version of the SDLC env var we exported via Terraform

case "${SDLC,,}" in
    npd)
    set_non_prod_vars
    ;;
    prd)
    set_prod_vars
    ;;
    dev)
    set_non_prod_vars
    ;;
    int)
    set_non_prod_vars
    ;;
    qa)
    set_prod_vars
    ;;
    uat)
    set_prod_vars
    ;;
    *)
    echo "${SDLC} did not match any known value"
esac

echo "AWS_CLI_URL=${AWS_CLI_URL}"
echo "CHEF_INSTALLER=${CHEF_INSTALLER}"
echo "CHEF_BOOTSTRAP_ARN=${CHEF_BOOTSTRAP_ARN}"
echo "JQ_LOCATION=${JQ_LOCATION}"
echo "CHEF_SERVER_FQDN=${CHEF_SERVER_FQDN}"

# recommended: upload the chef-client cookbook from the chef supermarket  https://supermarket.chef.io/cookbooks/chef-client
# Use this to apply sensible default settings for your chef-client config like logrotate and running as a service
# you can add more cookbooks in the run list, based on your needs
RUN_LIST="recipe[${CHEFROLE}]"


# Make sure required variables are set correctly
VARS_OK=true

#Report on any errors
if !($VARS_OK) ; then
	echo "There was a problem with one or more variables"
	echo "See previous output for additional information"
fi



##############################################
  ########## METHODS & FUNCTIONS ###########
##############################################


install_chef_client() {
  echo "Installing chef client..."
  # see: https://docs.chef.io/install_omnibus.html
  rpm -Uvh $CHEF_INSTALLER || true
}

write_chef_config() {
  echo "Writing chef config..."
  (
    echo "chef_server_url   '${CHEF_SERVER_FQDN}/organizations/${CHEF_ORGANIZATION}'"
    echo "node_name         '${NODE_NAME}'"
    echo "validation_client_name         'broadridge-validator'"
    echo "log_location     '/var/log/chef-client.log'"
    echo "log_level        :info"
	echo "rubygems_url  	'${RUBYGEMS_URL}'"
  ) >> /etc/chef/client.rb
}

set_cli_role() {
  echo "Setting cli role..."
  curl -o jq_linux64 ${JQ_LOCATION}
  sudo cp jq_linux64 /usr/bin/jq
  sudo chmod +x /usr/bin/jq
  echo "assuming bootstrap role"
  ASSUMED_ROLE=$(aws sts assume-role --role-arn ${CHEF_BOOTSTRAP_ARN} --role-session-name bootstrap)
  echo "exporting accesskeyid"
  export AWS_ACCESS_KEY_ID=$(echo $ASSUMED_ROLE | jq .Credentials.AccessKeyId | xargs)
  echo "exporting secret accesskeyid"
  export AWS_SECRET_ACCESS_KEY=$(echo $ASSUMED_ROLE | jq .Credentials.SecretAccessKey | xargs)
  echo "exporting SessionToken"
  export AWS_SESSION_TOKEN=$(echo $ASSUMED_ROLE | jq .Credentials.SessionToken | xargs)
}
download_validator() {
  echo "downloading validator.pem from S3"
  aws s3 cp s3://${S3_BUCKET}/chef-bootstrap/broadridge-validator.pem /etc/chef/validation.pem
  sudo chmod 644 /etc/chef/validation.pem
}

cleanup_cli_role(){
  echo "Cleaning up..."
  rm -rf /usr/bin/jq
  unset AWS_SESSION_TOKEN
  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
}

########################################
   ########## MAIN SCRIPT ###########
########################################

install_chef_client
write_chef_config
set_cli_role
download_validator
cleanup_cli_role

if [ -z "${NODE_ENVIRONMENT}" ]; then
  echo "Running chef-client -r ${RUN_LIST} -L /var/log/chef_bootup.log"
  chef-client -r "${RUN_LIST}" -L "/var/log/chef_bootup.log"
else
  echo "Running chef-client -r ${RUN_LIST} -E ${NODE_ENVIRONMENT}"
  chef-client -r "${RUN_LIST}" -E "${NODE_ENVIRONMENT}"
fi

if [ -f "/etc/chef/validation.pem" ]; then
  echo "Removing validation pem ..."
  rm /etc/chef/validation.pem
fi


--MIMEBOUNDARY--
