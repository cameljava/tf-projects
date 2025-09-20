#!/bin/bash

INSTANCE_ID="i-0d393be06c9162476"

# Trigger the custom failover alarm
aws cloudwatch put-metric-data \
  --namespace "Custom/Test" \
  --metric-name "InstanceFailure" \
  --dimensions InstanceId=$INSTANCE_ID \
  --value 1

echo "Simulated failure metric pushed for $INSTANCE_ID"