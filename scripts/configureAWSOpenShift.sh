#!/bin/sh
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#################################################
# Run this script from the ansible-configserver #
#################################################

# The purpose of this script is to configure to fully integrate the OpenShift environment to allow OpenShift to provision AWS resources:
#  - Configure AWS IAM role to allow OpenShift to provision resources
#  - Re-configure OpenShift Masters and OpenShift Nodes to make OpenShift aware of AWS deployment specifics

# First check all required env variables have been defined
if [[ -z "$NESTEDOPENSHIFTSTACK_STACKNAME" || -z "$VPC_STACKNAME" || -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  echo "Must provide all following variables in environment. Example (substitute your own parameters!):

export NESTEDOPENSHIFTSTACK_STACKNAME=XXXXXXXXXXXXXXXXXXXXX
export VPC_STACKNAME=XXXXXXXXXXXXXXXXXXXXX
export AWS_ACCESS_KEY_ID=XXXXXXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=XXXXXXXXXXXXXXXXXXXXX

You can get the stack names e.g.: from the CloudFormation page of the AWS services console,
see the 'Overview' tab of the *nested* stack which includes your VPC or OpenShiftStack deployment.
You can get the access keys from the AWS services console IAM > Users > Security credentials.
  " 1>&2
  exit 1
fi
REGION=`curl -s http://instance-data/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'` # use current region

# Reconfigure AWS ('Setup') IAM Role created by OpenShift QuickStart - 
# adding the required AWS IAM policies to the ‘Setup Role’ (IAM) used by the RedHat QuickStart to deploy OpenShift to AWS.
# This IAM Role is also used by OpenShift to authenticate / authorize with AWS when OpenShift.
echo "Reconfiguring AWS ('Setup') IAM Role"
AWS_IAM_ROLE_NAME=`aws cloudformation describe-stack-resources --region $REGION --stack-name $NESTEDOPENSHIFTSTACK_STACKNAME --logical-resource-id SetupRole --query StackResources[0].PhysicalResourceId --output text`
if [[ -z "$AWS_IAM_ROLE_NAME" ]]; then
  echo "Couldn't identify the resource ID of the AWS ('Setup') IAM Role. Verify the required env variables are exported and valid:
NESTEDOPENSHIFTSTACK_STACKNAME, VPC_STACKNAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY" 1>&2
  exit 1
fi
declare -a POLICIES=("AmazonEC2FullAccess" "AWSLambdaFullAccess" "IAMFullAccess" "AmazonS3FullAccess" "AmazonVPCFullAccess" "AWSKeyManagementServicePowerUser" "AmazonRoute53FullAccess")
for policy in "${POLICIES[@]}"
do
  echo "Attaching IAM policy $policy to Role: ${AWS_IAM_ROLE_NAME=}"
  aws iam attach-role-policy --region $REGION --role-name ${AWS_IAM_ROLE_NAME} --policy-arn "arn:aws:iam::aws:policy/$policy"
done
echo

# Update OpenShift Nodes (EC2 instances)
echo "Updating OpenShift Nodes (EC2 instances)"
OPENSHIFT_NODES_LIST=`aws ec2 describe-instances --region $REGION --filters "Name=tag:aws:cloudformation:stack-name,Values=$NESTEDOPENSHIFTSTACK_STACKNAME" --filters Name="tag:Name",Values="*nodes*" --query Reservations[].Instances[].PrivateIpAddress | awk -F'"' '{print $2}' | paste -sd " " -`
if [[ -z "$OPENSHIFT_NODES_LIST" ]]; then
  echo "Couldn't identify OpenShift nodes list. Verify the required env variables are exported and valid:
NESTEDOPENSHIFTSTACK_STACKNAME, VPC_STACKNAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY" 1>&2
  exit 1
fi
for node in $OPENSHIFT_NODES_LIST
do
  sudo ssh $node bash -c "'
  echo \"AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY\" >> /etc/sysconfig/atomic-openshift-node
  # Depending on OpenShift version 10+ or lower... see https://docs.openshift.com/container-platform/v.vv/install_config/master_node_configuration.html
  if [ `oc version | grep oc | awk -F "." '{ print $2 }'` -gt 9 ] ; then
    systemctl restart atomic-openshift-node
  else
    systemctl restart atomic-openshift-node.service
  fi
  '"
  echo Configured node $node
done
echo

# Update OpenShift Masters (EC2 instances)
echo "Updating OpenShift Masters (EC2 instances)"
OPENSHIFT_MASTERS_LIST=`aws ec2 describe-instances --region $REGION --filters "Name=tag:aws:cloudformation:stack-name,Values=$NESTEDOPENSHIFTSTACK_STACKNAME" --filters Name="tag:Name",Values="*master*" --query Reservations[].Instances[].PrivateIpAddress | awk -F'"' '{print $2}' | paste -sd " " -`
if [[ -z "$OPENSHIFT_MASTERS_LIST" ]]; then
  echo "Couldn't identify OpenShift masters list. Verify the required env variables are exported and valid:
NESTEDOPENSHIFTSTACK_STACKNAME, VPC_STACKNAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY" 1>&2
  exit 1
fi
for node in $OPENSHIFT_MASTERS_LIST
do
  sudo ssh $node bash -c "'
  echo \"AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}  \" >> /etc/sysconfig/atomic-openshift-master
  echo \"AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}  \" >> /etc/sysconfig/atomic-openshift-master-api
  echo \"AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}  \" >> /etc/sysconfig/atomic-openshift-master-controllers
  # Depending on OpenShift version 10+ or lower... see https://docs.openshift.com/container-platform/v.vv/install_config/master_node_configuration.html
  if [ `oc version | grep oc | awk -F "." '{ print $2 }'` -gt 9 ] ; then
    master-restart api
    master-restart controllers
  else
    systemctl restart atomic-openshift-master-api atomic-openshift-master-controllers
  fi
  '"
  echo Configured master $node
done
echo

echo Configuration of OpenShift for AWS is complete.
echo 
echo Use one of the Masters listed above to proceed with a deployment.



